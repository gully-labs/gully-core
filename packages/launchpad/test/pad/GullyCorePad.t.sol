// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.26;

import {KitV2Fixture} from "../kitv2/KitV2Fixture.sol";
import {GullyCorePad} from "../../src/pad/GullyCorePad.sol";
import {IGullyCorePad} from "../../src/pad/IGullyCorePad.sol";
import {GullyCorePadFactory} from "../../src/pad/GullyCorePadFactory.sol";
import {ILaunchpadKitV2, LaunchParamsV2, LaunchResultV2, TenantConfig} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";
import {BinShape} from "../../src/libraries/BinLaunchShapes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockERC721} from "solmate/src/test/utils/mocks/MockERC721.sol";

/// @dev Forces native into a contract that has no receive: the only way value gets there.
contract Forcer {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @notice `GullyCorePad` + `GullyCorePadFactory` against the REAL kit: a pad is a tenant, launches through it pay
/// the owner's integrator wallet, and the pad itself never holds a wei. (The factory's site fee has its
/// own file, GullyCorePadFactoryFee.t.sol.)
contract GullyCorePadTest is KitV2Fixture {
    uint256 internal _saltNonce;

    /// @dev A fresh user salt per create: one creator may run several pads on one chain, each at its own salt.
    function _salt() internal returns (bytes32) {
        return keccak256(abi.encode("pad-test-salt", ++_saltNonce));
    }

    address internal constant PAD_OWNER = address(0x9AD0);
    address internal constant PAD_WALLET = address(0x9A11);
    address internal constant NEW_OWNER = address(0x9E00);

    /// @dev The site fee in force for these tests. The fee mechanism itself is exercised in
    /// GullyCorePadFactoryFee.t.sol; here every create pays exactly it so the pad behaviour is what is tested.
    uint256 internal constant PAD_FEE = 0.003 ether;

    GullyCorePadFactory internal padFactory;
    address[] internal noQuotes;

    function setUp() public {
        _deployAll();
        padFactory = new GullyCorePadFactory(ILaunchpadKitV2(address(kit)), safe, safe, PAD_FEE, PAD_FEE * 10, 7 days);
        vm.deal(PAD_OWNER, 100 ether);
    }

    function _config() internal pure returns (TenantConfig memory c) {
        c.integrator = PAD_WALLET;
        c.integratorBps = 500;
        c.integratorLaunchFeeWei = 0.001 ether;
        c.allowedPresets = uint8(1 << uint8(Preset.FairLaunch)) | uint8(1 << uint8(Preset.Custom));
        c.allowedBinShapes = uint8(1 << uint8(BinShape.Linear)) | uint8(1 << uint8(BinShape.Exponential));
        c.restrictQuotes = false;
        c.active = true;
    }

    function _createPad() internal returns (GullyCorePad pad) {
        vm.prank(PAD_OWNER);
        pad = GullyCorePad(padFactory.createPad{value: PAD_FEE}(_salt(), "Mochi Pad", "data:application/json,{}", _config(), noQuotes));
    }

    /*//////////////////////////////////////////////////////////////
                               FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_FACTORY_createPadIsOneTransactionAndATenant() public {
        vm.expectEmit(false, true, false, true);
        emit GullyCorePadFactory.PadCreated(address(0), PAD_OWNER, "Mochi Pad");
        GullyCorePad pad = _createPad();

        assertEq(pad.owner(), PAD_OWNER);
        assertEq(pad.name(), "Mochi Pad");
        assertEq(pad.metadataURI(), "data:application/json,{}");
        assertEq(address(pad.KIT()), address(kit));
        assertEq(pad.FACTORY(), address(padFactory));
        assertTrue(padFactory.isPad(address(pad)));
        assertEq(padFactory.padCount(), 1);
        assertEq(padFactory.padAt(0), address(pad));

        // The kit stores the config under the PAD's address: the pad is the tenant.
        TenantConfig memory stored = kit.tenantConfig(address(pad));
        assertTrue(stored.active);
        assertEq(stored.integrator, PAD_WALLET);
        assertEq(stored.integratorBps, 500);
        assertEq(stored.integratorLaunchFeeWei, 0.001 ether);
        assertEq(kit.tenantConfig(PAD_OWNER).active, false, "the owner wallet is not a tenant");
        assertEq(pad.tenantConfig().integrator, PAD_WALLET);
    }

    function test_FACTORY_pagesPadsInCreationOrder() public {
        address a = address(_createPad());
        address b = address(_createPad());
        address c = address(_createPad());
        address[] memory all = padFactory.pads(0, 10);
        assertEq(all.length, 3);
        assertEq(all[0], a);
        assertEq(all[1], b);
        assertEq(all[2], c);
        address[] memory middle = padFactory.pads(1, 2);
        assertEq(middle.length, 1);
        assertEq(middle[0], b);
        assertEq(padFactory.pads(5, 9).length, 0);
        assertEq(padFactory.pads(2, 1).length, 0);
    }

    function test_FACTORY_allowedQuotesAreWrittenAtBirth() public {
        address[] memory quotes = new address[](1);
        quotes[0] = address(quote);
        TenantConfig memory c = _config();
        c.restrictQuotes = true;
        vm.prank(PAD_OWNER);
        GullyCorePad pad = GullyCorePad(padFactory.createPad{value: PAD_FEE}(_salt(), "Quoted", "", c, quotes));
        assertTrue(kit.tenantQuoteAllowed(address(pad), address(quote)));
        assertFalse(kit.tenantQuoteAllowed(address(pad), address(0)));
    }

    function test_FACTORY_kitRulesStillApply() public {
        // Above the kit's integrator bound (release 3: the whole, 10_000): the kit reverts inside createPad, so no
        // pad is left behind. A share above release 2's 20% cap is accepted now (owner default b).
        TenantConfig memory c = _config();
        c.integratorBps = 10_001;
        vm.prank(PAD_OWNER);
        vm.expectRevert(ILaunchpadKitV2.InvalidTenantConfig.selector);
        padFactory.createPad{value: PAD_FEE}(_salt(), "Too greedy", "", c, noQuotes);
        assertEq(padFactory.padCount(), 0);
        assertEq(padFactory.protocolFeesOwed(), 0, "a reverted create credits nothing");
    }

    function test_FACTORY_refusesTheKitAsFactoryInput() public {
        vm.expectRevert(GullyCorePadFactory.ZeroAddress.selector);
        new GullyCorePadFactory(ILaunchpadKitV2(address(0)), safe, safe, PAD_FEE, PAD_FEE * 10, 7 days);
    }

    /*//////////////////////////////////////////////////////////////
                             A LAUNCH THROUGH A PAD
    //////////////////////////////////////////////////////////////*/

    function test_LAUNCH_throughAPadPaysThePadWalletNeverThePad() public {
        GullyCorePad pad = _createPad();
        LaunchParamsV2 memory p = _clAndBin(keccak256("pad-launch"), address(quote));
        p.tenant = address(pad);
        p.integrator = PAD_WALLET;
        p.integratorBps = 500;
        p.integratorLaunchFeeWei = 0.001 ether;
        // Release 3: this pad is not designated, so the launch is on outside terms: no protocol share.
        p.creatorBps = 9_500;
        p.protocolBps = 0;
        uint256 safeOwed = kit.feesOwed(safe);

        LaunchResultV2 memory r = _launchOutside(p);
        assertEq(r.protocolFeeWei, 0, "an outside pad's launch owes Gully no launch fee");
        assertEq(kit.feesOwed(safe), safeOwed, "and credits the Safe nothing");
        assertFalse(kit.isLockedLaunch(r.poolIds[0]), "and its pools are not flagged");
        assertEq(clLocker.getLock(r.lockIds[0]).protocolBps, 0);
        assertEq(kit.getLaunch(r.token).tenant, address(pad));
        assertEq(kit.feesOwed(PAD_WALLET), 0.001 ether, "launch fee credited to the owner's wallet");
        assertEq(kit.feesOwed(address(pad)), 0, "nothing credited to the pad");
        assertEq(address(pad).balance, 0);
        assertEq(clLocker.getLock(r.lockIds[0]).integrator, PAD_WALLET, "lock split names the wallet");
        assertEq(clLocker.getLock(r.lockIds[0]).integratorBps, 500);
    }

    function test_LAUNCH_restatingDifferentTermsReverts() public {
        GullyCorePad pad = _createPad();
        LaunchParamsV2 memory p = _clAndBin(keccak256("pad-mismatch"), address(quote));
        p.tenant = address(pad);
        p.integrator = PAD_WALLET;
        p.integratorBps = 400; // stored is 500
        p.integratorLaunchFeeWei = 0.001 ether;
        p.creatorBps = 9_600;
        p.protocolBps = 0;
        vm.deal(LAUNCHER, 1 ether);
        vm.prank(LAUNCHER);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TenantConfigMismatch.selector, address(pad)));
        kit.createLaunch{value: 0.001 ether}(p); // an outside launch owes only the pad fee
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    function test_OWNER_configureAndMetadata() public {
        GullyCorePad pad = _createPad();
        TenantConfig memory c = _config();
        c.integratorBps = 1_000;
        vm.prank(PAD_OWNER);
        pad.configure(c);
        assertEq(kit.tenantConfig(address(pad)).integratorBps, 1_000);

        vm.prank(PAD_OWNER);
        vm.expectEmit(false, false, false, true);
        emit IGullyCorePad.MetadataUpdated("Mochi", "ipfs://brand");
        pad.setMetadata("Mochi", "ipfs://brand");
        assertEq(pad.name(), "Mochi");
        assertEq(pad.metadataURI(), "ipfs://brand");

        vm.prank(PAD_OWNER);
        pad.setQuote(address(quote), true);
        assertTrue(kit.tenantQuoteAllowed(address(pad), address(quote)));
    }

    function test_OWNER_strangerCannotTouchAnything() public {
        GullyCorePad pad = _createPad();
        vm.startPrank(ATTACKER);
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.configure(_config());
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.setMetadata("x", "");
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.setQuote(address(quote), true);
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.transferOwnership(ATTACKER);
        vm.expectRevert(IGullyCorePad.NotPendingOwner.selector);
        pad.acceptOwnership();
        vm.stopPrank();
        // And the kit's own entry point is useless to the attacker: the tenant is the pad, not them.
        vm.prank(ATTACKER);
        kit.setTenantConfig(_config());
        assertEq(kit.tenantConfig(address(pad)).integratorBps, 500);
    }

    function test_OWNER_twoStepTransferKeepsTheTenantIdentity() public {
        GullyCorePad pad = _createPad();
        vm.prank(PAD_OWNER);
        pad.transferOwnership(NEW_OWNER);
        assertEq(pad.owner(), PAD_OWNER, "not yet");
        assertEq(pad.pendingOwner(), NEW_OWNER);

        vm.prank(NEW_OWNER);
        pad.acceptOwnership();
        assertEq(pad.owner(), NEW_OWNER);
        assertEq(pad.pendingOwner(), address(0));

        // The old owner is out; the new one configures; the tenant address never moved.
        vm.prank(PAD_OWNER);
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.configure(_config());
        TenantConfig memory c = _config();
        c.integrator = NEW_OWNER;
        vm.prank(NEW_OWNER);
        pad.configure(c);
        assertEq(kit.tenantConfig(address(pad)).integrator, NEW_OWNER);
    }

    function test_OWNER_renounceIsDisabled() public {
        GullyCorePad pad = _createPad();
        vm.prank(PAD_OWNER);
        vm.expectRevert(IGullyCorePad.RenounceDisabled.selector);
        pad.renounceOwnership();
        vm.prank(PAD_OWNER);
        vm.expectRevert(IGullyCorePad.ZeroAddress.selector);
        pad.transferOwnership(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               NO CUSTODY
    //////////////////////////////////////////////////////////////*/

    function test_CUSTODY_padRefusesToBeItsOwnIntegrator() public {
        GullyCorePad pad = _createPad();
        TenantConfig memory c = _config();
        c.integrator = address(pad);
        vm.prank(PAD_OWNER);
        vm.expectRevert(IGullyCorePad.PadCannotBeIntegrator.selector);
        pad.configure(c);
    }

    function test_CUSTODY_padAcceptsNoNative() public {
        GullyCorePad pad = _createPad();
        vm.deal(ATTACKER, 1 ether);
        vm.prank(ATTACKER);
        (bool ok,) = address(pad).call{value: 1}("");
        assertFalse(ok, "no receive, no fallback");
    }

    function test_CUSTODY_rescueERC20MovesOnlyWhatWasMisdirected() public {
        GullyCorePad pad = _createPad();
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(pad), 5 ether);
        vm.prank(ATTACKER);
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.rescueERC20(address(stray), ATTACKER);
        vm.prank(PAD_OWNER);
        vm.expectRevert(IGullyCorePad.ZeroAddress.selector);
        pad.rescueERC20(address(stray), address(0));
        vm.prank(PAD_OWNER);
        vm.expectEmit(true, true, false, true);
        emit IGullyCorePad.Rescued(address(stray), PAD_WALLET, 5 ether);
        pad.rescueERC20(address(stray), PAD_WALLET);
        assertEq(stray.balanceOf(PAD_WALLET), 5 ether);
        assertEq(stray.balanceOf(address(pad)), 0);
        vm.prank(PAD_OWNER);
        vm.expectRevert(IGullyCorePad.NothingToRescue.selector);
        pad.rescueERC20(address(stray), PAD_WALLET);
    }

    function test_CUSTODY_rescueERC721AndForcedNative() public {
        GullyCorePad pad = _createPad();
        MockERC721 nft = new MockERC721("Pos", "POS");
        nft.mint(address(pad), 7);
        // A safeTransferFrom to the pad reverts (no receiver hook), which is why only transferFrom strands one.
        nft.mint(ATTACKER, 8);
        vm.prank(ATTACKER);
        vm.expectRevert();
        nft.safeTransferFrom(ATTACKER, address(pad), 8);
        vm.prank(ATTACKER);
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.rescueERC721(address(nft), 7, ATTACKER);
        vm.prank(PAD_OWNER);
        pad.rescueERC721(address(nft), 7, PAD_WALLET);
        assertEq(nft.ownerOf(7), PAD_WALLET);

        new Forcer{value: 1 ether}(payable(address(pad)));
        assertEq(address(pad).balance, 1 ether);
        vm.prank(ATTACKER);
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.rescueNative(ATTACKER);
        vm.prank(PAD_OWNER);
        pad.rescueNative(PAD_WALLET);
        assertEq(address(pad).balance, 0);
        assertEq(PAD_WALLET.balance, 1 ether);
        vm.prank(PAD_OWNER);
        vm.expectRevert(IGullyCorePad.NothingToRescue.selector);
        pad.rescueNative(PAD_WALLET);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_INIT_cloneCannotBeReinitializedAndImplementationIsLocked() public {
        GullyCorePad pad = _createPad();
        vm.prank(address(padFactory));
        vm.expectRevert(IGullyCorePad.AlreadyInitialized.selector);
        pad.initialize(ATTACKER, "x", "", _config(), noQuotes);

        vm.prank(ATTACKER);
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.initialize(ATTACKER, "x", "", _config(), noQuotes);

        GullyCorePad impl = padFactory.IMPLEMENTATION();
        assertEq(impl.owner(), address(0xdead));
        vm.prank(address(padFactory));
        vm.expectRevert(IGullyCorePad.AlreadyInitialized.selector);
        impl.initialize(ATTACKER, "x", "", _config(), noQuotes);
    }

    function test_INIT_nameAndMetadataBounds() public {
        vm.startPrank(PAD_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IGullyCorePad.NameLength.selector, 0, 1, 40));
        padFactory.createPad{value: PAD_FEE}(_salt(), "", "", _config(), noQuotes);
        string memory long = "0123456789012345678901234567890123456789X";
        vm.expectRevert(abi.encodeWithSelector(IGullyCorePad.NameLength.selector, 41, 1, 40));
        padFactory.createPad{value: PAD_FEE}(_salt(), long, "", _config(), noQuotes);
        bytes memory big = new bytes(4097);
        vm.expectRevert(abi.encodeWithSelector(IGullyCorePad.MetadataTooLong.selector, 4097, 4096));
        padFactory.createPad{value: PAD_FEE}(_salt(), "ok", string(big), _config(), noQuotes);
        vm.stopPrank();
    }

    function testFuzz_OWNER_onlyTheOwnerConfigures(address caller) public {
        vm.assume(caller != PAD_OWNER);
        GullyCorePad pad = _createPad();
        vm.prank(caller);
        vm.expectRevert(IGullyCorePad.NotOwner.selector);
        pad.configure(_config());
    }
}
