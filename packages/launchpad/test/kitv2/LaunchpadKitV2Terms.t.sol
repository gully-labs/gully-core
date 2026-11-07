// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";

import {LaunchTaxModule} from "gullycore-hooks/src/launch/LaunchTaxModule.sol";
import {GullyCoreProtocolFeeControllerV5} from "gullycore-fees/src/GullyCoreProtocolFeeControllerV5.sol";

import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {GullyCoreLPLocker} from "../../src/GullyCoreLPLocker.sol";
import {GullyCoreBinLPLocker} from "../../src/GullyCoreBinLPLocker.sol";
import {Lock} from "../../src/interfaces/IGullyCoreLPLocker.sol";
import {BinLock} from "../../src/interfaces/IGullyCoreBinLPLocker.sol";
import {
    ILaunchpadKitV2,
    LaunchParamsV2,
    LaunchResultV2,
    TaxParams,
    TenantConfig
} from "../../src/interfaces/ILaunchpadKitV2.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @dev A launch oracle that vouches for nothing: stands in for the release-1 and release-2 kits a V5 names.
contract QuietOracle {
    function isLockedLaunch(bytes32) external pure returns (bool) {
        return false;
    }
}

/// @notice Release 3: launch terms per tenant, against the real core, guards, lockers and fee controller V5.
///
/// Owner rule 2026-11-05: an outside launchpad's launch pays Gully the flat 0.30% core fee and NOTHING else
/// (no share of the pool fee, none of the creator tax, no launch fee); a launch on Gully's own terms pays the
/// release-2 split and the launch fee and NO flat fee. Gully terms need both keys: the Safe designates the
/// tenant and the tenant opts in.
abstract contract TermsBase is KitV2Fixture {
    GullyCoreProtocolFeeControllerV5 internal v5;

    /// @dev An outside launchpad (a tenant nobody designated) and the wallet its shares are paid to.
    address internal constant OUT_PAD = address(0x0D7AD);
    address internal constant PAD_WALLET = address(0x9AD9AD);
    uint24 internal constant PACKED_3000 = uint24(3000) | (uint24(3000) << 12);
    uint24 internal constant PACKED_1000 = uint24(1000) | (uint24(1000) << 12);
    uint256 internal constant PIPS = 1_000_000;

    function _installV5() internal {
        // Three oracles, as on Gully Chain testnet: the release-1 and release-2 kits, then this (release-3) kit.
        address[] memory oracles = new address[](3);
        oracles[0] = address(new QuietOracle());
        oracles[1] = address(new QuietOracle());
        oracles[2] = address(kit);
        v5 = new GullyCoreProtocolFeeControllerV5(safe, address(clPM), address(binPM), 3000, oracles, new address[](0), 7 days);
        clPM.setProtocolFeeController(IProtocolFeeController(address(v5)));
        binPM.setProtocolFeeController(IProtocolFeeController(address(v5)));
    }

    function _padConfig(uint16 padBps, uint96 padLaunchFee) internal pure returns (TenantConfig memory c) {
        c.integrator = PAD_WALLET;
        c.integratorBps = padBps;
        c.integratorLaunchFeeWei = padLaunchFee;
        c.allowedPresets = 31;
        c.allowedBinShapes = 31;
        c.active = true;
        c.maxTaxBps = 1_000;
    }

    /// @dev A CL + Bin launch through `tenant` on OUTSIDE terms: the pad takes `padBps`, the creator the rest.
    function _padParams(string memory tag, address tenant, uint16 padBps, uint96 padLaunchFee)
        internal
        view
        returns (LaunchParamsV2 memory p)
    {
        p = _clAndBin(keccak256(bytes(tag)), address(quote));
        p.tenant = tenant;
        p.integrator = PAD_WALLET;
        p.integratorBps = padBps;
        p.integratorLaunchFeeWei = padLaunchFee;
        p.creatorBps = 10_000 - padBps;
        p.protocolBps = 0;
    }

    function _tax(uint16 creatorBps, uint16 protocolBps, uint16 integratorBps) internal pure returns (TaxParams memory t) {
        t.buyBps = 500;
        t.sellBps = 300;
        t.taxSeconds = type(uint32).max;
        t.creatorBps = creatorBps;
        t.protocolBps = protocolBps;
        t.integratorBps = integratorBps;
    }

    /// @dev Exact-input sell of the launch token on a CL leg.
    function _sellCL(PoolKey memory key, address token, uint256 amountIn) internal {
        bool launchIs0 = Currency.unwrap(key.currency0) == token;
        IERC20(token).approve(address(clRouter), type(uint256).max);
        clRouter.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: launchIs0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: launchIs0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    function _q() internal view returns (Currency) {
        return Currency.wrap(address(quote));
    }

    function _legId(LaunchParamsV2 memory p, uint256 leg) internal view returns (bytes32 poolId) {
        (, poolId,) = kit.computeLegKey(_token(p.userSalt), p.legs[leg]);
    }
}

contract LaunchpadKitV2TermsTest is TermsBase {
    function setUp() public {
        _deployAll();
        _installV5();
    }

    /*//////////////////////////////////////////////////////////////
                              OUTSIDE TERMS
    //////////////////////////////////////////////////////////////*/

    /// The owner rule, end to end on both pool types: an outside pad's launch pays the Safe the flat 0.30% of
    /// what enters the pool, and nothing through the kit, the guard or the lock.
    function test_OUTSIDE_padLaunchPaysTheSafeOnlyTheFlatFee() public {
        vm.prank(OUT_PAD);
        kit.setTenantConfig(_padConfig(3_000, 0.001 ether));
        assertFalse(_onGullyTerms(OUT_PAD));
        assertEq(kit.launchFeeFor(OUT_PAD), 0, "no protocol launch fee on outside terms");

        LaunchParamsV2 memory p = _padParams("out-pad", OUT_PAD, 3_000, 0.001 ether);
        uint256 safeOwed = kit.feesOwed(safe);
        uint256 launcherBefore = LAUNCHER.balance;
        vm.expectEmit(true, true, false, true, address(kit));
        emit ILaunchpadKitV2.LaunchTerms(_token(p.userSalt), OUT_PAD, false);
        // Overpaid by 0.5 ether: only the pad's own launch fee is owed, the rest comes back.
        LaunchResultV2 memory r = _launchWithValue(p, 0.001 ether + 0.5 ether);

        assertEq(LAUNCHER.balance, launcherBefore + 0.5 ether, "the excess is refunded");
        assertEq(r.protocolFeeWei, 0, "no Gully launch fee");
        assertEq(r.integratorFeeWei, 0.001 ether);
        assertEq(kit.feesOwed(safe), safeOwed, "the kit credits the Safe nothing");
        assertEq(kit.feesOwed(PAD_WALLET), 0.001 ether);
        assertEq(address(kit).balance, kit.totalFeesOwed());

        // Not flagged, so born at the flat fee, in both directions, on both pool types.
        assertFalse(kit.isLockedLaunch(r.poolIds[0]));
        assertFalse(kit.isLockedLaunch(r.poolIds[1]));
        assertFalse(v5.isLockedLaunchPool(PoolId.wrap(r.poolIds[0])));
        assertEq(_clProtocolFee(r.poolIds[0]), PACKED_3000, "CL pool born at 0.30% per direction");
        assertEq(_binProtocolFee(r.poolIds[1]), PACKED_3000, "Bin pool born at 0.30% per direction");

        // Locked all the same, with no protocol share in the lock or in the guard's split.
        assertTrue(clLocker.isLocked(r.lockIds[0]));
        assertTrue(binLocker.isLocked(r.lockIds[1]));
        Lock memory lk = clLocker.getLock(r.lockIds[0]);
        assertEq(lk.protocolBps, 0);
        assertEq(lk.creatorBps, 7_000);
        assertEq(lk.integratorBps, 3_000);
        BinLock memory bl = binLocker.getLock(r.lockIds[1]);
        assertEq(bl.protocolBps, 0);
        assertEq(bl.integratorBps, 3_000);
        LaunchTaxModule.FeeSplit memory fs = clHook.getFeeSplit(PoolId.wrap(r.poolIds[0]));
        assertEq(fs.protocolBps, 0);
        assertEq(fs.creatorBps, 7_000);
        assertEq(fs.integratorBps, 3_000);
        assertEq(binHook.getFeeSplit(PoolId.wrap(r.poolIds[1])).protocolBps, 0);

        vm.warp(uint256(r.startTime) + 1 days);

        // ---- a buy on the CL leg ----
        {
            PoolId id = PoolId.wrap(r.poolIds[0]);
            PoolKey memory key = _clKey(r.token, p.legs[0]);
            uint256 amountIn = 10 ether;
            uint256 poolFee = amountIn * clHook.currentFee(id) / PIPS;
            _buyCL(key, r.token, amountIn);

            assertEq(clHook.feeTaken(id, _q()), poolFee, "the pool's own fee, taken by the guard");
            uint256 accrued = clPM.protocolFeesAccrued(_q());
            uint256 flat = (amountIn - poolFee) * 3000 / PIPS;
            emit log_named_uint("CL accrued", accrued);
            emit log_named_uint("CL 0.30% of what entered the pool", flat);
            // With a zero LP fee core takes the swap step's whole fee amount, which SwapMath rounds in the
            // pool's favour: 0.30% of what entered the pool, to within a unit or two either way.
            assertApproxEqAbs(accrued, flat, 2, "0.30% of what entered the pool");

            clHook.settleFee(id, _q());
            assertEq(clHook.claimable(safe, _q()), 0, "the guard credits the Safe nothing");
            assertEq(clHook.claimable(PAD_WALLET, _q()), poolFee * 3_000 / 10_000, "the pad's 30%");
            assertEq(clHook.claimable(CREATOR, _q()) + clHook.claimable(PAD_WALLET, _q()), poolFee, "creator + pad = the whole fee");

            uint256 safeBefore = quote.balanceOf(safe);
            v5.sweep(address(clPM), _q());
            assertEq(quote.balanceOf(safe) - safeBefore, accrued, "the Safe receives exactly the flat fee");
            assertEq(clPM.protocolFeesAccrued(_q()), 0, "nothing left in the pool manager");
            assertEq(quote.balanceOf(address(v5)), 0, "nothing left in the controller");

            vm.prank(CREATOR);
            clHook.claim(_q(), CREATOR);
            vm.prank(PAD_WALLET);
            clHook.claim(_q(), PAD_WALLET);
            assertEq(clHook.totalOwed(_q()), 0, "nothing left owed in the guard");

            // ---- a sell on the CL leg: core's flat fee is taken from the INPUT, the launch token ----
            uint256 sell = IERC20(r.token).balanceOf(address(this)) / 2;
            uint256 guardBefore = clHook.feeTaken(id, _q());
            _sellCL(key, r.token, sell);
            uint256 accruedToken = clPM.protocolFeesAccrued(Currency.wrap(r.token));
            assertApproxEqAbs(accruedToken, sell * 3000 / PIPS, 3, "0.30% of the launch tokens sold, in the launch token");
            assertEq(clPM.protocolFeesAccrued(_q()), 0, "a sell accrues no core fee in the quote");
            assertGt(clHook.feeTaken(id, _q()), guardBefore, "the pool's own fee on a sell is taken from the quote paid out");
            clHook.settleFee(id, _q());
            assertEq(clHook.claimable(safe, _q()), 0, "still nothing to the Safe through the guard");
            uint256 safeTokenBefore = IERC20(r.token).balanceOf(safe);
            v5.sweep(address(clPM), Currency.wrap(r.token));
            assertEq(IERC20(r.token).balanceOf(safe) - safeTokenBefore, accruedToken, "the Safe receives the sell's flat fee");
            assertEq(clPM.protocolFeesAccrued(Currency.wrap(r.token)), 0);
        }

        // ---- a buy on the Bin leg ----
        {
            PoolId id = PoolId.wrap(r.poolIds[1]);
            PoolKey memory key = _clKey(r.token, p.legs[1]);
            uint256 amountIn = 4 ether;
            uint256 poolFee = amountIn * binHook.currentFee(id) / PIPS;
            _buyBin(key, r.token, amountIn);

            assertEq(binHook.feeTaken(id, _q()), poolFee);
            uint256 accrued = binPM.protocolFeesAccrued(_q());
            uint256 flat = (amountIn - poolFee) * 3000 / PIPS;
            emit log_named_uint("Bin accrued", accrued);
            emit log_named_uint("Bin 0.30% of what entered the pool", flat);
            assertApproxEqAbs(accrued, flat, 16, "0.30% of what entered the pool (core rounds per bin)");

            binHook.settleFee(id, _q());
            assertEq(binHook.claimable(safe, _q()), 0, "the Bin guard credits the Safe nothing");
            assertEq(binHook.claimable(CREATOR, _q()) + binHook.claimable(PAD_WALLET, _q()), poolFee);

            uint256 safeBefore = quote.balanceOf(safe);
            v5.sweep(address(binPM), _q());
            assertEq(quote.balanceOf(safe) - safeBefore, accrued);
            assertEq(binPM.protocolFeesAccrued(_q()), 0);
        }
    }

    function test_OUTSIDE_aLaunchWithNoTenantIsOnOutsideTerms() public {
        assertFalse(_onGullyTerms(address(0)));
        assertEq(kit.launchFeeFor(address(0)), 0);

        // The release-2 shape (protocol 50%) is refused without a Gully tenant...
        LaunchParamsV2 memory p = _oneCL(keccak256("direct"), address(quote));
        p.tenant = address(0);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.ProtocolShareFixed.selector, uint16(5_000), uint16(0)));
        vm.prank(LAUNCHER);
        kit.createLaunch{value: INITIAL_LAUNCH_FEE}(p);

        // ...and the outside shape launches for free.
        LaunchResultV2 memory r = _launchOutside(_outside(p));
        assertEq(r.protocolFeeWei, 0);
        assertFalse(kit.isLockedLaunch(r.poolIds[0]));
        assertEq(_clProtocolFee(r.poolIds[0]), PACKED_3000);
        assertEq(kit.getLeg(r.poolIds[0]).launchToken, r.token, "the leg is recorded although it is not flagged");
        assertEq(clLocker.getLock(r.lockIds[0]).protocolBps, 0);
    }

    function test_OUTSIDE_aRepeatedPoolIsStillRefused() public {
        // The duplicate check no longer rides on the flag: two legs of one outside launch on the same pool.
        LaunchParamsV2 memory p = _outside(_clAndBin(keccak256("dup"), address(quote)));
        p.legs[1] = p.legs[0];
        p.legs[0].weightBps = 6_000;
        p.legs[1].weightBps = 4_000;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.DuplicateLegPool.selector, _legId(p, 0)));
        vm.prank(LAUNCHER);
        kit.createLaunch(p);
    }

    /// Owner default (b): no cap on the pad's share beyond what the launch restates. The whole fee to the pad.
    function test_OUTSIDE_thePadMayTakeTheWholeFee() public {
        vm.prank(OUT_PAD);
        kit.setTenantConfig(_padConfig(10_000, 0));
        LaunchParamsV2 memory p = _padParams("pad-all", OUT_PAD, 10_000, 0);
        LaunchResultV2 memory r = _launchOutside(p);

        PoolId id = PoolId.wrap(r.poolIds[0]);
        LaunchTaxModule.FeeSplit memory fs = clHook.getFeeSplit(id);
        assertEq(fs.creator, address(0), "a creator with no share is not named in the guard");
        assertEq(fs.integratorBps, 10_000);
        assertEq(clLocker.getLock(r.lockIds[0]).creator, CREATOR, "the lock still names the creator");

        vm.warp(uint256(r.startTime) + 1 days);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 3 ether + 7);
        uint256 pot = clHook.feeTaken(id, _q());
        clHook.settleFee(id, _q());
        assertEq(clHook.claimable(PAD_WALLET, _q()), pot);
        assertEq(clHook.claimable(CREATOR, _q()), 0);
        assertEq(clHook.claimable(safe, _q()), 0);

        TenantConfig memory tooMuch = _padConfig(10_001, 0);
        vm.expectRevert(ILaunchpadKitV2.InvalidTenantConfig.selector);
        vm.prank(OUT_PAD);
        kit.setTenantConfig(tooMuch);
    }

    /// No rounding unit reaches the Safe through the guard, whatever the amount and the pad's share.
    function testFuzz_OUTSIDE_settlementNeverCreditsTheSafe(uint96 amountIn, uint16 padBps, uint256 salt) public {
        amountIn = uint96(bound(amountIn, 1e9, 50 ether));
        padBps = uint16(bound(padBps, 1, 9_999));
        LaunchParamsV2 memory p = _outside(_oneCL(keccak256(abi.encode("fuzz-out", salt)), address(quote)));
        p.integratorBps = padBps;
        p.creatorBps = 10_000 - padBps;
        p.tax = _tax(10_000 - padBps, 0, padBps);
        LaunchResultV2 memory r = _launchOutside(p);
        PoolId id = PoolId.wrap(r.poolIds[0]);

        vm.warp(uint256(r.startTime) + 1 days);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, amountIn);
        uint256 feePot = clHook.feeTaken(id, _q());
        uint256 taxPot = clHook.totalTaken(id, _q());
        clHook.settleFee(id, _q());
        clHook.settleTax(id, _q());

        assertEq(clHook.claimable(safe, _q()), 0, "not one unit to the Safe");
        assertEq(clHook.claimable(CREATOR, _q()) + clHook.claimable(INTEGRATOR, _q()), feePot + taxPot, "both pots fully credited");
        assertEq(clHook.pendingFee(id, _q()), 0);
        assertEq(clHook.pendingTax(id, _q()), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               GULLY TERMS
    //////////////////////////////////////////////////////////////*/

    function test_GULLY_designatedTenantKeepsRelease2TermsAndPaysNoFlatFee() public {
        assertTrue(_onGullyTerms(GULLY_PAD));
        assertEq(kit.launchFeeFor(GULLY_PAD), INITIAL_LAUNCH_FEE);

        LaunchParamsV2 memory p = _clAndBin(keccak256("gully"), address(quote));
        uint256 safeOwed = kit.feesOwed(safe);
        vm.expectEmit(true, true, false, true, address(kit));
        emit ILaunchpadKitV2.LaunchTerms(_token(p.userSalt), GULLY_PAD, true);
        LaunchResultV2 memory r = _launchWithValue(p, INITIAL_LAUNCH_FEE);

        assertEq(r.protocolFeeWei, INITIAL_LAUNCH_FEE, "the launch fee is charged");
        assertEq(kit.feesOwed(safe) - safeOwed, INITIAL_LAUNCH_FEE);
        assertTrue(kit.isLockedLaunch(r.poolIds[0]));
        assertTrue(kit.isLockedLaunch(r.poolIds[1]));
        assertTrue(v5.isLockedLaunchPool(PoolId.wrap(r.poolIds[0])));
        assertEq(_clProtocolFee(r.poolIds[0]), 0, "born at zero core fee");
        assertEq(_binProtocolFee(r.poolIds[1]), 0, "born at zero core fee");
        assertEq(clLocker.getLock(r.lockIds[0]).protocolBps, 5_000);
        assertEq(clHook.getFeeSplit(PoolId.wrap(r.poolIds[0])).protocolBps, 5_000);

        vm.warp(uint256(r.startTime) + 1 days);
        PoolId id = PoolId.wrap(r.poolIds[0]);
        PoolKey memory key = _clKey(r.token, p.legs[0]);
        uint256 amountIn = 10 ether;
        uint256 poolFee = amountIn * clHook.currentFee(id) / PIPS;
        _buyCL(key, r.token, amountIn);

        assertEq(clPM.protocolFeesAccrued(_q()), 0, "no flat fee on a Gully-terms launch");
        assertEq(clHook.feeTaken(id, _q()), poolFee);
        clHook.settleFee(id, _q());
        uint256 creatorPart = poolFee * 4_000 / 10_000;
        uint256 padPart = poolFee * 1_000 / 10_000;
        assertEq(clHook.claimable(CREATOR, _q()), creatorPart);
        assertEq(clHook.claimable(INTEGRATOR, _q()), padPart);
        assertEq(clHook.claimable(safe, _q()), poolFee - creatorPart - padPart, "the protocol's half");

        // And it can never be charged: no increase can be announced on a locked launch of a named kit.
        vm.expectRevert();
        vm.prank(safe);
        v5.schedulePoolFeeRaise(address(clPM), key, PACKED_3000);
        vm.expectRevert();
        vm.prank(safe);
        v5.setPoolProtocolFee(address(clPM), key, PACKED_3000);
        assertEq(_clProtocolFee(r.poolIds[0]), 0);
    }

    function test_GULLY_boundsOfRelease2AreHeldByTheKit() public {
        // The integrator's share of the trade fee: at most 20%.
        LaunchParamsV2 memory p = _oneCL(keccak256("g-int"), address(quote));
        p.integratorBps = 2_001;
        p.creatorBps = 2_999;
        _syncGullyTenant(p);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.GullyTermsShareOutOfBounds.selector, uint16(2_001)));
        vm.prank(LAUNCHER);
        kit.createLaunch{value: INITIAL_LAUNCH_FEE}(p);

        // The protocol's share of the tax: at least 10%.
        p = _oneCL(keccak256("g-taxfloor"), address(quote));
        p.tax = _tax(9_001, 999, 0);
        _syncGullyTenant(p);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.GullyTermsShareOutOfBounds.selector, uint16(999)));
        vm.prank(LAUNCHER);
        kit.createLaunch{value: INITIAL_LAUNCH_FEE}(p);

        // The integrator's share of the tax: at most 20%.
        p.tax = _tax(6_999, 1_000, 2_001);
        _syncGullyTenant(p);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.GullyTermsShareOutOfBounds.selector, uint16(2_001)));
        vm.prank(LAUNCHER);
        kit.createLaunch{value: INITIAL_LAUNCH_FEE}(p);

        // Exactly on the bounds it launches, and the Safe is credited its 10% of the tax.
        p.tax = _tax(7_000, 1_000, 2_000);
        _syncGullyTenant(p);
        LaunchResultV2 memory r = _launch(p);
        PoolId id = PoolId.wrap(r.poolIds[0]);
        vm.warp(uint256(r.startTime) + 1 days);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 10 ether);
        uint256 taxPot = clHook.totalTaken(id, _q());
        assertEq(taxPot, 10 ether * 500 / 10_000, "5% buy tax");
        clHook.settleTax(id, _q());
        assertEq(clHook.claimable(safe, _q()), taxPot - taxPot * 7_000 / 10_000 - taxPot * 2_000 / 10_000);

        // Without the launch fee a Gully-terms launch is refused.
        p = _oneCL(keccak256("g-nofee"), address(quote));
        _syncGullyTenant(p);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InsufficientLaunchFee.selector, INITIAL_LAUNCH_FEE, 0));
        vm.prank(LAUNCHER);
        kit.createLaunch(p);
    }

    /*//////////////////////////////////////////////////////////////
                                TWO KEYS
    //////////////////////////////////////////////////////////////*/

    function test_KEYS_matrix() public {
        _matrixCase(false, false);
        _matrixCase(true, false);
        _matrixCase(false, true);
        _matrixCase(true, true);
    }

    function _matrixCase(bool designated, bool optedIn) internal {
        address tenant = address(uint160(0x7700) + (designated ? 1 : 0) + (optedIn ? 2 : 0));
        if (designated) {
            vm.prank(safe);
            kit.setGullyTenant(tenant, true);
        }
        TenantConfig memory c = _padConfig(1_000, 0);
        c.gullyTerms = optedIn;
        vm.prank(tenant);
        kit.setTenantConfig(c);

        bool gully = designated && optedIn;
        assertEq(kit.gullyDesignated(tenant), designated);
        assertEq(kit.tenantConfig(tenant).gullyTerms, optedIn);
        assertEq(_onGullyTerms(tenant), gully, "both keys, and only both");
        assertEq(kit.launchFeeFor(tenant), gully ? INITIAL_LAUNCH_FEE : 0);

        LaunchParamsV2 memory p = _oneCL(keccak256(abi.encode("matrix", designated, optedIn)), address(quote));
        p.tenant = tenant;
        p.integrator = PAD_WALLET;

        // The other terms' shape is refused.
        p.protocolBps = gully ? 0 : 5_000;
        p.creatorBps = gully ? 9_000 : 4_000;
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchpadKitV2.ProtocolShareFixed.selector, p.protocolBps, gully ? uint16(5_000) : uint16(0))
        );
        vm.prank(LAUNCHER);
        kit.createLaunch{value: INITIAL_LAUNCH_FEE}(p);

        // Its own terms launch.
        p.protocolBps = gully ? 5_000 : 0;
        p.creatorBps = gully ? 4_000 : 9_000;
        LaunchResultV2 memory r = _launchWithValue(p, gully ? INITIAL_LAUNCH_FEE : 0);
        assertEq(kit.isLockedLaunch(r.poolIds[0]), gully);
        assertEq(_clProtocolFee(r.poolIds[0]), gully ? 0 : PACKED_3000);
        assertEq(r.protocolFeeWei, gully ? INITIAL_LAUNCH_FEE : 0);
        assertEq(clHook.getFeeSplit(PoolId.wrap(r.poolIds[0])).protocolBps, gully ? 5_000 : 0);
    }

    function test_KEYS_onlyTheOwnerDesignates() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vm.prank(ATTACKER);
        kit.setGullyTenant(OUT_PAD, true);

        // A tenant cannot designate itself.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUT_PAD));
        vm.prank(OUT_PAD);
        kit.setGullyTenant(OUT_PAD, true);

        vm.expectRevert(ILaunchpadKitV2.ZeroAddress.selector);
        vm.prank(safe);
        kit.setGullyTenant(address(0), true);

        vm.expectEmit(true, false, false, true, address(kit));
        emit ILaunchpadKitV2.GullyTenantSet(OUT_PAD, true);
        vm.prank(safe);
        kit.setGullyTenant(OUT_PAD, true);
        assertTrue(kit.gullyDesignated(OUT_PAD));
        assertFalse(_onGullyTerms(OUT_PAD), "designation alone changes nothing: the tenant has not opted in");

        // The tenant's own key, and its event.
        TenantConfig memory c = _padConfig(1_000, 0);
        c.gullyTerms = true;
        vm.expectEmit(true, false, false, true, address(kit));
        emit ILaunchpadKitV2.TenantTermsSet(OUT_PAD, true);
        vm.prank(OUT_PAD);
        kit.setTenantConfig(c);
        assertTrue(_onGullyTerms(OUT_PAD));

        vm.expectEmit(true, false, false, true, address(kit));
        emit ILaunchpadKitV2.GullyTenantSet(OUT_PAD, false);
        vm.prank(safe);
        kit.setGullyTenant(OUT_PAD, false);
        assertFalse(_onGullyTerms(OUT_PAD));
    }

    /// A status change never touches a launch that exists, and only changes what the next launch must restate.
    function test_KEYS_aLaunchKeepsTheTermsItWasCreatedOn() public {
        LaunchParamsV2 memory a = _oneCL(keccak256("flip-a"), address(quote));
        LaunchResultV2 memory ra = _launch(a);
        assertTrue(kit.isLockedLaunch(ra.poolIds[0]));

        // The tenant opts out.
        TenantConfig memory c = _gullyTenantConfig();
        c.gullyTerms = false;
        vm.prank(GULLY_PAD);
        kit.setTenantConfig(c);
        assertFalse(_onGullyTerms(GULLY_PAD));
        assertTrue(kit.isLockedLaunch(ra.poolIds[0]), "the existing launch keeps its flag");
        assertEq(_clProtocolFee(ra.poolIds[0]), 0);

        // A launch signed for Gully terms now reverts; it is not re-priced.
        LaunchParamsV2 memory b = _oneCL(keccak256("flip-b"), address(quote));
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.ProtocolShareFixed.selector, uint16(5_000), uint16(0)));
        vm.prank(LAUNCHER);
        kit.createLaunch{value: INITIAL_LAUNCH_FEE}(b);

        // Restated for outside terms it launches, unflagged, at the flat fee, with no launch fee.
        b.protocolBps = 0;
        b.creatorBps = 9_000;
        LaunchResultV2 memory rb = _launchOutside(b);
        assertFalse(kit.isLockedLaunch(rb.poolIds[0]));
        assertEq(_clProtocolFee(rb.poolIds[0]), PACKED_3000);
        assertEq(rb.protocolFeeWei, 0);

        // Opted back in, then the Safe withdraws the designation: outside again; launch A is untouched.
        c.gullyTerms = true;
        vm.prank(GULLY_PAD);
        kit.setTenantConfig(c);
        assertTrue(_onGullyTerms(GULLY_PAD));
        vm.prank(safe);
        kit.setGullyTenant(GULLY_PAD, false);
        assertFalse(_onGullyTerms(GULLY_PAD));
        assertTrue(kit.isLockedLaunch(ra.poolIds[0]));
        assertFalse(kit.isLockedLaunch(rb.poolIds[0]), "and an outside launch never gains the flag");
    }

    /*//////////////////////////////////////////////////////////////
                                   TAX
    //////////////////////////////////////////////////////////////*/

    function test_TAX_outsideTermsGiveTheProtocolNoneOfIt() public {
        LaunchParamsV2 memory p = _outside(_oneCL(keccak256("tax-out"), address(quote)));
        p.tax = _tax(9_000, 1_000, 0);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TaxProtocolShareFixed.selector, uint16(1_000), uint16(0)));
        vm.prank(LAUNCHER);
        kit.createLaunch(p);

        // A pad bucket above the old 20% cap is the creator's to agree to.
        p.tax = _tax(6_000, 0, 4_000);
        LaunchResultV2 memory r = _launchOutside(p);
        PoolId id = PoolId.wrap(r.poolIds[0]);
        vm.warp(uint256(r.startTime) + 1 days);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 10 ether);

        uint256 taxPot = clHook.totalTaken(id, _q());
        assertEq(taxPot, 10 ether * 500 / 10_000, "5% buy tax");
        clHook.settleTax(id, _q());
        assertEq(clHook.claimable(safe, _q()), 0, "none of the tax to the Safe");
        assertEq(clHook.claimable(INTEGRATOR, _q()), taxPot * 4_000 / 10_000);
        assertEq(clHook.claimable(CREATOR, _q()), taxPot - taxPot * 4_000 / 10_000);
    }

    function test_TAX_reconfigureUsesTheTermsOfTheLaunch() public {
        // ---- a Gully-terms launch ----
        LaunchParamsV2 memory g = _oneCL(keccak256("re-g"), address(quote));
        LaunchResultV2 memory rg = _launch(g);
        PoolKey[] memory gk = new PoolKey[](1);
        gk[0] = _clKey(rg.token, g.legs[0]);

        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.GullyTermsShareOutOfBounds.selector, uint16(0)));
        vm.prank(OPERATOR);
        kit.reconfigureLaunch(rg.token, gk, g.schedule, _tax(10_000, 0, 0));

        // The tenant opting out afterwards does not move an existing launch onto outside terms.
        TenantConfig memory c = _gullyTenantConfig();
        c.gullyTerms = false;
        vm.prank(GULLY_PAD);
        kit.setTenantConfig(c);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.GullyTermsShareOutOfBounds.selector, uint16(0)));
        vm.prank(OPERATOR);
        kit.reconfigureLaunch(rg.token, gk, g.schedule, _tax(10_000, 0, 0));

        vm.prank(OPERATOR);
        kit.reconfigureLaunch(rg.token, gk, g.schedule, _tax(9_000, 1_000, 0));
        assertEq(clHook.getTax(PoolId.wrap(rg.poolIds[0])).protocolBps, 1_000);

        // ---- an outside-terms launch ----
        LaunchParamsV2 memory o = _outside(_oneCL(keccak256("re-o"), address(quote)));
        LaunchResultV2 memory ro = _launchOutside(o);
        PoolKey[] memory ok = new PoolKey[](1);
        ok[0] = _clKey(ro.token, o.legs[0]);

        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TaxProtocolShareFixed.selector, uint16(1_000), uint16(0)));
        vm.prank(OPERATOR);
        kit.reconfigureLaunch(ro.token, ok, o.schedule, _tax(9_000, 1_000, 0));

        vm.prank(OPERATOR);
        kit.reconfigureLaunch(ro.token, ok, o.schedule, _tax(10_000, 0, 0));
        assertEq(clHook.getTax(PoolId.wrap(ro.poolIds[0])).protocolBps, 0);
        assertEq(clHook.getTax(PoolId.wrap(ro.poolIds[0])).buyBps, 500);
    }

    /*//////////////////////////////////////////////////////////////
                     THE CONTROLLER, SEEN FROM A LAUNCH
    //////////////////////////////////////////////////////////////*/

    function test_CONTROLLER_thatZeroesAnOutsideLaunchIsRefused() public {
        // A controller that lists this kit's guard as zero-fee would silently waive what an outside launch owes.
        vm.prank(safe);
        v5.addZeroFeeHook(address(clHook));
        LaunchParamsV2 memory p = _outside(_oneCL(keccak256("zeroed"), address(quote)));
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchpadKitV2.ProtocolFeeNotBuilderFee.selector, _legId(p, 0), uint24(0), uint256(3000))
        );
        vm.prank(LAUNCHER);
        kit.createLaunch(p);
    }

    function test_CONTROLLER_thatDoesNotNameTheKitCannotChargeAGullyLaunch() public {
        // A V5 installed without this kit among its oracles would stamp 0.30% on a pool that already pays 50%.
        address[] memory oracles = new address[](1);
        oracles[0] = address(new QuietOracle());
        GullyCoreProtocolFeeControllerV5 other =
            new GullyCoreProtocolFeeControllerV5(safe, address(clPM), address(binPM), 3000, oracles, new address[](0), 7 days);
        clPM.setProtocolFeeController(IProtocolFeeController(address(other)));

        LaunchParamsV2 memory p = _oneCL(keccak256("unnamed"), address(quote));
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.ProtocolFeeNotZero.selector, _legId(p, 0), PACKED_3000));
        vm.prank(LAUNCHER);
        kit.createLaunch{value: INITIAL_LAUNCH_FEE}(p);

        // The same controller prices an outside launch correctly, so that one goes through.
        LaunchResultV2 memory r = _launchOutside(_outside(_oneCL(keccak256("unnamed-out"), address(quote))));
        assertEq(_clProtocolFee(r.poolIds[0]), PACKED_3000);
    }

    function test_CONTROLLER_perPoolLoweringAndAZeroFlatFee() public {
        LaunchParamsV2 memory p = _outside(_oneCL(keccak256("lower"), address(quote)));
        LaunchResultV2 memory r = _launchOutside(p);
        PoolId id = PoolId.wrap(r.poolIds[0]);
        PoolKey memory key = _clKey(r.token, p.legs[0]);
        vm.warp(uint256(r.startTime) + 1 days);

        // The Safe lowers this one pool to 0.10%, at once.
        vm.prank(safe);
        v5.setPoolProtocolFee(address(clPM), key, PACKED_1000);
        assertEq(_clProtocolFee(r.poolIds[0]), PACKED_1000);
        uint256 amountIn = 10 ether;
        uint256 poolFee = amountIn * clHook.currentFee(id) / PIPS;
        _buyCL(key, r.token, amountIn);
        assertApproxEqAbs(clPM.protocolFeesAccrued(_q()), (amountIn - poolFee) * 1000 / PIPS, 2, "0.10% after the lowering");

        // A flat fee of zero is a decision the Safe may take at once; a launch then is born at zero and is not refused.
        vm.prank(safe);
        v5.setBuilderFee(0);
        LaunchResultV2 memory r2 = _launchOutside(_outside(_oneCL(keccak256("lower-2"), address(quote))));
        assertEq(_clProtocolFee(r2.poolIds[0]), 0);
        assertFalse(kit.isLockedLaunch(r2.poolIds[0]));
    }
}

