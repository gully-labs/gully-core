// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {GullyCoreSignerScript} from "gullycore-hooks/script/GullyCoreSigner.sol";

import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {ILaunchTokenOrigin} from "gullycore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "gullycore-hooks/src/launch/BinLaunchGuardHook.sol";
import {ContractClockProbe} from "gullycore-hooks/script/ContractClock.sol";
import {GullyCoreGovernance} from "gullycore-hooks/script/GullyCoreGovernance.sol";
import {GullyCoreDeploy} from "gullycore-hooks/script/GullyCoreCreateX.sol";
import {GullyCoreRegistry} from "gullycore-registry/src/GullyCoreRegistry.sol";
import {GullyCoreMetadata} from "gullycore-registry/src/IGullyCoreRegistry.sol";

/**
 * Deploys `BinLaunchGuardHook` WITH the pool-id reservation (ported 2026-09-14) and lists it in the
 * registry in the same session. Kit v2 needs it: `LaunchpadKitV2`'s constructor refuses a Bin guard whose
 * `LAUNCH_TOKEN_FACTORY` is not the kit's factory.
 *
 * No Bin guard is deployed on any chain today, so nothing migrates. The factory is IMMUTABLE on the hook and
 * REQUIRED here (`vm.envAddress` fails loudly when unset): a Bin guard without it would let anybody squat a
 * kit's Bin launch pools, which is the open LOW this deployment closes.
 *
 * No owner, no guardian, no admin (CLAUDE.md Ownership table, "Contracts with no privileged role"). The
 * listing steward is the Ops key, as for `LaunchGuardHook`.
 *
 * THE ADDRESS. CreateX `deployCreate3` at `GULLYCORE_SALT_BIN_LAUNCH_GUARD_HOOK_QF` (owner decisions
 * 2026-09-19/20: `0x7878…78`, the same address on every chain). A Bin hook's permissions come from
 * `getHooksRegistrationBitmap()`, a function, so a mined address is safe; the bitmap is asserted anyway.
 * The broadcast artifact records a CALL to CreateX, so read the hook's address from this log.
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   BIN_POOL_MANAGER=0x... LAUNCH_TOKEN_FACTORY=0x... LAUNCH_GUARD_REGISTRY=0x... LAUNCH_GUARD_STEWARD=<ops> \
 *   TAX_PROTOCOL_RECIPIENT=<the Safe> LAUNCH_LP_SHARE_BPS=<0..5000, the CL guard's value> \
 *   forge script script/DeployBinLaunchGuardHook.s.sol --rpc-url $RPC
 */
