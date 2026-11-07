// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {LaunchTaxModule} from "gullycore-hooks/src/launch/LaunchTaxModule.sol";

import {
    ILaunchpadKitV2, LaunchParamsV2, LaunchResultV2, ScheduleParams, TaxParams, LegRecord, LegKind
} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {LaunchPresets, Preset, PresetParams} from "../../src/libraries/LaunchPresets.sol";
import {KitV2Fixture} from "./KitV2Fixture.sol";

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

/// @title LaunchpadKitV2FeeFloor
/// @notice Owner decision 2026-11-02, "1% on every launch type, 50/50, the protocol gets 0.50% forever; the
/// creator tax lasts forever". Every test here fails on the pre-2026-11-02 kit (0.30% presets, a free
/// protocol share in [20%, 50%], the 180-day tax ceiling). For the external audit.
contract LaunchpadKitV2FeeFloorTest is KitV2Fixture {
    function setUp() public {
        _deployAll();
    }

    function launchAs(LaunchParamsV2 memory p, uint256 value) external {
        _launchWithValue(p, value);
    }

    function _custom(uint24 initialFee, uint24 finalFee, bool enabled) internal pure returns (ScheduleParams memory s) {
        s = ScheduleParams({
            preset: Preset.Custom,
            initialFeeBips: initialFee,
            finalFeeBips: finalFee,
            decaySeconds: 60,
            enabled: enabled,
            startDelaySeconds: 120
        });
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    function test_FLOOR_constants() public view {
        assertEq(kit.MIN_TRADE_FEE_PIPS(), 10_000, "1% in pips");
        assertEq(kit.PROTOCOL_TRADE_SHARE_BPS(), 5_000, "50%");
        assertEq(kit.TAX_SECONDS_FOREVER(), type(uint32).max);
        assertEq(clHook.TAX_FOREVER(), type(uint40).max);
        assertEq(binHook.TAX_FOREVER(), type(uint40).max);
        assertEq(kit.LAUNCH_TOTAL_SUPPLY(), 1_000_000_000 ether, "1B tokens");
    }

    /*//////////////////////////////////////////////////////////////
                          SUPPLY: FIXED AT 1B
    //////////////////////////////////////////////////////////////*/

    function test_SUPPLY_onlyOneBillionLaunches() public {
        uint256[5] memory bad = [uint256(1_000_000_000 ether - 1), 1_000_000_000 ether + 1, 100_000_000 ether, 1_000_000_000_000 ether, 1_000_000_000];
        for (uint256 i; i < bad.length; ++i) {
            LaunchParamsV2 memory p = _clAndBin(keccak256(abi.encode("supply", i)), address(quote));
            p.totalSupply = bad[i];
            if (p.seedSupply > bad[i]) p.seedSupply = bad[i];
            vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TotalSupplyFixed.selector, bad[i], uint256(1_000_000_000 ether)));
            this.launchAs(p, 1 ether);
        }
        LaunchParamsV2 memory ok = _clAndBin(keccak256("supply-ok"), address(quote));
        LaunchResultV2 memory r = _launch(ok);
        assertEq(IERC20Supply(r.token).totalSupply(), 1_000_000_000 ether);
    }

    /// @notice Every named preset settles at exactly 1%.
    function test_FLOOR_everyPresetSettlesAtOnePercent() public pure {
        for (uint8 i = 1; i <= uint8(Preset.NoTax); ++i) {
            PresetParams memory pp = LaunchPresets.params(Preset(i));
            assertEq(pp.finalFeeBips, 10_000, "preset final fee");
            assertGe(pp.initialFeeBips, pp.finalFeeBips);
        }
        PresetParams memory flat = LaunchPresets.params(Preset.NoTax);
        assertEq(flat.initialFeeBips, 10_000, "NoTax is a flat 1%");
        assertFalse(flat.enabled);
    }

    /*//////////////////////////////////////////////////////////////
                        1% ON EVERY LAUNCH TYPE
    //////////////////////////////////////////////////////////////*/

    /// @notice FairLaunch and NoTax on CL + Bin, Stealth and AntiSniperAggressive on CL: each pool ends at 1%,
    /// split 50% to the protocol in the guard and in the lock.
    function test_FLOOR_presetLaunchesEndAtOnePercentFiftyFifty() public {
        Preset[2] memory both = [Preset.FairLaunch, Preset.NoTax];
        for (uint256 i; i < both.length; ++i) {
            LaunchParamsV2 memory p = _clAndBin(keccak256(abi.encode("preset-both", i)), address(quote));
            p.schedule.preset = both[i];
            _assertOnePercentFiftyFifty(_launch(p));
        }
        Preset[2] memory clOnly = [Preset.Stealth, Preset.AntiSniperAggressive];
        for (uint256 i; i < clOnly.length; ++i) {
            LaunchParamsV2 memory p = _oneCL(keccak256(abi.encode("preset-cl", i)), address(quote));
            p.schedule.preset = clOnly[i];
            p.legs[0].maxBuyPerTx = 1 ether;
            _assertOnePercentFiftyFifty(_launch(p));
        }
    }

    function test_FLOOR_customAtOnePercentLaunches() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("custom-1pct"), address(quote));
        p.schedule = _custom(100_000, 10_000, true);
        _assertOnePercentFiftyFifty(_launch(p));
    }

    function test_FLOOR_customBelowOnePercentIsRefused() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("custom-low"), address(quote));
        p.schedule = _custom(500_000, 9_999, true);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TradeFeeBelowFloor.selector, uint24(9_999), uint24(10_000)));
        this.launchAs(p, 1 ether);
        // The old 0.30% default.
        p.schedule = _custom(500_000, 3_000, true);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TradeFeeBelowFloor.selector, uint24(3_000), uint24(10_000)));
        this.launchAs(p, 1 ether);
        // A disabled schedule pins the fee at finalFeeBips: the same floor.
        p.schedule = _custom(3_000, 3_000, false);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TradeFeeBelowFloor.selector, uint24(3_000), uint24(10_000)));
        this.launchAs(p, 1 ether);
        p.schedule = _custom(0, 0, false);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TradeFeeBelowFloor.selector, uint24(0), uint24(10_000)));
        this.launchAs(p, 1 ether);
    }

    /// @notice Reconfiguration before the open cannot lower the fee either.
    function test_FLOOR_reconfigureCannotGoBelowOnePercent() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("reconf-low"), address(quote));
        LaunchResultV2 memory r = _launch(p);
        PoolKey[] memory keys = new PoolKey[](2);
        (keys[0],,) = kit.computeLegKey(r.token, p.legs[0]);
        (keys[1],,) = kit.computeLegKey(r.token, p.legs[1]);
        ScheduleParams memory s = _custom(50_000, 9_999, true);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TradeFeeBelowFloor.selector, uint24(9_999), uint24(10_000)));
        kit.reconfigureLaunch(r.token, keys, s, _noTax());
        s = _custom(50_000, 10_000, true);
        vm.prank(OPERATOR);
        kit.reconfigureLaunch(r.token, keys, s, _noTax());
        assertEq(clHook.getLaunch(PoolId.wrap(r.poolIds[0])).finalFeeBips, 10_000);
        assertEq(binHook.getLaunch(PoolId.wrap(r.poolIds[1])).finalFeeBips, 10_000);
    }

    /*//////////////////////////////////////////////////////////////
                    THE PROTOCOL'S 50% IS NOT A CHOICE
    //////////////////////////////////////////////////////////////*/

    function test_FLOOR_protocolShareIsExactlyHalf() public {
        uint16[4] memory bad = [uint16(2_000), 4_999, 5_001, 0];
        for (uint256 i; i < bad.length; ++i) {
            LaunchParamsV2 memory p = _clAndBin(keccak256(abi.encode("split", i)), address(quote));
            p.protocolBps = bad[i];
            p.creatorBps = uint16(10_000 - p.integratorBps - bad[i]);
            vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.ProtocolShareFixed.selector, bad[i], uint16(5_000)));
            this.launchAs(p, 1 ether);
        }
    }

    /// @notice The integrator is paid out of the creator's half, never the protocol's.
    function test_FLOOR_integratorComesOutOfTheCreatorsHalf() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("integrator-half"), address(quote));
        assertEq(p.integratorBps, 1_000);
        LaunchResultV2 memory r = _launch(p);
        LaunchTaxModule.FeeSplit memory f = clHook.getFeeSplit(PoolId.wrap(r.poolIds[0]));
        assertEq(f.protocolBps, 5_000);
        assertEq(f.creatorBps + f.integratorBps, 5_000);
    }

    /// @notice A creator tax, of any size or split, never touches the trade fee's split.
    function test_FLOOR_taxDoesNotMoveTheTradeFeeSplit() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("tax-split"), address(quote));
        p.tax = TaxParams({buyBps: 1_000, sellBps: 1_000, taxSeconds: kit.TAX_SECONDS_FOREVER(), creatorBps: 7_000, protocolBps: 1_000, integratorBps: 2_000});
        _assertOnePercentFiftyFifty(_launch(p));
    }

    /*//////////////////////////////////////////////////////////////
                         THE CREATOR TAX: FOREVER
    //////////////////////////////////////////////////////////////*/

    function test_FOREVER_taxNeverExpires() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("forever"), address(quote));
        p.tax = TaxParams({buyBps: 100, sellBps: 100, taxSeconds: kit.TAX_SECONDS_FOREVER(), creatorBps: 9_000, protocolBps: 1_000, integratorBps: 0});
        LaunchResultV2 memory r = _launch(p);
        PoolId cl = PoolId.wrap(r.poolIds[0]);
        PoolId bn = PoolId.wrap(r.poolIds[1]);
        assertEq(clHook.getTax(cl).expiresAt, type(uint40).max, "CL expiry is forever");
        assertEq(binHook.getTax(bn).expiresAt, type(uint40).max, "Bin expiry is forever");
        vm.warp(block.timestamp + 100 * 365 days);
        (uint16 b, uint16 s) = clHook.currentTaxRates(cl);
        assertEq(b, 100);
        assertEq(s, 100);
        (b, s) = binHook.currentTaxRates(bn);
        assertEq(b, 100);
        assertEq(s, 100);
    }

    /// @notice Past the old 180-day ceiling, a finite tax is accepted and ends when it says.
    function test_FOREVER_longFiniteTaxIsAccepted() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("long"), address(quote));
        p.tax = TaxParams({buyBps: 100, sellBps: 0, taxSeconds: 365 days, creatorBps: 9_000, protocolBps: 1_000, integratorBps: 0});
        LaunchResultV2 memory r = _launch(p);
        PoolId cl = PoolId.wrap(r.poolIds[0]);
        assertEq(clHook.getTax(cl).expiresAt, uint40(r.startTime) + 365 days);
        vm.warp(uint256(r.startTime) + 365 days);
        (uint16 b,) = clHook.currentTaxRates(cl);
        assertEq(b, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertOnePercentFiftyFifty(LaunchResultV2 memory r) internal view {
        uint256 settled = uint256(r.startTime) + 30 days; // past every preset's window
        for (uint256 i; i < r.poolIds.length; ++i) {
            PoolId id = PoolId.wrap(r.poolIds[i]);
            LegRecord memory leg = kit.getLeg(r.poolIds[i]);
            if (leg.kind == LegKind.CL) {
                assertEq(clHook.getLaunch(id).finalFeeBips, 10_000, "CL final fee");
                assertEq(clHook.feeAt(id, settled), 10_000, "CL settled fee");
                assertEq(clHook.getFeeSplit(id).protocolBps, 5_000, "CL guard split");
                assertEq(clLocker.getLock(r.lockIds[i]).protocolBps, 5_000, "CL lock split");
            } else {
                assertEq(binHook.getLaunch(id).finalFeeBips, 10_000, "Bin final fee");
                assertEq(binHook.feeAt(id, settled), 10_000, "Bin settled fee");
                assertEq(binHook.getFeeSplit(id).protocolBps, 5_000, "Bin guard split");
                assertEq(binLocker.getLock(r.lockIds[i]).protocolBps, 5_000, "Bin lock split");
            }
        }
    }
}
