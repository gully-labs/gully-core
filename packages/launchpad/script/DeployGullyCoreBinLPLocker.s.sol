// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {IImmutableState} from "infinity-periphery/src/interfaces/IImmutableState.sol";
import {GullyCoreDeploy} from "gullycore-hooks/script/GullyCoreCreateX.sol";
import {GullyCoreSignerScript} from "gullycore-hooks/script/GullyCoreSigner.sol";

import {GullyCoreBinLPLocker} from "../src/GullyCoreBinLPLocker.sol";
import {GullyCoreLPLocker} from "../src/GullyCoreLPLocker.sol";

/**
 * Deploys `GullyCoreBinLPLocker` against an EXISTING shared core's `BinPositionManager`, through CreateX
 * `deployCreate3` at `GULLYCORE_SALT_GULLYCORE_BIN_LP_LOCKER` - a `0x7878…78` address, the same on every chain
 * (`ops/deploy/salts/README.md`).
 *
 * ############################ WHAT CANNOT BE UNDONE ############################
 *
 * Everything. No owner, no setter, no pause, no upgrade. `protocolRecipient`, the three bps bounds and
 * `maxBinsPerLock` are immutables every future lock is validated against, forever, and every share locked
 * under a wrong value stays locked under it. So every argument is checked before the broadcast and read
 * back after it.
 *
 * THE NUMBERS ARE THE OWNER'S, not this script's. CLAUDE.md "Kit fees: decided by the owner, 2026-09-13":
 * protocol floor 20% of LP fees, protocol cap 50%, integrator cap 20% - the same as `GullyCoreLPLocker`.
 * Duplicated as constants here rather than read from the contract, because an assertion that sources its
 * expectation from the contract under test asserts nothing.
 *
 * MAX_BINS_PER_LOCK = 64 is sized from `test_gas_lockCollectClaim_10_and_64_bins`: a 64-bin lock and a
 * worst-case 64-bin collect (every bin crossed) both fit comfortably in one transaction on an Arbitrum
 * Nitro chain. Kit v2's own `maxBins` must be <= this.
 *
 * If `GULLYCORE_LP_LOCKER` is set, the script also asserts the CL locker on the same chain uses the same
 * protocol recipient and the same bounds, so a Bin leg and a CL leg of one launch cannot silently disagree.
 *
 * OWNERSHIP: nothing to transfer, nothing to accept. `protocolRecipient` must be the governance Safe
 * (CLAUDE.md "The governance Safe"), and the script refuses an EOA.
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   BIN_POSITION_MANAGER=0x... \
 *   LOCKER_PROTOCOL_RECIPIENT=<governance Safe> \
 *   GULLYCORE_LP_LOCKER=0x... \
 *   forge script script/DeployGullyCoreBinLPLocker.s.sol --rpc-url $RPC
 */
