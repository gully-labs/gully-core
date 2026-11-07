// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {GullyCoreSignerScript} from "gullycore-hooks/script/GullyCoreSigner.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {GullyCoreProtocolFeeControllerV5} from "../src/GullyCoreProtocolFeeControllerV5.sol";

interface ISafeExec {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
    function getThreshold() external view returns (uint256);
    function isOwner(address owner) external view returns (bool);
}

/**
 * LIVE end-to-end check of the builder and partner fee on a chain where V5 is the installed controller.
 * TESTNET ONLY as written: the Safe step is executed by the signer, which works only for a 1-of-1 Safe the signer
 * owns (Gully Chain testnet 485590). Everything is done with two throwaway test tokens the script creates.
 *
 * Transactions, each against the LIVE Vault, CL pool manager and V5:
 *   setup  two test tokens, a swap helper, a hookless static-fee pool (born at the flat fee), liquidity
 *   tx 1   swap 1 token0 in            -> the manager accrues exactly builderFee/1e6 of the input
 *   tx 2   the Safe lowers this pool to 0.10% zeroForOne (at once), then a second swap pays 0.10%
 *   tx 3   swap 1 token1 in (other direction, still at the flat fee), then `sweep` both currencies: the Safe
 *          receives every wei and the manager's accrued balances are zero
 *   exit   the liquidity is removed again
 * Also asserted: an increase through `setPoolProtocolFee` reverts `RaiseNeedsNotice`; the controller holds nothing.
 * LAUNCH_POOL_ID (optional): a locked launch pool of a kit V5 names; it must read zero and stay refused.
 * The same facts are read back from the chain by release/apply-builder-fee.sh after the broadcast.
 */
