// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {GullyCoreSignerScript} from "gullycore-hooks/script/GullyCoreSigner.sol";
import {GullyCoreDeploy} from "gullycore-hooks/script/GullyCoreCreateX.sol";
import {GullyCoreLaunchRegistry} from "../src/GullyCoreLaunchRegistry.sol";

/**
 * Deploys `GullyCoreLaunchRegistry` — the shared index of tokens launched through any Gully Core-based
 * launchpad — through CreateX at the mined salt.
 *
 * ONE SCRIPT, NOT TWO. `GullyCoreRegistry` needs a testnet variant and a mainnet variant because it
 * takes role holders as constructor arguments, and the sensible testnet default (deployer holds
 * everything) is a bad mainnet one. This contract takes NO role holders: it reads `CURATOR_ROLE`
 * and `GUARDIAN_ROLE` off the Gully Core registry, so whichever registry you point it at, its
 * governance is already whatever that registry's governance is. There is nothing here to get
 * wrong differently per environment.
 *
 * THE ADDRESS. CreateX `deployCreate3` at `GULLYCORE_SALT_GULLYCORE_LAUNCH_REGISTRY`, permissioned to the
 * deployer and chain-id free, so it is the same address on every chain (`ops/deploy/salts/README.md`).
 *
 * THE TWO ADDRESSES, and why both are asserted rather than accepted.
 *
 *   REGISTRY_VAULT -> the GullyCoreProtocol Vault. The trust anchor: a pool manager is believed iff
 *     `vault.isAppRegistered(manager)`, which is onlyOwner on the 48h custody timelock. A wrong
 *     Vault here silently voids every pool proof this registry will ever record, and the field is
 *     immutable, so reading it back afterwards is too late.
 *
 *   GULLYCORE_REGISTRY -> the live `GullyCoreRegistry`. Supplies this contract's curator and guardian
 *     roles and receives the hook attestations it forwards.
 *
 * THE ASSERTION THAT MATTERS: the two must share a Vault. A launch registry anchored to Vault A
 * while its Gully Core registry is anchored to Vault B would look completely healthy — every view
 * answers, every role resolves — while attesting pools from one protocol and taking governance
 * from another. That is not a configuration anybody would notice from a block explorer.
 *
 * Usage:
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   REGISTRY_VAULT=0x...        (the Vault)
 *   GULLYCORE_REGISTRY=0x...        (the live GullyCoreRegistry)
 *   REGISTRY_POOL_MANAGER=0x... (a live pool manager, to prove the Vault is the right one)
 *   forge script script/DeployLaunchRegistry.s.sol --rpc-url <chain> --broadcast --slow
 */
interface IVaultAppCheck {
    function isAppRegistered(address app) external view returns (bool);
}

interface IGullyCoreRegistryCheck {
    function vault() external view returns (address);
    function CURATOR_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function gullycoreCount() external view returns (uint256);
}

contract DeployLaunchRegistryScript is GullyCoreSignerScript {
    /// @dev The env suffix and the line in `ops/deploy/salts/labels.txt`.
    string internal constant LABEL = "GULLYCORE_LAUNCH_REGISTRY";

    struct Wiring {
        uint256 pk;
        address vault;
        address gullycoreRegistry;
        address poolManager;
        GullyCoreDeploy.Target target;
    }

    function run() public returns (GullyCoreLaunchRegistry registry) {
        uint256 pk = _pkFromEnv();
        return runWith(
            Wiring({
                pk: pk,
                vault: vm.envAddress("REGISTRY_VAULT"),
                gullycoreRegistry: vm.envAddress("GULLYCORE_REGISTRY"),
                poolManager: vm.envAddress("REGISTRY_POOL_MANAGER"),
                target: GullyCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    function initCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(type(GullyCoreLaunchRegistry).creationCode, abi.encode(w.vault, w.gullycoreRegistry));
    }

    function runWith(Wiring memory w) public returns (GullyCoreLaunchRegistry registry) {
        preflight(w);

        bytes memory code = initCode(w);
        _startBroadcastAs(w.pk);
        registry = GullyCoreLaunchRegistry(GullyCoreDeploy.deploy(w.target, code, LABEL));
        vm.stopBroadcast();

        postflight(registry, w);
    }

    /// @notice Every check that must pass before anything is broadcast. Public so tests drive it.
    function preflight(Wiring memory w) public view {
        require(w.target.deployer == _signerOf(w.pk), "the salt target is not this deployer");
        GullyCoreDeploy.preflight(w.target, LABEL);

        require(w.vault.code.length > 0, "REGISTRY_VAULT has no code");
        require(w.gullycoreRegistry.code.length > 0, "GULLYCORE_REGISTRY has no code");

        /* Prove the Vault is the real one BEFORE deploying against it. A Vault that does not know
           the live pool manager is either the wrong address or an impostor. */
        require(
            IVaultAppCheck(w.vault).isAppRegistered(w.poolManager),
            "REGISTRY_VAULT does not know REGISTRY_POOL_MANAGER - wrong Vault"
        );

        /* And prove the two registries are anchored to the same protocol. */
        require(IGullyCoreRegistryCheck(w.gullycoreRegistry).vault() == w.vault, "GULLYCORE_REGISTRY is anchored to a different Vault");
    }

    /// @notice Assert the deployed reality, not the intent. Public so tests drive it.
    function postflight(GullyCoreLaunchRegistry registry, Wiring memory w) public view {
        require(address(registry) == GullyCoreDeploy.predict(w.target), "launch registry is not at the predicted address");
        require(address(registry.vault()) == w.vault, "vault not wired");
        require(address(registry.gullycoreRegistry()) == w.gullycoreRegistry, "gully core registry not wired");
        require(
            registry.CURATOR_ROLE() == IGullyCoreRegistryCheck(w.gullycoreRegistry).CURATOR_ROLE(),
            "curator role hash diverged from the Gully Core registry"
        );
        require(
            registry.GUARDIAN_ROLE() == IGullyCoreRegistryCheck(w.gullycoreRegistry).GUARDIAN_ROLE(),
            "guardian role hash diverged from the Gully Core registry"
        );

        console.log("GullyCoreLaunchRegistry ", address(registry), "(CREATE3 via CreateX: same on every chain)");
        console.log("  vault             ", w.vault);
        console.log("  gullycoreRegistry     ", w.gullycoreRegistry);
        console.log("  gullycores listed    ", IGullyCoreRegistryCheck(w.gullycoreRegistry).gullycoreCount());
        console.log("  launches indexed  ", registry.launchCount());
        console.log("  This contract holds no roles of its own; curation is the Gully Core registry's.");
    }
}
