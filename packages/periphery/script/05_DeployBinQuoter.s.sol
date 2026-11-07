// SPDX-License-Identifier: UNLICENSED
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {BinQuoter} from "../src/pool-bin/lens/BinQuoter.sol";
import {CoreCreateX} from "infinity-core/script/CoreCreateX.sol";

/**
 * Pre-req: foundry on stable (1.0) otherwise verify will fail: ref https://github.com/foundry-rs/foundry/issues/9698
 *
 * Step 1: Deploy
 * forge script script/05_DeployBinQuoter.s.sol:DeployBinQuoterScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployBinQuoterScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("GULLYCORE-PERIPHERY/BinQuoter/1.0.0");
    }

    function run() public {

        uint256 deployerPrivateKey = _pk();
        _broadcastAs(deployerPrivateKey);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("BinPoolManager", binPoolManager);

        bytes memory creationCodeData = abi.encode(binPoolManager);
        bytes memory creationCode = abi.encodePacked(type(BinQuoter).creationCode, creationCodeData);
        address binQuoter =
            CoreCreateX.deploy(_signer(deployerPrivateKey), getDeploymentSalt(), creationCode, "");
        emit log_named_address("BinQuoter", binQuoter);

        vm.stopBroadcast();
    }
}
