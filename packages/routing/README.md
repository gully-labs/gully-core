# `@gullylabs/core-routing` — the routed-fill fee

GPL-2.0-or-later. Deployed addresses: `deployments/`.

Two contracts that let Gully Core's router fill a user's trade on a venue Gully Core does not run, and take a
governed fee for it (**10 bps on a routed fill, 0 on a Gully Core pool, the same on every chain**).

| | |
|---|---|
| `GullyCoreFillRouter` | holds allowances, bounds the trade, takes the fee on the **input** side, pays out |
| `GullyCoreFillExecutor` | the only contract that makes the caller-chosen call. Nobody approves it. That is the whole point — see its file header. |

**This package imports nothing from `../core` or `../periphery`, and names no third-party venue
anywhere.** The venue is `address target` + `bytes data`, built off chain from a deployed contract's
public ABI. Nothing of anyone else's is vendored, imported or linked; the BUSL question never arises.
Gully Core pools still live only on Gully Core's own Infinity core, and a Gully Core-pool trade does not pass through
here at all.

```
forge build                          # cancun
FOUNDRY_PROFILE=legacy forge build   # shanghai
forge test --force                   # via-IR: always --force after editing source
```
