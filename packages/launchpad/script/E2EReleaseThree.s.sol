// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {GullyCoreSignerScript} from "gullycore-hooks/script/GullyCoreSigner.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LaunchGuardHook} from "gullycore-hooks/src/launch/LaunchGuardHook.sol";
import {GullyCoreProtocolFeeControllerV5} from "gullycore-fees/src/GullyCoreProtocolFeeControllerV5.sol";
import {LaunchMetadata} from "gullycore-registry/src/IGullyCoreLaunchRegistry.sol";

import {LaunchpadKitV2} from "../src/LaunchpadKitV2.sol";
import {GullyCorePadFactory} from "../src/pad/GullyCorePadFactory.sol";
import {Preset} from "../src/libraries/LaunchPresets.sol";
import {
    LegKind,
    CLLegParams,
    LegParams,
    ScheduleParams,
    TaxParams,
    LaunchParamsV2,
    LaunchResultV2,
    TenantConfig
} from "../src/interfaces/ILaunchpadKitV2.sol";

interface ISafeExec {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
    function getThreshold() external view returns (uint256);
    function isOwner(address owner) external view returns (bool);
}

/// @dev A pad's fee wallet for the e2e: a contract the signer drives, so its claims can be made and "nothing is
/// stuck" can be shown for the pad's share too.
contract E2EWallet {
    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function exec(address to, bytes calldata data) external returns (bytes memory ret) {
        require(msg.sender == owner, "not the e2e signer");
        bool ok;
        (ok, ret) = to.call(data);
        require(ok, "wallet call failed");
    }

    receive() external payable {}
}

