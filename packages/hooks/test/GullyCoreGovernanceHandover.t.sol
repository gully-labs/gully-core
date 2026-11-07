// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {GullyCoreGovernance} from "../script/GullyCoreGovernance.sol";

/// @dev What the library reads of a Safe: its threshold and its owners.
contract SafeShape {
    uint256 internal _threshold;
    address[] internal _owners;

    function set(uint256 threshold_, address[] memory owners_) external {
        _threshold = threshold_;
        _owners = owners_;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }
}

/// @dev External entry points, so a refusal is a revert the test can expect.
contract GovernanceHarness {
    function requireGovernanceSafe(address candidate, address deployer) external view {
        GullyCoreGovernance.requireGovernanceSafe(candidate, deployer, "GOVERNANCE");
    }

    function requireSafeQuorum3(address safe, bool allowWeak) external view {
        GullyCoreGovernance.requireSafeQuorum(safe, "GOVERNANCE", allowWeak);
    }

    function requireSafeQuorum4(address safe, bool allowWeak, address signer) external view {
        GullyCoreGovernance.requireSafeQuorum(safe, "GOVERNANCE", allowWeak, signer);
    }

    function safeOf(uint256 chainId) external view returns (address) {
        return GullyCoreGovernance.safeOf(chainId);
    }
}

