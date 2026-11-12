# Integration guide

For developers who launch tokens, run a launchpad or run a DEX on Gully Core. It covers the launch kit
(`LaunchpadKitV2`), the lockers, the pad factory and the fees you pay. Gully Core is built on PancakeSwap Infinity's audited core.
Read the contracts in `packages/launchpad/src` for exact signatures.

Addresses are not in this guide. Read them from `deployments/8453.json`, `deployments/56.json`, `deployments/4663.json`, `deployments/6714.json`, `deployments/99901.json` and `deployments/485590.json`
(links: [8453](../deployments/8453.json), [56](../deployments/56.json), [4663](../deployments/4663.json), [6714](../deployments/6714.json), [99901](../deployments/99901.json), [485590](../deployments/485590.json)).

The TypeScript SDK is `@gullylabs/core-sdk` (MIT), with the `gullycore` CLI and the `@gullylabs/create-core-app`
template beside it. Source: [gully-labs/gully-core-sdk](https://github.com/gully-labs/gully-core-sdk); its address book is
generated from the `deployments/` files of this repository and a sync check keeps the two equal.

```bash
npm install @gullylabs/core-sdk viem        # @gullylabs/core-sdk 0.3.0, Node 20 or newer
npm install -g @gullylabs/core-cli          # the gullycore command
```

A read-only start: the launch kit's limits on Gully Chain Testnet through the keyless Gully RPC endpoint. It sends
nothing and needs no key.

```ts
import { createPublicClient, http } from "viem";
import { requireDeployment, requireLaunchpadV2, readKitV2Limits } from "@gullylabs/core-sdk";

const book = requireDeployment(485590); // Gully Chain Testnet; 8453, 56, 4663, 6714, 99901 for the mainnets
const client = createPublicClient({
  transport: http("https://rpc.gullyrpc.xyz/gullychain/evm/485590"), // keyless Gully RPC, rate-limited
});

const kit = requireLaunchpadV2(book).launchpadKitV2;
const limits = await readKitV2Limits(client, kit); // reads only, sends nothing
console.log(kit, limits.caps, limits.tax);
```

The app template (`npm create @gullylabs/core-app`) scaffolds today; the scaffolded app installs once the 0.3.1
template release is out.

## 1. What one launch does

`createLaunch(LaunchParamsV2)` is one transaction. It does all of this or nothing:

1. Checks the parameters, the terms, the fees and the schedule. No external call yet.
2. Creates a plain fixed-supply ERC-20 through `LaunchTokenFactory` at a CREATE2 address.
3. For each leg, opens a pool on the shared core with a launch guard hook, seeds it with launch token only,
   and locks the position in the locker (CL or Bin). The kit reads the lock back and checks it.
4. Writes one registry record per pool, attributed to the kit.
5. Sends any unseeded supply and rounding dust to `allocationRecipient` (or to `creator` when none is set).
6. Credits fees, emits events, refunds any `msg.value` above the fees.

If any step fails, everything reverts: token, pools, locks, records and fee credits. There is no try/catch in
the kit. The kit ends every launch holding zero launch token and zero bin shares, and it checks that.

No quote token is ever pulled. A single-sided range holds only the launch token, so a launch quoted in a token
you do not own, or one whose issuer can pause it, still succeeds. A paused quote can block trading later, not creation.

Total supply is fixed: `totalSupply` must equal 1,000,000,000 tokens (18 decimals). `seedSupply` may be smaller.
If `seedSupply < totalSupply`, `allocationRecipient` is required.

Token fields: name up to 64 bytes, symbol up to 32 bytes, `metadataURI` up to 512 bytes.

### Salt and token address

```
salt  = keccak256(abi.encode(msg.sender, userSalt))
token = predictLaunchToken(launcher, userSalt)
```

The launcher is folded into the salt, so nobody else can land on an address you mined. You need the token
address before you build the request, because the pool key sorts the two currencies by address
(`launchToken < quote` means the launch token is currency0). `computeLegKey(token, leg)` returns the key, the
pool id and which side the launch token is on. The kit asserts that the token it creates is at the predicted
address (`LaunchTokenAddressMismatch`).

Pool ids on a launch token are reserved. The guard hooks accept a claim on a factory token's pools only from the
kit that created it, and refuse any currency with no code. A front-runner cannot claim your pool ids.

## 2. createLaunch parameters

| Field | Meaning |
|---|---|
| `name`, `symbol`, `metadataURI` | Token fields. |
| `userSalt` | Your vanity salt. |
| `totalSupply`, `seedSupply`, `allocationRecipient` | See above. |
| `creator` | Lock creator and registry creator. Zero means the caller. |
| `launchOperator` | May call `reconfigureLaunch` before trading opens. Zero means the caller. |
| `launchSteward` | Registry steward of each leg's record. Zero means the caller. |
| `tenant`, `integrator`, `integratorBps`, `integratorLaunchFeeWei` | Your launchpad's terms. See sections 4 and 5. |
| `creatorBps`, `protocolBps` | The split of trading fees. They sum with `integratorBps` to 10,000. |
| `schedule` | Preset and start delay. |
| `tax` | Creator tax. |
| `legs` | One to `maxLegs()` pools. The cap is set per deployment and never above 8. |
| `listing` | Registry metadata for each pool. |

The kit refuses the kit itself as `creator`, `integrator` or `allocationRecipient`. It could never claim.

### Legs

A launch has one or more legs. Each leg is one pool.

- `kind`: `CL` or `Bin`.
- `quote`: any ERC-20 with code, or `address(0)` for the native asset. A leg may not quote the launch token
  itself. Pool ids must be distinct across legs.
- `weightBps`: the leg's share of `seedSupply`. Weights sum to exactly 10,000. Each leg gets
  `seedSupply * weightBps / 10,000`, floored. The last leg takes the remainder. A leg with zero supply reverts
  (`EmptyLeg`).
- `maxBuyPerTx`: a per-transaction cap on a buy, in quote units. Zero turns it off.

A multi-quote launch is just several legs with different quotes. All legs open together at the same `startTime`.

**CL leg** (`CLLegParams`): `tickSpacing`, `sqrtPriceX96` (the opening price, currency1 per currency0 after
sorting), `tickLower`, `tickUpper`. The range must be strictly on the launch token's side of the tick that core
reports after `initialize`:

- launch token is currency0: `tickLower > tick`
- launch token is currency1: `tickUpper <= tick`

Otherwise the kit reverts `RangeNotSingleSided`. A range that gives zero liquidity reverts
`SeedProducesNoLiquidity`.

**Bin leg** (`BinLegParams`): `binStep`, `activeId`, `shape`, and either `binCount` (named shapes) or
`offsets`, `weights`, `floorBins` (`Custom`). See section 7. The kit reads the active id back after
`initialize` and reverts `ActiveIdMoved` if it differs.

### Schedule

`ScheduleParams`: `preset`, `startDelaySeconds`, and for `Custom` only `initialFeeBips`, `finalFeeBips`,
`decaySeconds`, `enabled`. Fees are in pips (1,000,000 is 100%).

| Preset | Opens at | Settles at | Window |
|---|---|---|---|
| `FairLaunch` | 10% | 1% | 300 seconds |
| `AntiSniperAggressive` | 50% | 1% | 1,800 seconds |
| `Stealth` | 50% | 1% | 120 seconds |
| `NoTax` | flat 1% | 1% | no gate, no decay |
| `Custom` | yours | yours | yours, inside the guard's bounds |

Every launch pays at least a 1% steady trade fee, including `Custom` (`TradeFeeBelowFloor`). A preset
overwrites whatever you put in the custom fields.

`AntiSniperAggressive` needs a non-zero `maxBuyPerTx` on every CL leg (`MaxBuyRequiredByPreset`).

A preset is a price, not a prohibition. The guard taxes early buying on a decaying fee. It cannot see who is
buying, so it offers no per-wallet cap and no allowlist. `maxBuyPerTx` bounds one transaction only: splitting a
buy across transactions or wallets defeats it. The early-buy fee goes to the pool's liquidity providers.

`reconfigureLaunch(token, keys, schedule, tax)` lets the operator change the schedule and tax on all legs at
once, before trading opens. The guards freeze the config once trading starts.

### Creator tax

`TaxParams`: `buyBps`, `sellBps`, `taxSeconds`, `creatorBps`, `protocolBps`, `integratorBps`. All zero means no
tax. The guard takes the tax on the unspecified side of each swap, from `startTime` for `taxSeconds` seconds.

- Rates are at most 10% each.
- `taxSeconds = type(uint32).max` means the tax never ends.
- The three buckets sum to 10,000. The creator bucket pays `creator`, the integrator bucket pays `integrator`.
- On outside terms the protocol bucket must be 0 (`TaxProtocolShareFixed`).
- If you launch through a tenant, the rates must be at most the tenant's `maxTaxBps` (zero forbids a tax) and
  `integratorBps` must equal the tenant's `taxIntegratorBps` (`TaxNotAllowed`).

## 3. Locked liquidity

Every leg is locked in the same transaction. There are no unlocked legs.

**CL: `GullyCoreLPLocker`**

- A position that enters never leaves. The locker never transfers, approves, burns, subscribes to or reduces
  it. Its one call to the position manager is a zero-liquidity decrease followed by a take of the accrued fees.
- Entry is `safeTransferFrom` of the position NFT with `abi.encode(LockParams)`. The sender chooses the split.
  The kit mints to itself first and transfers after the Vault unlocks.
- Never mint a position straight to the locker, and never plain-`transferFrom` one. It arrives with no lock
  record and cannot be recovered.
- The split (`creatorBps`, `integratorBps`, `protocolBps`, sum 10,000) is written once and fixed forever.
- `collectFees(tokenId)` is permissionless. It credits `claimable` per party and per currency. Parties pull
  with `claim(currency, to)`. A paused or blocklisting token blocks only its own claims.
- Credit is the measured balance change, so a fee-on-transfer quote credits what arrived. Creator and
  integrator shares are floored. The protocol share takes the rounding remainder.
- The creator can hand the lock to a new address in two steps (`transferCreator`, `acceptCreator`). Balances
  already credited stay with the old address.
- Pools whose hook runs on liquidity removal are refused (`HookInterceptsRemoval`). Positions with a subscriber
  or zero liquidity are refused.
- No owner, no pause, no upgrade, no setter.

**Bin: `GullyCoreBinLPLocker`**

- Bin shares have no receiver callback, so the lock is a pull: `lock(key, binIds, shares, params)` takes shares
  from `msg.sender` only. Shares sent straight to the locker are stranded.
- Principal is tracked per bin as liquidity value. `collectFees(lockId)` burns only the shares whose value is
  above that principal, rounded against the burn. Principal never leaves.
- The proceeds of buys (the quote received for launch tokens sold) are principal. They stay in the pool as depth
  and nobody withdraws them.
- Fees come out in the bin's current composition, valued at the bin's price. Collect often. Fees collected late
  carry the position's price exposure until then.
- Fees accrued before a lock count as principal. A kit launch locks in the same transaction as the mint, so this
  is zero for launches.
- Bins must be listed in strictly increasing order. A lock is capped at `maxBinsPerLock` bins.
- Same split, same pull claims, same creator rotation, no admin.

A lock's split fixes how pool fees divide. It does not stop a pool's own hook from charging a separate fee. Launches
use Gully Core's guard hooks only.

## 4. Fees for an outside builder

If you are not Gully Labs, Gully takes one thing: a flat 0.30% of every trade, on every pool you create.

- It is core's protocol fee, set on the pool when it is initialized and enforced by Gully's fee controller on
  the shared core. The controller's cap is 0.4%.
- It applies to every pool: DEX pools, hook pools, and coins launched through the kit on your launchpad.
- Gully takes no share of the kit's trading-fee split. On your launches `protocolBps` is 0 in the fee split and in
  the lock (`ProtocolShareFixed` if you send anything else).
- Gully takes no share of the creator tax. The tax protocol bucket is 0.
- Gully charges no protocol launch fee on your launches. `launchFeeFor(tenant)` returns 0.
- The Safe may lower the fee on a pool. It can never raise it above the cap.
- The kit checks that a new pool really was born at the flat fee in both directions
  (`ProtocolFeeNotBuilderFee`).

The rest of the trading fee is yours to divide. The creator and the launchpad owner share it as your launchpad
sets: `integratorBps` to your fee wallet, the remainder to the creator. The 1% minimum steady fee and the fixed
supply apply to every launch.

Your own launch fee: a tenant may charge `integratorLaunchFeeWei` per launch, up to the kit's immutable
`maxIntegratorLaunchFeeWei`. It is paid in the native asset. The kit credits it to your integrator address and
you pull it with `claimFees(to)`. A recipient that cannot receive native cannot block anyone's launch.
`msg.value` must cover the fees. The excess is refunded to the sender.

A direct launch with `tenant = address(0)` pays your tenant nothing. A tenant config is a policy for launches
that go through your front end or contract, not a toll on the kit.

## 5. Opening your own launchpad or DEX

A launchpad or DEX front end on Gully Core is a **tenant** of the kit. A tenant is any address that has called
`setTenantConfig`. `GullyCorePadFactory` makes that easy and gives you a transferable on-chain identity.

`createPad(userSalt, name, metadataURI, config, allowedQuotes)`:

- Clones a `GullyCorePad` (EIP-1167) owned by the caller and, in the same transaction, makes it a kit tenant.
- The pad address is `predictPad(creator, userSalt)`. The creator is part of the salt, so nobody can take your
  address. With the factory at the same address on several chains, the same creator and salt give the same pad
  address on each. `padOrigin(pad)` returns the pair. Each chain's pad is its own contract with its own owner and
  terms.
- A second pad from the same creator and salt on one chain reverts `PadAlreadyExists`.
- `name` is 1 to 40 bytes. `metadataURI` (brand pointer: `ipfs://`, `https://` or a data URI) is up to 4,096 bytes.
- The pad owner changes tenant terms with `configure`, quotes with `setQuote`, and the brand with `setMetadata`.
  Ownership moves in two steps. `renounceOwnership` reverts.
- A pad holds nothing. Fees are credited to your `integrator` address, which may not be the pad.

### Tenant terms

`TenantConfig` is written by the tenant, and nobody else (the kit's owner included) can change it:

| Field | Meaning |
|---|---|
| `integrator`, `integratorBps` | Your fee wallet and its share of the trading fee, up to the locker's cap. |
| `integratorLaunchFeeWei` | Your per-launch fee, up to the kit's cap. |
| `allowedPresets` | Bit `i` allows `Preset(i)`. Must be non-zero. |
| `allowedBinShapes` | Bit `i` allows `BinShape(i)`. Zero forbids Bin legs. |
| `restrictQuotes` | When true, every leg's quote must be on your allowlist (`setTenantQuote`). |
| `active` | A launch naming an inactive tenant reverts `TenantNotActive`. |
| `maxTaxBps`, `taxIntegratorBps` | Tax policy, see section 2. |
| `gullyTerms` | Leave this false. |

A launch naming your tenant must restate your `integrator`, `integratorBps` and `integratorLaunchFeeWei`
exactly (`TenantConfigMismatch`). If you change your config, a pending launch reverts. It is never re-priced.
The same goes for `protocolBps`: it restates the terms the launcher expects.

The terms of a launch are fixed when it is created. A later change to your config does not touch launches that
already exist.

## 6. Time

Every window uses `block.timestamp`, in seconds. Nothing uses `block.number`. This covers the start delay,
the fee decay, the tax window, the fee notice periods and `Lock.lockedAt`.

- `startTime = block.timestamp + startDelaySeconds`, computed inside the transaction. A launch that waits in a
  queue cannot land with a start in the past. The delay is at most 30 days.
- Compare contract timestamps with block header timestamps off chain. Never use `eth_blockNumber` as a clock.
- A pause of the quote token does not stop the clock. If a pause spans the decay window, trading reopens at or
  near the final fee.

## 7. Bin shape rules

Offsets and weights are in fill order. Offset 1 is the bin next to the active bin on the launch token's side.
The kit puts them above the active bin (launch token is currency0) or below it (currency1). You cannot put a shape
on the quote side.

| Rule | What it requires | Error |
|---|---|---|
| R1 single-sided | every offset is at least 1 | `BinShapeNotSingleSided` |
| R2 monotonic | offsets strictly increase | `BinShapeNotMonotonic` |
| R3 no gap near the open | the first `floorBins` offsets are exactly 1, 2, ..., `floorBins`; `1 <= floorBins <= n` | `BinShapeInvalidFloor`, `BinShapeGapBelowFloor` |
| R4 count | `1 <= n <= maxBinsPerLeg`, equal array lengths | `BinShapeBadCount`, `BinShapeLengthMismatch` |
| R5 totals | weights sum to exactly 1e18 | `BinShapeWeightsDoNotSum` |
| R6 per bin | every weight above 0 and every bin gets at least 1 unit of launch token | `BinShapeZeroWeight`, `BinShapeDustBin` |
| id range | currency0: `activeId + offset <= 2^24 - 1`; currency1: `offset < activeId` | `BinIdOutOfRange` |

Named shapes (you give `binCount`): `Flat` (equal weights), `Linear` (weight proportional to `n - k`),
`Exponential` (each bin 9/10 of the one before), `Stepped` (tiers of 4 contiguous bins with 2 empty bins between
tiers, tier weight decreasing, `floorBins` = min(4, n)). The last bin takes the rounding remainder, so R5 holds.
`Custom` takes your arrays through the same checks.

Limits you will hit:

- Core caps a Bin pool's fee at 10%. `AntiSniperAggressive` and `Stealth` open at 50% and revert
  `PresetUnavailableOnBin` on any launch that has a Bin leg. `FairLaunch`, `NoTax` and `Custom` up to 10% work.
- A Bin leg's dust (at most one unit per bin) goes to `allocationRecipient`.
- Read `maxLegs()`, `maxBinsPerLeg()` and the Bin locker's `maxBinsPerLock()` for your chain before you size a launch.
  Large launches use a lot of gas. Check the chain's block gas limit and simulate first.

## 8. Events and errors

Kit events:

- `LaunchCreated(token, creator, tenant, launcher, operator, totalSupply, seedSupply, legCount, startTime,
  protocolFeeWei, integrator, integratorFeeWei)`
- `LaunchLegCreated(token, poolId, quote, kind, lockId, launchTokenSeeded, weightBps)`. It is emitted from the
  kit's address. `lockId` is the position id for a CL leg and the lock id for a Bin leg.
- `LaunchTerms(token, tenant, gullyTerms)`
- `LaunchReconfigured`
- `FeesCredited`, `FeesClaimed`
- `TenantConfigured`, `TenantTermsSet`, `TenantQuoteSet`

Locker events: `PositionLocked` (CL) or `BinsLocked` (Bin), `FeesCollected`, `Claimed`, `Skimmed`,
`CreatorTransferStarted`, `CreatorTransferred`.

Pad factory events: `PadCreated`, `PadOriginRecorded`, `PadFeePaid`.

Errors you will see from `createLaunch`:

| Group | Errors |
|---|---|
| shape | `InvalidLegCount`, `LegWeightsDoNotSum`, `EmptyLeg`, `LegTooLarge`, `InvalidSeedSupply`, `TotalSupplyFixed`, `AllocationRecipientRequired`, `InvalidRecipient`, `QuoteHasNoCode`, `QuoteIsLaunchToken`, `DuplicateLegPool`, `StartDelayTooLong` |
| schedule | `TradeFeeBelowFloor`, `MaxBuyRequiredByPreset`, `PresetUnavailableOnBin` |
| range | `RangeNotSingleSided`, `SeedProducesNoLiquidity`, `BinIdOutOfRange`, `ActiveIdMoved`, `BinShape*` |
| terms | `ProtocolShareFixed`, `TaxProtocolShareFixed`, `GullyTermsShareOutOfBounds` |
| fees | `InsufficientLaunchFee`, `IntegratorFeeAboveCap`, `IntegratorFeeWithoutIntegrator`, `NothingToClaim`, `NativeTransferFailed` |
| tenant | `TenantNotActive`, `TenantConfigMismatch`, `PresetNotAllowed`, `BinShapeNotAllowed`, `QuoteNotAllowed`, `TaxNotAllowed`, `InvalidTenantConfig` |
| atomic checks | `LaunchTokenAddressMismatch`, `LaunchTokenSupplyMismatch`, `LockNotRecorded`, `ProtocolFeeNotBuilderFee`, `KitRetainedLaunchToken`, `KitRetainedBinShares` |
| reconfigure | `UnknownLaunch`, `NotLaunchOperator`, `LegKeyMismatch` |

Errors from the guards, lockers, factory, registry and core come through unchanged. The lockers raise
`ProtocolBpsOutOfRange`, `IntegratorBpsTooHigh`, `BpsDoNotSumToDenominator`, `HookInterceptsRemoval`,
`EmptyPosition` and `NotLocked`. The Bin locker adds `BinIdsNotStrictlyIncreasing`, `SharesNotReceived` and
`NothingToCollect` (a free read for keepers: nothing is above principal yet).

## 9. What the kit does not protect

- **Misdirected value.** Launch tokens or native sent to the kit outside `createLaunch` are not recoverable.
  The governance Safe can move a stray ERC-20 out (`rescueERC20`), but not native. Positions or bin shares sent
  to a locker without the proper call are stranded.
- **Contracts that cannot claim.** A `creator` or `integrator` that cannot call the locker's `claim` strands its
  own share.
- **Your own fee is bypassable.** A launcher can call the kit with `tenant = address(0)`. The 0.30% core fee
  still applies. Your integrator share and launch fee do not.
- **A token's issuer.** If a quote token can be paused, blocklisted or burned by its issuer: buys and sells in
  that pair revert while it is paused, and `collectFees` and `claim` in that token revert until it is unpaused.
  Fees stay in the position or bins. Other legs of the same launch keep trading. An issuer burn against a
  locker's balance leaves that token short there, and claims in it pay first come until the balance runs out.
- **A pool's economics.** Presets raise the price of early buying. They do not stop snipers, sybil wallets,
  other venues, or the launcher's conduct with the token. A guarded pool does not make a token safe.
- **Hook fees.** The lockers' split covers the LP fee. A hook that keeps the LP fee low and charges its own fee is
  outside it. Launch only on Gully Core's guard hooks.
- **Late Bin collection.** Uncollected Bin fees move with the market until someone calls `collectFees`.
- **The clock.** Windows follow `block.timestamp`. A sequencer can move it within its chain's bounds, so a
  scheduled change can land up to about an hour early on an Arbitrum Nitro chain.
- **Registry text.** Launch metadata is free text from the launcher.
- **Governance Safe.** The recipient of protocol fees is fixed in the contracts. If that Safe were lost, new
  fees would keep going to it until a new kit is deployed.
- **Gas.** Launches with many legs and bins are expensive. Test on your chain.

## 10. Chain notes

**Anubis (6714).**

- gasDAI pays gas only. No transaction may carry a value. Every call to the kit and the pad factory must send
  `msg.value = 0`.
- There is no native pool and no wrapped native token. Quote in the ERC-20 DAI. Do not use `address(0)` as a quote.
- Every native fee on this chain is 0.
- `eth_getLogs` serves at most 5,000 blocks per request. Page your event reads.
- Multicall3 is not at the canonical address. Do not hard-code it.
-

**Robinhood Chain (4663).** An Arbitrum chain with ETH as gas. Native pools work, and WETH is
`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`. `block.number` here is the parent chain's block number, so use
timestamps only for every duration.

**BNB Chain (56).** BNB is the gas token and quotes native pools. WBNB is
`0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`. `block.number` is the chain's own (about 0.45 s a block), so block-based
windows are short: prefer timestamps. Public RPCs serve small `eth_getLogs` spans; page your event reads.

**Base (8453).** ETH is the gas token and quotes native pools. WETH is `0x4200000000000000000000000000000000000006`.
`block.number` is the chain's own (about 0.2 s a block): prefer timestamps for every duration. Public RPCs serve
`eth_getLogs` spans of about 10,000 blocks; page your event reads.

**Kinetiq Elysium (99901).** HYPE is the gas token and quotes native pools. The wrapped native used by Gully Core is
`0xceeB06009b870430aC2872e3ba875aB6A9AB6699` (WETH9 wrapping HYPE, 1:1). Read the chain through Gully RPC at
`https://rpc.gullyrpc.xyz/gullychain/evm/99901`. The chain's public endpoint rejects bursts of parallel requests: cap
the requests you keep in flight, batch your reads and honour `Retry-After`. Explorer: `https://scan.elysp.com`.
Contracts are source-verified on Gully's Sourcify at `https://verify.gullychain.xyz`.

**Gully Chain Testnet (485590).** An Arbitrum Orbit chain. `block.number` here is the parent chain's block number,
not a local one. This is another reason to use timestamps only.

Contract addresses: [`deployments/8453.json`](../deployments/8453.json), [`deployments/56.json`](../deployments/56.json), [`deployments/4663.json`](../deployments/4663.json), [`deployments/6714.json`](../deployments/6714.json), [`deployments/99901.json`](../deployments/99901.json) and
[`deployments/485590.json`](../deployments/485590.json).