/// @notice Construction, and a controller without `builderFee()` (the release-2 tolerance).
contract LaunchpadKitV2TermsConstructionTest is TermsBase {
    function setUp() public {
        _deployAll(); // V3 over V2 installed: no builderFee()
    }

    function test_CTOR_refusesLockersWithAProtocolFloor() public {
        LaunchpadKitV2.Deployment memory d = _deployment();
        d.clLocker = new GullyCoreLPLocker(clPosm, safe, 2_000, 5_000, 10_000);
        d.binLocker = new GullyCoreBinLPLocker(binPosm, safe, 2_000, 5_000, 10_000, 64);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.LockerFloorNotZero.selector, address(d.clLocker), uint16(2_000)));
        new LaunchpadKitV2(d);
    }

    function test_CTOR_refusesLockersWithAnIntegratorCap() public {
        LaunchpadKitV2.Deployment memory d = _deployment();
        d.clLocker = new GullyCoreLPLocker(clPosm, safe, 0, 5_000, 2_000);
        d.binLocker = new GullyCoreBinLPLocker(binPosm, safe, 0, 5_000, 2_000, 64);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.LockerMismatch.selector, address(d.clLocker)));
        new LaunchpadKitV2(d);
    }

    function test_CTOR_refusesGuardsOfAnEarlierRelease() public {
        LaunchpadKitV2.Deployment memory d = _deployment();
        bytes4[2] memory floors = [bytes4(keccak256("MIN_PROTOCOL_BPS()")), bytes4(keccak256("MIN_FEE_PROTOCOL_BPS()"))];
        address[2] memory hooks = [address(clHook), address(binHook)];
        for (uint256 f; f < 2; ++f) {
            for (uint256 h; h < 2; ++h) {
                vm.mockCall(hooks[h], abi.encodeWithSelector(floors[f]), abi.encode(uint16(1_000)));
                vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.HookTaxMismatch.selector, address(binHook)));
                new LaunchpadKitV2(d);
                vm.clearMockedCalls();
            }
        }
        // The release-2 integrator cap on both guards.
        for (uint256 h; h < 2; ++h) {
            vm.mockCall(hooks[h], abi.encodeWithSelector(bytes4(keccak256("MAX_INTEGRATOR_BPS()"))), abi.encode(uint16(2_000)));
        }
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.HookTaxMismatch.selector, address(binHook)));
        new LaunchpadKitV2(d);
        vm.clearMockedCalls();
        new LaunchpadKitV2(d); // and with nothing mocked the same wiring deploys
    }

    function test_CTOR_gullyTermsConstants() public view {
        assertEq(kit.PROTOCOL_TRADE_SHARE_BPS(), 5_000);
        assertEq(kit.GULLY_TAX_PROTOCOL_FLOOR_BPS(), 1_000);
        assertEq(kit.GULLY_MAX_INTEGRATOR_BPS(), 2_000);
        assertEq(kit.MIN_TRADE_FEE_PIPS(), 10_000);
        assertEq(kit.LAUNCH_TOTAL_SUPPLY(), 1_000_000_000 ether);
        assertEq(kit.maxIntegratorBps(), 10_000);
        assertEq(kit.maxTaxIntegratorBps(), 10_000);
        assertEq(clHook.MIN_PROTOCOL_BPS(), 0);
        assertEq(clHook.MIN_FEE_PROTOCOL_BPS(), 0);
        assertEq(binHook.MAX_PROTOCOL_BPS(), 5_000);
        assertEq(clLocker.minProtocolBps(), 0);
        assertEq(binLocker.maxIntegratorBps(), 10_000);
    }

    /// Under a controller with no flat fee (V2 behind V3) an outside launch is not asserted against: it is born
    /// at whatever that controller stamps. The kit stays usable; the flat fee needs V5.
    function test_LEGACY_controllerWithoutAFlatFeeIsTolerated() public {
        LaunchResultV2 memory r = _launchOutside(_outside(_oneCL(keccak256("legacy"), address(quote))));
        assertFalse(kit.isLockedLaunch(r.poolIds[0]));
        assertEq(_clProtocolFee(r.poolIds[0]), PACKED_999);

        LaunchResultV2 memory g = _launch(_oneCL(keccak256("legacy-g"), address(quote)));
        assertTrue(kit.isLockedLaunch(g.poolIds[0]));
        assertEq(_clProtocolFee(g.poolIds[0]), 0);
    }
}

