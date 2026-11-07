# `@gullylabs/core-launch-periphery` — the creator's first buy

GPL-2.0-or-later. Deployed addresses: `deployments/`.

One contract: `GullyCoreLaunchAndBuy`. It creates a Kit v2 launch and buys on one of its legs **in the
same transaction**, so the creator is not queuing at `startTime` alongside the bots.

It changes nothing in `packages/launchpad` or `packages/hooks`. It is a plain caller of
`LaunchpadKitV2.createLaunch` plus one Vault lock, and it works because both launch guards already
accept `startTime == block.timestamp` and already permit a swap AT `startTime`. Both facts are
asserted by `test_PREMISE_*` rather than assumed.

```
forge build                          # cancun
FOUNDRY_PROFILE=legacy forge build   # shanghai
forge test --force                   # via-IR: always --force after editing source
```

## The two things that are not free

1. **The launch-token address moves.** `LaunchTokenFactory` salts on its caller, which through this
   contract is this contract for everybody — so it folds the real creator back in
   (`keccak256(abi.encode(msg.sender, userSalt))`), restoring the per-creator namespace the factory's
   own header demands. The address is still **different from the direct path's**, and a vanity salt
   mined for one is worthless on the other. Call `GullyCoreLaunchAndBuy.predictLaunchToken`, not the
   kit's, and pass `BuyParams.expectedToken` so a wrong prediction reverts instead of surprising
   somebody.
2. **The first buy pays the opening LP fee** — 10% on `FairLaunch`, 50% on `AntiSniperAggressive` and
   `Stealth`, 1% on `NoTax` (0.30% on release 1) — because it lands at `elapsed == 0`, which is what the decay is for.
   It is not burned: it goes to the launch's own locked position and comes back in the launch's split.
   `previewOpeningFee` (pure) is what a UI shows; `BuyParams.maxLpFeePips` is the bound the contract
   enforces against the guard's own `currentFee`.

## No owner, no custody

No owner, no admin, no pause, no setter, no `delegatecall`, no `receive`, no `fallback`, no
token-receiver callback, and no storage of its own. `KIT`, `VAULT`, `CL_POOL_MANAGER` and
`BIN_POOL_MANAGER` are immutables read OFF THE KIT at construction; `SWEEP_RECIPIENT` is the only
supplied address and can only ever *receive* value nobody owns. Forced native and misdirected ERC-20s
leave through a permissionless sweep that pays only that address.
