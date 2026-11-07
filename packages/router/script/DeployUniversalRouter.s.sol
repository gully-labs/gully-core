// SPDX-License-Identifier: UNLICENSED
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.15;

import "forge-std/console2.sol";
import "forge-std/Script.sol";
import {RouterParameters} from "../src/base/RouterImmutables.sol";
import {UnsupportedProtocol} from "../src/deploy/UnsupportedProtocol.sol";
import {UniversalRouter} from "../src/UniversalRouter.sol";
import {CoreCreateX} from "infinity-core/script/CoreCreateX.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

abstract contract DeployUniversalRouter is Script {
    RouterParameters internal params;
    address internal unsupported;

    address constant UNSUPPORTED_PROTOCOL = address(0);
    bytes32 constant BYTES32_ZERO = bytes32(0);

    error Permit2NotDeployed();
    /// @notice A v2 / v3 / stable leg points at another protocol's factory. Gully Core is Infinity-only.
    error ForeignProtocolLegConfigured();
    /// @notice One of the three infi* legs is unset; a router with no Gully Core core routes nothing of ours.
    error GullyCoreCoreNotConfigured();

    // set values for params and unsupported
    function setUp() public virtual;

    /// @notice must be implemented by the inheriting contract to make sure eth deployment salt is unique
    /// with CreateX CREATE2 the address is decided by the deployer, this salt and the init code (see CoreCreateX)
    function getDeploymentSalt() public view virtual returns (bytes32);

    function run() external returns (address router) {
        /// @dev Gully Core deploys through canonical CreateX (core/script/CoreCreateX.sol, H-1).
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployerAddress = deployerPrivateKey != 0 ? vm.addr(deployerPrivateKey) : vm.envAddress("DEPLOYER"); // DEPLOYER + --unlocked: keyless rehearsal
        /* Gully Core is Infinity-only on every chain (CLAUDE.md, owner decision 2026-09-13): no routing of
           user trades into PancakeSwap's or Uniswap's pools. The upstream parameter files kept under
           script/deployParameters/mainnet/ (DeployBase, DeployBsc, DeployEth, ...) still carry
           PancakeSwap's v2/v3/stable factories AND PancakeSwap's Vault and pool managers under a
           GULLY CORE deployment salt. Refuse them before any key is used: a Gully Core router only ever has
           the three infi* legs, so every other leg must be address(0) -> UnsupportedProtocol. A new
           chain gets its own file modelled on DeployGullyCoreChain.s.sol, with OUR core addresses. */
        if (
            params.v2Factory != address(0) || params.v3Factory != address(0) || params.v3Deployer != address(0)
                || params.stableFactory != address(0) || params.stableInfo != address(0)
        ) revert ForeignProtocolLegConfigured();
        if (params.infiVault == address(0) || params.infiClPoolManager == address(0) || params.infiBinPoolManager == address(0)) {
            revert GullyCoreCoreNotConfigured();
        }

        if (deployerPrivateKey != 0) vm.startBroadcast(deployerPrivateKey);
        else vm.startBroadcast(deployerAddress);

        if (params.permit2 == address(0)) revert Permit2NotDeployed();

        // only deploy unsupported if this chain doesn't already have one
        if (unsupported == address(0)) {
            unsupported = address(new UnsupportedProtocol());
            console2.log("UnsupportedProtocol deployed:", unsupported);
        }

        params = RouterParameters({
            permit2: mapUnsupported(params.permit2),
            weth9: mapUnsupported(params.weth9),
            v2Factory: mapUnsupported(params.v2Factory),
            v3Factory: mapUnsupported(params.v3Factory),
            v3Deployer: mapUnsupported(params.v3Deployer),
            v2InitCodeHash: params.v2InitCodeHash,
            v3InitCodeHash: params.v3InitCodeHash,
            stableFactory: mapUnsupported(params.stableFactory),
            stableInfo: mapUnsupported(params.stableInfo),
            infiVault: mapUnsupported(params.infiVault),
            infiClPoolManager: mapUnsupported(params.infiClPoolManager),
            infiBinPoolManager: mapUnsupported(params.infiBinPoolManager)
        });

        logParams();

        /// Prepare the payload to transfer ownership to deployer.
        /// @dev deployer must call acceptOwnership after to be the owner
        address owner = deployerAddress;
        console.log("universal router owner:", owner);

        bytes memory afterDeploymentExecutionPayload = abi.encodeWithSelector(Ownable.transferOwnership.selector, owner);

        bytes memory creationCode = abi.encodePacked(type(UniversalRouter).creationCode, abi.encode(params));

        router = CoreCreateX.deploy(deployerAddress, getDeploymentSalt(), creationCode, afterDeploymentExecutionPayload);

        console.log("UniversalRouter contract deployed at ", router);

        vm.stopBroadcast();
    }

    function logParams() internal view {
        console2.log("permit2:", params.permit2);
        console2.log("weth9:", params.weth9);
        console2.log("v2Factory:", params.v2Factory);
        console2.log("v3Factory:", params.v3Factory);
        console2.log("v3Deployer:", params.v3Deployer);
        console2.log("v2InitCodeHash:");
        console2.logBytes32(params.v2InitCodeHash);
        console2.log("v3InitCodeHash:");
        console2.logBytes32(params.v3InitCodeHash);
        console2.log("stableFactory:", params.stableFactory);
        console2.log("stableInfo:", params.stableInfo);
        console2.log("infiVault:", params.infiVault);
        console2.log("infiClPoolManager:", params.infiClPoolManager);
        console2.log("infiBinPoolManager:", params.infiBinPoolManager);
    }

    function mapUnsupported(address protocol) internal view returns (address) {
        return protocol == address(0) ? unsupported : protocol;
    }
}