/// @notice The lockers with a pool that earns LP fees (a 20% LP share of the guard's fee): a lock with no
/// protocol share pays the creator and the pad only.
contract LaunchpadKitV2TermsLockerTest is TermsBase {
    function _lpShareBps() internal pure override returns (uint16) {
        return 2_000;
    }

    function setUp() public {
        _deployAll();
        _installV5();
    }

    function test_LOCKER_outsideLockPaysCreatorAndPadOnly() public {
        vm.prank(OUT_PAD);
        kit.setTenantConfig(_padConfig(3_333, 0));
        LaunchParamsV2 memory p = _padParams("lock-out", OUT_PAD, 3_333, 0);
        LaunchResultV2 memory r = _launchOutside(p);
        vm.warp(uint256(r.startTime) + 1 days);

        _buyCL(_clKey(r.token, p.legs[0]), r.token, 7 ether + 13);
        (uint256 a0, uint256 a1) = clLocker.collectFees(r.lockIds[0]);
        uint256 inQuote = Currency.unwrap(_clKey(r.token, p.legs[0]).currency0) == r.token ? a1 : a0;
        assertGt(inQuote, 0, "the locked position earned its share of the buy's fee");
        assertEq(clLocker.claimable(safe, _q()), 0, "the CL locker credits the Safe nothing");
        assertEq(clLocker.claimable(CREATOR, _q()) + clLocker.claimable(PAD_WALLET, _q()), inQuote);
        assertEq(clLocker.claimable(PAD_WALLET, _q()), inQuote * 3_333 / 10_000);

        _buyBin(_clKey(r.token, p.legs[1]), r.token, 3 ether + 11);
        (a0, a1) = binLocker.collectFees(r.lockIds[1]);
        inQuote = Currency.unwrap(_clKey(r.token, p.legs[1]).currency0) == r.token ? a1 : a0;
        assertGt(inQuote, 0);
        assertEq(binLocker.claimable(safe, _q()), 0, "the Bin locker credits the Safe nothing");
        assertEq(binLocker.claimable(CREATOR, _q()) + binLocker.claimable(PAD_WALLET, _q()), inQuote);
    }

    function test_LOCKER_gullyLockStillPaysTheProtocolHalf() public {
        LaunchParamsV2 memory p = _oneCL(keccak256("lock-g"), address(quote));
        LaunchResultV2 memory r = _launch(p);
        vm.warp(uint256(r.startTime) + 1 days);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 7 ether);
        (uint256 a0, uint256 a1) = clLocker.collectFees(r.lockIds[0]);
        uint256 inQuote = Currency.unwrap(_clKey(r.token, p.legs[0]).currency0) == r.token ? a1 : a0;
        assertGt(inQuote, 0);
        uint256 creatorPart = inQuote * 4_000 / 10_000;
        uint256 padPart = inQuote * 1_000 / 10_000;
        assertEq(clLocker.claimable(safe, _q()), inQuote - creatorPart - padPart);
    }

    function testFuzz_SPLIT_noProtocolShareMeansNoProtocolDust(uint128 amount, uint16 creatorBps) public view {
        creatorBps = uint16(bound(creatorBps, 0, 10_000));
        (uint256 c, uint256 i, uint256 pr) = clLocker.splitAmount(amount, creatorBps, 10_000 - creatorBps);
        assertEq(pr, 0);
        assertEq(c + i, amount);
        assertEq(i, uint256(amount) * (10_000 - creatorBps) / 10_000, "the pad's share is floored, the creator takes the rest");
        (c, i, pr) = binLocker.splitAmount(amount, creatorBps, 10_000 - creatorBps);
        assertEq(pr, 0);
        assertEq(c + i, amount);
    }

    function testFuzz_SPLIT_withAProtocolShareTheRemainderIsTheProtocols(uint128 amount, uint16 creatorBps, uint16 integratorBps)
        public
        view
    {
        creatorBps = uint16(bound(creatorBps, 0, 9_999));
        integratorBps = uint16(bound(integratorBps, 0, 9_999 - creatorBps));
        (uint256 c, uint256 i, uint256 pr) = clLocker.splitAmount(amount, creatorBps, integratorBps);
        assertEq(c, uint256(amount) * creatorBps / 10_000);
        assertEq(i, uint256(amount) * integratorBps / 10_000);
        assertEq(pr, amount - c - i);
        (uint256 c2, uint256 i2, uint256 pr2) = binLocker.splitAmount(amount, creatorBps, integratorBps);
        assertEq(c2, c);
        assertEq(i2, i);
        assertEq(pr2, pr);
    }
}
