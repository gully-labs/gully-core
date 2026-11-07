// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ContractClockProbe} from "./ContractClock.sol";
import {GullyCoreDeploy} from "./GullyCoreCreateX.sol";
import {GullyCoreGovernance} from "./GullyCoreGovernance.sol";
import {GullyCoreSignerScript} from "./GullyCoreSigner.sol";
import {GullyCoreOracleHook} from "../src/oracle/GullyCoreOracleHook.sol";

/// @notice `GullyCoreRegistry`'s `GullyCoreMetadata`, field for field (declared here so this package needs no
/// registry remapping; the post-flight reads the listing back).
struct OracleGullyCoreMetadata {
    string name;
    string description;
    string sourceURI;
    string auditURI;
    uint256[] chainIds;
}

interface IOracleRegistry {
    function register(address hook, OracleGullyCoreMetadata calldata metadata) external;
    function transferSteward(address hook, address newSteward) external;
    function isRegistered(address hook) external view returns (bool);
}

/**
 * Deploys `GullyCoreOracleHook` (CreateX label `GULLYCORE_ORACLE_HOOK`) against Gully Core core and lists it in
 * `GullyCoreRegistry` in the same session, handing the listing's steward to Ops.
 *
 * The hook has NO owner and no setter: every value below is immutable, and a wrong one is a redeploy
 * and a new salt. No defaults:
 *   ORACLE_MAX_TICK_DELTA        1 .. 1,000 (design: 100)
 *   ORACLE_MIN_WINDOW_SECONDS    60 .. 86,400 (design: 600; 1,800 advised for anything holding value)
 *   ORACLE_INITIAL_CARDINALITY   1 .. 1,024 (design: 16). Paid at EVERY pool's initialize, about 22k gas
 *                                a slot: on HyperEVM's 3M small blocks keep it at or under ~64.
 * Also: PRIVATE_KEY | DEPLOYER, the GULLYCORE_ORACLE_HOOK salt pair, ORACLE_POOL_MANAGER, ORACLE_RECIPIENT
 * (the Safe; where misdirected value is swept), ORACLE_REGISTRY, ORACLE_STEWARD (Ops).
 */
contract DeployGullyCoreOracleHookScript is GullyCoreSignerScript {
    string internal constant LABEL = "GULLYCORE_ORACLE_HOOK";
    uint16 internal constant BITMAP = 0x0042;
    string internal constant SOURCE_URI = "https://docs.gullychain.xyz/core#contracts";

    struct Params {
        uint256 pk;
        ICLPoolManager poolManager;
        address recipient;
        address registry;
        address steward;
        uint24 maxTickDelta;
        uint32 minWindow;
        uint16 initialCardinality;
        GullyCoreDeploy.Target target;
    }

    function run() public returns (GullyCoreOracleHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        uint256 pk = _pkFromEnv();
        return runWith(
            Params({
                pk: pk,
                poolManager: ICLPoolManager(vm.envAddress("ORACLE_POOL_MANAGER")),
                recipient: vm.envAddress("ORACLE_RECIPIENT"),
                registry: vm.envAddress("ORACLE_REGISTRY"),
                steward: vm.envAddress("ORACLE_STEWARD"),
                maxTickDelta: uint24(_bounded("ORACLE_MAX_TICK_DELTA", type(uint24).max)),
                minWindow: uint32(_bounded("ORACLE_MIN_WINDOW_SECONDS", type(uint32).max)),
                initialCardinality: uint16(_bounded("ORACLE_INITIAL_CARDINALITY", type(uint16).max)),
                target: GullyCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    function _bounded(string memory name, uint256 max) internal view returns (uint256 v) {
        v = vm.envUint(name);
        require(v <= max, string.concat(name, " overflows its type"));
    }

    function checkInputs(Params memory p, address deployer) public view {
        require(address(p.poolManager).code.length > 0, "ORACLE_POOL_MANAGER has no code");
        require(address(p.poolManager.vault()).code.length > 0, "the pool manager's vault has no code");
        GullyCoreGovernance.requireGovernanceSafe(p.recipient, deployer, "ORACLE_RECIPIENT");
        require(p.registry.code.length > 0, "ORACLE_REGISTRY has no code");
        require(p.steward != address(0), "ORACLE_STEWARD is unset");
        if (GullyCoreGovernance.isProductionChain(block.chainid)) {
            // The design's floor for anything holding value is 1,800; the contract's own floor is 60.
            require(p.minWindow >= 600, "ORACLE_MIN_WINDOW_SECONDS is under 600 on a production chain");
        }
    }

    function initCode(Params memory p) public view returns (bytes memory) {
        return abi.encodePacked(
            type(GullyCoreOracleHook).creationCode,
            abi.encode(p.poolManager, p.poolManager.vault(), p.recipient, p.maxTickDelta, p.minWindow, p.initialCardinality)
        );
    }

    function runWith(Params memory p) public returns (GullyCoreOracleHook hook) {
        address deployer = _signerOf(p.pk);
        require(p.target.deployer == deployer, "the salt target is not this deployer");
        GullyCoreDeploy.preflight(p.target, LABEL);
        checkInputs(p, deployer);

        console.log("=== GullyCoreOracleHook ===");
        console.log("  chain id          ", block.chainid);
        console.log("  pool manager      ", address(p.poolManager));
        console.log("  recipient (Safe)  ", p.recipient);
        console.log("  max tick delta    ", p.maxTickDelta);
        console.log("  min window, s     ", p.minWindow);
        console.log("  initial slots     ", p.initialCardinality);
        console.log("  will deploy to    ", GullyCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        uint256[] memory chains = new uint256[](1);
        chains[0] = block.chainid;
        _startBroadcastAs(p.pk);
        hook = GullyCoreOracleHook(payable(GullyCoreDeploy.deploy(p.target, code, LABEL)));
        IOracleRegistry(p.registry).register(
            address(hook),
            OracleGullyCoreMetadata({
                name: "Gully Core Price Oracle",
                description: "A truncated time-weighted average tick other contracts read: one observation per second at most, clamped per observation, minimum window enforced. Lags by design; not a spot price.",
                sourceURI: SOURCE_URI,
                auditURI: "",
                chainIds: chains
            })
        );
        if (p.steward != deployer) IOracleRegistry(p.registry).transferSteward(address(hook), p.steward);
        vm.stopBroadcast();

        require(address(hook) == GullyCoreDeploy.predict(p.target), "hook is not at the predicted address");
        require(hook.getHooksRegistrationBitmap() == BITMAP, "bitmap is not 0x0042");
        require(address(hook.poolManager()) == address(p.poolManager), "poolManager mismatch");
        require(address(hook.vault()) == address(p.poolManager.vault()), "vault mismatch");
        require(hook.protocolRecipient() == p.recipient, "recipient mismatch");
        require(hook.ORACLE_MAX_TICK_DELTA() == p.maxTickDelta, "max tick delta mismatch");
        require(hook.ORACLE_MIN_WINDOW_SECONDS() == p.minWindow, "min window mismatch");
        require(hook.ORACLE_INITIAL_CARDINALITY() == p.initialCardinality, "initial cardinality mismatch");
        require(hook.kind() == keccak256("gullycore.oracle.truncated-twap.v1"), "kind mismatch");
        (bool hasOwner,) = address(hook).staticcall(abi.encodeWithSignature("owner()"));
        require(!hasOwner, "the oracle hook must have no owner");
        require(IOracleRegistry(p.registry).isRegistered(address(hook)), "the hook is not listed");
        console.log("GullyCoreOracleHook", address(hook));
        console.log("  runtime bytes     ", address(hook).code.length);
    }
}
