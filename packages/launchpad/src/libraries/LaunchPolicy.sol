/*
  Gully Core

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://gullychain.xyz/core
  Docs:     https://docs.gullychain.xyz/core
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LaunchTaxModule} from "gullycore-hooks/src/launch/LaunchTaxModule.sol";
import {LaunchpadMetadata} from "gullycore-registry/src/IGullyCoreLaunchRegistry.sol";

import {
    ILaunchpadKitV2, ScheduleParams, TaxParams, LaunchParamsV2, TenantConfig
} from "../interfaces/ILaunchpadKitV2.sol";
import {ILaunchRegistryWriter} from "../interfaces/ILaunchRegistryWriter.sol";
import {LaunchPresets, Preset, PresetParams} from "./LaunchPresets.sol";
import {LaunchLegs} from "./LaunchLegs.sol";

/// @title LaunchPolicy
/// @notice The CHECKS phase of `LaunchpadKitV2.createLaunch` (shape, terms, fees, schedule, creator tax), the
/// same resolution for `reconfigureLaunch`, the tenant-config write, the ERC-20 rescue and the launchpad
/// listing.
///
/// @dev A second LINKED library beside `LaunchLegs`, and it exists for the same reason: EIP-170. The
/// release-2 kit was 24,556 bytes of runtime against the 24,576 limit, so release 3 (launch terms per tenant,
/// owner decision 2026-11-05) could not add a byte to it; this code was MOVED here, it was not rewritten.
/// Everything said about `LaunchLegs` holds:
///   * its public functions run by DELEGATECALL in the kit's context: `address(this)` is the kit,
///     `msg.sender` is the kit's caller, and the storage references passed in are the kit's own mappings;
///   * its address is fixed in the kit's bytecode at link time: no setter, no proxy, no upgrade; a library
///     has no storage of its own and no selfdestruct;
///   * Solidity's library call-guard makes every state-changing function here revert when CALLed directly;
///     the `view` functions can be called directly and only compute.
///
/// WHAT IT NEVER DOES: write the kit's `_gullyLaunch` flag, a leg record or a launch record, credit or pay a
/// fee, or call a pool manager, a guard or a locker. `precheck` and `resolveReconfig` are `view`. The three
/// writers are `setTenant` (the caller's own tenant config), `rescueERC20` (owner-gated by the kit) and
/// `registerLaunchpad` (the registry call the kit made itself before).
library LaunchPolicy {
    /// @dev The kit re-exports these as its public constants, so there is one figure, not two.
    uint24 internal constant MIN_TRADE_FEE_PIPS = 10_000;
    uint16 internal constant PROTOCOL_TRADE_SHARE_BPS = 5_000;
    uint16 internal constant GULLY_TAX_PROTOCOL_FLOOR_BPS = 1_000;
    uint16 internal constant GULLY_MAX_INTEGRATOR_BPS = 2_000;
    uint32 internal constant TAX_SECONDS_FOREVER = type(uint32).max;
    uint256 internal constant LAUNCH_TOTAL_SUPPLY = 1_000_000_000 ether;
    uint32 internal constant MAX_START_DELAY_SECONDS = 30 days;

    /*//////////////////////////////////////////////////////////////
                         createLaunch: THE CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev What `precheck` decides. One struct, because `createLaunch` keeps it across its leg loop and four
    /// separate results put that loop one slot too deep in the stack (solc 0.8.26, via-IR).
    /// @param gully Whether the launch is on Gully terms: BOTH keys, read in this block.
    /// @param required The native total the launch owes: the tenant's integrator launch fee, plus the protocol
    /// launch fee on Gully terms only.
    /// @param schedule The resolved guard schedule.
    /// @param tax The creator tax with recipients resolved (all zero: none).
    struct Checked {
        bool gully;
        uint256 required;
        LaunchLegs.Schedule schedule;
        LaunchTaxModule.TaxConfig tax;
    }

    /// @notice Everything `createLaunch` checks before it writes a flag, except the per-leg loop (which the
    /// kit keeps, because it writes the flags and the leg records as it goes).
    /// @param tenants The kit's tenant configs. @param designated The kit's `gullyDesignated`.
    /// @param protocolLaunchFeeWei The protocol launch fee in force in this block (`launchFeeWei()`).
    /// @param valueSent `msg.value` of the launch (a library function cannot read it itself).
    /// @return k See `Checked`.
    function precheck(
        LaunchParamsV2 calldata p,
        mapping(address => TenantConfig) storage tenants,
        mapping(address => bool) storage designated,
        uint256 protocolLaunchFeeWei,
        uint256 maxIntegratorLaunchFeeWei,
        uint8 maxLegs,
        uint256 valueSent
    ) public view returns (Checked memory k) {
        uint256 n = p.legs.length;
        if (n == 0 || n > maxLegs) revert ILaunchpadKitV2.InvalidLegCount(n, maxLegs);
        if (p.totalSupply != LAUNCH_TOTAL_SUPPLY) revert ILaunchpadKitV2.TotalSupplyFixed(p.totalSupply, LAUNCH_TOTAL_SUPPLY);
        if (p.seedSupply == 0 || p.seedSupply > p.totalSupply) {
            revert ILaunchpadKitV2.InvalidSeedSupply(p.seedSupply, p.totalSupply);
        }
        if (p.seedSupply < p.totalSupply && p.allocationRecipient == address(0)) {
            revert ILaunchpadKitV2.AllocationRecipientRequired();
        }
        // The kit can never claim a locker credit or call `claimFees` for itself: naming it strands value forever.
        if (p.creator == address(this) || p.integrator == address(this) || p.allocationRecipient == address(this)) {
            revert ILaunchpadKitV2.InvalidRecipient(address(this));
        }

        // THE TERMS (release 3), decided once, here, from the two keys as they stand in this block.
        // Gully terms: 50/50, and no creator, tenant or preset choice moves the protocol's half of the
        // trade fee; the integrator keeps release 2's cap. Outside terms: the protocol takes NO share.
        // Either way `protocolBps` restates what the launcher expects, so a status change between signing
        // and inclusion reverts the launch instead of re-pricing it.
        address tenant = p.tenant;
        // A tenant that is unknown or switched off is refused by name, before anything about its terms.
        if (tenant != address(0) && !tenants[tenant].active) revert ILaunchpadKitV2.TenantNotActive(tenant);
        bool gully = tenant != address(0) && designated[tenant] && tenants[tenant].gullyTerms;
        if (gully) {
            if (p.protocolBps != PROTOCOL_TRADE_SHARE_BPS) {
                revert ILaunchpadKitV2.ProtocolShareFixed(p.protocolBps, PROTOCOL_TRADE_SHARE_BPS);
            }
            if (p.integratorBps > GULLY_MAX_INTEGRATOR_BPS) revert ILaunchpadKitV2.GullyTermsShareOutOfBounds(p.integratorBps);
        } else if (p.protocolBps != 0) {
            revert ILaunchpadKitV2.ProtocolShareFixed(p.protocolBps, 0);
        }

        // Fees and tenant policy.
        uint256 integratorFee = p.integratorLaunchFeeWei;
        if (integratorFee > maxIntegratorLaunchFeeWei) {
            revert ILaunchpadKitV2.IntegratorFeeAboveCap(integratorFee, maxIntegratorLaunchFeeWei);
        }
        if (integratorFee != 0 && p.integrator == address(0)) revert ILaunchpadKitV2.IntegratorFeeWithoutIntegrator();
        if (tenant != address(0)) {
            TenantConfig storage t = tenants[tenant];
            if (
                t.integrator != p.integrator || t.integratorBps != p.integratorBps
                    || t.integratorLaunchFeeWei != integratorFee
            ) revert ILaunchpadKitV2.TenantConfigMismatch(tenant);
            if ((t.allowedPresets >> uint8(p.schedule.preset)) & 1 == 0) {
                revert ILaunchpadKitV2.PresetNotAllowed(tenant, p.schedule.preset);
            }
        }
        // The protocol launch fee is owed on Gully terms ONLY (release 3: an outside launch pays Gully none).
        uint256 required = integratorFee;
        if (gully) required += protocolLaunchFeeWei;
        if (valueSent < required) revert ILaunchpadKitV2.InsufficientLaunchFee(required, valueSent);

        k.gully = gully;
        k.required = required;
        k.schedule = _schedule(p.schedule);
        k.tax = _tax(
            p.tax, tenants, tenant, gully, k.schedule.startTime, p.creator == address(0) ? msg.sender : p.creator, p.integrator
        );
    }

    /*//////////////////////////////////////////////////////////////
                             reconfigureLaunch
    //////////////////////////////////////////////////////////////*/

    /// @notice What `reconfigureLaunch` restates on every leg: the schedule, the tenant's preset policy and
    /// the creator tax under the terms the LAUNCH was created on (`gully`), not the tenant's status now.
    function resolveReconfig(
        ScheduleParams calldata schedule,
        TaxParams calldata t,
        mapping(address => TenantConfig) storage tenants,
        address tenant,
        bool gully,
        address creator,
        address integrator
    ) public view returns (LaunchLegs.Reconfig memory r) {
        r.schedule = _schedule(schedule);
        if (tenant != address(0) && (tenants[tenant].allowedPresets >> uint8(schedule.preset)) & 1 == 0) {
            revert ILaunchpadKitV2.PresetNotAllowed(tenant, schedule.preset);
        }
        r.tax = _tax(t, tenants, tenant, gully, r.schedule.startTime, creator, integrator);
        r.preset = schedule.preset;
    }

    function _schedule(ScheduleParams calldata sp) private view returns (LaunchLegs.Schedule memory s) {
        if (sp.startDelaySeconds > MAX_START_DELAY_SECONDS) revert ILaunchpadKitV2.StartDelayTooLong(sp.startDelaySeconds);
        // block.timestamp + at most 30 days fits uint40 until the year 36812.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.startTime = uint40(block.timestamp + sp.startDelaySeconds);
        if (sp.preset == Preset.Custom) {
            s.initialFeeBips = sp.initialFeeBips;
            s.finalFeeBips = sp.finalFeeBips;
            s.decaySeconds = sp.decaySeconds;
            s.enabled = sp.enabled;
        } else {
            PresetParams memory pp = LaunchPresets.params(sp.preset);
            s.initialFeeBips = pp.initialFeeBips;
            s.finalFeeBips = pp.finalFeeBips;
            s.decaySeconds = pp.windowSeconds;
            s.enabled = pp.enabled;
            s.requiresMaxBuy = pp.requiresMaxBuyPerTx;
        }
        // 1% steady fee on every launch type (the presets carry it; a Custom schedule must too).
        if (s.finalFeeBips < MIN_TRADE_FEE_PIPS) revert ILaunchpadKitV2.TradeFeeBelowFloor(s.finalFeeBips, MIN_TRADE_FEE_PIPS);
    }

    /// @dev Tenant policy, the launch's terms and recipient resolution for the creator tax; the rate cap, the
    /// sum and the 50% protocol ceiling are the guard's. An all-zero `t` is "no tax" and the legs skip
    /// `configureTax` entirely.
    function _tax(
        TaxParams calldata t,
        mapping(address => TenantConfig) storage tenants,
        address tenant,
        bool gully,
        uint40 startTime,
        address creator,
        address integrator
    ) private view returns (LaunchTaxModule.TaxConfig memory cfg) {
        if (
            t.buyBps == 0 && t.sellBps == 0 && t.taxSeconds == 0 && t.creatorBps == 0 && t.protocolBps == 0
                && t.integratorBps == 0
        ) return cfg;
        if (tenant != address(0)) {
            TenantConfig storage tc = tenants[tenant];
            if (t.buyBps > tc.maxTaxBps) revert ILaunchpadKitV2.TaxNotAllowed(tenant, t.buyBps);
            if (t.sellBps > tc.maxTaxBps) revert ILaunchpadKitV2.TaxNotAllowed(tenant, t.sellBps);
            if (t.integratorBps != tc.taxIntegratorBps) revert ILaunchpadKitV2.TaxNotAllowed(tenant, t.integratorBps);
        }
        if (gully) {
            // Release 2's bounds, held here because the release-3 guards no longer carry them.
            if (t.protocolBps < GULLY_TAX_PROTOCOL_FLOOR_BPS) revert ILaunchpadKitV2.GullyTermsShareOutOfBounds(t.protocolBps);
            if (t.integratorBps > GULLY_MAX_INTEGRATOR_BPS) revert ILaunchpadKitV2.GullyTermsShareOutOfBounds(t.integratorBps);
        } else if (t.protocolBps != 0) {
            revert ILaunchpadKitV2.TaxProtocolShareFixed(t.protocolBps, 0);
        }
        cfg.buyBps = t.buyBps;
        cfg.sellBps = t.sellBps;
        // startTime <= now + 30 days and taxSeconds < 2^32: fits uint40. `TAX_SECONDS_FOREVER` is the guard's
        // `TAX_FOREVER` (a tax that never ends); any other value ends `taxSeconds` after the open.
        // forge-lint: disable-next-line(unsafe-typecast)
        cfg.expiresAt = t.taxSeconds == TAX_SECONDS_FOREVER ? type(uint40).max : uint40(uint256(startTime) + t.taxSeconds);
        cfg.creatorBps = t.creatorBps;
        cfg.protocolBps = t.protocolBps;
        cfg.integratorBps = t.integratorBps;
        cfg.creator = t.creatorBps == 0 ? address(0) : creator;
        cfg.integrator = t.integratorBps == 0 ? address(0) : integrator;
    }

    /*//////////////////////////////////////////////////////////////
                                 TENANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice `setTenantConfig`: `msg.sender` IS the tenant (the kit's caller, under DELEGATECALL).
    function setTenant(
        mapping(address => TenantConfig) storage tenants,
        TenantConfig calldata c,
        uint256 maxIntegratorLaunchFeeWei,
        uint16 maxIntegratorBps,
        uint16 maxTaxBps,
        uint16 maxTaxIntegratorBps
    ) public {
        if (
            c.integratorLaunchFeeWei > maxIntegratorLaunchFeeWei || c.integratorBps > maxIntegratorBps
                || (
                    c.integrator == address(0)
                        && (c.integratorBps != 0 || c.integratorLaunchFeeWei != 0 || c.taxIntegratorBps != 0)
                ) || c.integrator == address(this) || c.allowedPresets == 0 || c.allowedPresets >= 32
                || c.allowedBinShapes >= 32 || c.maxTaxBps > maxTaxBps || c.taxIntegratorBps > maxTaxIntegratorBps
        ) revert ILaunchpadKitV2.InvalidTenantConfig();
        tenants[msg.sender] = c;
        emit ILaunchpadKitV2.TenantTermsSet(msg.sender, c.gullyTerms);
        emit ILaunchpadKitV2.TenantConfigured(
            msg.sender,
            c.integrator,
            c.integratorBps,
            c.integratorLaunchFeeWei,
            c.allowedPresets,
            c.allowedBinShapes,
            c.restrictQuotes,
            c.active,
            c.maxTaxBps,
            c.taxIntegratorBps
        );
    }

    /*//////////////////////////////////////////////////////////////
                          RESCUE AND LISTING
    //////////////////////////////////////////////////////////////*/

    /// @notice `rescueERC20`: the kit gates it (`onlyOwner`) before it delegates here.
    function rescueERC20(address token, address to) public {
        if (to == address(0)) revert ILaunchpadKitV2.RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert ILaunchpadKitV2.NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ILaunchpadKitV2.ERC20Rescued(token, to, amount);
    }

    /// @notice `registerLaunchpad`: lists the kit as `SelfRegistered` with its immutable steward, or claims
    /// a listing a stranger created.
    function registerLaunchpad(ILaunchRegistryWriter registry, address steward, LaunchpadMetadata calldata metadata)
        public
    {
        if (registry.isLaunchpadRegistered(address(this))) {
            registry.claimLaunchpad(steward);
        } else {
            registry.registerLaunchpad(address(this), steward, metadata);
        }
    }
}