contract DeployGullyCoreBinLPLockerScript is GullyCoreSignerScript {
    // Release 3 (owner decision 2026-11-05): no protocol floor and no integrator cap below the whole, so a
    // lock on outside terms can carry a zero protocol share. Gully terms keep 50% / at most 20% through the kit.
    // Releases 1 and 2 deployed 2_000 / 5_000 / 2_000.
    uint16 internal constant MIN_PROTOCOL_BPS = 0;
    uint16 internal constant MAX_PROTOCOL_BPS = 5_000;
    uint16 internal constant MAX_INTEGRATOR_BPS = 10_000;
    uint16 internal constant MAX_BINS_PER_LOCK = 64;

    string internal constant LABEL = "GULLYCORE_BIN_LP_LOCKER";

    struct Wiring {
        /// @dev Deployer key. Never a literal - `run` takes it from `PRIVATE_KEY`, or it is 0 and the signer is
        /// `DEPLOYER` with --account / --ledger / --unlocked (a keyless rehearsal on a fork).
        uint256 pk;
        address positionManager;
        address protocolRecipient;
        /// @dev Optional. `address(0)` skips the cross-check.
        address clLocker;
        GullyCoreDeploy.Target target;
    }

    function run() public returns (GullyCoreBinLPLocker locker) {
        uint256 pk = _pkFromEnv();
        return runWith(
            Wiring({
                pk: pk,
                positionManager: vm.envAddress("BIN_POSITION_MANAGER"),
                protocolRecipient: vm.envAddress("LOCKER_PROTOCOL_RECIPIENT"),
                clLocker: vm.envOr("GULLYCORE_LP_LOCKER", address(0)),
                target: GullyCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    function initCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(GullyCoreBinLPLocker).creationCode,
            abi.encode(
                IBinPositionManager(w.positionManager),
                w.protocolRecipient,
                MIN_PROTOCOL_BPS,
                MAX_PROTOCOL_BPS,
                MAX_INTEGRATOR_BPS,
                MAX_BINS_PER_LOCK
            )
        );
    }

    function runWith(Wiring memory w) public returns (GullyCoreBinLPLocker locker) {
        _preflight(w);

        bytes memory code = initCode(w);
        _startBroadcastAs(w.pk);
        locker = GullyCoreBinLPLocker(payable(GullyCoreDeploy.deploy(w.target, code, LABEL)));
        vm.stopBroadcast();

        _postflight(locker, w);
    }

    function _preflight(Wiring memory w) internal view {
        require(w.target.deployer == _signerOf(w.pk), "the salt target is not this deployer");
        GullyCoreDeploy.preflight(w.target, LABEL);

        require(w.positionManager.code.length > 0, "BIN_POSITION_MANAGER has no code");
        address vault = address(IImmutableState(w.positionManager).vault());
        require(vault != address(0), "BIN_POSITION_MANAGER reports no vault");
        address bpm = address(IBinPositionManager(w.positionManager).binPoolManager());
        require(bpm.code.length > 0, "BIN_POSITION_MANAGER reports no bin pool manager");
        require(address(IBinPoolManager(bpm).vault()) == vault, "bin pool manager and position manager disagree on vault");

        require(w.protocolRecipient != address(0), "LOCKER_PROTOCOL_RECIPIENT is zero");
        // A Safe, not an EOA: the recipient is immutable, and a Safe's signers rotate without its address changing.
        require(w.protocolRecipient.code.length > 0, "LOCKER_PROTOCOL_RECIPIENT has no code - must be the Safe");
        require(w.protocolRecipient != _signerOf(w.pk), "LOCKER_PROTOCOL_RECIPIENT is the deployer");

        if (w.clLocker != address(0)) {
            GullyCoreLPLocker cl = GullyCoreLPLocker(payable(w.clLocker));
            require(cl.protocolRecipient() == w.protocolRecipient, "CL locker pays a different protocol recipient");
            require(cl.minProtocolBps() == MIN_PROTOCOL_BPS, "CL locker floor differs");
            require(cl.maxProtocolBps() == MAX_PROTOCOL_BPS, "CL locker cap differs");
            require(cl.maxIntegratorBps() == MAX_INTEGRATOR_BPS, "CL locker integrator cap differs");
            require(cl.vault() == vault, "CL locker is on a different vault");
        }
    }

    function _postflight(GullyCoreBinLPLocker locker, Wiring memory w) internal view {
        require(address(locker) == GullyCoreDeploy.predict(w.target), "locker is not at the predicted address");
        require(address(locker.positionManager()) == w.positionManager, "locker: positionManager");
        require(
            address(locker.binPoolManager()) == address(IBinPositionManager(w.positionManager).binPoolManager()),
            "locker: binPoolManager"
        );
        require(locker.vault() == address(IImmutableState(w.positionManager).vault()), "locker: vault");
        require(locker.protocolRecipient() == w.protocolRecipient, "locker: protocolRecipient");
        require(locker.minProtocolBps() == MIN_PROTOCOL_BPS, "locker: minProtocolBps");
        require(locker.maxProtocolBps() == MAX_PROTOCOL_BPS, "locker: maxProtocolBps");
        require(locker.maxIntegratorBps() == MAX_INTEGRATOR_BPS, "locker: maxIntegratorBps");
        require(locker.maxBinsPerLock() == MAX_BINS_PER_LOCK, "locker: maxBinsPerLock");
        require(locker.BPS_DENOMINATOR() == 10_000, "locker: denominator");
        require(locker.MAX_BINS_HARD_CAP() == 256, "locker: hard cap");
        require(locker.lockCount() == 0, "locker: not fresh");

        console.log("GullyCoreBinLPLocker   ", address(locker), "(CREATE3 via CreateX: same on every chain)");
        console.log("positionManager    ", w.positionManager);
        console.log("protocolRecipient  ", w.protocolRecipient);
    }
}
