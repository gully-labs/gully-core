// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerOwner, ICLPoolManagerWithPauseOwnable} from "infinity-core/src/pool-cl/CLPoolManagerOwner.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolManagerOwner, IBinPoolManagerWithPauseOwnable} from "infinity-core/src/pool-bin/BinPoolManagerOwner.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {GullyCoreProtocolFeeControllerV5} from "../src/GullyCoreProtocolFeeControllerV5.sol";
import {MockLaunchOracle, WastefulLaunchOracle, NotAnOracle} from "./utils/V3Mocks.sol";
import {MockCLLaunchHook, MockLocker, MockCLLaunchKit} from "./utils/LaunchFixtures.sol";
import {MockBinLaunchHook, MockBinLaunchKit} from "./FeeControllerV3LiveBin.t.sol";

/// REAL core (one Vault, the CL and Bin pool managers behind their owner wrappers) with V5 installed on both.
/// The builder and partner fee: every non-launch pool is born at a flat 3000 pips per direction, a locked
/// launch and a listed hook's pool at zero; every change goes down at once and up only after 7 days.
contract GullyCoreProtocolFeeControllerV5Test is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using BinPoolParametersHelper for bytes32;

    uint16 internal constant FEE = 3000;
    uint24 internal constant PACKED_3000 = uint24(3000) | (uint24(3000) << 12);
    uint24 internal constant PACKED_4000 = uint24(4000) | (uint24(4000) << 12);
    uint24 internal constant DYN = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint24 internal constant ACTIVE_ID = 2 ** 23;
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant FLOOR = 55_793; // 50_000 + floor(50_000 / 63) + 5_000

    Vault internal vault;
    CLPoolManager internal cl;
    BinPoolManager internal bin;
    CLPoolManagerOwner internal clWrapper;
    BinPoolManagerOwner internal binWrapper;
    CLPoolManagerRouter internal router;
    GullyCoreProtocolFeeControllerV5 internal v5;
    MockCLLaunchKit internal clKit;
    MockCLLaunchHook internal clLaunchHook;
    MockBinLaunchKit internal binKit;
    MockBinLaunchHook internal binLaunchHook;
    MockLaunchOracle internal flagKit;
    Currency internal c0;
    Currency internal c1;

    address internal safe = makeAddr("governanceSafe");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(T0);
        vault = new Vault();
        cl = new CLPoolManager(vault);
        bin = new BinPoolManager(vault);
        vault.registerApp(address(cl));
        vault.registerApp(address(bin));
        router = new CLPoolManagerRouter(vault, cl);
        clWrapper = new CLPoolManagerOwner(ICLPoolManagerWithPauseOwnable(address(cl)));
        cl.transferOwnership(address(clWrapper));
        binWrapper = new BinPoolManagerOwner(IBinPoolManagerWithPauseOwnable(address(bin)));
        bin.transferOwnership(address(binWrapper));

        clLaunchHook = new MockCLLaunchHook();
        clKit = new MockCLLaunchKit(cl, clLaunchHook, new MockLocker());
        binLaunchHook = new MockBinLaunchHook();
        binKit = new MockBinLaunchKit(bin, binLaunchHook);
        flagKit = new MockLaunchOracle();

        v5 = _deploy(FEE, _list(address(clKit), address(binKit), address(flagKit)), new address[](0));
        clWrapper.setProtocolFeeController(v5);
        binWrapper.setProtocolFeeController(v5);

        (c0, c1) = deployCurrencies(2 ** 250);
        IERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);
    }

    /* ------------------------------ helpers ------------------------------ */

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(address a, address b, address c) internal pure returns (address[] memory l) {
        l = new address[](3);
        l[0] = a;
        l[1] = b;
        l[2] = c;
    }

    function _deploy(uint16 fee, address[] memory oracles, address[] memory hooks)
        internal
        returns (GullyCoreProtocolFeeControllerV5)
    {
        return new GullyCoreProtocolFeeControllerV5(safe, address(cl), address(bin), fee, oracles, hooks, 7 days);
    }

    function _pack(uint16 a, uint16 b) internal pure returns (uint24) {
        return uint24(a) | (uint24(b) << 12);
    }

    function _clKey(uint24 fee, address hooks, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(hooks),
            poolManager: cl,
            fee: fee,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hooks == address(0) ? 0 : 1)), spacing)
        });
    }

    function _binKey(uint24 fee, address hooks, uint16 binStep) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(hooks),
            poolManager: bin,
            fee: fee,
            parameters: bytes32(uint256(hooks == address(0) ? 0 : 1)).setBinStep(binStep)
        });
    }

    function _clStamped(PoolKey memory k) internal view returns (uint24 protocolFee) {
        (,, protocolFee,) = cl.getSlot0(k.toId());
    }

    function _binStamped(PoolKey memory k) internal view returns (uint24 protocolFee) {
        (, protocolFee,) = bin.getSlot0(k.toId());
    }

    function _openCl(uint24 fee, int24 spacing) internal returns (PoolKey memory k) {
        k = _clKey(fee, address(0), spacing);
        cl.initialize(k, SQRT_RATIO_1_1);
    }

    function _addLiquidity(PoolKey memory k) internal {
        router.modifyPosition(
            k,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -6_000, tickUpper: 6_000, liquidityDelta: 1_000_000 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    function _swapExactIn(PoolKey memory k, bool zeroForOne, uint256 amountIn) internal {
        router.swap(
            k,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    /* ------------------------------ constructor ------------------------------ */

    function test_Constructor_SetsEverything() public view {
        assertEq(v5.owner(), safe);
        assertEq(v5.treasury(), safe);
        assertEq(v5.clPoolManager(), address(cl));
        assertEq(v5.binPoolManager(), address(bin));
        assertEq(v5.builderFee(), FEE);
        assertEq(v5.launchOracleCount(), 3);
        assertEq(v5.launchOracles()[0], address(clKit));
        assertEq(v5.launchOracles()[2], address(flagKit));
        assertTrue(v5.isLaunchOracle(address(binKit)));
        assertFalse(v5.isLaunchOracle(address(0)));
        assertFalse(v5.isLaunchOracle(stranger));
        assertEq(v5.ZERO_FEE_HOOK_REMOVAL_NOTICE(), 7 days);
        assertEq(v5.FEE_RAISE_NOTICE(), 7 days);
        assertEq(v5.MAX_PROTOCOL_FEE(), 4000);
        (uint16 p, uint40 at) = v5.pendingBuilderFee();
        assertEq(p, 0);
        assertEq(at, 0);
    }

    function test_Constructor_RefusesBadManagers() public {
        address[] memory k = _list(address(flagKit));
        address[] memory none = new address[](0);
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.ZeroAddress.selector);
        new GullyCoreProtocolFeeControllerV5(safe, address(0), address(bin), FEE, k, none, 7 days);
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.ZeroAddress.selector);
        new GullyCoreProtocolFeeControllerV5(safe, address(cl), address(0), FEE, k, none, 7 days);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.InvalidPoolManagers.selector, address(cl), address(cl)));
        new GullyCoreProtocolFeeControllerV5(safe, address(cl), address(cl), FEE, k, none, 7 days);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoCode.selector, stranger));
        new GullyCoreProtocolFeeControllerV5(safe, stranger, address(bin), FEE, k, none, 7 days);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoCode.selector, stranger));
        new GullyCoreProtocolFeeControllerV5(safe, address(cl), stranger, FEE, k, none, 7 days);
    }

    function test_Constructor_RefusesAFeeAboveTheCap_AcceptsTheCapAndZero() public {
        address[] memory k = _list(address(flagKit));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.FeeExceedsMaximum.selector, uint24(4001), uint16(4000)));
        _deploy(4001, k, new address[](0));
        assertEq(_deploy(4000, k, new address[](0)).builderFee(), 4000);
        assertEq(_deploy(0, k, new address[](0)).builderFee(), 0);
    }

    function test_Constructor_RefusesBadOracleSets() public {
        address[] memory none = new address[](0);
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.NoLaunchOracles.selector);
        _deploy(FEE, none, none);

        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) five[i] = address(new MockLaunchOracle());
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.TooManyLaunchOracles.selector, 5, 4));
        _deploy(FEE, five, none);

        address[] memory l = _list(address(flagKit), address(0), address(clKit));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.ZeroLaunchOracle.selector, 1));
        _deploy(FEE, l, none);

        l = _list(address(flagKit), stranger, address(clKit));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoCode.selector, stranger));
        _deploy(FEE, l, none);

        l = _list(address(flagKit), address(clKit), address(flagKit));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.DuplicateLaunchOracle.selector, address(flagKit)));
        _deploy(FEE, l, none);

        address notOracle = address(new NotAnOracle());
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.OracleDoesNotImplementInterface.selector, notOracle));
        _deploy(FEE, _list(notOracle), none);

        MockLaunchOracle yes = new MockLaunchOracle();
        yes.setMode(MockLaunchOracle.Mode.TrueForEverything);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.OracleDoesNotImplementInterface.selector, address(yes)));
        _deploy(FEE, _list(address(yes)), none);

        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.InvalidPoolManagers.selector, address(cl), address(bin)));
        _deploy(FEE, _list(address(cl)), none);
    }

    function test_Constructor_RemovalNoticeBounds_AndHookList() public {
        address[] memory k = _list(address(flagKit));
        address[] memory none = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.InvalidRemovalNotice.selector, 1 days - 1));
        new GullyCoreProtocolFeeControllerV5(safe, address(cl), address(bin), FEE, k, none, 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.InvalidRemovalNotice.selector, 90 days + 1));
        new GullyCoreProtocolFeeControllerV5(safe, address(cl), address(bin), FEE, k, none, 90 days + 1);
        new GullyCoreProtocolFeeControllerV5(safe, address(cl), address(bin), FEE, k, none, 1 days);
        new GullyCoreProtocolFeeControllerV5(safe, address(cl), address(bin), FEE, k, none, 90 days);

        // a listed hook may have no code yet (a mined address); the zero address, a kit and a manager are refused
        address mined = address(0xBEEF);
        GullyCoreProtocolFeeControllerV5 c = _deploy(FEE, k, _list(mined));
        assertTrue(c.isZeroFeeHook(mined));
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.ZeroAddress.selector);
        _deploy(FEE, k, _list(address(0)));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.InvalidZeroFeeHook.selector, address(flagKit)));
        _deploy(FEE, k, _list(address(flagKit)));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.InvalidZeroFeeHook.selector, address(cl)));
        _deploy(FEE, k, _list(address(cl)));
        address[] memory twice = new address[](2);
        twice[0] = mined;
        twice[1] = mined;
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.AlreadyZeroFeeHook.selector, mined));
        _deploy(FEE, k, twice);
    }

    /* ------------------------------ the flat rate, at pool creation ------------------------------ */

    function test_EveryStaticTier_IsBornAtTheFlatFee_CL() public {
        uint24[6] memory tiers = [uint24(0), 100, 500, 3000, 10_000, 1_000_000];
        for (uint256 i; i < tiers.length; ++i) {
            PoolKey memory k = _openCl(tiers[i], int24(int256(10 + i)));
            assertEq(_clStamped(k), PACKED_3000, "flat 3000 pips in both directions on every static tier");
            assertEq(v5.protocolFeeForPool(k), PACKED_3000);
            assertEq(v5.poolProtocolFee(address(cl), k.toId()), PACKED_3000);
        }
    }

    function test_FlatFee_OnBin_StaticAndHookless() public {
        PoolKey memory k = _binKey(3000, address(0), 10);
        bin.initialize(k, ACTIVE_ID);
        assertEq(_binStamped(k), PACKED_3000);
        assertEq(v5.poolProtocolFee(address(bin), k.toId()), PACKED_3000, "the Bin slot0 layout is read correctly");
    }

    function test_DynamicFeePool_OnAnUnlistedHook_PaysTheFlatFee() public {
        // a second claim hook that no kit vouches for: a builder's own hook
        MockCLLaunchHook builderHook = new MockCLLaunchHook();
        PoolKey memory k = _clKey(DYN, address(builderHook), 60);
        builderHook.claim(k);
        cl.initialize(k, SQRT_RATIO_1_1);
        assertEq(_clStamped(k), PACKED_3000, "a builder's hook pool pays the builder fee");
    }

    function test_LockedLaunch_IsBornAtZero_CL_And_Bin() public {
        PoolKey memory a = _clKey(DYN, address(clLaunchHook), 60);
        clKit.createLockedLaunch(a, SQRT_RATIO_1_1);
        assertEq(_clStamped(a), 0, "a kit-locked CL launch pays no core protocol fee");
        assertTrue(v5.isLockedLaunchPool(a.toId()));

        PoolKey memory b = _binKey(DYN, address(binLaunchHook), 10);
        binKit.createLockedLaunch(b, ACTIVE_ID);
        assertEq(_binStamped(b), 0, "a kit-locked Bin launch pays no core protocol fee");

        // an UNLOCKED launch on the same kit hook is an ordinary pool
        PoolKey memory u = _clKey(DYN, address(clLaunchHook), 10);
        clKit.createUnlockedLaunch(u, SQRT_RATIO_1_1);
        assertEq(_clStamped(u), PACKED_3000);
        assertFalse(v5.isLockedLaunchPool(u.toId()));
    }

    function test_OracleAnswer_MustBeExactlyTrue() public {
        PoolKey memory k = _clKey(3000, address(0), 60);
        bytes32 id = PoolId.unwrap(k.toId());
        flagKit.setFlag(id, true);
        assertEq(v5.protocolFeeForPool(k), 0, "any oracle in the set zeroes the pool");
        MockLaunchOracle.Mode[6] memory bad = [
            MockLaunchOracle.Mode.Revert,
            MockLaunchOracle.Mode.RevertWithTrueData,
            MockLaunchOracle.Mode.ReturnTwo,
            MockLaunchOracle.Mode.ReturnLongTrue,
            MockLaunchOracle.Mode.ReturnShort,
            MockLaunchOracle.Mode.ReturnBomb
        ];
        for (uint256 i; i < bad.length; ++i) {
            flagKit.setMode(bad[i]);
            assertEq(v5.protocolFeeForPool(k), PACKED_3000, "anything but a 32-byte true is a no");
        }
        flagKit.setMode(MockLaunchOracle.Mode.BurnThenTrue);
        flagKit.setBurnSlots(1_000_000);
        assertEq(v5.protocolFeeForPool(k), PACKED_3000, "an oracle that burns its stipend loses its zero rule, nothing else");
    }

    function test_GasFloor_HoldsBeforeEachOracleCall() public {
        WastefulLaunchOracle first = new WastefulLaunchOracle();
        MockLaunchOracle second = new MockLaunchOracle();
        address[] memory l = new address[](2);
        l[0] = address(first);
        l[1] = address(second);
        GullyCoreProtocolFeeControllerV5 c = _deploy(FEE, l, new address[](0));
        PoolKey memory k = _clKey(3000, address(0), 60);
        second.setFlag(PoolId.unwrap(k.toId()), true);
        first.setMode(WastefulLaunchOracle.Mode.BurnAllGas);

        // plenty of gas: the wasteful oracle burns its stipend, the honest one is still asked and vouches
        assertEq(c.protocolFeeForPool{gas: 400_000}(k), 0);
        // too little to give the second oracle its stipend: the call reverts, it never resolves a fee
        (bool ok, bytes memory ret) =
            address(c).staticcall{gas: 80_000}(abi.encodeWithSelector(c.protocolFeeForPool.selector, k));
        assertFalse(ok, "a starved check reverts rather than charging a locked launch");
        if (ret.length >= 4) {
            assertEq(bytes4(ret), GullyCoreProtocolFeeControllerV5.InsufficientGasForLaunchCheck.selector);
        }
        assertEq(c.LAUNCH_ORACLE_MIN_GASLEFT(), FLOOR);
    }

    function test_NoLaunchOracleGetter() public {
        (bool ok,) = address(v5).staticcall(abi.encodeWithSignature("launchOracle()"));
        assertFalse(ok, "V5 must not answer launchOracle(): a kit reads isLaunchOracle");
    }

    function test_ZeroBuilderFee_AsksNobody_AndEveryPoolIsFree() public {
        vm.prank(safe);
        v5.setBuilderFee(0);
        flagKit.setMode(MockLaunchOracle.Mode.Revert);
        PoolKey memory k = _openCl(3000, 60);
        assertEq(_clStamped(k), 0);
        // with no fee to waive the oracles are not called at all: 30k gas is far below one stipend
        assertEq(v5.protocolFeeForPool{gas: 30_000}(k), 0);
    }

    /* ------------------------------ the flat rate: down at once, up after notice ------------------------------ */

    function test_SetBuilderFee_OnlyOwner_AndCapped() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.setBuilderFee(1000);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.FeeExceedsMaximum.selector, uint24(4001), uint16(4000)));
        v5.setBuilderFee(4001);
    }

    function test_Lowering_AppliesAtOnce_ToNewPools() public {
        vm.prank(safe);
        v5.setBuilderFee(1000);
        assertEq(v5.builderFee(), 1000);
        PoolKey memory k = _openCl(3000, 60);
        assertEq(_clStamped(k), _pack(1000, 1000));
        // the same value again is not an increase either
        vm.prank(safe);
        v5.setBuilderFee(1000);
        assertEq(v5.builderFee(), 1000);
    }

    function test_Raising_WaitsSevenDays_ThenAppliesByItself() public {
        vm.prank(safe);
        v5.setBuilderFee(4000);
        assertEq(v5.builderFee(), FEE, "an increase does not apply at once");
        (uint16 p, uint40 at) = v5.pendingBuilderFee();
        assertEq(p, 4000);
        assertEq(at, T0 + 7 days);

        PoolKey memory before = _openCl(3000, 10);
        assertEq(_clStamped(before), PACKED_3000);

        vm.warp(T0 + 7 days - 1);
        assertEq(v5.builderFee(), FEE, "one second before the notice ends the old fee still holds");
        PoolKey memory lastSecond = _openCl(3000, 20);
        assertEq(_clStamped(lastSecond), PACKED_3000);

        vm.warp(T0 + 7 days);
        assertEq(v5.builderFee(), 4000, "the increase starts by itself");
        (p, at) = v5.pendingBuilderFee();
        assertEq(p, 0);
        assertEq(at, 0);
        PoolKey memory afterNotice = _openCl(3000, 30);
        assertEq(_clStamped(afterNotice), PACKED_4000);
        assertEq(_clStamped(before), PACKED_3000, "an existing pool keeps what it was born with");
    }

    function test_Rescheduling_RestartsTheNotice_NeverShortensIt() public {
        vm.startPrank(safe);
        v5.setBuilderFee(3500);
        vm.warp(T0 + 6 days);
        v5.setBuilderFee(4000);
        vm.stopPrank();
        (uint16 p, uint40 at) = v5.pendingBuilderFee();
        assertEq(p, 4000);
        assertEq(at, T0 + 13 days);
        vm.warp(T0 + 7 days);
        assertEq(v5.builderFee(), FEE, "the first announcement no longer counts");
        vm.warp(T0 + 13 days);
        assertEq(v5.builderFee(), 4000);
    }

    function test_Lowering_CancelsAPendingIncrease() public {
        vm.startPrank(safe);
        v5.setBuilderFee(4000);
        v5.setBuilderFee(2000);
        vm.stopPrank();
        assertEq(v5.builderFee(), 2000);
        vm.warp(T0 + 30 days);
        assertEq(v5.builderFee(), 2000, "the cancelled increase never arrives");
    }

    function test_CancelPendingBuilderFee() public {
        vm.prank(safe);
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.NoPendingBuilderFee.selector);
        v5.cancelPendingBuilderFee();

        vm.prank(safe);
        v5.setBuilderFee(4000);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.cancelPendingBuilderFee();
        vm.prank(safe);
        v5.cancelPendingBuilderFee();
        vm.warp(T0 + 30 days);
        assertEq(v5.builderFee(), FEE);

        // once an increase has started it is the fee in force: there is nothing left to cancel
        vm.prank(safe);
        v5.setBuilderFee(4000);
        vm.warp(block.timestamp + 7 days);
        vm.prank(safe);
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.NoPendingBuilderFee.selector);
        v5.cancelPendingBuilderFee();
        assertEq(v5.builderFee(), 4000);
    }

    function test_AfterAMaturedIncrease_ComparisonsUseTheNewFee() public {
        vm.prank(safe);
        v5.setBuilderFee(4000);
        vm.warp(T0 + 7 days);
        // 3500 is now a DECREASE (from 4000) and applies at once
        vm.prank(safe);
        v5.setBuilderFee(3500);
        assertEq(v5.builderFee(), 3500);
        (uint16 p,) = v5.pendingBuilderFee();
        assertEq(p, 0);
    }

    function testFuzz_BuilderFee_NeverRisesWithoutNotice(uint16 a, uint16 b, uint32 wait) public {
        a = uint16(bound(a, 0, 4000));
        b = uint16(bound(b, 0, 4000));
        wait = uint32(bound(wait, 0, 7 days - 1));
        vm.startPrank(safe);
        v5.setBuilderFee(a);
        uint16 inForce = v5.builderFee();
        v5.setBuilderFee(b);
        vm.stopPrank();
        vm.warp(block.timestamp + wait);
        uint16 nowFee = v5.builderFee();
        assertLe(nowFee, inForce > b ? inForce : (b <= inForce ? inForce : inForce), "no increase inside the notice");
        assertLe(nowFee, 4000);
        if (b <= inForce) assertEq(nowFee, b);
        else assertEq(nowFee, inForce);
    }

    /* ------------------------------ an existing pool ------------------------------ */

    function test_SetPoolProtocolFee_LowersAtOnce_PerDirection() public {
        PoolKey memory k = _openCl(3000, 60);
        vm.prank(safe);
        v5.setPoolProtocolFee(address(cl), k, _pack(1000, 3000));
        assertEq(_clStamped(k), _pack(1000, 3000));
        vm.prank(safe);
        v5.setPoolProtocolFee(address(cl), k, 0);
        assertEq(_clStamped(k), 0);
    }

    function test_SetPoolProtocolFee_RefusesAnyIncrease() public {
        PoolKey memory k = _openCl(3000, 60);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.RaiseNeedsNotice.selector, PACKED_3000, PACKED_4000));
        v5.setPoolProtocolFee(address(cl), k, PACKED_4000);
        // one direction down, the other up: still an increase
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.RaiseNeedsNotice.selector, PACKED_3000, _pack(0, 3001)));
        v5.setPoolProtocolFee(address(cl), k, _pack(0, 3001));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.RaiseNeedsNotice.selector, PACKED_3000, _pack(3001, 0)));
        v5.setPoolProtocolFee(address(cl), k, _pack(3001, 0));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.FeeExceedsMaximum.selector, _pack(4001, 0), uint16(4000)));
        v5.setPoolProtocolFee(address(cl), k, _pack(4001, 0));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.FeeExceedsMaximum.selector, _pack(0, 4001), uint16(4000)));
        v5.setPoolProtocolFee(address(cl), k, _pack(0, 4001));
        vm.stopPrank();
        assertEq(_clStamped(k), PACKED_3000);
    }

    function test_PerPoolCalls_AreOwnerOnly_AndOnlyOnTheTwoManagers() public {
        PoolKey memory k = _openCl(3000, 60);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.setPoolProtocolFee(address(cl), k, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.schedulePoolFeeRaise(address(cl), k, PACKED_4000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.executePoolFeeRaise(address(cl), k);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.cancelPoolFeeRaise(address(cl), k);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.syncPoolToPolicy(address(cl), k);
        vm.stopPrank();

        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.UnknownPoolManager.selector, stranger));
        v5.setPoolProtocolFee(stranger, k, 0);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.UnknownPoolManager.selector, stranger));
        v5.schedulePoolFeeRaise(stranger, k, PACKED_4000);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.UnknownPoolManager.selector, stranger));
        v5.syncPoolToPolicy(stranger, k);
        vm.stopPrank();
    }

    function test_PoolRaise_ScheduleWaitExecute() public {
        PoolKey memory k = _openCl(3000, 60);
        vm.prank(safe);
        v5.setPoolProtocolFee(address(cl), k, _pack(1000, 1000));

        vm.prank(safe);
        v5.schedulePoolFeeRaise(address(cl), k, PACKED_3000);
        (uint24 fee, uint40 at) = v5.pendingPoolFeeRaise(address(cl), k.toId());
        assertEq(fee, PACKED_3000);
        assertEq(at, T0 + 7 days);
        assertEq(_clStamped(k), _pack(1000, 1000), "announcing changes nothing");

        vm.warp(T0 + 7 days - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.RaiseNotYetExecutable.selector, uint40(T0 + 7 days)));
        v5.executePoolFeeRaise(address(cl), k);

        vm.warp(T0 + 7 days);
        vm.prank(safe);
        v5.executePoolFeeRaise(address(cl), k);
        assertEq(_clStamped(k), PACKED_3000);
        (fee, at) = v5.pendingPoolFeeRaise(address(cl), k.toId());
        assertEq(fee, 0);
        assertEq(at, 0);

        // it cannot be executed twice
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoPendingRaise.selector, address(cl), k.toId()));
        v5.executePoolFeeRaise(address(cl), k);
    }

    function test_PoolRaise_NotARaise_IsRefused_AndCapHolds() public {
        PoolKey memory k = _openCl(3000, 60);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NotARaise.selector, PACKED_3000, PACKED_3000));
        v5.schedulePoolFeeRaise(address(cl), k, PACKED_3000);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NotARaise.selector, PACKED_3000, _pack(1, 2)));
        v5.schedulePoolFeeRaise(address(cl), k, _pack(1, 2));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.FeeExceedsMaximum.selector, _pack(4001, 4000), uint16(4000)));
        v5.schedulePoolFeeRaise(address(cl), k, _pack(4001, 4000));
        vm.stopPrank();
    }

    function test_PoolRaise_Rescheduling_RestartsTheNotice() public {
        PoolKey memory k = _openCl(3000, 60);
        vm.startPrank(safe);
        v5.schedulePoolFeeRaise(address(cl), k, _pack(3500, 3500));
        vm.warp(T0 + 6 days);
        v5.schedulePoolFeeRaise(address(cl), k, PACKED_4000);
        vm.warp(T0 + 7 days);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.RaiseNotYetExecutable.selector, uint40(T0 + 13 days)));
        v5.executePoolFeeRaise(address(cl), k);
        vm.warp(T0 + 13 days);
        v5.executePoolFeeRaise(address(cl), k);
        vm.stopPrank();
        assertEq(_clStamped(k), PACKED_4000);
    }

    function test_PoolRaise_Cancel_AndLoweringWithdrawsIt() public {
        PoolKey memory k = _openCl(3000, 60);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoPendingRaise.selector, address(cl), k.toId()));
        v5.cancelPoolFeeRaise(address(cl), k);

        v5.schedulePoolFeeRaise(address(cl), k, PACKED_4000);
        v5.cancelPoolFeeRaise(address(cl), k);
        vm.warp(T0 + 8 days);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoPendingRaise.selector, address(cl), k.toId()));
        v5.executePoolFeeRaise(address(cl), k);

        // a decrease withdraws a pending increase on that pool
        v5.schedulePoolFeeRaise(address(cl), k, PACKED_4000);
        v5.setPoolProtocolFee(address(cl), k, _pack(2000, 2000));
        vm.warp(T0 + 30 days);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoPendingRaise.selector, address(cl), k.toId()));
        v5.executePoolFeeRaise(address(cl), k);
        vm.stopPrank();
        assertEq(_clStamped(k), _pack(2000, 2000));
    }

    function test_PoolRaise_OnBin_ReadsTheBinLayout() public {
        PoolKey memory k = _binKey(3000, address(0), 10);
        bin.initialize(k, ACTIVE_ID);
        vm.startPrank(safe);
        v5.setPoolProtocolFee(address(bin), k, _pack(500, 700));
        assertEq(_binStamped(k), _pack(500, 700));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.RaiseNeedsNotice.selector, _pack(500, 700), _pack(500, 701)));
        v5.setPoolProtocolFee(address(bin), k, _pack(500, 701));
        v5.schedulePoolFeeRaise(address(bin), k, PACKED_3000);
        vm.warp(T0 + 7 days);
        v5.executePoolFeeRaise(address(bin), k);
        vm.stopPrank();
        assertEq(_binStamped(k), PACKED_3000);
        // a pending raise on the Bin manager is not one on the CL manager
        (uint24 f,) = v5.pendingPoolFeeRaise(address(cl), k.toId());
        assertEq(f, 0);
    }

    function test_LockedLaunch_CanNeverBeCharged() public {
        PoolKey memory a = _clKey(DYN, address(clLaunchHook), 60);
        clKit.createLockedLaunch(a, SQRT_RATIO_1_1);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.RaiseNeedsNotice.selector, uint24(0), PACKED_3000));
        v5.setPoolProtocolFee(address(cl), a, PACKED_3000);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.LockedLaunchPoolKeepsZeroFee.selector, a.toId()));
        v5.schedulePoolFeeRaise(address(cl), a, PACKED_3000);
        assertEq(v5.syncPoolToPolicy(address(cl), a), 0);
        vm.stopPrank();
        assertEq(_clStamped(a), 0);
    }

    function test_AnnouncedRaise_IsRefusedAtExecution_IfThePoolBecameALockedLaunchOrItsHookWasListed() public {
        // a raise announced on an ordinary pool; before it executes a kit vouches for the pool
        PoolKey memory k = _openCl(3000, 60);
        vm.startPrank(safe);
        v5.setPoolProtocolFee(address(cl), k, 0);
        v5.schedulePoolFeeRaise(address(cl), k, PACKED_3000);
        vm.stopPrank();
        flagKit.setFlag(PoolId.unwrap(k.toId()), true);
        vm.warp(T0 + 7 days);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.LockedLaunchPoolKeepsZeroFee.selector, k.toId()));
        v5.executePoolFeeRaise(address(cl), k);
        assertEq(_clStamped(k), 0);

        // and the same for a hook listed after the announcement
        MockCLLaunchHook hook = new MockCLLaunchHook();
        PoolKey memory h = _clKey(DYN, address(hook), 60);
        hook.claim(h);
        cl.initialize(h, SQRT_RATIO_1_1);
        vm.startPrank(safe);
        v5.setPoolProtocolFee(address(cl), h, 0);
        v5.schedulePoolFeeRaise(address(cl), h, PACKED_3000);
        v5.addZeroFeeHook(address(hook));
        vm.warp(T0 + 14 days);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.ZeroFeeHookPoolKeepsZeroFee.selector, h.toId(), address(hook)));
        v5.executePoolFeeRaise(address(cl), h);
        vm.stopPrank();
        assertEq(_clStamped(h), 0);
    }

    function test_SyncPoolToPolicy_FollowsTheRule() public {
        PoolKey memory k = _openCl(3000, 60);
        // the default goes down: sync brings the existing pool down at once
        vm.startPrank(safe);
        v5.setBuilderFee(1000);
        assertEq(v5.syncPoolToPolicy(address(cl), k), _pack(1000, 1000));
        assertEq(_clStamped(k), _pack(1000, 1000));
        // the default goes back up (after its notice): sync refuses, the pool needs its own announcement
        v5.setBuilderFee(3000);
        vm.warp(T0 + 7 days);
        assertEq(v5.builderFee(), 3000);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.RaiseNeedsNotice.selector, _pack(1000, 1000), PACKED_3000));
        v5.syncPoolToPolicy(address(cl), k);
        vm.stopPrank();
        assertEq(_clStamped(k), _pack(1000, 1000));
    }

    function test_PackFee() public {
        assertEq(v5.packFee(3000, 3000), PACKED_3000);
        assertEq(v5.packFee(0, 4000), uint24(4000) << 12);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.FeeExceedsMaximum.selector, uint24(4001), uint16(4000)));
        v5.packFee(4001, 0);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.FeeExceedsMaximum.selector, uint24(4001), uint16(4000)));
        v5.packFee(0, 4001);
    }

    /* ------------------------------ zero-fee hooks ------------------------------ */

    function test_ZeroFeeHooks_AddAtOnce_RemoveAfterNotice() public {
        MockCLLaunchHook hook = new MockCLLaunchHook();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.addZeroFeeHook(address(hook));

        vm.startPrank(safe);
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.ZeroAddress.selector);
        v5.addZeroFeeHook(address(0));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoCode.selector, stranger));
        v5.addZeroFeeHook(stranger);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.InvalidZeroFeeHook.selector, address(clKit)));
        v5.addZeroFeeHook(address(clKit));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.InvalidZeroFeeHook.selector, address(bin)));
        v5.addZeroFeeHook(address(bin));

        v5.addZeroFeeHook(address(hook));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.AlreadyZeroFeeHook.selector, address(hook)));
        v5.addZeroFeeHook(address(hook));
        vm.stopPrank();
        assertTrue(v5.isZeroFeeHook(address(hook)));

        PoolKey memory k = _clKey(DYN, address(hook), 60);
        hook.claim(k);
        cl.initialize(k, SQRT_RATIO_1_1);
        assertEq(_clStamped(k), 0, "a listed hook's pool is born at zero");

        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.ZeroFeeHookPoolKeepsZeroFee.selector, k.toId(), address(hook)));
        v5.schedulePoolFeeRaise(address(cl), k, PACKED_3000);

        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoPendingRemoval.selector, address(hook)));
        v5.cancelZeroFeeHookRemoval(address(hook));
        v5.scheduleZeroFeeHookRemoval(address(hook));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NotZeroFeeHook.selector, address(hook)));
        v5.scheduleZeroFeeHookRemoval(address(hook));
        (bool listed, uint40 removalAt) = v5.zeroFeeHook(address(hook));
        assertTrue(listed);
        assertEq(removalAt, T0 + 7 days);
        vm.warp(T0 + 7 days - 1);
        assertTrue(v5.isZeroFeeHook(address(hook)), "listed until the notice ends");
        v5.cancelZeroFeeHookRemoval(address(hook));
        vm.warp(T0 + 30 days);
        assertTrue(v5.isZeroFeeHook(address(hook)), "a cancelled removal never happens");

        v5.scheduleZeroFeeHookRemoval(address(hook));
        vm.warp(block.timestamp + 7 days);
        assertFalse(v5.isZeroFeeHook(address(hook)));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NoPendingRemoval.selector, address(hook)));
        v5.cancelZeroFeeHookRemoval(address(hook));
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NotZeroFeeHook.selector, stranger));
        v5.scheduleZeroFeeHookRemoval(stranger);
        // re-listing a removed hook is allowed (it lowers fees)
        v5.addZeroFeeHook(address(hook));
        vm.stopPrank();
        assertTrue(v5.isZeroFeeHook(address(hook)));
        assertFalse(v5.isZeroFeeHook(address(0)), "hookless pools always pay");
    }

    /* ------------------------------ money: exact fee, collection, nothing stuck ------------------------------ */

    function test_Swap_PaysExactly30BpsOfTheInput_ToTheSafe_AndNothingIsLeft() public {
        PoolKey memory k = _openCl(500, 10);
        _addLiquidity(k);
        uint256 amountIn = 1 ether;

        _swapExactIn(k, true, amountIn);
        assertEq(cl.protocolFeesAccrued(c0), (amountIn * 3000) / 1e6, "0.30% of the input, zeroForOne");
        assertEq(cl.protocolFeesAccrued(c1), 0);
        _swapExactIn(k, false, amountIn);
        assertEq(cl.protocolFeesAccrued(c1), (amountIn * 3000) / 1e6, "0.30% of the input, oneForZero");
        assertEq(v5.accrued(address(cl), c0), 0.003 ether);

        // sweep is permissionless and can only pay the Safe
        vm.prank(stranger);
        assertEq(v5.sweep(address(cl), c0), 0.003 ether);
        assertEq(IERC20(Currency.unwrap(c0)).balanceOf(safe), 0.003 ether);
        assertEq(cl.protocolFeesAccrued(c0), 0, "nothing left behind in the manager");
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NothingToCollect.selector, address(cl), c0));
        v5.sweep(address(cl), c0);

        // collect: owner only, never to the zero address, partial then all
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.collect(address(cl), c1, 0, stranger);
        vm.startPrank(safe);
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.ZeroRecipient.selector);
        v5.collect(address(cl), c1, 0, address(0));
        assertEq(v5.collect(address(cl), c1, 0.001 ether, safe), 0.001 ether);
        assertEq(v5.collect(address(cl), c1, 0, safe), 0.002 ether);
        vm.stopPrank();
        assertEq(IERC20(Currency.unwrap(c1)).balanceOf(safe), 0.003 ether);
        assertEq(cl.protocolFeesAccrued(c1), 0);
        assertEq(IERC20(Currency.unwrap(c0)).balanceOf(address(v5)), 0, "the controller never holds fees");
        assertEq(IERC20(Currency.unwrap(c1)).balanceOf(address(v5)), 0);
    }

    function test_LoweredPool_PaysTheLowerFee_FromTheNextSwap() public {
        PoolKey memory k = _openCl(500, 10);
        _addLiquidity(k);
        vm.prank(safe);
        v5.setPoolProtocolFee(address(cl), k, _pack(1000, 3000));
        _swapExactIn(k, true, 1 ether);
        assertEq(cl.protocolFeesAccrued(c0), 0.001 ether, "0.10% after the Safe lowered this pool");
        _swapExactIn(k, false, 1 ether);
        assertEq(cl.protocolFeesAccrued(c1), 0.003 ether, "the other direction is untouched");
    }

    function test_LaunchPool_PaysNoCoreFee_OnASwap() public {
        PoolKey memory a = _clKey(DYN, address(clLaunchHook), 60);
        clKit.createLockedLaunch(a, SQRT_RATIO_1_1);
        _addLiquidity(a);
        _swapExactIn(a, true, 1 ether);
        assertEq(cl.protocolFeesAccrued(c0), 0);
        assertEq(cl.protocolFeesAccrued(c1), 0);
    }

    function test_FeesAccruedUnderAnEarlierController_AreCollectableByV5() public {
        // a second V5 takes over: what accrued under the first is paid out by the second
        PoolKey memory k = _openCl(500, 10);
        _addLiquidity(k);
        _swapExactIn(k, true, 1 ether);
        GullyCoreProtocolFeeControllerV5 next = _deploy(FEE, _list(address(flagKit)), new address[](0));
        clWrapper.setProtocolFeeController(next);
        vm.expectRevert();
        v5.sweep(address(cl), c0);
        assertEq(next.sweep(address(cl), c0), 0.003 ether);
        assertEq(IERC20(Currency.unwrap(c0)).balanceOf(safe), 0.003 ether);
    }

    function test_RescueERC20_AndNoWayToSendItNativeCoin() public {
        MockERC20 stray = new MockERC20("S", "S", 18);
        stray.mint(address(v5), 5 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v5.rescueERC20(address(stray), stranger);
        vm.startPrank(safe);
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.RescueToZero.selector);
        v5.rescueERC20(address(stray), address(0));
        v5.rescueERC20(address(stray), safe);
        vm.expectRevert(abi.encodeWithSelector(GullyCoreProtocolFeeControllerV5.NothingToRescue.selector, address(stray)));
        v5.rescueERC20(address(stray), safe);
        vm.stopPrank();
        assertEq(stray.balanceOf(safe), 5 ether);

        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(v5).call{value: 1 ether}("");
        assertFalse(ok, "no receive and no fallback: native coin cannot be sent here");
    }

    function test_Ownership_TwoStep_AndRenounceDisabled() public {
        vm.prank(safe);
        vm.expectRevert(GullyCoreProtocolFeeControllerV5.RenounceDisabled.selector);
        v5.renounceOwnership();
        address next = makeAddr("nextSafe");
        vm.prank(safe);
        v5.transferOwnership(next);
        assertEq(v5.owner(), safe, "nothing moves until the new owner accepts");
        vm.prank(next);
        v5.acceptOwnership();
        assertEq(v5.owner(), next);
        assertEq(v5.treasury(), safe, "the treasury is immutable");
    }
}
