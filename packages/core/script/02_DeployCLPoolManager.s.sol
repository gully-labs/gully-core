// SPDX-License-Identifier: UNLICENSED
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {CLPoolManager} from "../src/pool-cl/CLPoolManager.sol";
import {CoreCreateX} from "./CoreCreateX.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 *
 * Step 1: Deploy
 * forge script script/02_DeployCLPoolManager.s.sol:DeployCLPoolManagerScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployCLPoolManagerScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("GULLYCORE-CORE/CLPoolManager/1.0.0");
    }

    function run() public {

        uint256 deployerPrivateKey = _pk();
        address deployer = _signer(deployerPrivateKey);
        _broadcastAs(deployerPrivateKey);

        address vault = getAddressFromConfig("vault");
        console.log("vault address: ", address(vault));

        /// @dev append the vault address to the creationCode
        bytes memory creationCode = abi.encodePacked(type(CLPoolManager).creationCode, abi.encode(vault));

        /// @dev prepare the payload to transfer ownership from deployment contract to real deployer address
        bytes memory afterDeploymentExecutionPayload =
            abi.encodeWithSelector(Ownable.transferOwnership.selector, deployer);

        address clPoolManager = CoreCreateX.deploy(_signer(deployerPrivateKey), getDeploymentSalt(), creationCode, afterDeploymentExecutionPayload);
        console.log("CLPoolManager contract deployed at ", clPoolManager);

        console.log("Registering CLPoolManager");
        IVault(address(vault)).registerApp(address(clPoolManager));

        vm.stopBroadcast();
    }
}
