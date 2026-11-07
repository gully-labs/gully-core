// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreateXTest} from "gullycore-hooks/test/helpers/CreateXLike.sol";
import {DeployGullyCoreTunerGateScript} from "../script/DeployGullyCoreTunerGate.s.sol";
import {GullyCoreTunerGate} from "../src/GullyCoreTunerGate.sol";

contract GateSafeStandIn {}

contract DeployGullyCoreTunerGateTest is Test {
    uint256 internal constant PK = 0xA11CE;
    address internal constant OPS = address(0x0B5);
    address internal deployer;
    address internal safe;
    DeployGullyCoreTunerGateScript internal script;

    function setUp() public {
        deployer = vm.addr(PK);
        CreateXTest.etch();
        safe = address(new GateSafeStandIn());
        script = new DeployGullyCoreTunerGateScript();
    }

    function _p() internal view returns (DeployGullyCoreTunerGateScript.Params memory) {
        return DeployGullyCoreTunerGateScript.Params({
            pk: PK,
            owner: safe,
            guardian: OPS,
            recipient: safe,
            agentNotice: 1 days,
            policyNotice: 1 days,
            maxDeviationBps: 1_000,
            target: CreateXTest.target(deployer, bytes11("gate"))
        });
    }

    function test_deploys_readsBack_noAgentNoPolicy() public {
        GullyCoreTunerGate gate = script.runWith(_p());
        assertEq(gate.owner(), safe);
        assertEq(gate.guardian(), OPS);
        assertEq(gate.agent(), address(0));
        assertFalse(gate.paused());
    }

    function test_refusesAnEoaOwner_andAGuardianThatIsTheOwnerOrDeployer() public {
        DeployGullyCoreTunerGateScript.Params memory p = _p();
        p.owner = address(0xE0A);
        vm.expectRevert(bytes("GATE_OWNER has no code - the Safe, not an EOA"));
        script.runWith(p);
        p = _p();
        p.guardian = safe;
        vm.expectRevert(bytes("GATE_GUARDIAN must be Ops, not the owner or the deployer"));
        script.runWith(p);
        p = _p();
        p.guardian = deployer;
        vm.expectRevert(bytes("GATE_GUARDIAN must be Ops, not the owner or the deployer"));
        script.runWith(p);
    }

    function test_onProduction_refusesAnOwnerThatIsNotTheSafeOfRecord() public {
        vm.chainId(485590);
        vm.expectRevert(bytes("GATE_OWNER is not the governance Safe of record"));
        script.checkInputs(_p(), deployer);
    }

    function test_refusesASecondDeployAtTheSameSalt() public {
        script.runWith(_p());
        vm.expectRevert(bytes("the predicted address already has code on this chain (GULLYCORE_TUNER_GATE)"));
        script.runWith(_p());
    }
}
