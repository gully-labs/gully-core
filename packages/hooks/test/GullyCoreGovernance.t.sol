// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GullyCoreGovernance} from "../script/GullyCoreGovernance.sol";

/// A Safe stand-in that answers getThreshold() / getOwners() like Safe 1.4.1. Immutables, so vm.etch of its code
/// at the Safe of record carries the quorum with it.
contract QuorumSafe {
    uint256 internal immutable THRESHOLD;
    uint256 internal immutable OWNERS;

    constructor(uint256 threshold, uint256 owners) {
        THRESHOLD = threshold;
        OWNERS = owners;
    }

    function getThreshold() external view returns (uint256) {
        return THRESHOLD;
    }

    function getOwners() external view returns (address[] memory o) {
        o = new address[](OWNERS);
        for (uint256 i; i < OWNERS; i++) o[i] = address(uint160(0x1000 + i));
    }
}

/// Has code, but is not a Safe.
contract NotASafe {}

/// The library is internal: this wrapper makes reverts observable.
contract GovernanceHarness {
    function requireGovernanceSafe(address candidate, address deployer, string memory label) external view {
        GullyCoreGovernance.requireGovernanceSafe(candidate, deployer, label);
    }

    function requireSafeQuorum(address safe, string memory label, bool allowWeakOnTestnet) external view {
        GullyCoreGovernance.requireSafeQuorum(safe, label, allowWeakOnTestnet);
    }
}

contract GullyCoreGovernanceQuorumTest is Test {
    uint256 internal constant GULLY_MAINNET = 48559;
    address internal constant DEPLOYER = address(0xD3); // not the Safe
    GovernanceHarness internal h;

    function setUp() public {
        h = new GovernanceHarness();
    }

    function _safe(uint256 threshold, uint256 owners) internal returns (address) {
        return address(new QuorumSafe(threshold, owners));
    }

    // ---- the quorum rule itself ----

    function test_quorum_aOneOfOneSafeIsRefused() public {
        address s = _safe(1, 1);
        vm.chainId(GULLY_MAINNET);
        vm.expectRevert(bytes("OWNER is a 1-of-1 Safe: governance needs a threshold of at least 2 and at least 3 owners"));
        h.requireSafeQuorum(s, "OWNER", false);
    }

    function test_quorum_twoOfTwoAndOneOfThreeAreRefused() public {
        vm.chainId(GULLY_MAINNET);
        address a = _safe(2, 2);
        vm.expectRevert(bytes("OWNER is a 2-of-2 Safe: governance needs a threshold of at least 2 and at least 3 owners"));
        h.requireSafeQuorum(a, "OWNER", false);
        address b = _safe(1, 3);
        vm.expectRevert(bytes("OWNER is a 1-of-3 Safe: governance needs a threshold of at least 2 and at least 3 owners"));
        h.requireSafeQuorum(b, "OWNER", false);
    }

    function test_quorum_twoOfThreeAndThreeOfFivePass() public {
        vm.chainId(GULLY_MAINNET);
        h.requireSafeQuorum(_safe(2, 3), "OWNER", false);
        h.requireSafeQuorum(_safe(3, 5), "OWNER", false);
    }

    function test_quorum_theTestnetOverrideIsIgnoredOnMainnet() public {
        address s = _safe(1, 1);
        vm.chainId(GULLY_MAINNET);
        vm.expectRevert(bytes("OWNER is a 1-of-1 Safe: governance needs a threshold of at least 2 and at least 3 owners"));
        h.requireSafeQuorum(s, "OWNER", true);
        vm.chainId(8453);
        vm.expectRevert(bytes("OWNER is a 1-of-1 Safe: governance needs a threshold of at least 2 and at least 3 owners"));
        h.requireSafeQuorum(s, "OWNER", true);
    }

    function test_quorum_theTestnetOverrideWorksOnlyOnGullyTestnet() public {
        address s = _safe(1, 1);
        vm.chainId(485590);
        h.requireSafeQuorum(s, "OWNER", true); // explicit override, testnet: allowed
        vm.expectRevert(bytes("OWNER is a 1-of-1 Safe: governance needs a threshold of at least 2 and at least 3 owners"));
        h.requireSafeQuorum(s, "OWNER", false); // no override: refused on the testnet too
    }

    function test_quorum_aContractThatIsNotASafeIsRefused() public {
        address s = address(new NotASafe());
        vm.chainId(GULLY_MAINNET);
        vm.expectRevert(bytes("OWNER does not answer getThreshold()/getOwners() like a Safe"));
        h.requireSafeQuorum(s, "OWNER", false);
    }

    // ---- through requireGovernanceSafe, on Gully Chain testnet 485590 (the Safe of record is SAFE) ----

    function test_governance_testnetSafeOfRecordAsOneOfOneIsRefusedWithoutTheOverride() public {
        vm.chainId(485590);
        vm.etch(GullyCoreGovernance.SAFE, address(new QuorumSafe(1, 1)).code);
        vm.expectRevert(bytes("GOV is a 1-of-1 Safe: governance needs a threshold of at least 2 and at least 3 owners"));
        h.requireGovernanceSafe(GullyCoreGovernance.SAFE, DEPLOYER, "GOV");
    }

    function test_governance_testnetSafeOfRecordWithAQuorumPasses() public {
        vm.chainId(485590);
        vm.etch(GullyCoreGovernance.SAFE, address(new QuorumSafe(2, 3)).code);
        h.requireGovernanceSafe(GullyCoreGovernance.SAFE, DEPLOYER, "GOV");
    }

    function test_governance_mainnetStillRefusesWhileTheSafeOfRecordIsUnset() public {
        vm.chainId(GULLY_MAINNET);
        address s = _safe(3, 5);
        vm.expectRevert(bytes("GullyCoreGovernance: governance Safe of record is not set"));
        h.requireGovernanceSafe(s, DEPLOYER, "GOV");
    }

    function test_governance_devChainsAreUnchanged() public {
        vm.chainId(31337);
        h.requireGovernanceSafe(address(new NotASafe()), DEPLOYER, "GOV"); // code + not the deployer is enough there
    }
}