/// @title E2EReleaseThree
/// @notice Release 3, end to end, with two tenants on one chain (Gully Chain testnet; any chain whose governance
/// Safe is 1-of-1 owned by the signer while the run lasts):
///
///   OUTSIDE PAD   a pad made through the pad factory, not designated. Launch (no Gully launch fee) -> buy ->
///                 sell. The Safe receives the flat core fee and NOTHING else: not from the kit, not from the
///                 guard's fee split, not from the creator tax. Then the Safe lowers that one pool and the next
///                 buy pays the lower fee.
///   GULLY PAD     a pad the Safe designates and that opted in. Launch (launch fee charged) -> buy -> sell. The
///                 pool is born at a zero core fee; the Safe receives release 2's split (half the pool fee, a
///                 tenth of the tax, the launch fee) and no flat fee.
///
/// Then everything is settled, claimed and swept, and the script requires that nothing is left: no pot pending,
/// nothing owed by the guard, nothing accrued in the pool manager, nothing owed by the kit, nothing in the
/// controller or the router. The locked liquidity stays locked: that is what a launch is.
///
/// The `require`s run in forge's simulation (a fork: the dry run executes them all). A broadcast sends the same
/// transactions; `release/e2e-release3.sh` then reads the facts back from the chain.
///
/// Inputs (environment): LAUNCHPAD_KIT_V2 (the release-3 kit), GULLYCORE_PAD_FACTORY (the release-3 pad factory),
/// PRIVATE_KEY or DEPLOYER (the signer: the Safe's single owner).
contract E2EReleaseThreeScript is GullyCoreSignerScript {
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant BUY = 1 ether;

    LaunchpadKitV2 internal kit;
    GullyCorePadFactory internal factory;
    LaunchGuardHook internal guard;
    ICLPoolManager internal cl;
    GullyCoreProtocolFeeControllerV5 internal v5;
    address internal safe;
    address internal me;
    MockERC20 internal quote;
    CLPoolManagerRouter internal router;
    Currency internal q;

    struct Launched {
        address pad;
        E2EWallet wallet;
        LaunchParamsV2 p;
        LaunchResultV2 r;
        PoolKey key;
        PoolId id;
    }

    function run() external {
        uint256 pk = _pkFromEnv();
        me = _signerOf(pk);
        kit = LaunchpadKitV2(vm.envAddress("LAUNCHPAD_KIT_V2"));
        factory = GullyCorePadFactory(vm.envAddress("GULLYCORE_PAD_FACTORY"));
        guard = kit.clHook();
        cl = kit.clPoolManager();
        safe = kit.owner();
        v5 = GullyCoreProtocolFeeControllerV5(address(cl.protocolFeeController()));

        require(address(factory.KIT()) == address(kit), "the pad factory is not bound to this kit");
        require(kit.protocolFeeRecipient() == safe && guard.protocolRecipient() == safe, "a fee recipient is not the Safe");
        require(v5.treasury() == safe && v5.owner() == safe, "the installed controller is not a V5 owned by the Safe");
        require(v5.isLaunchOracle(address(kit)), "the installed V5 does not name this kit");
        require(!v5.isZeroFeeHook(address(guard)), "the installed V5 lists the launch guard as zero-fee");
        uint16 flat = v5.builderFee();
        require(flat == 3000, "the e2e expects the flat fee at 3000 pips");
        require(
            ISafeExec(safe).getThreshold() == 1 && ISafeExec(safe).isOwner(me),
            "this e2e needs a Safe that is 1-of-1 owned by the signer"
        );
        // A kit that owes nothing, so every sum below is exact (anyone may call flushProtocolFees / claimFees first).
        uint256 kitOwedAtStart = kit.totalFeesOwed();
        require(kitOwedAtStart == 0, "the kit already owes native: flush it first, then run the e2e");
        uint256 safeNativeAtStart = safe.balance;

        _startBroadcastAs(pk);

        // ---------------------------------------------------------------- setup
        quote = new MockERC20("Release 3 E2E Quote", "R3Q", 18);
        q = Currency.wrap(address(quote));
        quote.mint(me, 1_000 ether);
        router = new CLPoolManagerRouter(IVault(address(cl.vault())), cl);
        quote.approve(address(router), type(uint256).max);

        Launched memory out;
        Launched memory gul;
        out.wallet = new E2EWallet();
        gul.wallet = new E2EWallet();
        out.pad = factory.createPad{value: factory.padFeeWei()}(
            _salt("pad-out"), "R3 E2E outside pad", "", _padConfig(address(out.wallet), 3_000, 3_000, false), new address[](0)
        );
        gul.pad = factory.createPad{value: factory.padFeeWei()}(
            _salt("pad-gully"), "R3 E2E Gully pad", "", _padConfig(address(gul.wallet), 1_000, 2_000, true), new address[](0)
        );
        // The Safe's key: only the Gully pad is designated. The outside pad cannot give itself the status.
        _safeExec(address(kit), abi.encodeCall(kit.setGullyTenant, (gul.pad, true)));
        require(kit.gullyDesignated(gul.pad) && kit.tenantConfig(gul.pad).gullyTerms, "terms: the Gully pad lacks a key");
        require(!kit.gullyDesignated(out.pad), "terms: the outside pad is designated");
        require(kit.launchFeeFor(out.pad) == 0, "an outside launch owes Gully no launch fee");

        // ================================================================ OUTSIDE PAD
        // 1: launch. No value: no Gully launch fee, and this pad charges none of its own.
        out.p = _params("out", out.pad, address(out.wallet), 3_000, 7_000, 0, _tax(7_000, 0, 3_000));
        out.r = kit.createLaunch(out.p);
        (out.key,,) = kit.computeLegKey(out.r.token, out.p.legs[0]);
        out.id = PoolId.wrap(out.r.poolIds[0]);
        require(!kit.isLockedLaunch(out.r.poolIds[0]), "outside: the pool must not be flagged");
        require(_stamped(out.id) == _pack(flat), "outside: the pool is not born at the flat fee");
        require(kit.totalFeesOwed() == kitOwedAtStart, "outside: the kit credited a fee");
        require(guard.getFeeSplit(out.id).protocolBps == 0, "outside: the guard's split names a protocol share");

        // 2: buy 1 quote. The guard takes the pool's 1% and the 2% tax; core takes 0.30% of what enters the pool
        // (to within a few units: with a zero LP fee core takes the step's whole fee, which rounds in its favour).
        uint256 flatQuote;
        {
            uint256 poolFee = BUY * guard.currentFee(out.id) / PIPS;
            uint256 tax = BUY * 200 / 10_000;
            _swap(out.key, out.r.token, true, BUY);
            require(guard.feeTaken(out.id, q) == poolFee, "outside buy: pool fee");
            require(guard.totalTaken(out.id, q) == tax, "outside buy: tax");
            flatQuote = cl.protocolFeesAccrued(q);
            uint256 want = (BUY - poolFee - tax) * flat / PIPS;
            require(flatQuote + 3 >= want && flatQuote <= want + 3, "outside buy: the flat fee is not 0.30% of what entered the pool");
        }
        // 3: sell half of what was bought. Core's fee is taken from the input, the launch token.
        uint256 flatToken;
        {
            uint256 sell = IERC20(out.r.token).balanceOf(me) / 2;
            IERC20(out.r.token).approve(address(router), type(uint256).max);
            _swap(out.key, out.r.token, false, sell);
            flatToken = cl.protocolFeesAccrued(Currency.wrap(out.r.token));
            uint256 want = sell * flat / PIPS;
            require(flatToken + 3 >= want && flatToken <= want + 3, "outside sell: the flat fee is not 0.30% of the input");
        }
        // settle, claim, sweep: the Safe is credited nothing by the guard and receives exactly the flat fee.
        uint256 outPots = guard.pendingFee(out.id, q) + guard.pendingTax(out.id, q);
        guard.settleFee(out.id, q);
        guard.settleTax(out.id, q);
        require(guard.claimable(safe, q) == 0, "outside: the guard credited the Safe");
        require(guard.claimable(me, q) + guard.claimable(address(out.wallet), q) == outPots, "outside: creator + pad != the pots");
        guard.claim(q, me);
        out.wallet.exec(address(guard), abi.encodeCall(guard.claim, (q, address(out.wallet))));
        require(guard.totalOwed(q) == 0, "outside: something is left owed in the guard");
        require(v5.sweep(address(cl), q) == flatQuote, "outside: sweep (quote)");
        require(v5.sweep(address(cl), Currency.wrap(out.r.token)) == flatToken, "outside: sweep (launch token)");
        require(quote.balanceOf(safe) == flatQuote, "outside: the Safe did not receive exactly the flat fee");
        require(IERC20(out.r.token).balanceOf(safe) == flatToken, "outside: the Safe's launch-token fee");

        // per-pool lowering: the Safe lowers this one pool to 0.10% at once; the next buy pays 0.10%.
        uint256 loweredQuote;
        {
            _safeExec(address(v5), abi.encodeCall(v5.setPoolProtocolFee, (address(cl), out.key, _pack(1000))));
            require(_stamped(out.id) == _pack(1000), "lowering: not applied");
            uint256 poolFee = BUY * guard.currentFee(out.id) / PIPS;
            uint256 tax = BUY * 200 / 10_000;
            _swap(out.key, out.r.token, true, BUY);
            loweredQuote = cl.protocolFeesAccrued(q);
            uint256 want = (BUY - poolFee - tax) * 1000 / PIPS;
            require(loweredQuote + 3 >= want && loweredQuote <= want + 3, "lowering: the next buy did not pay 0.10%");
            require(v5.sweep(address(cl), q) == loweredQuote, "lowering: sweep");
            guard.settleFee(out.id, q);
            guard.settleTax(out.id, q);
            require(guard.claimable(safe, q) == 0, "lowering: the guard credited the Safe");
            guard.claim(q, me);
            out.wallet.exec(address(guard), abi.encodeCall(guard.claim, (q, address(out.wallet))));
        }
        uint256 safeQuoteAfterOutside = quote.balanceOf(safe);
        require(safeQuoteAfterOutside == flatQuote + loweredQuote, "outside: the Safe's quote is not the two flat fees");

        // ================================================================ GULLY PAD
        // 1: launch on Gully terms: the launch fee is charged, the pool is flagged and born at zero.
        uint256 launchFee = kit.launchFeeFor(gul.pad);
        require(launchFee == kit.launchFeeWei(), "gully: launchFeeFor");
        gul.p = _params("gully", gul.pad, address(gul.wallet), 1_000, 4_000, 5_000, _tax(7_000, 1_000, 2_000));
        gul.r = kit.createLaunch{value: launchFee}(gul.p);
        (gul.key,,) = kit.computeLegKey(gul.r.token, gul.p.legs[0]);
        gul.id = PoolId.wrap(gul.r.poolIds[0]);
        require(kit.isLockedLaunch(gul.r.poolIds[0]), "gully: the pool is not flagged");
        require(_stamped(gul.id) == 0, "gully: the pool is not born at zero");
        require(kit.feesOwed(safe) == launchFee, "gully: the launch fee was not credited to the Safe");

        // 2 and 3: buy, then sell half. No flat fee accrues.
        uint256 gullyFee;
        uint256 gullyTax;
        {
            _swap(gul.key, gul.r.token, true, BUY);
            uint256 sell = IERC20(gul.r.token).balanceOf(me) / 2;
            IERC20(gul.r.token).approve(address(router), type(uint256).max);
            _swap(gul.key, gul.r.token, false, sell);
            require(cl.protocolFeesAccrued(q) == 0, "gully: a flat fee accrued in the quote");
            require(cl.protocolFeesAccrued(Currency.wrap(gul.r.token)) == 0, "gully: a flat fee accrued in the launch token");
            gullyFee = guard.pendingFee(gul.id, q);
            gullyTax = guard.pendingTax(gul.id, q);
            require(gullyFee != 0 && gullyTax != 0, "gully: no fee or no tax taken");
        }
        // settle: release 2's split. The protocol takes the remainder of each pot.
        uint256 safeShare = (gullyFee - gullyFee * 4_000 / 10_000 - gullyFee * 1_000 / 10_000)
            + (gullyTax - gullyTax * 7_000 / 10_000 - gullyTax * 2_000 / 10_000);
        guard.settleFee(gul.id, q);
        guard.settleTax(gul.id, q);
        require(guard.claimable(safe, q) == safeShare, "gully: the Safe's share is not half the fee plus a tenth of the tax");
        guard.claim(q, me);
        gul.wallet.exec(address(guard), abi.encodeCall(guard.claim, (q, address(gul.wallet))));
        _safeExec(address(guard), abi.encodeCall(guard.claim, (q, safe)));
        kit.flushProtocolFees();

        // ================================================================ NOTHING STUCK
        require(quote.balanceOf(safe) == safeQuoteAfterOutside + safeShare, "the Safe's quote total");
        require(safe.balance == safeNativeAtStart + launchFee, "the Safe did not receive the launch fee");
        require(guard.totalOwed(q) == 0, "something is left owed in the guard");
        require(guard.pendingFee(out.id, q) + guard.pendingTax(out.id, q) == 0, "outside pots");
        require(guard.pendingFee(gul.id, q) + guard.pendingTax(gul.id, q) == 0, "gully pots");
        require(cl.protocolFeesAccrued(q) == 0, "accrued quote left in the pool manager");
        require(cl.protocolFeesAccrued(Currency.wrap(out.r.token)) == 0, "accrued launch token left in the pool manager");
        require(kit.totalFeesOwed() == 0 && address(kit).balance == 0, "the kit still owes or holds native");
        require(quote.balanceOf(address(v5)) == 0 && quote.balanceOf(address(router)) == 0, "quote left in the controller or router");
        require(quote.balanceOf(address(kit)) == 0 && IERC20(out.r.token).balanceOf(address(kit)) == 0, "tokens left in the kit");
        vm.stopBroadcast();

        console.log("=== RELEASE 3 E2E PASSED ===");
        console.log("E2E kit", address(kit));
        console.log("E2E guard", address(guard));
        console.log("E2E clPoolManager", address(cl));
        console.log("E2E feeController", address(v5));
        console.log("E2E safe", safe);
        console.log("E2E quote", address(quote));
        console.log("E2E router", address(router));
        console.log("E2E outPad", out.pad);
        console.log("E2E outWallet", address(out.wallet));
        console.log("E2E outToken", out.r.token);
        console.log("E2E outPool", vm.toString(out.r.poolIds[0]));
        console.log("E2E gullyPad", gul.pad);
        console.log("E2E gullyWallet", address(gul.wallet));
        console.log("E2E gullyToken", gul.r.token);
        console.log("E2E gullyPool", vm.toString(gul.r.poolIds[0]));
        console.log("E2E flatQuote", flatQuote);
        console.log("E2E flatToken", flatToken);
        console.log("E2E loweredQuote", loweredQuote);
        console.log("E2E gullySafeShare", safeShare);
        console.log("E2E launchFee", launchFee);
        console.log("E2E safeQuoteTotal", quote.balanceOf(safe));
    }

    function _salt(string memory tag) internal view returns (bytes32) {
        return keccak256(abi.encode("gully-core.release-3.e2e", tag, block.chainid, block.timestamp));
    }

    function _padConfig(address wallet, uint16 padBps, uint16 taxPadBps, bool gullyTerms)
        internal
        pure
        returns (TenantConfig memory c)
    {
        c.integrator = wallet;
        c.integratorBps = padBps;
        c.allowedPresets = 31;
        c.active = true;
        c.maxTaxBps = 1_000;
        c.taxIntegratorBps = taxPadBps;
        c.gullyTerms = gullyTerms;
    }

    function _tax(uint16 creatorBps, uint16 protocolBps, uint16 integratorBps) internal pure returns (TaxParams memory t) {
        t.buyBps = 200;
        t.sellBps = 200;
        t.taxSeconds = type(uint32).max;
        t.creatorBps = creatorBps;
        t.protocolBps = protocolBps;
        t.integratorBps = integratorBps;
    }

    /// @dev One CL leg against the e2e quote, a flat 1% fee from the first second (a disabled schedule), the
    /// signer as creator, operator and steward.
    function _params(
        string memory tag,
        address tenant,
        address wallet,
        uint16 padBps,
        uint16 creatorBps,
        uint16 protocolBps,
        TaxParams memory tax
    ) internal view returns (LaunchParamsV2 memory p) {
        p.name = string.concat("Release 3 E2E ", tag);
        p.symbol = "R3E";
        p.metadataURI = "ipfs://release-3-e2e";
        p.userSalt = _salt(tag);
        p.totalSupply = kit.LAUNCH_TOTAL_SUPPLY();
        p.seedSupply = p.totalSupply;
        p.creator = me;
        p.tenant = tenant;
        p.integrator = wallet;
        p.integratorBps = padBps;
        p.creatorBps = creatorBps;
        p.protocolBps = protocolBps;
        p.schedule = ScheduleParams({
            preset: Preset.Custom,
            initialFeeBips: 10_000,
            finalFeeBips: 10_000,
            decaySeconds: 60,
            enabled: false,
            startDelaySeconds: 0
        });
        p.tax = tax;
        address token = kit.predictLaunchToken(me, p.userSalt);
        bool is0 = uint160(token) < uint160(address(quote));
        p.legs = new LegParams[](1);
        p.legs[0].kind = LegKind.CL;
        p.legs[0].quote = address(quote);
        p.legs[0].weightBps = 10_000;
        p.legs[0].cl = CLLegParams({
            tickSpacing: 60,
            sqrtPriceX96: SQRT_1_1,
            tickLower: is0 ? int24(60) : int24(-60_000),
            tickUpper: is0 ? int24(60_000) : int24(0)
        });
        LaunchMetadata memory m;
        m.description = "Gully Core release 3 end-to-end run.";
        m.websiteURI = "https://gullychain.xyz/core";
        p.listing = m;
    }

    function _stamped(PoolId id) internal view returns (uint24 fee) {
        (,, fee,) = cl.getSlot0(id);
    }

    function _pack(uint16 fee) internal pure returns (uint24) {
        return uint24(fee) | (uint24(fee) << 12);
    }

    /// @dev Exact input. A buy pays the quote; a sell pays the launch token.
    function _swap(PoolKey memory key, address token, bool isBuy, uint256 amountIn) internal {
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        bool zeroForOne = isBuy ? !tokenIs0 : tokenIs0;
        router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// @dev A 1-of-1 Safe whose owner sends the transaction: the pre-approved signature form (v = 1, r = owner).
    function _safeExec(address to, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(me))), bytes32(0), uint8(1));
        bool ok = ISafeExec(safe).execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig);
        require(ok, "the Safe transaction failed");
    }
}