contract DeployBinLaunchGuardHookScript is GullyCoreSignerScript {
    /// @dev bit 0 beforeInitialize | bit 2 beforeMint | bit 6 beforeSwap | bit 7 afterSwap | bit 10
    /// beforeSwapReturnsDelta | bit 11 afterSwapReturnsDelta (the two hook deltas the guard takes its
    /// fee and the creator tax through, in the quote currency). Duplicated from the kit on purpose.
    uint16 internal constant EXPECTED_BITMAP = 0x0CC5;

    string internal constant LABEL = "BIN_LAUNCH_GUARD_HOOK_QF";

    string internal constant SOURCE_URI =
        "https://docs.gullychain.xyz/core#contracts";

    function run() public returns (BinLaunchGuardHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        uint256 pk = _pkFromEnv();
        return runWith(
            pk,
            vm.envAddress("BIN_POOL_MANAGER"),
            vm.envAddress("LAUNCH_TOKEN_FACTORY"),
            vm.envAddress("LAUNCH_GUARD_REGISTRY"),
            vm.envAddress("LAUNCH_GUARD_STEWARD"),
            vm.envAddress("TAX_PROTOCOL_RECIPIENT"),
            _lpShareFromEnv(),
            GullyCoreDeploy.fromEnv(LABEL, _signerOf(pk))
        );
    }

    /// @dev `LAUNCH_LP_SHARE_BPS` has NO default: the share is immutable and the same for every pool
    /// this guard will ever run, so it is stated for every deployment, zero included.
    function _lpShareFromEnv() internal view returns (uint16) {
        uint256 v = vm.envUint("LAUNCH_LP_SHARE_BPS");
        require(v <= 5_000, "LAUNCH_LP_SHARE_BPS is above the guard's cap (5000)");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(v);
    }

    /// @param taxRecipient Where the protocol bucket of the fee and of the creator tax is credited, forever:
    /// the governance Safe.
    /// @param lpShareBps The share of the trade fee left to the pool as its LP fee, on buys, forever.
    /// @param target The mined CreateX salt this hook's address comes from.
    function runWith(
        uint256 pk,
        address binPoolManager,
        address factory,
        address registry,
        address steward,
        address taxRecipient,
        uint16 lpShareBps,
        GullyCoreDeploy.Target memory target
    ) public returns (BinLaunchGuardHook hook) {
        address deployer = _signerOf(pk);
        require(target.deployer == deployer, "the salt target is not this deployer");
        GullyCoreDeploy.preflight(target, LABEL);

        require(binPoolManager.code.length > 0, "BIN_POOL_MANAGER has no code");
        require(taxRecipient.code.length > 0, "TAX_PROTOCOL_RECIPIENT has no code - a Safe, not an EOA");
        require(taxRecipient != deployer, "TAX_PROTOCOL_RECIPIENT is the deployer");
        GullyCoreGovernance.requireGovernanceSafe(taxRecipient, deployer, "TAX_PROTOCOL_RECIPIENT");
        require(factory != address(0) && factory.code.length > 0, "LAUNCH_TOKEN_FACTORY has no code");
        // Probed with the deployer EOA, which can never be a factory token. NOT `address(this)`: forge
        // refuses `address(this)` inside a script contract (`forge script` 1.8.1), and the test suite,
        // which drives `runWith` from a test contract, never sees that refusal.
        require(ILaunchTokenOrigin(factory).deployerOf(deployer) == address(0), "LAUNCH_TOKEN_FACTORY is not a factory");
        (bool ok, bytes memory ret) = factory.staticcall(abi.encodeWithSignature("launchTokenInitCodeHash()"));
        require(ok && ret.length == 32 && bytes32(ret) != bytes32(0), "LAUNCH_TOKEN_FACTORY has no init code hash");
        require(registry.code.length > 0, "LAUNCH_GUARD_REGISTRY has no code");
        require(steward != address(0), "LAUNCH_GUARD_STEWARD unset - Ops");
        GullyCoreRegistry(registry).gullycoreCount();

        uint256[] memory chains = new uint256[](1);
        chains[0] = block.chainid;

        bytes memory code = abi.encodePacked(
            type(BinLaunchGuardHook).creationCode,
            abi.encode(IBinPoolManager(binPoolManager), ILaunchTokenOrigin(factory), taxRecipient, lpShareBps)
        );

        _startBroadcastAs(pk);
        hook = BinLaunchGuardHook(payable(GullyCoreDeploy.deploy(target, code, LABEL)));
        GullyCoreRegistry(registry).register(
            address(hook),
            GullyCoreMetadata({
                name: "BinLaunchGuard",
                description: "Decaying sniper tax and a frozen, expiring creator tax for Bin pools, on block.timestamp; launch pools reserved for the token's creator.",
                sourceURI: SOURCE_URI,
                auditURI: "",
                chainIds: chains
            })
        );
        if (steward != deployer) GullyCoreRegistry(registry).transferSteward(address(hook), steward);
        vm.stopBroadcast();

        require(address(hook) == GullyCoreDeploy.predict(target), "hook is not at the predicted address");
        require(address(hook.poolManager()) == binPoolManager, "hook: poolManager");
        require(address(hook.LAUNCH_TOKEN_FACTORY()) == factory, "hook: LAUNCH_TOKEN_FACTORY");
        require(hook.getHooksRegistrationBitmap() == EXPECTED_BITMAP, "hook: bitmap");
        require(keccak256(bytes(hook.CLOCK_MODE())) == keccak256("mode=timestamp"), "hook: clock");
        require(hook.MAX_INITIAL_FEE() == 100_000 && hook.MAX_FINAL_FEE() == 20_000, "hook: fee caps moved");
        require(hook.MIN_DECAY_SECONDS() == 60 && hook.MAX_DECAY_SECONDS() == 30 days, "hook: decay bounds moved");
        require(hook.MAX_START_DELAY_SECONDS() == 30 days, "hook: start delay moved");
        require(hook.protocolRecipient() == taxRecipient, "hook: tax recipient");
        require(hook.LP_SHARE_BPS() == lpShareBps, "hook: LP_SHARE_BPS");
        // Release 3: no protocol floor on the fee or the tax, no integrator cap below the whole; the 50% protocol
        // ceiling and the 10% tax-rate cap stay.
        require(hook.MAX_LP_SHARE_BPS() == 5_000 && hook.MIN_FEE_PROTOCOL_BPS() == 0, "hook: fee bounds moved");
        require(address(hook.vault()) == address(IBinPoolManager(binPoolManager).vault()), "hook: vault");
        require(hook.MAX_TAX_BPS() == 1_000 && hook.MIN_PROTOCOL_BPS() == 0, "hook: tax bounds moved");
        require(hook.MAX_PROTOCOL_BPS() == 5_000 && hook.MAX_INTEGRATOR_BPS() == 10_000, "hook: tax caps moved");
        require(hook.TAX_FOREVER() == type(uint40).max, "hook: not the forever-tax guard (2026-11-02)");
        GullyCoreRegistry reg = GullyCoreRegistry(registry);
        require(reg.isRegistered(address(hook)), "hook was not listed");
        require(reg.getGullyCore(address(hook)).submitter == deployer, "someone else listed this hook first");
        require(reg.getGullyCore(address(hook)).steward == steward, "listing steward is not the Ops steward");

        console.log("BinLaunchGuardHook      ", address(hook), "(CREATE3 via CreateX: same on every chain)");
        console.log("  LAUNCH_TOKEN_FACTORY  ", factory);
        console.log("  tax protocolRecipient ", taxRecipient);
        console.log("No owner, no guardian, no admin. NEXT: export BIN_LAUNCH_GUARD_HOOK=<address above>");
    }
}
