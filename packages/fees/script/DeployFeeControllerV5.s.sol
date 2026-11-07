// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {GullyCoreSignerScript} from "gullycore-hooks/script/GullyCoreSigner.sol";
import {GullyCoreGovernance} from "gullycore-hooks/script/GullyCoreGovernance.sol";
import {GullyCoreDeploy} from "gullycore-hooks/script/GullyCoreCreateX.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";

import {GullyCoreProtocolFeeControllerV5} from "../src/GullyCoreProtocolFeeControllerV5.sol";
import {ILockedLaunchOracle} from "../src/interfaces/ILockedLaunchOracle.sol";

/**
 * Deploys GullyCoreProtocolFeeControllerV5 (the flat builder and partner fee) through CreateX CREATE3 at the
 * permissioned salt of label GULLYCORE_FEE_CONTROLLER_V5. It deploys and checks; it does NOT install: the Safe
 * calls `setProtocolFeeController(V5)` on both pool-manager owner wrappers afterwards.
 *
 * Inputs (environment; none has a default):
 *   FEE_OWNER_SAFE                        the governance Safe: owner and immutable treasury
 *   CL_POOL_MANAGER, BIN_POOL_MANAGER     the two pool managers V5 prices
 *   BUILDER_FEE_PIPS                      the flat fee per direction for every non-launch pool (3000 = 0.30%)
 *   LAUNCH_ORACLES                        comma list, 1 to 4 Gully Core kits (every kit whose locked launches exist)
 *   ZERO_FEE_HOOKS                        comma list, or the word `none`
 *   ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS  1 to 90 days (7 days or more on a production chain)
 *   GULLYCORE_SALT_GULLYCORE_FEE_CONTROLLER_V5 / GULLYCORE_ADDRESS_GULLYCORE_FEE_CONTROLLER_V5
 */
