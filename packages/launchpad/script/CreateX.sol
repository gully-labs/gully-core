// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity ^0.8.26;

/// @notice The CreateX interface and address math moved to `packages/hooks/script/GullyCoreCreateX.sol` on
/// 2026-09-20, when every release script (not only the pad factory) began deploying through CreateX: the
/// registry, fees and hooks-revshare packages need the same math, and two copies of a deployment address
/// calculation is exactly the kind of thing that drifts. This file re-exports the symbols so the paths
/// already written into tests and dev scripts keep working. New code should import
/// `gullycore-hooks/script/GullyCoreCreateX.sol` directly.
import {ICreateX, CreateXCreate3, GullyCoreDeploy} from "gullycore-hooks/script/GullyCoreCreateX.sol";
