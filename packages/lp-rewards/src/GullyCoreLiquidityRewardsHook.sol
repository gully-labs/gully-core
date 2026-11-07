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

import {BaseCLHook} from "gullycore-hooks/src/base/BaseCLHook.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

import {LiquidityRewardsModule} from "./LiquidityRewardsModule.sol";

/// @title GullyCoreLiquidityRewardsHook
/// @notice A CL Gully Core that streams project-funded rewards to in-range liquidity. Standalone: the
/// composition with the oracle and dynamic-fee modules (`GullyCoreDexRewardsHook`) is a documented follow-up.
///
/// @dev Bitmap `0x0095`: beforeInitialize (refuse an unconfigured pool, record the tick), beforeAddLiquidity,
/// beforeRemoveLiquidity, afterSwap. No returns-delta bit: the hook never touches an LP's principal, a fee or
/// a swap amount. The design's composed bitmap (`0x00D7`) adds afterInitialize and beforeSwap; standalone,
/// the tick at initialize is computed with the same `TickMath` call core uses, and accrual runs at the top
/// of `afterSwap` with the liquidity in force during the swap (eligible liquidity only changes at the
/// crossings applied after it), which is the same number with one callback fewer.
///
/// THIS HOOK REGISTERS A REMOVAL CALLBACK. `GullyCoreLPLocker` refuses positions on it and the registry classes it
/// as able to trap liquidity. `LiquidityRewardsModule` documents why its removal path cannot revert.
contract GullyCoreLiquidityRewardsHook is BaseCLHook, LiquidityRewardsModule {
    constructor(ICLPoolManager poolManager_, ModuleParams memory params) BaseCLHook(poolManager_) LiquidityRewardsModule(params) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | AFTER_SWAP;
    }

    function _rewardsPoolManager() internal view override returns (ICLPoolManager) {
        return poolManager;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        _rewardsOnInitialize(key, sqrtPriceX96);
        return ICLHooks.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _rewardsOnModify(sender, key, params, hookData, true);
        return ICLHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _rewardsOnModify(sender, key, params, hookData, false);
        return ICLHooks.beforeRemoveLiquidity.selector;
    }

    function _afterSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _rewardsOnSwap(key);
        return (ICLHooks.afterSwap.selector, 0);
    }
}