/// @notice Option 2 (owner decision 2026-11-05): the temporary 1-of-1 hand-over Safe is accepted for the
/// duration of a hand-over run and in no other case. Every "refused" test here is a red check: it names one
/// condition of the relaxation and shows the refusal comes back when that condition alone is missing.
contract GullyCoreGovernanceHandoverTest is Test {
    address internal constant DEPLOYER = 0x92cFC047652d6aEf7eb0fa2744B912d9f627fA41;
    address internal constant HANDOVER_SAFE = 0xaaa3ee4e1c7b6241156516D4B630A3bF2541f786;
    address internal constant T1 = 0x5aD50DdE058b2c41298D9C5A33527a7E2150CD78;
    address internal constant T2 = 0x1490fDC92438FD37032F63a97dC361D21265756d;
    address internal constant T3 = 0xA60985eB5E61C0DF5150db022FE5c21C89B363f0;
    string internal constant FLAG = "GULLYCORE_HANDOVER_RUN";
    string internal constant WEAK = "GULLYCORE_ALLOW_TESTNET_WEAK_SAFE";

    GovernanceHarness internal h;

    function setUp() public {
        h = new GovernanceHarness();
        vm.chainId(8453);
        _shape(HANDOVER_SAFE, 1, _one(DEPLOYER));
    }

    /// @dev `vm.setEnv` writes the PROCESS environment, which forge does not reset between tests (or between
    /// test contracts). Every test that reads a flag therefore starts from both flags off and leaves them off.
    modifier flagsOff() {
        vm.setEnv(FLAG, "false");
        vm.setEnv(WEAK, "false");
        _;
        vm.setEnv(FLAG, "false");
        vm.setEnv(WEAK, "false");
    }

    function _one(address a) internal pure returns (address[] memory o) {
        o = new address[](1);
        o[0] = a;
    }

    function _treasury() internal pure returns (address[] memory o) {
        o = new address[](3);
        o[0] = T1;
        o[1] = T2;
        o[2] = T3;
    }

    /// @dev Put a Safe-shaped contract at `at`.
    function _shape(address at, uint256 threshold, address[] memory owners) internal {
        vm.etch(at, address(new SafeShape()).code);
        SafeShape(at).set(threshold, owners);
    }

    /*//////////////////////////////////////////////////////////////
                           THE SAFE OF RECORD
    //////////////////////////////////////////////////////////////*/

    function test_constants_theHandoverSafeIsWhatItsInputsGive() public pure {
        assertEq(GullyCoreGovernance.predictHandoverSafe(), GullyCoreGovernance.HANDOVER_SAFE);
        assertEq(GullyCoreGovernance.HANDOVER_SAFE, HANDOVER_SAFE);
        assertEq(GullyCoreGovernance.HANDOVER_DEPLOYER, DEPLOYER);
    }

    function test_safeOf_isTheHandoverSafeOnTheFiveChainsOnly() public view {
        uint256[5] memory chains = [uint256(4663), 8453, 56, 999, 6714];
        for (uint256 i; i < chains.length; ++i) {
            assertEq(h.safeOf(chains[i]), HANDOVER_SAFE);
            assertTrue(GullyCoreGovernance.isHandoverChain(chains[i]));
        }
        assertEq(h.safeOf(1), address(0), "Ethereum has no Safe of record");
        assertEq(h.safeOf(42161), address(0));
        assertFalse(GullyCoreGovernance.isHandoverChain(1));
        assertFalse(GullyCoreGovernance.isHandoverChain(485590), "the testnet is not a hand-over chain");
        assertEq(h.safeOf(485590), GullyCoreGovernance.SAFE, "the testnet Safe of record is unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                             THE RUN ITSELF
    //////////////////////////////////////////////////////////////*/

    function test_handover_acceptedDuringARun() public flagsOff {
        vm.setEnv(FLAG, "true");
        uint256[5] memory chains = [uint256(4663), 8453, 56, 999, 6714];
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
            h.requireSafeQuorum4(HANDOVER_SAFE, false, DEPLOYER);
        }
    }

    /// RED: the flag is what opens it.
    function test_handover_refusedWithoutTheFlag() public flagsOff {
        vm.expectRevert(bytes("GOVERNANCE is a 1-of-1 Safe: governance needs a threshold of at least 2 and at least 3 owners"));
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
        vm.expectRevert();
        h.requireSafeQuorum4(HANDOVER_SAFE, false, DEPLOYER);
    }

    /// RED: only THE hand-over Safe.
    function test_handover_refusedForAnyOtherSafe() public flagsOff {
        vm.setEnv(FLAG, "true");
        address other = address(0x5AFE);
        _shape(other, 1, _one(DEPLOYER));
        vm.expectRevert(bytes("GOVERNANCE is not the governance Safe of record"));
        h.requireGovernanceSafe(other, DEPLOYER);
        vm.expectRevert();
        h.requireSafeQuorum4(other, false, DEPLOYER);
    }

    /// RED: only a 1-of-1 whose single owner is the signer.
    function test_handover_refusedWhenTheSingleOwnerIsNotTheSigner() public flagsOff {
        vm.setEnv(FLAG, "true");
        _shape(HANDOVER_SAFE, 1, _one(address(0xBAD)));
        vm.expectRevert();
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
        // ...and a signer that is not the deployer of record, even if it owns the Safe.
        vm.expectRevert();
        h.requireGovernanceSafe(HANDOVER_SAFE, address(0xBAD));
        vm.expectRevert();
        h.requireSafeQuorum4(HANDOVER_SAFE, false, address(0xBAD));
    }

    /// RED: no other weak shape rides on the flag.
    function test_handover_refusedForOtherWeakShapes() public flagsOff {
        vm.setEnv(FLAG, "true");
        address[] memory two = new address[](2);
        two[0] = DEPLOYER;
        two[1] = T1;
        _shape(HANDOVER_SAFE, 1, two); // 1-of-2
        vm.expectRevert();
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
        _shape(HANDOVER_SAFE, 2, two); // 2-of-2
        vm.expectRevert();
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
        _shape(HANDOVER_SAFE, 1, _treasury()); // 1-of-3
        vm.expectRevert();
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
        // One owner and any threshold but 1 (a real Safe refuses this shape; the rule does not lean on that).
        _shape(HANDOVER_SAFE, 2, _one(DEPLOYER));
        vm.expectRevert();
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
        _shape(HANDOVER_SAFE, 0, _one(DEPLOYER));
        vm.expectRevert();
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
    }

    /// RED: only the hand-over chains.
    function test_handover_refusedOnAnyOtherChain() public flagsOff {
        vm.setEnv(FLAG, "true");
        vm.chainId(1);
        vm.expectRevert(bytes("GullyCoreGovernance: governance Safe of record is not set"));
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
        vm.expectRevert();
        h.requireSafeQuorum4(HANDOVER_SAFE, false, DEPLOYER);
        vm.chainId(485590);
        vm.expectRevert();
        h.requireSafeQuorum4(HANDOVER_SAFE, false, DEPLOYER);
    }

    /// RED: the entry point that names no signer never relaxes.
    function test_handover_theThreeArgumentFormNeverRelaxes() public flagsOff {
        vm.setEnv(FLAG, "true");
        vm.expectRevert();
        h.requireSafeQuorum3(HANDOVER_SAFE, false);
    }

    /// RED: the testnet's weak-Safe flag does nothing on a hand-over chain.
    function test_handover_theTestnetFlagDoesNotOpenAMainnet() public flagsOff {
        vm.setEnv(WEAK, "true");
        vm.expectRevert();
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
        vm.expectRevert();
        h.requireSafeQuorum3(HANDOVER_SAFE, true);
    }

    /*//////////////////////////////////////////////////////////////
                           AFTER THE CONVERSION
    //////////////////////////////////////////////////////////////*/

    function test_afterConversion_twoOfThreePassesWithTheFlagUnset() public flagsOff {
        _shape(HANDOVER_SAFE, 2, _treasury());
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
        h.requireSafeQuorum3(HANDOVER_SAFE, false);
        // and the flag, left set by mistake, changes nothing for a Safe that is already 2-of-3
        vm.setEnv(FLAG, "true");
        h.requireGovernanceSafe(HANDOVER_SAFE, DEPLOYER);
    }

    function test_governanceSafe_stillRefusesTheDeployerAndAnEoa() public flagsOff {
        vm.setEnv(FLAG, "true");
        vm.expectRevert(bytes("GOVERNANCE has no code - the Safe, not an EOA"));
        h.requireGovernanceSafe(address(0xE0A), DEPLOYER);
        // The deployer is refused by name even if its address had Safe-shaped code (the code check comes first).
        _shape(DEPLOYER, 1, _one(DEPLOYER));
        vm.expectRevert(bytes("GOVERNANCE is the deployer"));
        h.requireGovernanceSafe(DEPLOYER, DEPLOYER);
    }
}
