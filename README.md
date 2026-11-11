<p align="center">
  <a href="https://gullylabs.xyz">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="branding/logotype-reversed.svg">
      <img src="branding/logotype-color.svg" alt="Gully Labs" width="360">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://gullycore.xyz/">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="branding/gully-core-mark-dark.svg">
      <img src="branding/gully-core-mark-light.svg" alt="Gully Core" width="146" height="24">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://gullylabs.xyz">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="branding/powered-by-dark.svg">
      <img src="branding/powered-by-light.svg" alt="Powered by Gully Labs">
    </picture>
  </a>
</p>

# Gully Core

Launchpads, DEXes and markets on one shared core. Built on PancakeSwap Infinity's audited core.

This repository holds the Solidity contracts: the settlement core, periphery and router, hooks, the
launch kit, lockers, fee controllers, registries, governance, routed fills, limit orders and DCA,
managed vaults and liquidity rewards, each with its tests and deploy scripts.

## Deployments

| Network | Chain id | Status | Addresses |
|---|---|---|---|
| Gully Chain Testnet | 485590 | Live, 65 contracts, source-verified | [`deployments/485590.json`](deployments/485590.json) |
| Anubis | 6714 | Live, 48 contracts, source-verified on Sourcify, explorer verification pending, no pools yet | [`deployments/6714.json`](deployments/6714.json) |
| Robinhood Chain | 4663 | Live, 45 contracts, source-verified on Sourcify | [`deployments/4663.json`](deployments/4663.json) |
| BNB Chain | 56 | Live, 45 contracts, source-verified on Sourcify | [`deployments/56.json`](deployments/56.json) |
| Base | 8453 | Live, 45 contracts, source-verified on Sourcify | [`deployments/8453.json`](deployments/8453.json) |
| Kinetiq Elysium | 99901 | Live, 45 contracts, source-verified on Gully's Sourcify (verify.gullychain.xyz) | [`deployments/99901.json`](deployments/99901.json) |
| HyperEVM | 999 | On hold, not deployed | |

Builders start with the [integration guide](docs/integration-guide.md).

On Anubis, gasDAI pays gas and nothing else: a transaction cannot carry a value, and there is no native pool
and no wrapped native. Quote in the ERC-20 DAI. `eth_getLogs` serves 5,000 blocks a request, and Multicall3 is not at
the canonical address. Both are in the guide.

Main entry points on Gully Chain Testnet, current launch release:

