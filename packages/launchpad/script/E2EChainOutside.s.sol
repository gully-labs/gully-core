// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {GullyCoreSignerScript} from "gullycore-hooks/script/GullyCoreSigner.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LaunchGuardHook} from "gullycore-hooks/src/launch/LaunchGuardHook.sol";
import {GullyCoreProtocolFeeControllerV5} from "gullycore-fees/src/GullyCoreProtocolFeeControllerV5.sol";
import {LaunchMetadata} from "gullycore-registry/src/IGullyCoreLaunchRegistry.sol";

import {LaunchpadKitV2} from "../src/LaunchpadKitV2.sol";
import {Preset} from "../src/libraries/LaunchPresets.sol";
import {
    LegKind, CLLegParams, LegParams, ScheduleParams, LaunchParamsV2, LaunchResultV2
} from "../src/interfaces/ILaunchpadKitV2.sol";

interface IWrapped {
    function deposit() external payable;
}

/// @title E2EChainOutside
/// @notice The post-deploy check of a mainnet, after the conversion, so it needs nothing from the Safe: three live
/// transactions (a tenantless launch, a buy, a sell) of a throwaway coin against the chain's wrapped native, then settle,
/// claim and sweep. The Safe must receive the flat fee and nothing else, and nothing may be left behind. It opens a real
/// pool with E2E_BUY_WEI of real funds. NOT for a chain with no confirmed quote (Anubis: no pool is opened there).
/// Inputs: LAUNCHPAD_KIT_V2, E2E_QUOTE (wrapped native), E2E_BUY_WEI, PRIVATE_KEY or DEPLOYER.
contract E2EChainOutsideScript is GullyCoreSignerScript {
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;
    uint256 internal constant PIPS = 1_000_000;

    function run() external {
        uint256 pk = _pkFromEnv();
        address me = _signerOf(pk);
        LaunchpadKitV2 kit = LaunchpadKitV2(vm.envAddress("LAUNCHPAD_KIT_V2"));
        address quote = vm.envAddress("E2E_QUOTE");
        uint256 buy = vm.envUint("E2E_BUY_WEI");
        LaunchGuardHook guard = kit.clHook();
        ICLPoolManager cl = kit.clPoolManager();
        GullyCoreProtocolFeeControllerV5 v5 = GullyCoreProtocolFeeControllerV5(address(cl.protocolFeeController()));
        address safe = kit.owner();
        require(v5.treasury() == safe, "the controller's treasury is not the Safe");
        Currency q = Currency.wrap(quote);
        uint256 safeQuoteBefore = IERC20(quote).balanceOf(safe);
        require(cl.protocolFeesAccrued(q) == 0, "fees already accrued in the quote: sweep first, the sums below are exact");

        bytes32 salt = keccak256(abi.encode("gully-core.e2e.outside", block.chainid, block.timestamp));
        address token = kit.predictLaunchToken(me, salt);
        bool is0 = uint160(token) < uint160(quote);
        LaunchParamsV2 memory p;
        p.name = "Gully Core deploy check";
        p.symbol = "GCCHECK";
        p.metadataURI = "ipfs://gully-core-deploy-check";
        p.userSalt = salt;
        p.totalSupply = kit.LAUNCH_TOTAL_SUPPLY();
        p.seedSupply = p.totalSupply;
        p.creator = me;
        p.creatorBps = 10_000;
        p.schedule = ScheduleParams({
            preset: Preset.Custom, initialFeeBips: 10_000, finalFeeBips: 10_000, decaySeconds: 60, enabled: false, startDelaySeconds: 0
        });
        p.legs = new LegParams[](1);
        p.legs[0].kind = LegKind.CL;
        p.legs[0].quote = quote;
        p.legs[0].weightBps = 10_000;
        p.legs[0].cl = CLLegParams({
            tickSpacing: 60,
            sqrtPriceX96: SQRT_1_1,
            tickLower: is0 ? int24(60) : int24(-60_000),
            tickUpper: is0 ? int24(60_000) : int24(0)
        });
        LaunchMetadata memory m;
        m.description = "Gully Core deploy check. Not a project.";
        m.websiteURI = "https://gullychain.xyz/core";
        p.listing = m;

        _startBroadcastAs(pk);
        IWrapped(quote).deposit{value: buy}();
        CLPoolManagerRouter router = new CLPoolManagerRouter(IVault(address(cl.vault())), cl);
        IERC20(quote).approve(address(router), type(uint256).max);

        LaunchResultV2 memory r = kit.createLaunch(p);
        (PoolKey memory key,,) = kit.computeLegKey(r.token, p.legs[0]);
        PoolId id = PoolId.wrap(r.poolIds[0]);
        require(!kit.isLockedLaunch(r.poolIds[0]), "an outside launch must not be flagged");
        require(r.protocolFeeWei == 0, "an outside launch owes no launch fee");

        uint256 poolFee = buy * guard.currentFee(id) / PIPS;
        _swap(router, cl, key, r.token, true, buy);
        uint256 flatQuote = cl.protocolFeesAccrued(q);
        uint256 want = (buy - poolFee) * v5.builderFee() / PIPS;
        require(flatQuote + 3 >= want && flatQuote <= want + 3, "the buy did not pay the flat fee");

        uint256 sell = IERC20(r.token).balanceOf(me) / 2;
        IERC20(r.token).approve(address(router), type(uint256).max);
        _swap(router, cl, key, r.token, false, sell);
        uint256 flatToken = cl.protocolFeesAccrued(Currency.wrap(r.token));
        require(flatToken + 3 >= sell * v5.builderFee() / PIPS, "the sell did not pay the flat fee");

        guard.settleFee(id, q);
        require(guard.claimable(safe, q) == 0, "the guard credited the Safe");
        guard.claim(q, me);
        require(guard.pendingFee(id, q) == 0 && guard.claimable(me, q) == 0, "something is left in the guard");
        require(v5.sweep(address(cl), q) == flatQuote, "sweep (quote)");
        require(v5.sweep(address(cl), Currency.wrap(r.token)) == flatToken, "sweep (launch token)");
        vm.stopBroadcast();

        require(IERC20(quote).balanceOf(safe) - safeQuoteBefore == flatQuote, "the Safe did not receive exactly the flat fee");
        require(IERC20(r.token).balanceOf(safe) == flatToken, "the Safe's launch-token fee");
        require(cl.protocolFeesAccrued(q) == 0 && cl.protocolFeesAccrued(Currency.wrap(r.token)) == 0, "accrued left in the manager");
        require(kit.feesOwed(safe) == 0 && address(kit).balance == kit.totalFeesOwed(), "the kit holds something");
        console.log("=== CHAIN E2E PASSED ===");
        console.log("E2E token", r.token);
        console.log("E2E pool", vm.toString(r.poolIds[0]));
        console.log("E2E flatQuote", flatQuote);
        console.log("E2E flatToken", flatToken);
    }

    function _swap(CLPoolManagerRouter router, ICLPoolManager, PoolKey memory key, address token, bool isBuy, uint256 amountIn) internal {
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        bool zeroForOne = isBuy ? !tokenIs0 : tokenIs0;
        router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }
}
