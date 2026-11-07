/*
  Gully Core

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://gullychain.xyz/core
  Docs:     https://docs.gullychain.xyz/core
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";

import {ILockedLaunchOracle} from "./interfaces/ILockedLaunchOracle.sol";

/// @notice The `getSlot0` of the concentrated-liquidity pool manager (third word: the pool's protocol fee).
interface ICLSlot0 {
    function getSlot0(PoolId id) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

/// @notice The `getSlot0` of the Bin pool manager (second word: the pool's protocol fee).
interface IBinSlot0 {
    function getSlot0(PoolId id) external view returns (uint24 activeId, uint24 protocolFee, uint24 lpFee);
}

/// @title GullyCoreProtocolFeeControllerV5
/// @notice The builder and partner fee (owner decision, 2026-11-05). Every pool that is not a locked launch
/// of a Gully Core kit pays ONE flat protocol fee on every trade: `builderFee()`, 3000 pips (0.30%) per
/// direction at deployment, inside core's cap of 4000 pips (0.40%). Locked launch pools of the kits in a
/// fixed set, and pools of hooks on the Safe-kept zero-fee list, are born at zero, exactly as under V4.
///
///     protocolFeeForPool(key) = isZeroFeeHook(key.hooks)
///                               || (any launchOracle_i).isLockedLaunch(key.toId()) == true
///                                   ? 0
///                                   : builderFee() in both directions
///
/// @dev WHY IT EXISTS. V4 asks `GullyCoreProtocolFeeControllerV2` for every non-launch fee. V2 takes a SHARE of
/// the pool's own fee (25%) on static-fee pools and a flat 999 pips on dynamic ones, so no setting of it gives
/// "0.30% of every trade" on every tier; and under V2 and V4 the owner can raise an existing pool's fee in one
/// transaction. V5 replaces the policy with one flat rate and makes every increase wait.
///
/// THE RULE FOR EVERY CHANGE: DOWN AT ONCE, UP AFTER NOTICE.
///   - `setBuilderFee(lower)` applies at once and cancels a pending increase. `setBuilderFee(higher)` only
///     schedules it: it takes effect by itself `FEE_RAISE_NOTICE` (7 days) later, never above
///     `MAX_PROTOCOL_FEE`. Scheduling again replaces the pending value and restarts the notice.
///   - Core stores a pool's fee when the pool is created, so `builderFee()` prices NEW pools. An existing pool
///     is moved one at a time: `setPoolProtocolFee` applies at once when neither direction goes up and reverts
///     otherwise; an increase goes through `schedulePoolFeeRaise`, then `executePoolFeeRaise` once the notice has
///     passed. `syncPoolToPolicy` follows the same rule.
///   - There is no kill switch and no guardian: the Safe lowers the fee to zero at once with `setBuilderFee(0)`,
///     and coming back from zero is an increase like any other.
///
/// WHAT IT KEEPS FROM V4, UNCHANGED IN BEHAVIOUR: the immutable launch-oracle set and its bounded, per-call
/// gas-floored staticcall (a pool is a locked launch only when an oracle answers exactly `true` in 32 bytes);
/// no `launchOracle()` getter (a kit reads `isLaunchOracle`); the zero-fee hook list (added at once, removed
/// after `ZERO_FEE_HOOK_REMOVAL_NOTICE`); `collect`, the permissionless `sweep` to the immutable `treasury`,
/// `accrued`, `rescueERC20`; `Ownable2Step` with `renounceOwnership` reverting. No `receive`, no `fallback`,
/// no `delegatecall`, no `selfdestruct`. It holds no funds: fees sit in the pool managers until collected.
///
/// HOT PATH. Core staticcalls `protocolFeeForPool` inside every pool creation and pool creation reverts if it
/// reverts. The only revert here is the one V4 has: `InsufficientGasForLaunchCheck`, which fails the caller's
/// own pool creation and can never resolve a fee for a pool an oracle vouches for. The flat rate is read
/// first; when it is zero nobody is asked.
///
/// THE TWO POOL MANAGERS ARE IMMUTABLE. To tell a decrease from an increase the controller reads the pool's
/// fee in force from the manager, and the CL and Bin managers return it in different places of `getSlot0`.
/// Both addresses are fixed at construction; every per-pool call refuses any other address.
///
/// OWNERSHIP: the governance Safe, which is also `treasury`, the only place fees can be sent by `sweep`.
contract GullyCoreProtocolFeeControllerV5 is IProtocolFeeController, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    /// @notice Hard cap enforced by core (`ProtocolFeeLibrary.MAX_PROTOCOL_FEE`): 0.4% per direction.
    uint16 public constant MAX_PROTOCOL_FEE = 4000;

    /// @notice How long every increase waits, for new pools and for an existing pool alike.
    uint32 public constant FEE_RAISE_NOTICE = 7 days;

    /// @notice The most oracles one controller can name. Bounds the hot path's worst-case gas.
    uint256 public constant MAX_LAUNCH_ORACLES = 4;

    /// @notice Gas forwarded to each `isLockedLaunch` call. A plain storage read needs ~2.5k.
    uint256 public constant LAUNCH_ORACLE_GAS = 50_000;

    /// @notice Minimum `gasleft()` before EACH oracle call: the stipend, the 1/64 EIP-150 retains, and
    /// headroom for a cold account access. Below it the call could receive less than the stipend.
    uint256 public constant LAUNCH_ORACLE_MIN_GASLEFT = LAUNCH_ORACLE_GAS + LAUNCH_ORACLE_GAS / 63 + 5_000;

    uint32 public constant MIN_ZERO_FEE_HOOK_REMOVAL_NOTICE = 1 days;
    uint32 public constant MAX_ZERO_FEE_HOOK_REMOVAL_NOTICE = 90 days;

    /// @notice The concentrated-liquidity pool manager this controller prices.
    address public immutable clPoolManager;
    /// @notice The Bin pool manager this controller prices.
    address public immutable binPoolManager;

    uint256 public immutable launchOracleCount;
    address public immutable launchOracle0;
    address public immutable launchOracle1;
    address public immutable launchOracle2;
    address public immutable launchOracle3;

    /// @notice Notice before a hook leaves the zero-fee list (removal raises the fee on its NEW pools).
    uint32 public immutable ZERO_FEE_HOOK_REMOVAL_NOTICE;

    /// @notice Where `sweep` sends collected fees: the governance Safe this controller was deployed for.
    address public immutable treasury;

    /// @dev One slot: the rate in force, a scheduled higher rate and when it starts.
    uint16 private _builderFee;
    uint16 private _pendingBuilderFee;
    uint40 private _pendingBuilderFeeAt;

    struct ZeroFeeHook {
        bool listed;
        uint40 removalAt;
    }

    mapping(address hook => ZeroFeeHook) private _zeroFeeHooks;

    struct PendingRaise {
        uint24 fee; // packed as core expects: low 12 bits zeroForOne, next 12 oneForZero
        uint40 executableAt;
    }

    mapping(address poolManager => mapping(PoolId => PendingRaise)) private _pendingRaise;

    event BuilderFeeChanged(uint16 previousFee, uint16 newFee);
    event BuilderFeeIncreaseScheduled(uint16 currentFee, uint16 newFee, uint40 effectiveAt);
    event BuilderFeeIncreaseCancelled(uint16 cancelledFee, uint40 effectiveAt);
    event PoolFeeChanged(address indexed poolManager, PoolId indexed poolId, uint24 previousFee, uint24 newFee);
    event PoolFeeRaiseScheduled(address indexed poolManager, PoolId indexed poolId, uint24 currentFee, uint24 newFee, uint40 executableAt);
    event PoolFeeRaiseCancelled(address indexed poolManager, PoolId indexed poolId, uint24 cancelledFee);
    event ZeroFeeHookAdded(address indexed hook);
    event ZeroFeeHookRemovalScheduled(address indexed hook, uint40 removalAt);
    event ZeroFeeHookRemovalCancelled(address indexed hook);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ProtocolFeesCollected(
        address indexed poolManager, Currency indexed currency, address indexed recipient, uint256 amount
    );

    error ZeroAddress();
    error NoCode(address account);
    error NoLaunchOracles();
    error TooManyLaunchOracles(uint256 count, uint256 maximum);
    error ZeroLaunchOracle(uint256 index);
    error DuplicateLaunchOracle(address launchOracle);
    error OracleDoesNotImplementInterface(address launchOracle);
    error InvalidPoolManagers(address clPoolManager, address binPoolManager);
    error InsufficientGasForLaunchCheck(uint256 available, uint256 required);
    error ZeroRecipient();
    error RenounceDisabled();
    error NothingToCollect(address poolManager, Currency currency);
    error LockedLaunchPoolKeepsZeroFee(PoolId poolId);
    error NothingToRescue(address token);
    error RescueToZero();
    error InvalidRemovalNotice(uint256 notice);
    error AlreadyZeroFeeHook(address hook);
    error NotZeroFeeHook(address hook);
    error NoPendingRemoval(address hook);
    error InvalidZeroFeeHook(address hook);
    error ZeroFeeHookPoolKeepsZeroFee(PoolId poolId, address hook);
    /// @notice A fee above core's cap of 4000 pips in one direction.
    error FeeExceedsMaximum(uint24 fee, uint16 maximum);
    /// @notice Not one of the two pool managers this controller was built for.
    error UnknownPoolManager(address poolManager);
    /// @notice The new fee is higher than the pool's fee in force in at least one direction: schedule it.
    error RaiseNeedsNotice(uint24 currentFee, uint24 newFee);
    /// @notice `schedulePoolFeeRaise` was given a fee that raises nothing: use `setPoolProtocolFee`.
    error NotARaise(uint24 currentFee, uint24 newFee);
    error NoPendingRaise(address poolManager, PoolId poolId);
    error RaiseNotYetExecutable(uint40 executableAt);
    error NoPendingBuilderFee();

    /// @param owner_ The governance Safe; also the immutable `treasury`.
    /// @param clPoolManager_ The CL pool manager. Must have code.
    /// @param binPoolManager_ The Bin pool manager. Must have code and differ from the CL one.
    /// @param builderFee_ The flat fee of every non-launch pool at deployment, in pips per direction (3000).
    /// @param launchOracles_ One to four Gully Core kits whose locked launch pools are born at zero.
    /// @param zeroFeeHooks_ Hooks listed from the first block (may have no code yet: a mined address).
    /// @param zeroFeeHookRemovalNotice_ Notice before a hook leaves the list, 1 to 90 days.
    constructor(
        address owner_,
        address clPoolManager_,
        address binPoolManager_,
        uint16 builderFee_,
        address[] memory launchOracles_,
        address[] memory zeroFeeHooks_,
        uint32 zeroFeeHookRemovalNotice_
    ) Ownable(owner_) {
        if (clPoolManager_ == address(0) || binPoolManager_ == address(0)) revert ZeroAddress();
        if (clPoolManager_ == binPoolManager_) revert InvalidPoolManagers(clPoolManager_, binPoolManager_);
        if (clPoolManager_.code.length == 0) revert NoCode(clPoolManager_);
        if (binPoolManager_.code.length == 0) revert NoCode(binPoolManager_);
        clPoolManager = clPoolManager_;
        binPoolManager = binPoolManager_;

        if (builderFee_ > MAX_PROTOCOL_FEE) revert FeeExceedsMaximum(builderFee_, MAX_PROTOCOL_FEE);
        _builderFee = builderFee_;
        emit BuilderFeeChanged(0, builderFee_);

        uint256 count = launchOracles_.length;
        if (count == 0) revert NoLaunchOracles();
        if (count > MAX_LAUNCH_ORACLES) revert TooManyLaunchOracles(count, MAX_LAUNCH_ORACLES);
        for (uint256 i; i < count; ++i) {
            address oracle = launchOracles_[i];
            if (oracle == address(0)) revert ZeroLaunchOracle(i);
            if (oracle.code.length == 0) revert NoCode(oracle);
            if (oracle == clPoolManager_ || oracle == binPoolManager_) revert InvalidPoolManagers(clPoolManager_, binPoolManager_);
            for (uint256 j; j < i; ++j) {
                if (launchOracles_[j] == oracle) revert DuplicateLaunchOracle(oracle);
            }
            /* A contract that cannot answer `isLockedLaunch` would be a zero rule that silently never
               fires. No real pool has id 0, so an honest kit answers `false`. */
            (bool ok, uint256 word) = _askOracle(oracle, bytes32(0));
            if (!ok || word != 0) revert OracleDoesNotImplementInterface(oracle);
        }
        launchOracleCount = count;
        launchOracle0 = launchOracles_[0];
        launchOracle1 = count > 1 ? launchOracles_[1] : address(0);
        launchOracle2 = count > 2 ? launchOracles_[2] : address(0);
        launchOracle3 = count > 3 ? launchOracles_[3] : address(0);

        if (
            zeroFeeHookRemovalNotice_ < MIN_ZERO_FEE_HOOK_REMOVAL_NOTICE
                || zeroFeeHookRemovalNotice_ > MAX_ZERO_FEE_HOOK_REMOVAL_NOTICE
        ) revert InvalidRemovalNotice(zeroFeeHookRemovalNotice_);
        ZERO_FEE_HOOK_REMOVAL_NOTICE = zeroFeeHookRemovalNotice_;

        treasury = owner_;
        emit TreasuryUpdated(address(0), owner_);

        for (uint256 i; i < zeroFeeHooks_.length; ++i) {
            address hook = zeroFeeHooks_[i];
            if (hook == clPoolManager_ || hook == binPoolManager_) revert InvalidZeroFeeHook(hook);
            for (uint256 j; j < count; ++j) {
                if (launchOracles_[j] == hook) revert InvalidZeroFeeHook(hook);
            }
            _listZeroFeeHook(hook);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    HOT PATH - CALLED DURING POOL INIT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IProtocolFeeController
    function protocolFeeForPool(PoolKey memory poolKey) external view override returns (uint24) {
        return _resolve(poolKey);
    }

    /// @notice Whether any kit in the set vouches for `poolId` as a locked launch.
    function isLockedLaunchPool(PoolId poolId) external view returns (bool) {
        return _isLockedLaunch(PoolId.unwrap(poolId));
    }

    function _resolve(PoolKey memory poolKey) private view returns (uint24) {
        uint16 fee = builderFee();
        if (fee == 0) return 0;
        if (_isZeroFeeHook(address(poolKey.hooks))) return 0;
        if (_isLockedLaunch(PoolId.unwrap(poolKey.toId()))) return 0;
        return _pack(fee, fee);
    }

    function _pack(uint16 zeroForOne, uint16 oneForZero) private pure returns (uint24) {
        return uint24(zeroForOne) | (uint24(oneForZero) << 12);
    }

    function _isZeroFeeHook(address hook) private view returns (bool) {
        ZeroFeeHook memory z = _zeroFeeHooks[hook];
        return z.listed && (z.removalAt == 0 || block.timestamp < z.removalAt);
    }

    function _isLockedLaunch(bytes32 poolId) private view returns (bool) {
        uint256 count = launchOracleCount;
        for (uint256 i; i < count; ++i) {
            if (_vouches(_launchOracleAt(i), poolId)) return true;
        }
        return false;
    }

    function _vouches(address oracle, bytes32 poolId) private view returns (bool) {
        uint256 available = gasleft();
        if (available < LAUNCH_ORACLE_MIN_GASLEFT) {
            revert InsufficientGasForLaunchCheck(available, LAUNCH_ORACLE_MIN_GASLEFT);
        }
        (bool ok, uint256 word) = _askOracle(oracle, poolId);
        /* Exactly `true`: a failed call, a short or long answer, or any other word is "no". An oracle
           that misbehaves must never be the one that waives revenue. */
        return ok && word == 1;
    }

    function _askOracle(address oracle, bytes32 poolId) private view returns (bool ok, uint256 word) {
        bytes4 selector = ILockedLaunchOracle.isLockedLaunch.selector;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, poolId)
            ok := staticcall(LAUNCH_ORACLE_GAS, oracle, 0x00, 0x24, 0x00, 0x20)
            word := mload(0x00)
            ok := and(ok, eq(returndatasize(), 0x20))
        }
    }

    function _launchOracleAt(uint256 index) private view returns (address) {
        if (index == 0) return launchOracle0;
        if (index == 1) return launchOracle1;
        if (index == 2) return launchOracle2;
        return launchOracle3;
    }

    /*//////////////////////////////////////////////////////////////
                     THE FLAT RATE - NEW POOLS
    //////////////////////////////////////////////////////////////*/

    /// @notice The flat protocol fee a new non-launch pool is born with, in pips per direction.
    /// @dev A scheduled increase counts from its `effectiveAt` without any further transaction.
    function builderFee() public view returns (uint16) {
        uint40 at = _pendingBuilderFeeAt;
        if (at != 0 && block.timestamp >= at) return _pendingBuilderFee;
        return _builderFee;
    }

    /// @notice A scheduled increase that has not started yet: `(0, 0)` when there is none.
    function pendingBuilderFee() external view returns (uint16 fee, uint40 effectiveAt) {
        effectiveAt = _pendingBuilderFeeAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        fee = _pendingBuilderFee;
    }

    /// @notice Set the flat fee for pools created from now on. A value at or below the fee in force applies
    /// at once and cancels a pending increase; a higher one starts `FEE_RAISE_NOTICE` later.
    function setBuilderFee(uint16 newFee) external onlyOwner {
        if (newFee > MAX_PROTOCOL_FEE) revert FeeExceedsMaximum(newFee, MAX_PROTOCOL_FEE);
        uint16 current = _rollBuilderFee();
        if (newFee <= current) {
            _clearPendingBuilderFee();
            _builderFee = newFee;
            emit BuilderFeeChanged(current, newFee);
        } else {
            uint40 effectiveAt = uint40(block.timestamp) + FEE_RAISE_NOTICE;
            _pendingBuilderFee = newFee;
            _pendingBuilderFeeAt = effectiveAt;
            emit BuilderFeeIncreaseScheduled(current, newFee, effectiveAt);
        }
    }

    /// @notice Withdraw a scheduled increase before it starts.
    function cancelPendingBuilderFee() external onlyOwner {
        _rollBuilderFee();
        if (_pendingBuilderFeeAt == 0) revert NoPendingBuilderFee();
        _clearPendingBuilderFee();
    }

    /// @dev Write a matured increase into `_builderFee`, so "the fee in force" is one stored number.
    function _rollBuilderFee() private returns (uint16 current) {
        uint40 at = _pendingBuilderFeeAt;
        current = _builderFee;
        if (at != 0 && block.timestamp >= at) {
            uint16 next = _pendingBuilderFee;
            _builderFee = next;
            _pendingBuilderFee = 0;
            _pendingBuilderFeeAt = 0;
            emit BuilderFeeChanged(current, next);
            current = next;
        }
    }

    function _clearPendingBuilderFee() private {
        uint40 at = _pendingBuilderFeeAt;
        if (at == 0) return;
        emit BuilderFeeIncreaseCancelled(_pendingBuilderFee, at);
        _pendingBuilderFee = 0;
        _pendingBuilderFeeAt = 0;
    }

    /*//////////////////////////////////////////////////////////////
                         THE ORACLE SET - READ ONLY
    //////////////////////////////////////////////////////////////*/

    function launchOracles() external view returns (address[] memory oracles) {
        uint256 count = launchOracleCount;
        oracles = new address[](count);
        for (uint256 i; i < count; ++i) {
            oracles[i] = _launchOracleAt(i);
        }
    }

    function isLaunchOracle(address candidate) external view returns (bool) {
        return _isLaunchOracle(candidate);
    }

    function _isLaunchOracle(address candidate) private view returns (bool) {
        if (candidate == address(0)) return false;
        return candidate == launchOracle0 || candidate == launchOracle1 || candidate == launchOracle2
            || candidate == launchOracle3;
    }

    /*//////////////////////////////////////////////////////////////
                           ZERO-FEE HOOKS
    //////////////////////////////////////////////////////////////*/

    function isZeroFeeHook(address hook) external view returns (bool) {
        return _isZeroFeeHook(hook);
    }

    function zeroFeeHook(address hook) external view returns (bool listed, uint40 removalAt) {
        ZeroFeeHook memory z = _zeroFeeHooks[hook];
        return (z.listed, z.removalAt);
    }

    /// @notice List a hook whose pools are born at zero. At once: it only lowers fees.
    function addZeroFeeHook(address hook) external onlyOwner {
        if (hook == clPoolManager || hook == binPoolManager || _isLaunchOracle(hook)) revert InvalidZeroFeeHook(hook);
        if (hook == address(0)) revert ZeroAddress();
        if (hook.code.length == 0) revert NoCode(hook);
        _listZeroFeeHook(hook);
    }

    /// @notice Announce that a hook leaves the list after `ZERO_FEE_HOOK_REMOVAL_NOTICE`.
    function scheduleZeroFeeHookRemoval(address hook) external onlyOwner {
        ZeroFeeHook storage z = _zeroFeeHooks[hook];
        if (!z.listed || z.removalAt != 0) revert NotZeroFeeHook(hook);
        uint40 removalAt = uint40(block.timestamp) + ZERO_FEE_HOOK_REMOVAL_NOTICE;
        z.removalAt = removalAt;
        emit ZeroFeeHookRemovalScheduled(hook, removalAt);
    }

    function cancelZeroFeeHookRemoval(address hook) external onlyOwner {
        ZeroFeeHook storage z = _zeroFeeHooks[hook];
        if (!z.listed || z.removalAt == 0 || block.timestamp >= z.removalAt) revert NoPendingRemoval(hook);
        z.removalAt = 0;
        emit ZeroFeeHookRemovalCancelled(hook);
    }

    function _listZeroFeeHook(address hook) private {
        if (hook == address(0)) revert ZeroAddress();
        ZeroFeeHook storage z = _zeroFeeHooks[hook];
        if (z.listed && z.removalAt == 0) revert AlreadyZeroFeeHook(hook);
        z.listed = true;
        z.removalAt = 0;
        emit ZeroFeeHookAdded(hook);
    }

    /*//////////////////////////////////////////////////////////////
                    AN EXISTING POOL - DOWN AT ONCE, UP AFTER NOTICE
    //////////////////////////////////////////////////////////////*/

    /// @notice The protocol fee in force on a pool, packed as core stores it.
    function poolProtocolFee(address poolManager, PoolId poolId) public view returns (uint24 fee) {
        if (poolManager == clPoolManager) {
            (,, fee,) = ICLSlot0(poolManager).getSlot0(poolId);
        } else if (poolManager == binPoolManager) {
            (, fee,) = IBinSlot0(poolManager).getSlot0(poolId);
        } else {
            revert UnknownPoolManager(poolManager);
        }
    }

    /// @notice A scheduled increase on one pool: `(0, 0)` when there is none.
    function pendingPoolFeeRaise(address poolManager, PoolId poolId) external view returns (uint24 fee, uint40 executableAt) {
        PendingRaise memory p = _pendingRaise[poolManager][poolId];
        return (p.fee, p.executableAt);
    }

    /// @notice Lower an existing pool's protocol fee, at once. Reverts `RaiseNeedsNotice` when either
    /// direction would go up. A decrease also withdraws a pending increase on that pool.
    /// @param newProtocolFee Packed: low 12 bits zeroForOne, next 12 oneForZero (`packFee`).
    function setPoolProtocolFee(address poolManager, PoolKey calldata key, uint24 newProtocolFee) external onlyOwner {
        _validatePacked(newProtocolFee);
        PoolId id = key.toId();
        uint24 current = poolProtocolFee(poolManager, id);
        if (_raises(current, newProtocolFee)) revert RaiseNeedsNotice(current, newProtocolFee);
        _cancelRaise(poolManager, id);
        IProtocolFees(poolManager).setProtocolFee(key, newProtocolFee);
        emit PoolFeeChanged(poolManager, id, current, newProtocolFee);
    }

    /// @notice Announce an increase on one existing pool. It can be executed `FEE_RAISE_NOTICE` later.
    /// Scheduling again replaces the pending value and restarts the notice.
    function schedulePoolFeeRaise(address poolManager, PoolKey calldata key, uint24 newProtocolFee) external onlyOwner {
        _validatePacked(newProtocolFee);
        PoolId id = key.toId();
        _refuseZeroRulePool(key, id);
        uint24 current = poolProtocolFee(poolManager, id);
        if (!_raises(current, newProtocolFee)) revert NotARaise(current, newProtocolFee);
        uint40 executableAt = uint40(block.timestamp) + FEE_RAISE_NOTICE;
        _pendingRaise[poolManager][id] = PendingRaise({fee: newProtocolFee, executableAt: executableAt});
        emit PoolFeeRaiseScheduled(poolManager, id, current, newProtocolFee, executableAt);
    }

    /// @notice Apply an announced increase once its notice has passed.
    function executePoolFeeRaise(address poolManager, PoolKey calldata key) external onlyOwner {
        PoolId id = key.toId();
        PendingRaise memory p = _pendingRaise[poolManager][id];
        if (p.executableAt == 0) revert NoPendingRaise(poolManager, id);
        if (block.timestamp < p.executableAt) revert RaiseNotYetExecutable(p.executableAt);
        _refuseZeroRulePool(key, id);
        uint24 current = poolProtocolFee(poolManager, id);
        delete _pendingRaise[poolManager][id];
        IProtocolFees(poolManager).setProtocolFee(key, p.fee);
        emit PoolFeeChanged(poolManager, id, current, p.fee);
    }

    /// @notice Withdraw an announced increase on one pool.
    function cancelPoolFeeRaise(address poolManager, PoolKey calldata key) external onlyOwner {
        PoolId id = key.toId();
        if (_pendingRaise[poolManager][id].executableAt == 0) revert NoPendingRaise(poolManager, id);
        _cancelRaise(poolManager, id);
    }

    /// @notice Bring an existing pool to what a new pool with this key would be born with, when that is
    /// not an increase. An increase reverts `RaiseNeedsNotice`: schedule it.
    function syncPoolToPolicy(address poolManager, PoolKey calldata key) external onlyOwner returns (uint24 applied) {
        applied = _resolve(key);
        PoolId id = key.toId();
        uint24 current = poolProtocolFee(poolManager, id);
        if (_raises(current, applied)) revert RaiseNeedsNotice(current, applied);
        _cancelRaise(poolManager, id);
        IProtocolFees(poolManager).setProtocolFee(key, applied);
        emit PoolFeeChanged(poolManager, id, current, applied);
    }

    /// @notice Pack two directional fees the way core expects. Reverts above the cap.
    function packFee(uint16 zeroForOne, uint16 oneForZero) external pure returns (uint24) {
        if (zeroForOne > MAX_PROTOCOL_FEE) revert FeeExceedsMaximum(zeroForOne, MAX_PROTOCOL_FEE);
        if (oneForZero > MAX_PROTOCOL_FEE) revert FeeExceedsMaximum(oneForZero, MAX_PROTOCOL_FEE);
        return _pack(zeroForOne, oneForZero);
    }

    /// @dev True when `next` is higher than `current` in at least one direction.
    function _raises(uint24 current, uint24 next) private pure returns (bool) {
        return (next & 0xfff) > (current & 0xfff) || (next >> 12) > (current >> 12);
    }

    function _validatePacked(uint24 fee) private pure {
        if ((fee & 0xfff) > MAX_PROTOCOL_FEE || (fee >> 12) > MAX_PROTOCOL_FEE) revert FeeExceedsMaximum(fee, MAX_PROTOCOL_FEE);
    }

    /// @dev A locked launch pool and a pool of a listed hook keep their zero: no increase can be announced
    /// or executed on them.
    function _refuseZeroRulePool(PoolKey calldata key, PoolId id) private view {
        if (_isZeroFeeHook(address(key.hooks))) revert ZeroFeeHookPoolKeepsZeroFee(id, address(key.hooks));
        if (_isLockedLaunch(PoolId.unwrap(id))) revert LockedLaunchPoolKeepsZeroFee(id);
    }

    function _cancelRaise(address poolManager, PoolId id) private {
        PendingRaise memory p = _pendingRaise[poolManager][id];
        if (p.executableAt == 0) return;
        delete _pendingRaise[poolManager][id];
        emit PoolFeeRaiseCancelled(poolManager, id, p.fee);
    }

    /*//////////////////////////////////////////////////////////////
                              COLLECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw accrued protocol fees from a pool manager to `recipient`. Owner only.
    /// @param amount Pass `0` for the whole accrued balance.
    function collect(address poolManager, Currency currency, uint256 amount, address recipient)
        external
        onlyOwner
        returns (uint256 amountCollected)
    {
        if (recipient == address(0)) revert ZeroRecipient();
        amountCollected = IProtocolFees(poolManager).collectProtocolFees(recipient, currency, amount);
        emit ProtocolFeesCollected(poolManager, currency, recipient, amountCollected);
    }

    /// @notice Send everything accrued in `currency` to `treasury`. Permissionless: the destination is
    /// immutable, so a caller can only pay gas to move the protocol's fees to the governance Safe.
    /// Reverts when there is nothing to collect.
    function sweep(address poolManager, Currency currency) external returns (uint256 amountCollected) {
        address to = treasury;
        if (IProtocolFees(poolManager).protocolFeesAccrued(currency) == 0) {
            revert NothingToCollect(poolManager, currency);
        }
        amountCollected = IProtocolFees(poolManager).collectProtocolFees(to, currency, 0);
        emit ProtocolFeesCollected(poolManager, currency, to, amountCollected);
    }

    /// @notice How much is waiting to be collected.
    function accrued(address poolManager, Currency currency) external view returns (uint256) {
        return IProtocolFees(poolManager).protocolFeesAccrued(currency);
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`. This contract holds no funds of its own.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /// @notice Disabled: an unowned controller could never collect.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
