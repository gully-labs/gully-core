// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/**
 * The governance Safe of record, in ONE place, asserted on EVERY production chain.
 *
 * ######################### WHY THIS FILE EXISTS #########################
 *
 * Eleven deploy scripts each carried their own copy of the Safe address under the name
 * `ROBINHOOD_SAFE`, and each asserted it like this:
 *
 *     if (block.chainid == ROBINHOOD_CHAIN_ID) require(w.safe == ROBINHOOD_SAFE, "...");
 *
 * The name was the bug in miniature. Gully Core's ownership decision is that the SAME Safe address is
 * used on every chain (CLAUDE.md, "The governance Safe"), but calling the constant
 * `ROBINHOOD_SAFE` made it look chain-specific, and so the check was gated on that one chain. The
 * consequence was harmless while one chain was the only target and stopped being harmless the moment
 * a second production chain arrived: there the Safe-of-record comparison simply DID NOT RUN.
 * The scripts checked only that the owner had code and was not the deployer — which a wrong Safe,
 * a stale Safe, or an attacker's Safe all satisfy.
 *
 * ######################### IT FAILS CLOSED #########################
 *
 * The gate is inverted from how it was. It does NOT enumerate the chains to check; it enumerates
 * the chains to SKIP, and checks everything else. So a chain nobody has thought about yet — the
 * next Base, the next Anubis — is asserted BY DEFAULT rather than silently exempt. That inversion
 * is the whole point: the previous shape needed someone to remember to add a chain id, and the
 * failure of remembering was invisible.
 *
 * The skipped set is only local development and public testnets, where no Safe of record exists.
 * A testnet deployment therefore still gets the `code.length` and `!= deployer` checks, just not
 * the identity one.
 */
