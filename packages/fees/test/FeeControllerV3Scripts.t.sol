// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";

import {GullyCoreProtocolFeeControllerV2} from "../src/GullyCoreProtocolFeeControllerV2.sol";
import {GullyCoreProtocolFeeControllerV3} from "../src/GullyCoreProtocolFeeControllerV3.sol";
import {DeployFeeControllerV3Script} from "../script/DeployFeeControllerV3.s.sol";
import {BuildInstallFeeControllerV3Script, InstallV3Calldata} from "../script/BuildInstallFeeControllerV3.s.sol";
import {MockLaunchOracle, NotAnOracle} from "./utils/V3Mocks.sol";

/// @dev Stands in for the Safe: a contract, so the "owner must not be an EOA" check is meaningful.
contract SafeStub {}

/// @dev Kit v2 as far as the deploy gate can see it: an owner, and `isLockedLaunch`.
contract OwnedOracle is MockLaunchOracle {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @dev The part of `*PoolManagerOwner` the install touches.
contract WrapperStub {
    address public owner;
    address public controller;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address o) external {
        require(msg.sender == owner, "owner");
        owner = o;
    }

    function setProtocolFeeController(address c) external {
        require(msg.sender == owner, "owner");
        controller = c;
    }
}

contract FeeControllerV3ScriptsTest is Test {
    DeployFeeControllerV3Script deployScript;
    BuildInstallFeeControllerV3Script installScript;

    address safe;
    GullyCoreProtocolFeeControllerV2 v2;
    OwnedOracle kit;
    GullyCoreProtocolFeeControllerV3 v3;

    TimelockController timelock;
    WrapperStub clWrapper;
    WrapperStub binWrapper;

    address stranger = makeAddr("stranger");

    function setUp() public {
        deployScript = new DeployFeeControllerV3Script();
        installScript = new BuildInstallFeeControllerV3Script();

        safe = address(new SafeStub());
        v2 = new GullyCoreProtocolFeeControllerV2(safe, makeAddr("guardian"));
        kit = new OwnedOracle(safe);
        v3 = new GullyCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kit));

        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(InstallV3Calldata.CUSTODY_DELAY, proposers, executors, address(0));

        clWrapper = new WrapperStub(address(timelock));
        binWrapper = new WrapperStub(address(timelock));
    }

    /* ------------------------- deploy gate ------------------------- */

    function test_Deploy_GatePassesForTheRealShape() public view {
        deployScript.checkInputs(safe, address(v2), address(kit));
        deployScript.verifyDeployment(v3, safe, address(v2), address(kit));
    }

    function test_Deploy_RefusesV2OwnedBySomeoneElse() public {
        GullyCoreProtocolFeeControllerV2 foreign = new GullyCoreProtocolFeeControllerV2(address(new SafeStub()), address(0));
        vm.expectRevert(bytes("V2 is not owned by the Safe: V3 would compose over foreign policy"));
        deployScript.checkInputs(safe, address(foreign), address(kit));
    }

    function test_Deploy_RefusesATenantKit() public {
        OwnedOracle tenantKit = new OwnedOracle(stranger);
        vm.expectRevert(bytes("kit is not owned by the Safe: not Gully Core's kit"));
        deployScript.checkInputs(safe, address(v2), address(tenantKit));
    }

    function test_Deploy_RefusesAKitWithoutOwner() public {
        MockLaunchOracle ownerless = new MockLaunchOracle();
        vm.expectRevert(bytes("kit has no owner(): not LaunchpadKit v2"));
        deployScript.checkInputs(safe, address(v2), address(ownerless));
    }

    function test_Deploy_RefusesNonOracleAndLiars() public {
        NotAnOracle wrong = new NotAnOracle();
        vm.expectRevert(bytes("kit does not implement isLockedLaunch"));
        deployScript.checkInputs(safe, address(v2), address(wrong));

        OwnedOracle liar = new OwnedOracle(safe);
        liar.setMode(MockLaunchOracle.Mode.TrueForEverything);
        vm.expectRevert(bytes("kit does not implement isLockedLaunch"));
        deployScript.checkInputs(safe, address(v2), address(liar));
    }

    function test_Deploy_RefusesEOAOwnerAndDuplicates() public {
        vm.expectRevert(bytes("owner must be the Safe contract, not an EOA"));
        deployScript.checkInputs(stranger, address(v2), address(kit));

        vm.expectRevert(bytes("inputs must be three distinct contracts"));
        deployScript.checkInputs(safe, address(v2), address(v2));
    }

    function test_Deploy_ReadBackCatchesAWrongImmutable() public {
        OwnedOracle otherKit = new OwnedOracle(safe);
        vm.expectRevert(bytes("launchOracle immutable mismatch"));
        deployScript.verifyDeployment(v3, safe, address(v2), address(otherKit));
    }

    /* --------------------- the custody operation --------------------- */

    function test_Install_SaltIsTheConvention() public pure {
        assertEq(InstallV3Calldata.SALT, keccak256("gullycore.install.feeControllerV3"));
        // The literal, so a silent change of the string shows. Until 2026-11-06 this line still carried
        // keccak256("deepcore.install.feeControllerV3") (0xec2b...a9f4), the pre-rebrand value, and failed.
        // This is the timelock operation salt of the V3 install batch, not a CreateX salt: no address depends on it.
        assertEq(InstallV3Calldata.SALT, 0x0557090f57db84ad9c490dd87ad0371885b7c5812921420ff037e8c0e4bbec02);
    }

    function test_Install_RefusesZeroV3() public {
        vm.expectRevert(bytes("zero address"));
        installScript.checkOperation(address(0), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper));
    }

    function test_Install_RefusesV2AsV3() public {
        vm.expectRevert(bytes("that is V2, not V3"));
        installScript.checkOperation(address(v2), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper));
    }

    /// The live state until the queued accepts execute: the Safe still owns the wrappers.
    function test_Install_RefusesWhileTheSafeStillOwnsTheWrappers() public {
        WrapperStub safeOwned = new WrapperStub(safe);
        vm.expectRevert(
            bytes("wrappers are not owned by the custody timelock yet: execute and verify the queued acceptOwnership first")
        );
        installScript.checkOperation(address(v3), safe, address(v2), address(timelock), address(safeOwned), address(binWrapper));
    }

    /// Full rehearsal against a real OpenZeppelin TimelockController: the Safe schedules the printed
    /// bytes, nobody can execute early, a stranger executes after 48h, and both wrappers point at V3.
    function test_Install_RehearsalAgainstARealTimelock() public {
        installScript.checkOperation(address(v3), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper));

        bytes32 id = InstallV3Calldata.operationId(address(clWrapper), address(binWrapper), address(v3));
        (address[] memory t, uint256[] memory v, bytes[] memory p) =
            InstallV3Calldata.batch(address(clWrapper), address(binWrapper), address(v3));
        assertEq(id, timelock.hashOperationBatch(t, v, p, bytes32(0), InstallV3Calldata.SALT));

        vm.prank(stranger);
        (bool ok,) = address(timelock).call(
            InstallV3Calldata.scheduleCalldata(address(clWrapper), address(binWrapper), address(v3))
        );
        assertFalse(ok, "only the Safe proposes");

        vm.prank(safe);
        (ok,) = address(timelock).call(
            InstallV3Calldata.scheduleCalldata(address(clWrapper), address(binWrapper), address(v3))
        );
        assertTrue(ok, "Safe schedules");
        assertTrue(timelock.isOperationPending(id));

        bytes memory exec = InstallV3Calldata.executeCalldata(address(clWrapper), address(binWrapper), address(v3));
        vm.warp(block.timestamp + InstallV3Calldata.CUSTODY_DELAY - 1);
        vm.prank(stranger);
        (ok,) = address(timelock).call(exec);
        assertFalse(ok, "not before 48h");

        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        (ok,) = address(timelock).call(exec);
        assertTrue(ok, "anyone executes after 48h");

        assertEq(clWrapper.controller(), address(v3));
        assertEq(binWrapper.controller(), address(v3));
        assertTrue(timelock.isOperationDone(id));
    }
}
