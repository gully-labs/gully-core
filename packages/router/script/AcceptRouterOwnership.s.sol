// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Script.sol";

interface IOwnable2Step {
    function acceptOwnership() external;
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/**
 * Claims ownership of the UniversalRouter.
 *
 * CreateX deploys it (core/script/CoreCreateX.sol), so the router's constructor
 * owner is CreateX. The deploy script queues a transfer to the
 * deployer, but Ownable2Step means it is only PENDING until accepted — leaving the
 * router owned by a contract nobody controls.
 */
contract AcceptRouterOwnershipScript is Script {
    function run() public {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address me = pk != 0 ? vm.addr(pk) : vm.envAddress("DEPLOYER"); // DEPLOYER + --unlocked: a keyless rehearsal
        IOwnable2Step router = IOwnable2Step(vm.envAddress("UNIVERSAL_ROUTER"));

        require(router.pendingOwner() == me, "deployer is not pendingOwner");

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast(me);
        router.acceptOwnership();
        vm.stopBroadcast();

        require(router.owner() == me, "ownership not accepted");
        console.log("UniversalRouter owner now", router.owner());
    }
}