library GullyCoreGovernance {
    /// @notice Gully Chain testnet (Orbit L3, chain id 485590).
    uint256 internal constant GULLY_TESTNET_CHAIN_ID = 485590;

    /**
     * The Gully Core governance Safe of record on Gully Chain TESTNET 485590 (owner decision 2026-10-28).
     *
     * Safe L2 v1.4.1 (Gully's own deployment, generated/safe.json: singleton
     * 0x76667330c237Fb40f28d74563cdAAae4b06C23Ec, proxy factory 0xd9d2Ba03a7754250FDD71333F444636471CACBC4,
     * fallback handler 0xcB4a8d3609A7CCa2D9c063a742f75c899BF2f7b5). Created by
     * `createProxyWithNonce(singleton, setup([0x92cFC047652d6aEf7eb0fa2744B912d9f627fA41], 1, 0, 0x,
     * fallbackHandler, 0, 0, 0), uint256(keccak256("gully-core.governance.testnet.v1")))`. That makes it a
     * **1-of-1 testnet Safe** owned by the testnet deployer. It is TESTNET ONLY. Mainnet must be a separate
     * 3-of-5 Safe recorded in `MAINNET_SAFE`.
     *
     * The address is predicted, and `eth_call` of that exact call returns it. `requireGovernanceSafe`
     * still requires CODE at it, so every production deploy refuses until the Safe has really been
     * created on chain (the first step of the owner's release command).
     */
    address internal constant SAFE = 0xC5526E28B5cDe3C5962A224896804a499d5bb240;

    /// @notice The mainnet governance Safe of record (3-of-5). UNSET: every mainnet deploy refuses until the
    /// owner supplies it.
    address internal constant MAINNET_SAFE = address(0);

    /// @notice The weakest governance Safe a production chain accepts: a threshold of 2, and 3 owners.
    uint256 internal constant MIN_SAFE_THRESHOLD = 2;
    uint256 internal constant MIN_SAFE_OWNERS = 3;

    /// @notice Env flag that lets a weaker Safe (the 1-of-1 testnet Safe) through. Honoured ONLY on Gully Chain
    /// testnet 485590; on any other production chain it is ignored and the quorum check still refuses.
    string internal constant TESTNET_WEAK_SAFE_ENV = "GULLYCORE_ALLOW_TESTNET_WEAK_SAFE";

    /*//////////////////////////////////////////////////////////////
          OPTION 2: THE HAND-OVER RUN (owner decision 2026-11-05)
    //////////////////////////////////////////////////////////////*/

    // On each new chain the deploy is run by a TEMPORARY 1-of-1 Safe owned by the deployer; the last step of
    // the run converts it to 2-of-3 with the Treasury owners and removes the deployer. That Safe is created
    // through the canonical Safe 1.4.1 proxy factory with a fixed initializer and salt nonce, so its address
    // is the same on every chain that has canonical Safe 1.4.1, and it IS the governance Safe of record there.
    //
    // THE RELAXATION IS NARROW. A Safe under 2-of-3 is accepted only when ALL of these hold:
    //   * the environment says a hand-over run is in progress (`GULLYCORE_HANDOVER_RUN=true`, set by the
    //     release script for the length of the run and by nothing else);
    //   * the chain is one of the hand-over chains;
    //   * the Safe is exactly `HANDOVER_SAFE`;
    //   * it is 1-of-1 and its single owner is the signer of this script, who is `HANDOVER_DEPLOYER`.
    // Every other Safe, chain, shape or signer keeps the refusal. After the conversion the same address is
    // 2-of-3 and passes the ordinary rule with the flag unset.

    /// @notice The deployer of record on every hand-over chain (the Gully Chain testnet deployer: owner
    /// decision 2026-11-05, "same key", so the CREATE3 addresses match across chains).
    address internal constant HANDOVER_DEPLOYER = 0x92cFC047652d6aEf7eb0fa2744B912d9f627fA41;
    /// @notice Canonical Safe 1.4.1: proxy factory, SafeL2 singleton, CompatibilityFallbackHandler.
    address internal constant SAFE_141_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_141_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_141_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    /// @notice `saltNonce = uint256(keccak256(HANDOVER_SALT_LABEL))` in `createProxyWithNonce`.
    string internal constant HANDOVER_SALT_LABEL = "gully-core.governance.handover.v1";
    /// @notice keccak256(SafeProxyFactory.proxyCreationCode() ++ uint256(SAFE_141_L2_SINGLETON)), read on Base
    /// 2026-11-05. The release script recomputes the address from the live factory on each chain and refuses
    /// a chain where it differs.
    bytes32 internal constant HANDOVER_PROXY_INIT_CODE_HASH =
        0xe298282cefe913ab5d282047161268a8222e4bd4ed106300c547894bbefd31ee;
    /// @notice The hand-over Safe: CREATE2(factory, keccak256(keccak256(initializer) ++ saltNonce), init code),
    /// initializer = setup([HANDOVER_DEPLOYER], 1, 0, "", SAFE_141_FALLBACK_HANDLER, 0, 0, 0). See
    /// `predictHandoverSafe`, which recomputes it; a test pins the two together.
    address internal constant HANDOVER_SAFE = 0xaaa3ee4e1c7b6241156516D4B630A3bF2541f786;
    /// @notice Set to `true` by the release script for the duration of a hand-over run. Read here only.
    string internal constant HANDOVER_RUN_ENV = "GULLYCORE_HANDOVER_RUN";

    /// @notice Robinhood Chain, Base, BNB Chain, HyperEVM, Anubis.
    function isHandoverChain(uint256 chainId) internal pure returns (bool) {
        return chainId == 4663 || chainId == 8453 || chainId == 56 || chainId == 999 || chainId == 6714;
    }

    /// @notice `HANDOVER_SAFE`, recomputed from its inputs.
    function predictHandoverSafe() internal pure returns (address) {
        address[] memory owners = new address[](1);
        owners[0] = HANDOVER_DEPLOYER;
        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            uint256(1),
            address(0),
            bytes(""),
            SAFE_141_FALLBACK_HANDLER,
            address(0),
            uint256(0),
            address(0)
        );
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), uint256(keccak256(bytes(HANDOVER_SALT_LABEL)))));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), SAFE_141_PROXY_FACTORY, salt, HANDOVER_PROXY_INIT_CODE_HASH))))
        );
    }

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /**
     * @notice The Safe of record for `chainId`.
     *
     * On Gully Chain testnet 485590 it is a DEPLOY-TIME input: `GULLYCORE_GOVERNANCE` when set (the owner
     * supplies it; the release script l3/gully-core/release/deploy-testnet.sh always sets it), otherwise
     * the predicted 1-of-1 testnet Safe `SAFE`. Every other production chain uses `MAINNET_SAFE`, which is
     * unset, so mainnet deploys refuse until the owner supplies the mainnet Safe.
     */
    function safeOf(uint256 chainId) internal view returns (address) {
        if (chainId == GULLY_TESTNET_CHAIN_ID) return VM.envOr("GULLYCORE_GOVERNANCE", SAFE);
        // Option 2: one Safe of record on every hand-over chain, before and after its conversion to 2-of-3.
        if (isHandoverChain(chainId)) return HANDOVER_SAFE;
        return MAINNET_SAFE;
    }

    /**
     * @notice True where the Safe of record MUST own what is being deployed.
     *
     * Everything that is not a known development or test chain. Listed as an exclusion on purpose:
     * a chain nobody thought about is asserted by default. Gully Chain testnet 485590 IS asserted (it
     * has a Safe of record).
     */
    function isProductionChain(uint256 chainId) internal pure returns (bool) {
        // anvil / hardhat / ganache defaults, and the chain ids the dev stacks pin.
        if (chainId == 31337 || chainId == 1337 || chainId == 1338) return false;
        // Public testnets without a Gully Core Safe of record.
        if (chainId == 998 || chainId == 11155111 || chainId == 84532 || chainId == 2201 || chainId == 5042002) return false;
        return true;
    }

    /**
     * @notice Assert that `candidate` is a usable governance owner for this deployment.
     *
     * Four checks, in increasing strength:
     *   1. it is a contract  — an EOA can never be the Safe, on any chain;
     *   2. it is not the deployer — the deploy key must not end up owning what it deploys;
     *   3. on a production chain, it IS that chain's Safe of record (refused while that record is unset);
     *   4. on a production chain, that Safe has a real quorum: getThreshold() >= 2 and getOwners() >= 3
     *      (a 1-of-1 Safe is one key with extra steps). Only on Gully Chain testnet 485590 may
     *      GULLYCORE_ALLOW_TESTNET_WEAK_SAFE=true let a weaker Safe through.
     *
     * `label` names the environment variable so a failure says which input was wrong rather than
     * only that one was.
     */
    function requireGovernanceSafe(address candidate, address deployer, string memory label) internal view {
        require(candidate != address(0), string.concat(label, " is unset"));
        require(candidate.code.length > 0, string.concat(label, " has no code - the Safe, not an EOA"));
        require(candidate != deployer, string.concat(label, " is the deployer"));
        if (isProductionChain(block.chainid)) {
            address safe = safeOf(block.chainid);
            require(safe != address(0), "GullyCoreGovernance: governance Safe of record is not set");
            require(candidate == safe, string.concat(label, " is not the governance Safe of record"));
            requireSafeQuorum(candidate, label, VM.envOr(TESTNET_WEAK_SAFE_ENV, false), deployer);
        }
    }

    /**
     * @notice Assert that the Safe `safe` needs at least MIN_SAFE_THRESHOLD of at least MIN_SAFE_OWNERS owners.
     *
     * `allowWeakOnTestnet` (the GULLYCORE_ALLOW_TESTNET_WEAK_SAFE flag) waives it only when this is Gully Chain
     * testnet 485590; on every other chain a weak Safe is refused whatever the flag says. A contract that does not
     * answer getThreshold()/getOwners() like a Safe is refused too.
     */
    function requireSafeQuorum(address safe, string memory label, bool allowWeakOnTestnet) internal view {
        // No signer named: the hand-over relaxation cannot apply.
        requireSafeQuorum(safe, label, allowWeakOnTestnet, address(0));
    }

    /// @notice The quorum rule with the signer named, which is what lets the hand-over run through (and
    /// nothing else): see "OPTION 2" above.
    function requireSafeQuorum(address safe, string memory label, bool allowWeakOnTestnet, address signer) internal view {
        (bool okT, bytes memory t) = safe.staticcall(abi.encodeWithSignature("getThreshold()"));
        (bool okO, bytes memory o) = safe.staticcall(abi.encodeWithSignature("getOwners()"));
        require(okT && t.length == 32 && okO && o.length >= 64, string.concat(label, " does not answer getThreshold()/getOwners() like a Safe"));
        uint256 threshold = abi.decode(t, (uint256));
        address[] memory ownerList = abi.decode(o, (address[]));
        uint256 owners = ownerList.length;
        if (threshold >= MIN_SAFE_THRESHOLD && owners >= MIN_SAFE_OWNERS && threshold <= owners) return;
        if (allowWeakOnTestnet && block.chainid == GULLY_TESTNET_CHAIN_ID) return;
        // Option 2, the duration of a hand-over run only: THE hand-over Safe, still 1-of-1, owned by the signer.
        if (
            VM.envOr(HANDOVER_RUN_ENV, false) && isHandoverChain(block.chainid) && safe == HANDOVER_SAFE && threshold == 1
                && owners == 1 && signer != address(0) && ownerList[0] == signer && signer == HANDOVER_DEPLOYER
        ) return;
        revert(
            string.concat(
                label, " is a ", VM.toString(threshold), "-of-", VM.toString(owners),
                " Safe: governance needs a threshold of at least 2 and at least 3 owners"
            )
        );
    }
}
