// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployGullyCoreDynamicFeeHookScript} from "../../script/DeployGullyCoreDynamicFeeHook.s.sol";
import {DeployGullyCoreBinDynamicFeeHookScript} from "../../script/DeployGullyCoreBinDynamicFeeHook.s.sol";
import {DeployGullyCoreDexHookScript} from "../../script/DeployGullyCoreDexHook.s.sol";

contract ManagerStub {
    address public protocolFeeController;

    constructor(address c) {
        protocolFeeController = c;
    }
}

/// @dev V5's shape: a flat fee, and a hook list that does not name the hook.
contract FlatController {
    function builderFee() external pure returns (uint16) {
        return 3000;
    }

    function isZeroFeeHook(address) external pure returns (bool) {
        return false;
    }
}

/// @dev V4's shape: no flat fee, a hook list.
contract ListController {
    mapping(address => bool) public isZeroFeeHook;

    function list(address hook) external {
        isZeroFeeHook[hook] = true;
    }
}

/// @notice Release 3 (owner default d): on a chain whose controller is the flat-fee V5 Gully's own hooks pay the flat
/// fee, so the scripts' "must be listed as zero-fee" rule does not apply there. It still applies everywhere else.
contract DeployScriptsFlatFeeChainTest is Test {
    address constant HOOK = address(0x4004);

    function _check(address manager) internal view {
        clScript.requireListedAsZeroFee(manager, HOOK);
        binScript.requireListedAsZeroFee(manager, HOOK);
        dexScript.requireListedAsZeroFee(manager, HOOK);
    }

    DeployGullyCoreDynamicFeeHookScript clScript;
    DeployGullyCoreBinDynamicFeeHookScript binScript;
    DeployGullyCoreDexHookScript dexScript;

    function setUp() public {
        clScript = new DeployGullyCoreDynamicFeeHookScript();
        binScript = new DeployGullyCoreBinDynamicFeeHookScript();
        dexScript = new DeployGullyCoreDexHookScript();
    }

    function test_flatFeeChain_accepted_onAllThreeScripts() public {
        ManagerStub m = new ManagerStub(address(new FlatController()));
        assertTrue(clScript.isFlatFeeChain(address(m)));
        assertTrue(dexScript.isFlatFeeChain(address(m)));
        _check(address(m));
    }

    function test_listController_stillRefusesAnUnlistedHook() public {
        ListController c = new ListController();
        ManagerStub m = new ManagerStub(address(c));
        assertFalse(clScript.isFlatFeeChain(address(m)));
        vm.expectRevert();
        clScript.requireListedAsZeroFee(address(m), HOOK);
        vm.expectRevert();
        binScript.requireListedAsZeroFee(address(m), HOOK);
        vm.expectRevert();
        dexScript.requireListedAsZeroFee(address(m), HOOK);
        c.list(HOOK);
        _check(address(m));
    }
}