contract E2EBuilderFeeScript is GullyCoreSignerScript {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    struct Ctx {
        GullyCoreProtocolFeeControllerV5 v5;
        ICLPoolManager cl;
        address safe;
        address me;
        MockERC20 t0;
        MockERC20 t1;
        CLPoolManagerRouter router;
        PoolKey key;
        uint16 fee;
    }

    function run() external {
        uint256 pk = _pkFromEnv();
        Ctx memory c;
        c.me = _signerOf(pk);
        c.v5 = GullyCoreProtocolFeeControllerV5(vm.envAddress("FEE_CONTROLLER_V5"));
        c.cl = ICLPoolManager(vm.envAddress("CL_POOL_MANAGER"));
        IVault vault = IVault(vm.envAddress("VAULT"));
        c.safe = vm.envAddress("FEE_OWNER_SAFE");

        require(address(c.cl.protocolFeeController()) == address(c.v5), "V5 is not the installed controller on the CL manager");
        require(c.v5.clPoolManager() == address(c.cl), "V5 was not built for this CL manager");
        require(c.v5.treasury() == c.safe && c.v5.owner() == c.safe, "V5 owner/treasury is not the Safe");
        require(ISafeExec(c.safe).getThreshold() == 1 && ISafeExec(c.safe).isOwner(c.me), "this e2e needs a 1-of-1 Safe owned by the signer (testnet)");
        c.fee = c.v5.builderFee();
        require(c.fee > 1000 && c.fee <= 4000, "the e2e expects a builder fee above 1000 pips");
        uint24 packed = uint24(c.fee) | (uint24(c.fee) << 12);

        _startBroadcastAs(pk);
        // ---- setup ----
        MockERC20 a = new MockERC20("Builder Fee E2E A", "BFEA", 18);
        MockERC20 b = new MockERC20("Builder Fee E2E B", "BFEB", 18);
        (c.t0, c.t1) = address(a) < address(b) ? (a, b) : (b, a);
        c.t0.mint(c.me, 1_000_000 ether);
        c.t1.mint(c.me, 1_000_000 ether);
        c.router = new CLPoolManagerRouter(vault, c.cl);
        c.t0.approve(address(c.router), type(uint256).max);
        c.t1.approve(address(c.router), type(uint256).max);
        c.key = PoolKey({
            currency0: Currency.wrap(address(c.t0)),
            currency1: Currency.wrap(address(c.t1)),
            hooks: IHooks(address(0)),
            poolManager: c.cl,
            fee: 500,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(0), 10)
        });
        c.cl.initialize(c.key, SQRT_RATIO_1_1);
        require(_stamped(c) == packed, "a non-launch pool was not born at the flat builder fee");
        c.router.modifyPosition(
            c.key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -6_000, tickUpper: 6_000, liquidityDelta: 100_000 ether, salt: 0}),
            ""
        );

        // ---- tx 1: a swap pays exactly the flat fee ----
        _swap(c, true, 1 ether);
        uint256 expect0 = (1 ether * uint256(c.fee)) / 1e6;
        require(c.cl.protocolFeesAccrued(c.key.currency0) == expect0, "tx 1: the swap did not accrue exactly the builder fee");

        // ---- tx 2: the Safe lowers this pool at once; an increase is refused ----
        uint24 lowered = uint24(1000) | (uint24(c.fee) << 12);
        _safeExec(c, address(c.v5), abi.encodeCall(c.v5.setPoolProtocolFee, (address(c.cl), c.key, lowered)));
        require(_stamped(c) == lowered, "tx 2: the pool was not lowered");
        _swap(c, true, 1 ether);
        expect0 += (1 ether * 1000) / 1e6;
        require(c.cl.protocolFeesAccrued(c.key.currency0) == expect0, "tx 2: the lowered pool did not pay 0.10%");

        // ---- tx 3: the other direction still pays the flat fee; sweep leaves nothing ----
        _swap(c, false, 1 ether);
        uint256 expect1 = (1 ether * uint256(c.fee)) / 1e6;
        require(c.cl.protocolFeesAccrued(c.key.currency1) == expect1, "tx 3: oneForZero did not accrue the builder fee");
        uint256 s0 = c.t0.balanceOf(c.safe);
        uint256 s1 = c.t1.balanceOf(c.safe);
        c.v5.sweep(address(c.cl), c.key.currency0);
        c.v5.sweep(address(c.cl), c.key.currency1);
        require(c.t0.balanceOf(c.safe) - s0 == expect0 && c.t1.balanceOf(c.safe) - s1 == expect1, "tx 3: the Safe did not receive every wei");
        require(c.cl.protocolFeesAccrued(c.key.currency0) == 0 && c.cl.protocolFeesAccrued(c.key.currency1) == 0, "fees left in the manager");
        require(c.t0.balanceOf(address(c.v5)) == 0 && c.t1.balanceOf(address(c.v5)) == 0, "the controller holds funds");

        // ---- exit: the liquidity comes back out ----
        c.router.modifyPosition(
            c.key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -6_000, tickUpper: 6_000, liquidityDelta: -100_000 ether, salt: 0}),
            ""
        );
        vm.stopBroadcast();

        // ---- not broadcast: an increase without notice is refused (simulated as the Safe) ----
        vm.prank(c.safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.RaiseNeedsNotice.selector, lowered, packed));
        c.v5.setPoolProtocolFee(address(c.cl), c.key, packed);

        bytes32 launchId = vm.envOr("LAUNCH_POOL_ID", bytes32(0));
        if (launchId != bytes32(0)) {
            (,, uint24 launchFee,) = c.cl.getSlot0(PoolId.wrap(launchId));
            require(launchFee == 0, "the launch pool pays a core protocol fee");
            require(c.v5.isLockedLaunchPool(PoolId.wrap(launchId)), "V5 does not recognise the launch pool");
            console.log("  launch pool reads zero core fee and is vouched for:", vm.toString(launchId));
        }

        console.log("=== E2E PASSED ===");
        console.log("  pool id   ", vm.toString(PoolId.unwrap(c.key.toId())));
        console.log("  token0    ", address(c.t0));
        console.log("  token1    ", address(c.t1));
        console.log("  router    ", address(c.router));
        console.log("  builder fee pips", uint256(c.fee));
        console.log("  Safe received token0", expect0);
        console.log("  Safe received token1", expect1);
    }

    function _stamped(Ctx memory c) internal view returns (uint24 fee) {
        (,, fee,) = c.cl.getSlot0(c.key.toId());
    }

    function _swap(Ctx memory c, bool zeroForOne, uint256 amountIn) internal {
        c.router.swap(
            c.key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// @dev A 1-of-1 Safe whose owner sends the transaction: the pre-approved signature form (v = 1, r = owner).
    function _safeExec(Ctx memory c, address to, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(c.me))), bytes32(0), uint8(1));
        bool ok = ISafeExec(c.safe).execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
        require(ok, "the Safe transaction failed");
    }
}
