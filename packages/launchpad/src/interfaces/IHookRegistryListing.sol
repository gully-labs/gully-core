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

import {GullyCoreMetadata} from "gullycore-registry/src/IGullyCoreRegistry.sol";

/// @notice The three registry entry points the launchpad kit uses.
/// @dev `IGullyCoreRegistry` declares the registry's events, errors and types but no functions -
/// its callable surface lives on the concrete `GullyCoreRegistry`. This narrow interface lets the
/// kit call that surface without compiling the whole registry implementation into its own build,
/// and makes the exact privileges the kit exercises legible at a glance: it may list a hook and
/// hand the listing over. It cannot verify, deprecate or flag anything.
interface IHookRegistryListing {
    function register(address hook, GullyCoreMetadata calldata metadata) external;

    function transferSteward(address hook, address newSteward) external;

    function isRegistered(address hook) external view returns (bool);
}
