// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IImmutableState} from "infinity-periphery/src/interfaces/IImmutableState.sol";
import {GullyCoreDeploy} from "gullycore-hooks/script/GullyCoreCreateX.sol";
import {GullyCoreSignerScript} from "gullycore-hooks/script/GullyCoreSigner.sol";

import {GullyCoreLPLocker} from "../src/GullyCoreLPLocker.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LaunchTokenFactory} from "../src/LaunchTokenFactory.sol";

/**
 * Deploys `GullyCoreLPLocker` and `LaunchTokenFactory` against an EXISTING shared core, each through
 * CreateX `deployCreate3` at its own mined salt.
 *
 * ############################ WHAT CANNOT BE UNDONE ############################
 *
 * Everything. Neither contract has an owner, a setter, a pause or an upgrade path. The locker's
 * `protocolRecipient` and its three bps bounds are immutables that every future lock is validated
 * against, forever. A wrong value here is a contract to abandon, not a setting to fix - and every
 * position already locked in it stays locked under the wrong value. So every argument is checked
 * before the broadcast and read back after it.
 *
 * THE ADDRESSES (owner decisions 2026-09-19/20). Both are `0x7878…78` addresses mined for the
 * deployer and identical on every chain: `GULLYCORE_SALT_GULLYCORE_LP_LOCKER` and
 * `GULLYCORE_SALT_LAUNCH_TOKEN_FACTORY`. Two contracts, two salts - one salt can only ever hold one
 * contract. `ops/deploy/salts/README.md` has the mechanism; the factory's address matters twice over,
 * because both launch guards bind it as an immutable and `LaunchToken` addresses are CREATE2'd from it.
 *
 * THE NUMBERS ARE THE OWNER'S, not this script's. CLAUDE.md "Kit fees: decided by the owner,
 * 2026-09-13": protocol floor 20% of LP fees, protocol cap 50%, integrator cap 20%. They are
 * constants HERE (duplicated rather than read from the contract, because an assertion that sources
 * its expectation from the contract under test asserts nothing) and constructor arguments THERE.
 *
 * OWNERSHIP: nothing to transfer, nothing to accept. The deployer holds no authority over either
 * contract the moment this script returns. `protocolRecipient` must be the governance Safe
 * (CLAUDE.md "The governance Safe": "Protocol fees go here"), and the script refuses an EOA.
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   CL_POSITION_MANAGER=<this chain's CLPositionManager> \
 *   LOCKER_PROTOCOL_RECIPIENT=<governance Safe> \
 *   forge script script/DeployGullyCoreLPLocker.s.sol --rpc-url $RPC
 */