| Contract | Address |
|---|---|
| `LaunchpadKitV2` | [`0xb204c2c6CB7Ad0758Fa90B73E1B0e2405A510636`](https://testnet.gullyscan.xyz/address/0xb204c2c6CB7Ad0758Fa90B73E1B0e2405A510636) |
| `GullyCorePadFactory` | [`0xFB740b71F8548b013f921dC331e5662f8bc5b7BD`](https://testnet.gullyscan.xyz/address/0xFB740b71F8548b013f921dC331e5662f8bc5b7BD) |
| `Vault` | [`0x90c882D9C307c2bF7E961bC279b0929f92997dD4`](https://testnet.gullyscan.xyz/address/0x90c882D9C307c2bF7E961bC279b0929f92997dD4) |
| `UniversalRouter` | [`0xb6ab6f0D23c769329DB4b3CFB947fDe3a9e797A5`](https://testnet.gullyscan.xyz/address/0xb6ab6f0D23c769329DB4b3CFB947fDe3a9e797A5) |
| `MixedQuoter` | [`0x8b9F914e7a6CF966D6826dAC965499E43a91e55F`](https://testnet.gullyscan.xyz/address/0x8b9F914e7a6CF966D6826dAC965499E43a91e55F) |
| `GullyCoreProtocolFeeControllerV5` | [`0x8aE0C023A4e345Ff9D14E123848816ad332fDe95`](https://testnet.gullyscan.xyz/address/0x8aE0C023A4e345Ff9D14E123848816ad332fDe95) |
| `GullyCoreLaunchRegistry` | [`0x232B22f21cF12Db740df21DE09915eC7F6e61039`](https://testnet.gullyscan.xyz/address/0x232B22f21cF12Db740df21DE09915eC7F6e61039) |

Owner and every protocol fee recipient on testnet is the governance Safe
[`0xC5526E28B5cDe3C5962A224896804a499d5bb240`](https://testnet.gullyscan.xyz/address/0xC5526E28B5cDe3C5962A224896804a499d5bb240),
a testnet-only 1-of-1. Not deployed on testnet: `packages/hooks-rwa`, the votes token and the custody
timelock.

## Features

- **One shared core.** A single Vault with concentrated-liquidity (CL) and Bin pool managers, on the
  Infinity architecture. Settlement compiles against EIP-1153 transient storage or a storage backend
  from the same source.
- **Token launches.** `LaunchpadKitV2` opens a launch in one transaction on a CL range or a shaped Bin
  distribution, tradable on the real pool from the first block, with the liquidity locked forever by
  `GullyCoreLPLocker` / `GullyCoreBinLPLocker`. No curve contract and no migration.
- **Anti-snipe fee.** The launch guards charge an opening fee of up to 50% on CL (10% on Bin) that
  decays to the pool's trade fee over a window of at least 60 seconds.
- **Creator tax.** Buy and sell rates from 0 to 10%, set at launch. A tax may last forever
  (`TAX_FOREVER`); it is frozen, like the whole launch configuration, from the first trade.
- **Launchpads and DEXes in one transaction.** `GullyCorePadFactory` creates a Launchpad or DEX as a
  clone, with its owner, name, brand and launch terms stored on chain.
- **Routing.** Trades on Gully Core pools pay no router fee; `GullyCoreFillRouter` fills a trade on
  another venue for a fee under an immutable cap.
- **Locks and distribution.** Liquidity locks, token locks and vesting, Merkle airdrops, team splits
  and multisend.
- **Hooks.** Dynamic-fee hooks for CL and Bin pools, a revenue-share hook, market-hours and
  stock-pair hooks with price-band oracles, an on-chain price oracle module, and a registry that
  records what each hook may do.
- **Orders, vaults and rewards.** `GullyCoreRangeOrders` (CL limit orders) and `GullyCoreDCA` are Vault
  lockers that need no hook; `GullyCoreManagedVault` clones hold two positions around the oracle's TWAP;
  `GullyCoreLiquidityRewardsHook` streams project-funded rewards to in-range liquidity.
- **Bounded admin.** Contracts are owned by the governance Safe. Fees and caps are immutable or move
  only behind notice delays written in the contracts, every protocol fee recipient is the Safe, and
  `renounceOwnership` is disabled on Gully Core's own contracts.

## Fees for builders

Anyone building on Gully Core pays Gully one flat protocol fee: **0.30% of every trade**, on every pool
they create (DEX pools, hook pools, stock markets, and coins launched through the kit on their own
launchpad). It is taken from the swap input by `GullyCoreProtocolFeeControllerV5`.

| Rule | Value | Where it is enforced |
|---|---|---|
| Flat protocol fee | 3000 pips per direction | `GullyCoreProtocolFeeControllerV5.builderFee` |
| Cap | 4000 pips (0.40%) | `ProtocolFeeLibrary.MAX_PROTOCOL_FEE` |
| Lowering the fee, flat or per pool | at once | `setBuilderFee`, `setPoolProtocolFee` |
| Raising the fee | after a 7-day notice, never above the cap | `FEE_RAISE_NOTICE` |

On a builder's launches Gully takes no share of the pool fee, no share of the creator tax and no launch
fee: the creator and the launchpad owner share them as the launchpad configures. Launches on Gully's
own surfaces use separate terms (a 1% pool fee split 50/50, 10% of the creator tax and the launch fee,
with no extra 0.30%); they need both the Safe's designation and the tenant's opt-in, so a launchpad
cannot be placed on them from outside.

Every launch through the kit has a pool fee of at least 1% (`MIN_TRADE_FEE_PIPS`) after the opening
window and a supply of exactly 1,000,000,000 tokens (`LAUNCH_TOTAL_SUPPLY`).

## Packages

| Package | What it is | Licence |
|---|---|---|
| `packages/core` | Vault, CL and Bin pool managers, libraries. A fork of `pancakeswap/infinity-core` with a hardened Vault and two transient-storage backends | GPL-2.0-or-later |
| `packages/periphery` | Position managers, quoters. A fork of `pancakeswap/infinity-periphery` | GPL-2.0-or-later |
| `packages/router` | UniversalRouter. A fork of `pancakeswap/infinity-universal-router` | GPL-2.0-or-later (file headers) |
| `packages/hooks` | Base hooks, the launch guards and creator tax, the dynamic-fee hooks | GPL-2.0-or-later |
| `packages/hooks-revshare` | Revenue-share hook and the epoch distributors | GPL-2.0-or-later |
| `packages/hooks-rwa` | Market-hours, stock-pair and permissioned-pool hooks, price-band oracles | GPL-2.0-or-later |
| `packages/launchpad` | `LaunchpadKitV2`, lockers, token factory, Launchpad factory, splits, locks, multisend, Merkle drops | GPL-2.0-or-later |
| `packages/launch-periphery` | Launch-and-buy | GPL-2.0-or-later |
| `packages/registry` | The hook registry and the launch registry | GPL-2.0-or-later |
| `packages/fees` | Protocol fee controllers | GPL-2.0-or-later |
| `packages/governance` | Timelock, votes token, tuner gate | GPL-2.0-or-later |
| `packages/routing` | Routed-fill router and executor | GPL-2.0-or-later |
| `packages/orders` | `GullyCoreRangeOrders` and `GullyCoreDCA`: Vault lockers, not hooks | GPL-2.0-or-later |
| `packages/vaults` | `GullyCoreVaultFactory` and `GullyCoreManagedVault` clones | GPL-2.0-or-later |
| `packages/lp-rewards` | `GullyCoreLiquidityRewardsHook` | GPL-2.0-or-later |

## Build and test

Requires [Foundry](https://getfoundry.sh) 1.8.1.

```sh
git clone --recurse-submodules https://github.com/gully-labs/gully-core.git
cd gully-core/packages/<package>
forge test --threads 1                          # default profile: EIP-1153 transient storage, evm_version cancun
FOUNDRY_PROFILE=legacy forge test --threads 1   # legacy profile: storage backend, evm_version shanghai
```

Every package builds under both profiles from the same source. Packages find each other by relative
path (`../core`, `../hooks`, ...), so keep the `packages/` layout as it is.

- **Do not add `packages/periphery/lib/infinity-core` or `packages/router/lib/infinity-periphery`.**
  Periphery and the router compile against this repository's `packages/core` and `packages/periphery`
  through their remappings; an upstream copy would silently substitute the unhardened Vault.
- **All packages are via-IR builds.** `packages/launchpad` needs roughly 6 GB of memory per compiler
  process. Build one package at a time on a small machine.
- Fork tests in `packages/router` need `FORK_URL` / `ARB_FORK_URL`; `.github/workflows/ci.yml` lists
  what a plain run excludes.
- `tools/manifest_check.py` checks the files listed in `docs/UPSTREAM-IDENTICAL.sha256` still match
  upstream byte for byte. Run it from the repository root.
- Deterministic deploys go through canonical CreateX (`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`):
  CREATE2 for core, periphery and router (`packages/core/script/CoreCreateX.sol`), CREATE3 at
  permissioned salts for everything else (`packages/hooks/script/GullyCoreCreateX.sol`).

## What differs from upstream in the core

`Vault.sync()` is gated by `isLocked` and `Vault.lock()` clears the reserve slots on exit, in both
builds, so no reserve written during a lock can survive it; this matters on the storage backend,
where values persist across transactions. The settlement layer is compiled against one of two
API-identical transient backends chosen per build profile. The regression guard is
`packages/core/test/transient/TransientBackendSafety.t.sol`.

## Source and licence

Gully Core is licensed GPL-2.0-or-later: see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

It is a fork of the DeepCore Protocol contracts
([deep-core-protocol/contracts](https://github.com/deep-core-protocol/contracts), imported unmodified at
`c0911932`), which are themselves built on PancakeSwap Infinity
([`infinity-core`](https://github.com/pancakeswap/infinity-core),
[`infinity-periphery`](https://github.com/pancakeswap/infinity-periphery),
[`infinity-universal-router`](https://github.com/pancakeswap/infinity-universal-router)). Every upstream
copyright notice and licence header is kept as shipped, and Gully Labs' changes carry a modification
notice. The files that are byte-identical to PancakeSwap Infinity are listed in
`docs/UPSTREAM-IDENTICAL.sha256`.

## Security

Report vulnerabilities privately: see [`SECURITY.md`](SECURITY.md). Contributions: see
[`CONTRIBUTING.md`](CONTRIBUTING.md).

<p align="center"><sub>Community: <a href="https://t.me/GullyChain">Telegram news</a> · <a href="https://t.me/GullyChainDeploys">Deploys</a> · <a href="https://t.me/GullyBuyBot">BuyBot</a> · <a href="https://t.me/GullyChainBot">Chain Bot</a> · <a href="https://discord.com/invite/tY2ErsNNBp">Discord</a></sub></p>
