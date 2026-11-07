/*
  Gully Core

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://gullychain.xyz/core
  Docs:     https://docs.gullychain.xyz/core
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {IBinFungibleToken} from "infinity-periphery/src/pool-bin/interfaces/IBinFungibleToken.sol";
import {IImmutableState} from "infinity-periphery/src/interfaces/IImmutableState.sol";
import {Permit2Forwarder} from "infinity-periphery/src/base/Permit2Forwarder.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LaunchGuardHook} from "gullycore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "gullycore-hooks/src/launch/BinLaunchGuardHook.sol";
import {LaunchTaxModule} from "gullycore-hooks/src/launch/LaunchTaxModule.sol";
import {IGullyCoreLaunchOrigin} from "gullycore-registry/src/IGullyCoreLaunchOrigin.sol";
import {LaunchpadMetadata} from "gullycore-registry/src/IGullyCoreLaunchRegistry.sol";
import {ILockedLaunchOracle} from "gullycore-fees/src/interfaces/ILockedLaunchOracle.sol";

import {GullyCoreLPLocker} from "./GullyCoreLPLocker.sol";
import {GullyCoreBinLPLocker} from "./GullyCoreBinLPLocker.sol";
import {LockParams} from "./interfaces/IGullyCoreLPLocker.sol";
import {ILaunchTokenFactory} from "./interfaces/ILaunchTokenFactory.sol";
import {ILaunchRegistryWriter} from "./interfaces/ILaunchRegistryWriter.sol";
import {
    ILaunchpadKitV2,
    LegKind,
    BinShape,
    LegParams,
    ScheduleParams,
    TaxParams,
    LaunchParamsV2,
    LaunchResultV2,
    LegRecord,
    LaunchRecordV2,
    TenantConfig
} from "./interfaces/ILaunchpadKitV2.sol";
import {LaunchPresets, Preset, PresetParams} from "./libraries/LaunchPresets.sol";
import {LaunchLegs} from "./libraries/LaunchLegs.sol";
import {LaunchPolicy} from "./libraries/LaunchPolicy.sol";

/// @title LaunchpadKitV2
/// @notice One transaction: a fresh launch token, 1..N LOCKED pools (single-sided CL ranges and/or shaped
/// Bin distributions) each quoted in native or any ERC-20, a launch guard on every pool, a registry record
/// per pool, and the protocol and tenant launch fees. Launch pools are born at a ZERO core protocol fee
/// through `GullyCoreProtocolFeeControllerV3`, which asks this contract `isLockedLaunch(poolId)`.
///
/// @dev Design of record: `docs/kit-v2-integration.md`, section "Kit v2 (implemented)". The load-bearing
/// properties, each tied to where it is enforced:
///
/// ########################## 1. THE V3 FLAG (the one promise V3 trusts) ##########################
///
///   `_gullyLaunch[poolId] = true` is written for EVERY leg in the checks-and-effects phase of
///   `createLaunch`, before the kit makes any external call at all (the token address is computed locally
///   from the factory's CREATE2 inputs precisely so this holds). Core reads the protocol fee once, inside
///   `initialize`, so the flag must already be there. It is written in exactly one place, never cleared,
///   and never touched by the owner, by `reconfigureLaunch`, or by any other path.
///
///   Every flagged leg is then initialized, seeded, and LOCKED in the same call, and the lock is read back
///   and asserted (`LockNotRecorded`). There is no try/catch in this contract or in `LaunchLegs`. So a flag
///   can only survive in a transaction whose lock was proven, and a failed lock reverts the flag with the pool.
///
///   The CHECKS that need no flag (shape, terms, fees, schedule, tax) live in a second linked library,
///   `LaunchPolicy`, reached by one DELEGATECALL BEFORE the flags: it is `view`, it runs in this contract's
///   context and it calls nobody (release 3: the release-2 kit was 20 bytes under EIP-170, so the terms
///   logic had to live outside it).
///
///   The interaction phase lives in the linked library `LaunchLegs`, reached by one DELEGATECALL after every
///   flag is written: the kit in one piece measured 42.9 KB against EIP-170's 24,576 bytes. The library runs
///   in the kit's context (every call it makes is FROM the kit), has no storage, no owner and no upgrade path,
///   and its address is fixed in this contract's bytecode at link time.
///
///   Both leg types are flagged, because both are locked. The V3 doc's "never flag Bin legs" predates
///   `GullyCoreBinLPLocker`; the rule it encodes is "never flag an UNLOCKED leg", and v2 has no unlocked legs.
///   A Bin leg is flagged only because it is locked through `GullyCoreBinLPLocker` with the kit holding zero
///   of every seeded bin's shares afterwards (`KitRetainedBinShares`).
///
/// ################################# 2. SQUATTING #################################
///
///   * Token address: the factory salt is `keccak256(abi.encode(msg.sender, userSalt))`, so a launcher
///     cannot land on another launcher's mined address through the kit's shared factory namespace.
///   * Pool ids: both guards reserve pools on factory tokens for `deployerOf(token)` - this kit - and
///     refuse any claim on a currency with no code, and the token only gains code inside this call.
///
/// ################################# 3. FEES #################################
///
///   * Owner = the governance Safe (`Ownable2Step`; `renounceOwnership` reverts). Its ONLY power is the
///     protocol launch fee, inside the immutable `maxLaunchFeeWei`. Increases take effect automatically
///     `launchFeeNoticeSeconds` after they are announced; decreases are immediate; nothing is retroactive
///     (a launch pays the fee in force in its own block, and nothing about a launch reads it again).
///   * The tenant's integrator launch fee is capped by the immutable `maxIntegratorLaunchFeeWei`.
///   * Both are PULL-credited (`feesOwed`), never pushed during a launch: a recipient that cannot receive
///     native currency cannot block anybody's launch. `flushProtocolFees` is permissionless and can only
///     pay the immutable `protocolFeeRecipient`.
///   * `msg.value` below the total reverts; any excess is refunded to `msg.sender`, last.
///
/// ############################## 4. WHAT IT DOES NOT DO ##############################
///
///   * Custody between transactions. The kit ends every launch holding zero launch token (asserted) and
///     zero bin shares (asserted); its only resting balance is native owed to fee recipients.
///   * Touch the quote currency. A single-sided launch never transfers the quote, so a paused, blocklisted
///     or rebasing quote (a Robinhood stock token) cannot block or skew creation. It can block TRADING.
///   * Protect a launch against the tenant's own hook fee - launches use Gully Core's guards only. Those take
///     the trade fee themselves, in the quote, split by the lock's split (which the kit's library writes
///     into the guard) under the guards' own protocol floor, the same 20% the lockers carry.
///   * Enforce the creator tax's floor. `LaunchParamsV2.tax` is passed through to the guards' `configureTax`
///     with the recipients resolved (`creator`, `integrator`); the GUARD validates rates, expiry, the 10%
///     protocol floor and the 20% integrator cap, because anyone can configure a pool there without this
///     kit. The kit adds only tenant policy (`maxTaxBps`, a restated `taxIntegratorBps`) and asserts at
///     construction that both guards pay the same `protocolFeeRecipient` this kit does.
///   * Stop a sequencer from moving `block.timestamp` inside Nitro's bounds (see `LaunchGuardHook` CLOCK).
///
/// ####################### 5. RELEASE 3: LAUNCH TERMS PER TENANT #######################
///
///   Owner rule 2026-11-05: outside launchpads and builders pay Gully ONLY core's flat protocol fee (0.30% of
///   every trade, `GullyCoreProtocolFeeControllerV5`). Gully's own surfaces keep release 2's terms. A launch
///   is on GULLY TERMS when BOTH keys are set at `createLaunch`:
///
///     1. `gullyDesignated[tenant]`, written only by the owner (the governance Safe) through `setGullyTenant`;
///     2. `TenantConfig.gullyTerms`, written only by the tenant itself through `setTenantConfig`.
///
///   So an outside pad cannot give itself Gully's status, and Gully cannot put an outside pad on Gully terms.
///
///     GULLY TERMS    `protocolBps == PROTOCOL_TRADE_SHARE_BPS` (50%) in the fee split and the lock, integrator
///                    at most `GULLY_MAX_INTEGRATOR_BPS`, a tax protocol bucket of at least
///                    `GULLY_TAX_PROTOCOL_FLOOR_BPS`, the protocol launch fee charged, every pool flagged
///                    (`isLockedLaunch`) and therefore born at a ZERO core protocol fee.
///     OUTSIDE TERMS  every other tenant, and a launch with no tenant: `protocolBps == 0` in the fee split and
///                    the lock, a tax protocol bucket of 0, no protocol launch fee, NO flag: the pool is born
///                    at core's flat fee. The pad's shares are whatever its tenant config says; the launch
///                    restates them.
///
///   The terms are fixed per launch: the split is written once in the guard and the lock, the flag is written
///   once and never cleared, and `reconfigureLaunch` validates a restated tax under the terms the launch was
///   created on, whatever the tenant's status is by then. The 1% minimum trade fee and the fixed supply apply
///   to both.
contract LaunchpadKitV2 is ILaunchpadKitV2, ILockedLaunchOracle, IGullyCoreLaunchOrigin, Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;
    using BinPoolParametersHelper for bytes32;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice `beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta`, what
    /// `LaunchGuardHook` reports.
    uint16 public constant CL_HOOK_BITMAP = 0x0CC1;
    /// @notice `beforeInitialize | beforeMint | beforeSwap | afterSwap | beforeSwapReturnsDelta |
    /// afterSwapReturnsDelta`, what `BinLaunchGuardHook` reports.
    uint16 public constant BIN_HOOK_BITMAP = 0x0CC5;
    uint8 public constant MAX_LEGS_HARD_CAP = 8;
    /// @notice The steady trade fee every launch of this kit pays at least, in pips: 1% (owner decision
    /// 2026-11-02, "1% on every launch type"). Applies to every preset and to `Custom` (`finalFeeBips`, which
    /// is also the flat fee of a disabled schedule), on `createLaunch` and on `reconfigureLaunch`.
    uint24 public constant MIN_TRADE_FEE_PIPS = LaunchPolicy.MIN_TRADE_FEE_PIPS;
    /// @notice The protocol's share of the trade fee of a launch ON GULLY TERMS, exactly: 50% (owner decision
    /// 2026-11-02, "50/50, the protocol gets 0.50% forever"). Written into the guard's fee split and the lock,
    /// which are both written once, so it holds for the life of the pool. An integrator is paid from the
    /// creator's half. A launch on outside terms (release 3) carries exactly 0 instead.
    uint16 public constant PROTOCOL_TRADE_SHARE_BPS = LaunchPolicy.PROTOCOL_TRADE_SHARE_BPS;
    /// @notice Gully terms: the protocol's floor on the creator tax, 10% (the figure the release-1 and
    /// release-2 guards enforced; the release-3 guards have no floor, so the kit holds it).
    uint16 public constant GULLY_TAX_PROTOCOL_FLOOR_BPS = LaunchPolicy.GULLY_TAX_PROTOCOL_FLOOR_BPS;
    /// @notice Gully terms: the integrator's cap on the trade fee and on the tax, 20% (again the figure the
    /// earlier guards and lockers enforced).
    uint16 public constant GULLY_MAX_INTEGRATOR_BPS = LaunchPolicy.GULLY_MAX_INTEGRATOR_BPS;
    /// @notice `TaxParams.taxSeconds` meaning "the creator tax never ends": the kit writes the guard's
    /// `TAX_FOREVER` expiry (owner decision 2026-11-02, the 180-day limit is gone).
    uint32 public constant TAX_SECONDS_FOREVER = LaunchPolicy.TAX_SECONDS_FOREVER;
    /// @notice Every launch of this kit mints exactly 1,000,000,000 tokens (18 decimals; owner decision
    /// 2026-11-02, "supply is fixed at 1B on every launch"). `seedSupply` may still be less (the rest goes to
    /// `allocationRecipient`).
    uint256 public constant LAUNCH_TOTAL_SUPPLY = LaunchPolicy.LAUNCH_TOTAL_SUPPLY;
    /// @notice Floor on the public notice an INCREASE must sit behind. Decreases are immediate,
    /// because delay never sits on a reduction of the owner's power.
    ///
    /// CLOCK. This is measured on `block.timestamp`, which on an Arbitrum Nitro chain the sequencer
    /// may set up to roughly 1 hour ahead of real time. So a scheduled increase can become
    /// applicable about an hour early — ~4% of this one-day floor. It is recorded rather than
    /// defended against: only the owner (the governance Safe) can schedule an increase at all, the
    /// amount is still bounded by the immutable cap, and nothing retroactive follows from it. The
    /// launch guards carry the same note; it was missing here, which is finding L-2 of the
    /// 2026-09-18 review.
    uint32 public constant MIN_FEE_NOTICE_SECONDS = 1 days;
    uint32 public constant MAX_FEE_NOTICE_SECONDS = 30 days;
    /// @notice Mirrors both guards' `MAX_START_DELAY_SECONDS`, asserted equal at construction.
    uint32 public constant MAX_START_DELAY_SECONDS = LaunchPolicy.MAX_START_DELAY_SECONDS;
    string public constant CLOCK_MODE = "mode=timestamp";
    uint16 private constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    ICLPoolManager public immutable clPoolManager;
    LaunchGuardHook public immutable clHook;
    ICLPositionManager public immutable clPositionManager;
    GullyCoreLPLocker public immutable clLocker;
    IBinPoolManager public immutable binPoolManager;
    BinLaunchGuardHook public immutable binHook;
    IBinPositionManager public immutable binPositionManager;
    GullyCoreBinLPLocker public immutable binLocker;
    ILaunchTokenFactory public immutable tokenFactory;
    ILaunchRegistryWriter public immutable launchRegistry;
    /// @dev Read off each position manager, never trusted from a deployer.
    IAllowanceTransfer public immutable clPermit2;
    IAllowanceTransfer public immutable binPermit2;
    /// @notice The governance Safe. Also both lockers' `protocolRecipient`, asserted at construction.
    address public immutable protocolFeeRecipient;
    /// @notice Steward of this kit's own `GullyCoreLaunchRegistry` launchpad listing. Metadata only.
    address public immutable launchpadSteward;
    uint256 public immutable maxLaunchFeeWei;
    uint32 public immutable launchFeeNoticeSeconds;
    uint256 public immutable maxIntegratorLaunchFeeWei;
    uint8 public immutable maxLegs;
    uint16 public immutable maxBinsPerLeg;
    /// @dev Both lockers' integrator cap (asserted equal), cached for tenant-config validation.
    uint16 public immutable maxIntegratorBps;
    /// @dev Both guards' creator-tax caps (asserted equal), cached for tenant-config validation.
    uint16 public immutable maxTaxBps;
    uint16 public immutable maxTaxIntegratorBps;
    bytes32 private immutable _tokenInitCodeHash;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // slot 0 `_owner` (Ownable), slot 1 `_pendingOwner` (Ownable2Step), slot 2 `_status` (ReentrancyGuard)
    uint256 private _launchFeeWei; // slot 3
    uint256 private _pendingLaunchFeeWei; // slot 4
    uint64 private _pendingLaunchFeeEffectiveAt; // slot 5
    /// @dev THE V3 flag: "this pool is a locked launch on GULLY TERMS, born at a zero core protocol fee".
    /// Written once per leg of a Gully-terms launch in `createLaunch`, never cleared. Release 3: a leg of an
    /// outside-terms launch is NOT flagged (it pays core's flat fee); `_legs` is what records every leg.
    mapping(bytes32 poolId => bool) private _gullyLaunch; // slot 6
    mapping(bytes32 poolId => LegRecord) private _legs; // slot 7
    mapping(address token => LaunchRecordV2) private _launches; // slot 8
    mapping(address token => bytes32[]) private _legsOfToken; // slot 9
    /// @notice Native owed to each fee recipient. Sum is `totalFeesOwed`.
    mapping(address account => uint256) public feesOwed; // slot 10
    uint256 public totalFeesOwed; // slot 11
    mapping(address tenant => TenantConfig) private _tenants; // slot 12
    mapping(address tenant => mapping(address quote => bool)) public override tenantQuoteAllowed; // slot 13
    /// @notice Release 3: the governance Safe's half of the two-key Gully status. Owner-written only.
    mapping(address tenant => bool) public override gullyDesignated; // slot 14

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    struct Deployment {
        address owner;
        ICLPoolManager clPoolManager;
        LaunchGuardHook clHook;
        ICLPositionManager clPositionManager;
        GullyCoreLPLocker clLocker;
        IBinPoolManager binPoolManager;
        BinLaunchGuardHook binHook;
        IBinPositionManager binPositionManager;
        GullyCoreBinLPLocker binLocker;
        ILaunchTokenFactory tokenFactory;
        ILaunchRegistryWriter launchRegistry;
        address protocolFeeRecipient;
        address launchpadSteward;
        uint256 initialLaunchFeeWei;
        uint256 maxLaunchFeeWei;
        uint32 launchFeeNoticeSeconds;
        uint256 maxIntegratorLaunchFeeWei;
        uint8 maxLegs;
        uint16 maxBinsPerLeg;
    }

    constructor(Deployment memory d) Ownable(d.owner) {
        if (
            address(d.clPoolManager) == address(0) || address(d.binPoolManager) == address(0)
                || address(d.tokenFactory) == address(0) || address(d.launchRegistry) == address(0)
                || d.protocolFeeRecipient == address(0) || d.launchpadSteward == address(0)
        ) revert ZeroAddress();
        if (address(d.tokenFactory).code.length == 0) revert NoCode(address(d.tokenFactory));
        if (address(d.launchRegistry).code.length == 0) revert NoCode(address(d.launchRegistry));

        address vault_ = address(d.clPoolManager.vault());
        if (address(d.binPoolManager.vault()) != vault_) revert VaultMismatch(address(d.binPoolManager));
        if (IImmutableState(address(d.clPositionManager)).vault() != d.clPoolManager.vault()) {
            revert VaultMismatch(address(d.clPositionManager));
        }
        if (IImmutableState(address(d.binPositionManager)).vault() != d.clPoolManager.vault()) {
            revert VaultMismatch(address(d.binPositionManager));
        }
        if (d.launchRegistry.vault() != vault_) revert VaultMismatch(address(d.launchRegistry));
        if (address(d.clPositionManager.clPoolManager()) != address(d.clPoolManager)) {
            revert PositionManagerMismatch(address(d.clPositionManager));
        }
        if (address(d.binPositionManager.binPoolManager()) != address(d.binPoolManager)) {
            revert PositionManagerMismatch(address(d.binPositionManager));
        }

        // ---- the guards: right manager, right bitmap, timestamp clock, reservation bound to our factory,
        //      creator tax paying the same Safe with the same caps ----
        _checkHook(address(d.clHook), address(d.clPoolManager), CL_HOOK_BITMAP, address(d.tokenFactory));
        _checkHook(address(d.binHook), address(d.binPoolManager), BIN_HOOK_BITMAP, address(d.tokenFactory));
        if (
            d.clHook.MAX_START_DELAY_SECONDS() != MAX_START_DELAY_SECONDS
                || d.binHook.MAX_START_DELAY_SECONDS() != MAX_START_DELAY_SECONDS
        ) revert HookClockMismatch(address(d.clHook));

        // ---- the lockers: Gully Core's, on these position managers, paying the same Safe, same bounds ----
        if (address(d.clLocker.positionManager()) != address(d.clPositionManager)) revert LockerMismatch(address(d.clLocker));
        if (address(d.binLocker.positionManager()) != address(d.binPositionManager)) {
            revert LockerMismatch(address(d.binLocker));
        }
        if (
            d.clLocker.protocolRecipient() != d.protocolFeeRecipient
                || d.binLocker.protocolRecipient() != d.protocolFeeRecipient
                || d.clLocker.minProtocolBps() != d.binLocker.minProtocolBps()
                || d.clLocker.maxProtocolBps() != d.binLocker.maxProtocolBps()
                || d.clLocker.maxIntegratorBps() != d.binLocker.maxIntegratorBps()
        ) revert LockerMismatch(address(d.binLocker));
        // Release 3: an outside-terms lock carries a ZERO protocol share and whatever pad share the creator
        // agreed to, so both lockers must have no protocol floor and no integrator cap below the whole.
        // (The Bin locker's bounds equal the CL locker's: asserted just above.)
        if (d.clLocker.minProtocolBps() != 0) revert LockerFloorNotZero(address(d.clLocker), d.clLocker.minProtocolBps());
        if (d.clLocker.maxIntegratorBps() != BPS) revert LockerMismatch(address(d.clLocker));
        // The fixed 50% protocol share of Gully terms must be a split both lockers and both guards accept.
        if (d.clLocker.maxProtocolBps() < PROTOCOL_TRADE_SHARE_BPS) revert LockerMismatch(address(d.clLocker));
        if (d.clHook.MAX_PROTOCOL_BPS() < PROTOCOL_TRADE_SHARE_BPS || d.binHook.MAX_PROTOCOL_BPS() < PROTOCOL_TRADE_SHARE_BPS) {
            revert HookTaxMismatch(address(d.clHook));
        }
        // A forever tax needs guards without the old 180-day ceiling.
        if (d.clHook.TAX_FOREVER() != type(uint40).max || d.binHook.TAX_FOREVER() != type(uint40).max) {
            revert HookTaxMismatch(address(d.binHook));
        }

        // ---- the creator tax: both guards pay this kit's Safe, with one set of caps ----
        maxTaxBps = d.clHook.MAX_TAX_BPS();
        maxTaxIntegratorBps = d.clHook.MAX_INTEGRATOR_BPS();
        if (
            d.clHook.protocolRecipient() != d.protocolFeeRecipient || d.binHook.protocolRecipient() != d.protocolFeeRecipient
                || d.binHook.MAX_TAX_BPS() != maxTaxBps || d.binHook.MAX_INTEGRATOR_BPS() != maxTaxIntegratorBps
                // Release 3: guards with no protocol floor on the fee or the tax, and no integrator cap
                // below the whole. Guards of an earlier release would refuse every outside-terms launch.
                || maxTaxIntegratorBps != BPS || d.clHook.MIN_PROTOCOL_BPS() != 0 || d.binHook.MIN_PROTOCOL_BPS() != 0
                || d.clHook.MIN_FEE_PROTOCOL_BPS() != 0 || d.binHook.MIN_FEE_PROTOCOL_BPS() != 0
        ) revert HookTaxMismatch(address(d.binHook));

        // ---- bounds ----
        if (d.maxLegs == 0 || d.maxLegs > MAX_LEGS_HARD_CAP) revert InvalidLegCap(d.maxLegs);
        if (d.maxBinsPerLeg == 0 || d.maxBinsPerLeg > d.binLocker.maxBinsPerLock()) revert InvalidBinCap(d.maxBinsPerLeg);
        if (d.launchFeeNoticeSeconds < MIN_FEE_NOTICE_SECONDS || d.launchFeeNoticeSeconds > MAX_FEE_NOTICE_SECONDS) {
            revert InvalidNotice(d.launchFeeNoticeSeconds);
        }
        if (d.initialLaunchFeeWei > d.maxLaunchFeeWei) revert LaunchFeeAboveCap(d.initialLaunchFeeWei, d.maxLaunchFeeWei);

        clPoolManager = d.clPoolManager;
        clHook = d.clHook;
        clPositionManager = d.clPositionManager;
        clLocker = d.clLocker;
        binPoolManager = d.binPoolManager;
        binHook = d.binHook;
        binPositionManager = d.binPositionManager;
        binLocker = d.binLocker;
        tokenFactory = d.tokenFactory;
        launchRegistry = d.launchRegistry;
        clPermit2 = Permit2Forwarder(address(d.clPositionManager)).permit2();
        binPermit2 = Permit2Forwarder(address(d.binPositionManager)).permit2();
        protocolFeeRecipient = d.protocolFeeRecipient;
        launchpadSteward = d.launchpadSteward;
        maxLaunchFeeWei = d.maxLaunchFeeWei;
        launchFeeNoticeSeconds = d.launchFeeNoticeSeconds;
        maxIntegratorLaunchFeeWei = d.maxIntegratorLaunchFeeWei;
        maxLegs = d.maxLegs;
        maxBinsPerLeg = d.maxBinsPerLeg;
        maxIntegratorBps = d.clLocker.maxIntegratorBps();
        _tokenInitCodeHash = d.tokenFactory.launchTokenInitCodeHash();

        _launchFeeWei = d.initialLaunchFeeWei;
        emit LaunchFeeChanged(0, d.initialLaunchFeeWei);

        // The Bin locker pulls a lock's shares from `msg.sender` only, inside a `lock` call this kit makes.
        IBinFungibleToken(address(d.binPositionManager)).approveForAll(address(d.binLocker), true);
    }

    function _checkHook(address hook, address manager, uint16 bitmap, address factory) private view {
        if (hook == address(0)) revert ZeroAddress();
        // Both guards expose `poolManager()`, `CLOCK_MODE()` and `LAUNCH_TOKEN_FACTORY()` with identical
        // ABI shapes, so the CL type is used to read either.
        address hookManager = address(LaunchGuardHook(payable(hook)).poolManager());
        if (hookManager != manager) revert HookPoolManagerMismatch(manager, hookManager);
        uint16 actual = IHooks(hook).getHooksRegistrationBitmap();
        if (actual != bitmap) revert UnexpectedHookBitmap(bitmap, actual);
        if (keccak256(bytes(LaunchGuardHook(payable(hook)).CLOCK_MODE())) != keccak256(bytes(CLOCK_MODE))) {
            revert HookClockMismatch(hook);
        }
        if (address(LaunchGuardHook(payable(hook)).LAUNCH_TOKEN_FACTORY()) != factory) revert HookFactoryMismatch(hook, factory);
    }

    /*//////////////////////////////////////////////////////////////
                              THE ONE CALL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    function createLaunch(LaunchParamsV2 calldata p)
        external
        payable
        override
        nonReentrant
        returns (LaunchResultV2 memory r)
    {
        /* =========================== CHECKS (no external calls) =========================== */
        // Shape, THE TERMS (release 3: both keys, read in this block), fees and tenant policy, the schedule
        // and the creator tax: one DELEGATECALL into the linked `LaunchPolicy`, which is `view`, runs in this
        // contract's context and calls no other contract. It reverts on every refusal `createLaunch` had.
        uint256 n = p.legs.length;
        LaunchPolicy.Checked memory k =
            LaunchPolicy.precheck(p, _tenants, gullyDesignated, launchFeeWei(), maxIntegratorLaunchFeeWei, maxLegs, msg.value);
        bytes32 salt = keccak256(abi.encode(msg.sender, p.userSalt));
        address token = _predict(salt);

        r.token = token;
        r.startTime = k.schedule.startTime;
        r.poolIds = new bytes32[](n);
        r.lockIds = new uint256[](n);
        r.protocolFeeWei = k.required - p.integratorLaunchFeeWei;
        r.integratorFeeWei = p.integratorLaunchFeeWei;

        PoolKey[] memory keys = new PoolKey[](n);
        uint256[] memory supplies = new uint256[](n);
        {
            uint256 weightSum;
            uint256 remaining = p.seedSupply;
            for (uint256 i; i < n; ++i) {
                LegParams calldata leg = p.legs[i];
                _checkLeg(p, leg, k.schedule, token);
                weightSum += leg.weightBps;
                uint256 supply = i + 1 == n ? remaining : p.seedSupply * leg.weightBps / BPS;
                remaining -= supply;
                if (supply == 0) revert EmptyLeg(i);
                if (supply > type(uint128).max) revert LegTooLarge(i, supply);
                supplies[i] = supply;

                bool launchIs0;
                (keys[i], launchIs0) = _buildKey(token, leg);
                bytes32 poolId = PoolId.unwrap(keys[i].toId());
                // `_legs` records every leg of every launch (the flag below no longer does: release 3).
                if (_legs[poolId].launchToken != address(0)) revert DuplicateLegPool(poolId);

                /* ------------------------------------------------------------------------------
                   THE FLAG. Written for every leg of a GULLY-TERMS launch before this transaction
                   makes its first call of any kind. Mutation-checked: moving it after `initialize`
                   lets the controller stamp its flat fee on the pool, and every Gully-terms launch
                   then reverts `ProtocolFeeNotZero`. An outside-terms leg is deliberately NOT
                   flagged: its pool is born at the flat fee, and flagging it would zero what an
                   outside launch owes (mutation-checked the other way).
                   ------------------------------------------------------------------------------ */
                if (k.gully) _gullyLaunch[poolId] = true;
                _legs[poolId] = LegRecord({launchToken: token, kind: leg.kind, launchTokenIsCurrency0: launchIs0, lockId: 0});
                _legsOfToken[token].push(poolId);
                r.poolIds[i] = poolId;
            }
            if (weightSum != BPS) revert LegWeightsDoNotSum(weightSum);
        }

        address creator = p.creator == address(0) ? msg.sender : p.creator;
        address operator = p.launchOperator == address(0) ? msg.sender : p.launchOperator;
        _launches[token] = LaunchRecordV2({
            creator: creator,
            createdAt: uint64(block.timestamp),
            // n <= MAX_LEGS_HARD_CAP
            // forge-lint: disable-next-line(unsafe-typecast)
            legCount: uint8(n),
            operator: operator,
            startTime: k.schedule.startTime,
            tenant: p.tenant,
            integrator: p.integrator
        });
        _credit(protocolFeeRecipient, r.protocolFeeWei);
        _credit(p.integrator, r.integratorFeeWei);

        /* ================================= INTERACTIONS ================================= */
        // One DELEGATECALL into the linked `LaunchLegs`: plan and validate every Bin shape, create the
        // token, open, seed, lock and register every leg, return the remainder, assert the kit holds none.
        // It runs in this contract's context, so every call it makes comes from the kit.
        r.lockIds = LaunchLegs.execute(
            LaunchLegs.Context({
                env: LaunchLegs.Env({
                    clPoolManager: clPoolManager,
                    clHook: clHook,
                    clPositionManager: clPositionManager,
                    clLocker: clLocker,
                    binPoolManager: binPoolManager,
                    binHook: binHook,
                    binPositionManager: binPositionManager,
                    binLocker: binLocker,
                    clPermit2: clPermit2,
                    binPermit2: binPermit2,
                    tokenFactory: tokenFactory,
                    launchRegistry: launchRegistry,
                    maxBinsPerLeg: maxBinsPerLeg
                }),
                token: token,
                salt: salt,
                creator: creator,
                steward: p.launchSteward == address(0) ? msg.sender : p.launchSteward,
                gullyTerms: k.gully,
                schedule: k.schedule,
                tax: k.tax,
                keys: keys,
                poolIds: r.poolIds,
                supplies: supplies
            }),
            p
        );
        for (uint256 i; i < n; ++i) {
            _legs[r.poolIds[i]].lockId = r.lockIds[i];
        }

        emit LaunchCreated(
            token,
            creator,
            p.tenant,
            msg.sender,
            operator,
            p.totalSupply,
            p.seedSupply,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8(n),
            k.schedule.startTime,
            r.protocolFeeWei,
            p.integrator,
            r.integratorFeeWei
        );

        if (msg.value > k.required) _sendNative(msg.sender, msg.value - k.required);
    }

    /*//////////////////////////////////////////////////////////////
                               LEG CHECKS
    //////////////////////////////////////////////////////////////*/

    function _checkLeg(LaunchParamsV2 calldata p, LegParams calldata leg, LaunchLegs.Schedule memory s, address token)
        private
        view
    {
        address quote = leg.quote;
        if (quote == token) revert QuoteIsLaunchToken(quote);
        if (quote != address(0) && quote.code.length == 0) revert QuoteHasNoCode(quote);
        if (leg.kind == LegKind.Bin) {
            if (s.initialFeeBips > LPFeeLibrary.TEN_PERCENT_FEE) revert PresetUnavailableOnBin(p.schedule.preset);
        } else if (s.requiresMaxBuy && leg.maxBuyPerTx == 0) {
            revert MaxBuyRequiredByPreset(p.schedule.preset);
        }
        if (p.tenant != address(0)) {
            TenantConfig storage t = _tenants[p.tenant];
            if (t.restrictQuotes && !tenantQuoteAllowed[p.tenant][quote]) revert QuoteNotAllowed(p.tenant, quote);
            if (leg.kind == LegKind.Bin && (t.allowedBinShapes >> uint8(leg.bin.shape)) & 1 == 0) {
                revert BinShapeNotAllowed(p.tenant, leg.bin.shape);
            }
        }
    }







    function _buildKey(address token, LegParams calldata leg) private view returns (PoolKey memory key, bool launchIs0) {
        launchIs0 = uint160(token) < uint160(leg.quote);
        (address c0, address c1) = launchIs0 ? (token, leg.quote) : (leg.quote, token);
        key.currency0 = Currency.wrap(c0);
        key.currency1 = Currency.wrap(c1);
        // Never a caller input: a static fee silently discards the guard's fee override.
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        if (leg.kind == LegKind.CL) {
            key.hooks = IHooks(address(clHook));
            key.poolManager = clPoolManager;
            key.parameters = bytes32(uint256(CL_HOOK_BITMAP)).setTickSpacing(leg.cl.tickSpacing);
        } else {
            key.hooks = IHooks(address(binHook));
            key.poolManager = binPoolManager;
            key.parameters = bytes32(uint256(BIN_HOOK_BITMAP)).setBinStep(leg.bin.binStep);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            RECONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    /// @dev Operator only, all legs at once (so every pool keeps one opening time), before the guards freeze
    /// at `startTime`. Pins each leg's launch-token side and per-leg buy cap; restates the creator tax (the
    /// guards freeze both together, and an all-zero `tax` clears it). Never touches `_gullyLaunch`.
    function reconfigureLaunch(
        address token,
        PoolKey[] calldata keys,
        ScheduleParams calldata schedule,
        TaxParams calldata tax
    ) external override nonReentrant {
        LaunchRecordV2 storage rec = _launches[token];
        if (rec.creator == address(0)) revert UnknownLaunch(token);
        if (msg.sender != rec.operator) revert NotLaunchOperator(token, msg.sender);

        // The terms are the launch's own: every leg of a Gully-terms launch is flagged, no leg of an
        // outside-terms launch is, and a launch has at least one leg. The tenant's status today is not read.
        bytes32[] storage ids = _legsOfToken[token];
        LaunchLegs.Reconfig memory r = LaunchPolicy.resolveReconfig(
            schedule, tax, _tenants, rec.tenant, _gullyLaunch[ids[0]], rec.creator, rec.integrator
        );

        // The per-leg work lives in the linked library (kit size); it runs in this context, so every
        // guard call is FROM the kit, the launch owner. It never touches `_gullyLaunch`.
        if (keys.length != ids.length) revert LegKeyMismatch(keys.length);
        for (uint256 i; i < keys.length; ++i) {
            bytes32 poolId = PoolId.unwrap(keys[i].toId());
            if (poolId != ids[i]) revert LegKeyMismatch(i);
            LegRecord storage leg = _legs[poolId];
            if (leg.kind == LegKind.CL) LaunchLegs.reconfigureCL(clHook, keys[i], leg.launchTokenIsCurrency0, r);
            else LaunchLegs.reconfigureBin(binHook, keys[i], leg.launchTokenIsCurrency0, r);
        }
        rec.startTime = r.schedule.startTime;
        emit LaunchReconfigured(
            token,
            msg.sender,
            r.schedule.startTime,
            r.schedule.decaySeconds,
            r.schedule.initialFeeBips,
            r.schedule.finalFeeBips,
            r.schedule.enabled,
            r.tax.buyBps,
            r.tax.sellBps,
            r.tax.expiresAt
        );
    }

    /*//////////////////////////////////////////////////////////////
                       PROTOCOL LAUNCH FEE (OWNER)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    /// @notice The owner's only power. `<=` the fee in force applies now and cancels any pending increase;
    /// `>` it is announced and takes effect `launchFeeNoticeSeconds` later, by itself. A new increase
    /// replaces a pending one and restarts the notice, so no announcement can ever shorten the wait.
    function setLaunchFee(uint256 newFeeWei) external override onlyOwner {
        if (newFeeWei > maxLaunchFeeWei) revert LaunchFeeAboveCap(newFeeWei, maxLaunchFeeWei);
        _materialiseLaunchFee();
        uint256 current = _launchFeeWei;
        if (newFeeWei <= current) {
            _clearPending();
            _launchFeeWei = newFeeWei;
            emit LaunchFeeChanged(current, newFeeWei);
        } else {
            uint64 effectiveAt = uint64(block.timestamp) + launchFeeNoticeSeconds;
            _pendingLaunchFeeWei = newFeeWei;
            _pendingLaunchFeeEffectiveAt = effectiveAt;
            emit LaunchFeeIncreaseScheduled(current, newFeeWei, effectiveAt);
        }
    }

    /// @inheritdoc ILaunchpadKitV2
    function cancelPendingLaunchFee() external override onlyOwner {
        _materialiseLaunchFee();
        if (_pendingLaunchFeeEffectiveAt == 0) revert NoPendingLaunchFee();
        _clearPending();
    }

    /// @inheritdoc ILaunchpadKitV2
    /// @notice The protocol launch fee a launch in THIS block pays.
    function launchFeeWei() public view override returns (uint256) {
        uint64 at = _pendingLaunchFeeEffectiveAt;
        if (at != 0 && block.timestamp >= at) return _pendingLaunchFeeWei;
        return _launchFeeWei;
    }

    /// @notice An announced increase that has not taken effect yet. `(0, 0)` when there is none.
    function pendingLaunchFee() external view returns (uint256 feeWei, uint64 effectiveAt) {
        effectiveAt = _pendingLaunchFeeEffectiveAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        feeWei = _pendingLaunchFeeWei;
    }

    /// @notice Disabled. An owner that could renounce would freeze the fee at its current level forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 that was sent to the kit by mistake to `to`. Owner only.
    /// @dev The kit holds nothing between transactions by design: `createLaunch` asserts it retained no
    /// launch token and no Bin shares before it returns, and native fee credit is accounted per address.
    /// Any ERC-20 balance here is therefore misdirected value with, until now, no path out (acceptance
    /// finding A, 2026-09-18). This cannot reach a launch, a lock, a quote in flight or anyone's credit:
    /// none of those is ever an ERC-20 balance of the kit. The body is in `LaunchPolicy` (kit size).
    function rescueERC20(address token, address to) external onlyOwner {
        LaunchPolicy.rescueERC20(token, to);
    }

    function _materialiseLaunchFee() private {
        uint64 at = _pendingLaunchFeeEffectiveAt;
        if (at != 0 && block.timestamp >= at) {
            uint256 next = _pendingLaunchFeeWei;
            emit LaunchFeeChanged(_launchFeeWei, next);
            _launchFeeWei = next;
            _pendingLaunchFeeWei = 0;
            _pendingLaunchFeeEffectiveAt = 0;
        }
    }

    function _clearPending() private {
        uint64 at = _pendingLaunchFeeEffectiveAt;
        if (at == 0) return;
        emit PendingLaunchFeeCancelled(_pendingLaunchFeeWei, at);
        _pendingLaunchFeeWei = 0;
        _pendingLaunchFeeEffectiveAt = 0;
    }

    /*//////////////////////////////////////////////////////////////
                              FEE PAYOUTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    function claimFees(address to) external override nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = _debit(msg.sender);
        emit FeesClaimed(msg.sender, to, amount);
        _sendNative(to, amount);
    }

    /// @inheritdoc ILaunchpadKitV2
    /// @notice Permissionless: it can only ever pay the immutable protocol recipient.
    function flushProtocolFees() external override nonReentrant returns (uint256 amount) {
        amount = _debit(protocolFeeRecipient);
        emit FeesClaimed(protocolFeeRecipient, protocolFeeRecipient, amount);
        _sendNative(protocolFeeRecipient, amount);
    }

    function _credit(address account, uint256 amount) private {
        if (amount == 0) return;
        feesOwed[account] += amount;
        totalFeesOwed += amount;
        emit FeesCredited(account, amount);
    }

    function _debit(address account) private returns (uint256 amount) {
        amount = feesOwed[account];
        if (amount == 0) revert NothingToClaim();
        feesOwed[account] = 0;
        totalFeesOwed -= amount;
    }

    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         TENANTS (SELF-SERVICE)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    /// @notice `msg.sender` IS the tenant. Nobody else - the kit owner included - can write a tenant's policy.
    /// @dev A launch naming this tenant must restate `integrator`, `integratorBps` and
    /// `integratorLaunchFeeWei` exactly, so changing the config can only make a pending launch revert,
    /// never re-price it. The validation and the write are in `LaunchPolicy` (kit size); under DELEGATECALL
    /// `msg.sender` there is this function's caller.
    function setTenantConfig(TenantConfig calldata c) external override {
        LaunchPolicy.setTenant(_tenants, c, maxIntegratorLaunchFeeWei, maxIntegratorBps, maxTaxBps, maxTaxIntegratorBps);
    }

    /// @inheritdoc ILaunchpadKitV2
    function setTenantQuote(address quote, bool allowed) external override {
        tenantQuoteAllowed[msg.sender][quote] = allowed;
        emit TenantQuoteSet(msg.sender, quote, allowed);
    }

    function tenantConfig(address tenant) external view override returns (TenantConfig memory) {
        return _tenants[tenant];
    }

    /*//////////////////////////////////////////////////////////////
                    GULLY TERMS (RELEASE 3, TWO KEYS)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    /// @notice The owner's key. Designating a tenant changes nothing until that tenant opts in itself
    /// (`TenantConfig.gullyTerms`), and nothing about any launch that already exists: a launch's terms are
    /// written once, when it is created.
    function setGullyTenant(address tenant, bool designated) external override onlyOwner {
        if (tenant == address(0)) revert ZeroAddress();
        gullyDesignated[tenant] = designated;
        emit GullyTenantSet(tenant, designated);
    }



    /// @inheritdoc ILaunchpadKitV2
    /// @dev Both keys, as `LaunchPolicy.precheck` reads them (nobody can designate the zero address, so a
    /// launch with no tenant is never on Gully terms).
    function launchFeeFor(address tenant) external view override returns (uint256) {
        return gullyDesignated[tenant] && _tenants[tenant].gullyTerms ? launchFeeWei() : 0;
    }



    /*//////////////////////////////////////////////////////////////
                           LAUNCHPAD LISTING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    /// @notice Permissionless. Lists this kit as `SelfRegistered` with the IMMUTABLE steward, or claims a
    /// listing a stranger created. The caller chooses only the initial metadata, which the steward can edit.
    function registerLaunchpad(LaunchpadMetadata calldata metadata) external override nonReentrant {
        LaunchPolicy.registerLaunchpad(launchRegistry, launchpadSteward, metadata);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The fee controller's question: "is this pool a locked launch that is born at a zero core
    /// protocol fee". A plain storage read: no guard, no calls.
    /// @dev Release 3: true for the legs of GULLY-TERMS launches only. An outside-terms launch is locked all
    /// the same (`getLeg` shows its lock), but it answers false here, so the controller charges it the flat fee.
    function isLockedLaunch(bytes32 poolId) external view override(ILaunchpadKitV2, ILockedLaunchOracle) returns (bool) {
        return _gullyLaunch[poolId];
    }

    /// @notice `GullyCoreLaunchRegistry`'s attribution probe.
    function launchOriginOf(bytes32 poolId)
        external
        view
        override(ILaunchpadKitV2, IGullyCoreLaunchOrigin)
        returns (address creator)
    {
        address token = _legs[poolId].launchToken;
        return token == address(0) ? address(0) : _launches[token].creator;
    }

    /// @inheritdoc ILaunchpadKitV2
    function predictLaunchToken(address launcher, bytes32 userSalt) external view override returns (address) {
        return _predict(keccak256(abi.encode(launcher, userSalt)));
    }

    /// @notice The key and id `createLaunch` builds for a leg of `token`, and which side the token sorts to.
    function computeLegKey(address token, LegParams calldata leg)
        external
        view
        returns (PoolKey memory key, bytes32 poolId, bool launchTokenIsCurrency0)
    {
        (key, launchTokenIsCurrency0) = _buildKey(token, leg);
        poolId = PoolId.unwrap(key.toId());
    }

    /// @inheritdoc ILaunchpadKitV2
    function getLeg(bytes32 poolId) external view override returns (LegRecord memory) {
        return _legs[poolId];
    }

    /// @inheritdoc ILaunchpadKitV2
    function getLaunch(address token) external view override returns (LaunchRecordV2 memory) {
        return _launches[token];
    }

    /// @inheritdoc ILaunchpadKitV2
    function legsOf(address token) external view override returns (bytes32[] memory) {
        return _legsOfToken[token];
    }

    /// @dev `LaunchTokenFactory` address rule, computed locally so no external call precedes the flags:
    /// CREATE2(factory, keccak256(abi.encode(kit, salt)), launchTokenInitCodeHash).
    function _predict(bytes32 salt) private view returns (address) {
        bytes32 effective = keccak256(abi.encode(address(this), salt));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(tokenFactory), effective, _tokenInitCodeHash))))
        );
    }
}
