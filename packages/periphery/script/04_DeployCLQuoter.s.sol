// SPDX-License-Identifier: UNLICENSED
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {CLQuoter} from "../src/pool-cl/lens/CLQuoter.sol";
import {CoreCreateX} from "infinity-core/script/CoreCreateX.sol";

/**
 * Pre-req: foundry on stable (1.0) otherwise verify will fail: ref https://github.com/foundry-rs/foundry/issues/9698
 *
 * Step 1: Deploy
 * forge script script/04_DeployCLQuoter.s.sol:DeployCLQuoterScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployCLQuoterScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("GULLYCORE-PERIPHERY/CLQuoter/1.0.0");
    }

    function run() public {

        uint256 deployerPrivateKey = _pk();
        _broadcastAs(deployerPrivateKey);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        bytes memory creationCodeData = abi.encode(clPoolManager);
        bytes memory creationCode = abi.encodePacked(type(CLQuoter).creationCode, creationCodeData);
        address clQuoter =
            CoreCreateX.deploy(_signer(deployerPrivateKey), getDeploymentSalt(), creationCode, "");
        emit log_named_address("CLQuoter", clQuoter);

        vm.stopBroadcast();
    }
}