contract DeployGullyCoreLPLockerScript is GullyCoreSignerScript {
    // Release 3 (owner decision 2026-11-05): no protocol floor and no integrator cap below the whole, so a
    // lock on outside terms can carry a zero protocol share. Gully terms keep 50% / at most 20% through the kit.
    // Releases 1 and 2 deployed 2_000 / 5_000 / 2_000.
    uint16 internal constant MIN_PROTOCOL_BPS = 0;
    uint16 internal constant MAX_PROTOCOL_BPS = 5_000;
    uint16 internal constant MAX_INTEGRATOR_BPS = 10_000;

    string internal constant LOCKER_LABEL = "GULLYCORE_LP_LOCKER";
    string internal constant FACTORY_LABEL = "LAUNCH_TOKEN_FACTORY";

    struct Wiring {
        /// @dev Deployer key. Never a literal - `run` takes it from `PRIVATE_KEY`, or it is 0 and the signer is
        /// `DEPLOYER` with --account / --ledger / --unlocked (a keyless rehearsal on a fork).
        uint256 pk;
        address positionManager;
        address protocolRecipient;
        GullyCoreDeploy.Target lockerTarget;
        GullyCoreDeploy.Target factoryTarget;
    }

    function run() public returns (GullyCoreLPLocker locker, LaunchTokenFactory factory) {
        uint256 pk = _pkFromEnv();
        return runWith(
            Wiring({
                pk: pk,
                positionManager: vm.envAddress("CL_POSITION_MANAGER"),
                protocolRecipient: vm.envAddress("LOCKER_PROTOCOL_RECIPIENT"),
                lockerTarget: GullyCoreDeploy.fromEnv(LOCKER_LABEL, _signerOf(pk)),
                factoryTarget: GullyCoreDeploy.fromEnv(FACTORY_LABEL, _signerOf(pk))
            })
        );
    }

    function lockerInitCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(GullyCoreLPLocker).creationCode,
            abi.encode(
                ICLPositionManager(w.positionManager),
                w.protocolRecipient,
                MIN_PROTOCOL_BPS,
                MAX_PROTOCOL_BPS,
                MAX_INTEGRATOR_BPS
            )
        );
    }

    function runWith(Wiring memory w) public returns (GullyCoreLPLocker locker, LaunchTokenFactory factory) {
        _preflight(w);

        bytes memory lockerCode = lockerInitCode(w);
        bytes memory factoryCode = type(LaunchTokenFactory).creationCode; // no constructor arguments
        _startBroadcastAs(w.pk);
        locker = GullyCoreLPLocker(payable(GullyCoreDeploy.deploy(w.lockerTarget, lockerCode, LOCKER_LABEL)));
        factory = LaunchTokenFactory(GullyCoreDeploy.deploy(w.factoryTarget, factoryCode, FACTORY_LABEL));
        vm.stopBroadcast();

        _postflight(locker, factory, w);
    }

    function _preflight(Wiring memory w) internal view {
        require(w.lockerTarget.deployer == _signerOf(w.pk), "the locker salt target is not this deployer");
        require(w.factoryTarget.deployer == _signerOf(w.pk), "the factory salt target is not this deployer");
        require(w.lockerTarget.salt != w.factoryTarget.salt, "one salt cannot deploy two contracts");
        GullyCoreDeploy.preflight(w.lockerTarget, LOCKER_LABEL);
        GullyCoreDeploy.preflight(w.factoryTarget, FACTORY_LABEL);

        require(w.positionManager.code.length > 0, "CL_POSITION_MANAGER has no code");
        require(
            address(IImmutableState(w.positionManager).vault()) != address(0), "CL_POSITION_MANAGER reports no vault"
        );
        require(w.protocolRecipient != address(0), "LOCKER_PROTOCOL_RECIPIENT is zero");
        // A Safe, not an EOA: the recipient is immutable, and a Safe's signers rotate without its address
        // changing. An EOA here is an unrotatable revenue key for the life of the locker.
        require(w.protocolRecipient.code.length > 0, "LOCKER_PROTOCOL_RECIPIENT has no code - must be the Safe");
        require(w.protocolRecipient != _signerOf(w.pk), "LOCKER_PROTOCOL_RECIPIENT is the deployer");
    }

    function _postflight(GullyCoreLPLocker locker, LaunchTokenFactory factory, Wiring memory w) internal view {
        require(address(locker) == GullyCoreDeploy.predict(w.lockerTarget), "locker is not at the predicted address");
        require(address(factory) == GullyCoreDeploy.predict(w.factoryTarget), "factory is not at the predicted address");
        require(address(locker.positionManager()) == w.positionManager, "locker: positionManager");
        require(locker.vault() == address(IImmutableState(w.positionManager).vault()), "locker: vault");
        require(locker.protocolRecipient() == w.protocolRecipient, "locker: protocolRecipient");
        require(locker.minProtocolBps() == MIN_PROTOCOL_BPS, "locker: minProtocolBps");
        require(locker.maxProtocolBps() == MAX_PROTOCOL_BPS, "locker: maxProtocolBps");
        require(locker.maxIntegratorBps() == MAX_INTEGRATOR_BPS, "locker: maxIntegratorBps");
        require(locker.BPS_DENOMINATOR() == 10_000, "locker: denominator");
        require(locker.lockCount() == 0, "locker: not fresh");

        require(
            factory.launchTokenInitCodeHash() == keccak256(type(LaunchToken).creationCode), "factory: init code hash"
        );
        require(factory.MAX_NAME_BYTES() == 64, "factory: name bound");
        require(factory.MAX_SYMBOL_BYTES() == 32, "factory: symbol bound");
        require(factory.MAX_METADATA_URI_BYTES() == 512, "factory: uri bound");

        console.log("GullyCoreLPLocker      ", address(locker), "(CREATE3 via CreateX: same on every chain)");
        console.log("LaunchTokenFactory ", address(factory), "(CREATE3 via CreateX: same on every chain)");
        console.log("protocolRecipient  ", w.protocolRecipient);
        console.logBytes32(factory.launchTokenInitCodeHash());
    }
}