contract DeployFeeControllerV5Script is GullyCoreSignerScript {
    string internal constant LABEL = "GULLYCORE_FEE_CONTROLLER_V5";
    uint32 internal constant PRODUCTION_MIN_REMOVAL_NOTICE = 7 days;
    uint256 internal constant MAX_LAUNCH_ORACLES = 4;

    struct Inputs {
        address safe;
        address cl;
        address bin;
        uint16 builderFee;
        address[] kits;
        address[] hooks;
        uint32 notice;
    }

    function run() external returns (GullyCoreProtocolFeeControllerV5 controller) {
        uint256 pk = _pkFromEnv();
        Inputs memory in_;
        in_.safe = vm.envAddress("FEE_OWNER_SAFE");
        in_.cl = vm.envAddress("CL_POOL_MANAGER");
        in_.bin = vm.envAddress("BIN_POOL_MANAGER");
        uint256 fee = vm.envUint("BUILDER_FEE_PIPS");
        require(fee <= 4000, "BUILDER_FEE_PIPS is above core's cap of 4000");
        in_.builderFee = uint16(fee);
        in_.kits = vm.envAddress("LAUNCH_ORACLES", ",");
        string memory hooksRaw = vm.envString("ZERO_FEE_HOOKS");
        in_.hooks = keccak256(bytes(hooksRaw)) == keccak256("none") ? new address[](0) : vm.envAddress("ZERO_FEE_HOOKS", ",");
        uint256 notice = vm.envUint("ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS");
        require(notice <= type(uint32).max, "ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS is out of range");
        in_.notice = uint32(notice);
        return runWith(pk, in_, GullyCoreDeploy.fromEnv(LABEL, _signerOf(pk)));
    }

    function initCode(Inputs memory in_) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(GullyCoreProtocolFeeControllerV5).creationCode,
            abi.encode(in_.safe, in_.cl, in_.bin, in_.builderFee, in_.kits, in_.hooks, in_.notice)
        );
    }

    function runWith(uint256 pk, Inputs memory in_, GullyCoreDeploy.Target memory target)
        public
        returns (GullyCoreProtocolFeeControllerV5 controller)
    {
        GullyCoreGovernance.requireGovernanceSafe(in_.safe, _signerOf(pk), "FEE_OWNER_SAFE");
        require(target.deployer == _signerOf(pk), "the salt target is not this deployer");
        GullyCoreDeploy.preflight(target, LABEL);
        checkInputs(in_);

        console.log("=== DEPLOY GullyCoreProtocolFeeControllerV5 ===");
        console.log("  deployer        ", _signerOf(pk));
        console.log("  owner + treasury", in_.safe);
        console.log("  CL pool manager ", in_.cl);
        console.log("  Bin pool manager", in_.bin);
        console.log("  builder fee (pips per direction)", uint256(in_.builderFee));
        console.log("  launch oracles, in the order they are asked:", in_.kits.length);
        for (uint256 i; i < in_.kits.length; ++i) {
            console.log("    ", i, in_.kits[i]);
        }
        console.log("  zero-fee hooks:", in_.hooks.length);
        for (uint256 i; i < in_.hooks.length; ++i) {
            console.log("    ", i, in_.hooks[i]);
        }
        console.log("  removal notice (s)", uint256(in_.notice));
        console.log("  will deploy to", GullyCoreDeploy.predict(target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(in_);
        _startBroadcastAs(pk);
        controller = GullyCoreProtocolFeeControllerV5(GullyCoreDeploy.deploy(target, code, LABEL));
        vm.stopBroadcast();

        require(address(controller) == GullyCoreDeploy.predict(target), "V5 is not at the predicted address");
        verifyDeployment(controller, in_);
        console.log("");
        console.log("=== DEPLOYED, NOT INSTALLED ===");
        console.log("  V5 ", address(controller));
        console.log("Next, from the Safe: setProtocolFeeController(V5) on both pool-manager owner wrappers.");
    }

    function checkInputs(Inputs memory in_) public view {
        require(in_.safe != address(0) && in_.safe.code.length > 0, "owner must be the Safe contract, not an EOA");
        require(in_.cl.code.length > 0 && in_.bin.code.length > 0, "a pool manager has no code");
        require(in_.cl != in_.bin, "CL_POOL_MANAGER and BIN_POOL_MANAGER are the same address");
        /* Both must be pool managers of the core: they answer the fee surface this controller drives. */
        IProtocolFees(in_.cl).protocolFeeController();
        IProtocolFees(in_.bin).protocolFeeController();
        require(in_.kits.length > 0, "LAUNCH_ORACLES is empty: name every kit whose pools must keep their zero");
        require(in_.kits.length <= MAX_LAUNCH_ORACLES, "LAUNCH_ORACLES names more than 4 kits");
        for (uint256 i; i < in_.kits.length; ++i) {
            address kit = in_.kits[i];
            string memory at = string.concat("LAUNCH_ORACLES[", vm.toString(i), "]");
            require(kit != address(0) && kit.code.length > 0, string.concat(at, " has no code"));
            require(kit != in_.safe && kit != in_.cl && kit != in_.bin, string.concat(at, " is the Safe or a pool manager, not a kit"));
            for (uint256 j; j < i; ++j) {
                require(in_.kits[j] != kit, string.concat(at, " is listed twice"));
            }
            (bool ok, bytes memory ret) = kit.staticcall(abi.encodeCall(ILockedLaunchOracle.isLockedLaunch, (bytes32(0))));
            require(ok && ret.length == 32 && uint256(bytes32(ret)) == 0, string.concat(at, " does not implement isLockedLaunch"));
            /* A kit is Gully Core's own only when the Safe owns it: a tenant's kit must never zero the protocol fee. */
            (ok, ret) = kit.staticcall(abi.encodeWithSignature("owner()"));
            require(ok && ret.length == 32, string.concat(at, " has no owner(): not a Gully Core kit"));
            require(abi.decode(ret, (address)) == in_.safe, string.concat(at, " is not owned by the Safe: not Gully Core's kit"));
        }
        require(in_.notice >= 1 days && in_.notice <= 90 days, "ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS is outside 1..90 days");
        if (GullyCoreGovernance.isProductionChain(block.chainid)) {
            require(in_.notice >= PRODUCTION_MIN_REMOVAL_NOTICE, "the removal notice is under 7 days on a production chain");
        }
        for (uint256 i; i < in_.hooks.length; ++i) {
            address hook = in_.hooks[i];
            string memory at = string.concat("ZERO_FEE_HOOKS[", vm.toString(i), "]");
            require(hook != address(0), string.concat(at, " is the zero address"));
            require(hook != in_.safe && hook != in_.cl && hook != in_.bin, string.concat(at, " is the Safe or a pool manager"));
            for (uint256 j; j < in_.kits.length; ++j) {
                require(hook != in_.kits[j], string.concat(at, " is a launch oracle"));
            }
            for (uint256 j; j < i; ++j) {
                require(in_.hooks[j] != hook, string.concat(at, " is listed twice"));
            }
            if (hook.code.length == 0) {
                /* Only a dynamic-fee hook's mined CREATE3 address may be listed before it exists. */
                require(isMinedDynamicFeeHook(hook), string.concat(at, " has no code and is not a dynamic-fee hook's mined address"));
                continue;
            }
            (bool ok, bytes memory ret) = hook.staticcall(abi.encodeWithSignature("owner()"));
            require(ok && ret.length == 32, string.concat(at, " has no owner(): not a Gully Core hook"));
            require(abi.decode(ret, (address)) == in_.safe, string.concat(at, " is not owned by the Safe"));
        }
    }

    function isMinedDynamicFeeHook(address hook) public view returns (bool) {
        string[2] memory labels = ["GULLYCORE_DYNAMIC_FEE_HOOK", "GULLYCORE_BIN_DYNAMIC_FEE_HOOK"];
        for (uint256 i; i < 2; ++i) {
            bytes32 salt = vm.envOr(string.concat("GULLYCORE_SALT_", labels[i]), bytes32(0));
            address expected = vm.envOr(string.concat("GULLYCORE_ADDRESS_", labels[i]), address(0));
            if (salt == bytes32(0) || expected != hook) continue;
            GullyCoreDeploy.Target memory t = GullyCoreDeploy.fromEnv(labels[i], address(bytes20(salt)));
            if (GullyCoreDeploy.predict(t) == hook) return true;
        }
        return false;
    }

    function verifyDeployment(GullyCoreProtocolFeeControllerV5 c, Inputs memory in_) public view {
        require(address(c).code.length > 0, "no code at V5");
        require(c.owner() == in_.safe, "owner is not the Safe");
        require(c.pendingOwner() == address(0), "unexpected pending owner");
        require(c.treasury() == in_.safe, "treasury is not the Safe");
        require(c.clPoolManager() == in_.cl && c.binPoolManager() == in_.bin, "pool manager immutables mismatch");
        require(c.builderFee() == in_.builderFee, "builder fee mismatch");
        (uint16 pending, uint40 at) = c.pendingBuilderFee();
        require(pending == 0 && at == 0, "a builder fee increase is pending at deployment");
        require(c.FEE_RAISE_NOTICE() == 7 days, "the raise notice is not 7 days");
        require(c.MAX_PROTOCOL_FEE() == 4000, "the cap is not 4000 pips");
        require(c.LAUNCH_ORACLE_GAS() == 50_000 && c.LAUNCH_ORACLE_MIN_GASLEFT() == 55_793, "oracle gas constants changed");
        require(c.launchOracleCount() == in_.kits.length, "launchOracleCount mismatch");
        address[] memory stored = c.launchOracles();
        for (uint256 i; i < in_.kits.length; ++i) {
            require(stored[i] == in_.kits[i], "launchOracles entry or order mismatch");
            require(c.isLaunchOracle(in_.kits[i]), "isLaunchOracle denies a configured kit");
        }
        require(c.ZERO_FEE_HOOK_REMOVAL_NOTICE() == in_.notice, "removal notice immutable mismatch");
        for (uint256 i; i < in_.hooks.length; ++i) {
            (bool listed, uint40 removalAt) = c.zeroFeeHook(in_.hooks[i]);
            require(listed && removalAt == 0 && c.isZeroFeeHook(in_.hooks[i]), "a listed hook does not read as a zero-fee hook");
        }
        require(!c.isZeroFeeHook(address(0)), "the zero address reads as a zero-fee hook");
        /* No `launchOracle()`: a kit must read the set through isLaunchOracle. */
        (bool answered,) = address(c).staticcall(abi.encodeWithSignature("launchOracle()"));
        require(!answered, "V5 answers launchOracle()");
    }
}
