// SPDX-License-Identifier: UNLICENSED
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {BinPoolManager} from "../src/pool-bin/BinPoolManager.sol";
import {CoreCreateX} from "./CoreCreateX.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 *
 * Step 1: Deploy
 * forge script script/03_DeployBinPoolManager.s.sol:DeployBinPoolManagerScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployBinPoolManagerScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("GULLYCORE-CORE/BinPoolManager/1.0.0");
    }

    function run() public {

        uint256 deployerPrivateKey = _pk();
        address deployer = _signer(deployerPrivateKey);
        _broadcastAs(deployerPrivateKey);

        address vault = getAddressFromConfig("vault");
        console.log("vault address: ", address(vault));

        /// @dev append the vault address to the creationCode
        bytes memory creationCode = abi.encodePacked(type(BinPoolManager).creationCode, abi.encode(vault));

        /// @dev prepare the payload to transfer ownership from deployer to real owner
        bytes memory afterDeploymentExecutionPayload =
            abi.encodeWithSelector(Ownable.transferOwnership.selector, deployer);

        address binPoolManager = CoreCreateX.deploy(_signer(deployerPrivateKey), getDeploymentSalt(), creationCode, afterDeploymentExecutionPayload);

        console.log("BinPoolManager contract deployed at ", binPoolManager);

        console.log("Registering BinPoolManager");
        IVault(address(vault)).registerApp(address(binPoolManager));

        vm.stopBroadcast();
    }
}
