// SPDX-License-Identifier: UNLICENSED
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.15;

import {DeployUniversalRouter} from "../DeployUniversalRouter.s.sol";
import {RouterParameters} from "../../src/base/RouterImmutables.sol";

interface IWrappedNativeMeta {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/**
 * UniversalRouter for Gully Core on any chain (Gully Chain testnet 485590 first). Nothing is deployed yet.
 *
 * Only the Gully Core (infi*) legs are wired; v2 / v3 / stable stay at address(0), which the base script
 * maps to UnsupportedProtocol. The salt is fixed, so with the same deployer and the same Vault / pool
 * manager addresses the router lands at the same CreateX CREATE2 address on every chain.
 *
 * Nothing chain-specific is typed into this file. Every value is read from the environment, and the
 * script refuses a chain it was not told to expect:
 *
 *   EXPECTED_CHAIN_ID       the chain this run is for; must equal block.chainid
 *   ROUTER_WRAPPED_NATIVE   that chain's wrapped native token, READ on chain first (18 decimals)
 *   VAULT, CL_POOL_MANAGER, BIN_POOL_MANAGER   from core's read-backs on that chain
 *   PRIVATE_KEY (deploys through canonical CreateX, see core/script/CoreCreateX.sol)
 *
 * Permit2 is the canonical address and must have code on the chain.
 */
contract DeployGullyCoreChain is DeployUniversalRouter {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public override {
        uint256 expected = vm.envUint("EXPECTED_CHAIN_ID");
        require(block.chainid == expected, "DeployGullyCoreChain: not the expected chain");
        address permit2 = vm.envOr("ROUTER_PERMIT2", PERMIT2); // canonical, unless the chain cannot have it (Anubis)
        require(permit2.code.length > 0, "Permit2 has no code on this chain");

        address wnative = vm.envAddress("ROUTER_WRAPPED_NATIVE");
        require(wnative.code.length > 0, "ROUTER_WRAPPED_NATIVE has no code on this chain");
        require(IWrappedNativeMeta(wnative).decimals() == 18, "wrapped native is not 18 decimals");
        require(bytes(IWrappedNativeMeta(wnative).symbol()).length > 0, "wrapped native has no symbol");

        address vault = vm.envAddress("VAULT");
        address cl = vm.envAddress("CL_POOL_MANAGER");
        address bin = vm.envAddress("BIN_POOL_MANAGER");
        require(vault.code.length > 0, "VAULT has no code on this chain");
        require(cl.code.length > 0, "CL_POOL_MANAGER has no code on this chain");
        require(bin.code.length > 0, "BIN_POOL_MANAGER has no code on this chain");

        params = RouterParameters({
            permit2: permit2,
            weth9: wnative,
            v2Factory: address(0),
            v3Factory: address(0),
            v3Deployer: address(0),
            v2InitCodeHash: bytes32(0),
            v3InitCodeHash: bytes32(0),
            stableFactory: address(0),
            stableInfo: address(0),
            infiVault: vault,
            infiClPoolManager: cl,
            infiBinPoolManager: bin
        });
        unsupported = address(0);
    }

    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("GULLYCORE-UNIVERSAL-ROUTER/1.0.0");
    }
}
