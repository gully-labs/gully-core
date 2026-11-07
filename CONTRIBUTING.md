# Contributing to Gully Core

## Set up

```sh
git clone --recurse-submodules https://github.com/gully-labs/gully-core.git
```

Use Foundry 1.8.1. Work in one package at a time; see the README for memory needs.

## Before you open a pull request

- Run `forge test --threads 1` in the package you changed, under both profiles: the default and
  `FOUNDRY_PROFILE=legacy`. A change must build and pass on both.
- Add a test for every behaviour you change.
- Keep contract sizes under the EIP-170 limit: `tools/build.sh <package>` reports any that go over.
- Run `python tools/manifest_check.py` from the repository root. Files listed in
  `docs/UPSTREAM-IDENTICAL.sha256` must stay byte-identical to upstream.

## Rules

- **Licence.** Contributions are made under GPL-2.0-or-later.
- **Headers.** Never remove or edit an SPDX line or a copyright notice. When you modify a file, keep the
  existing lines and make sure it carries a modification notice beneath them.
- **One core.** Do not add `packages/periphery/lib/infinity-core` or
  `packages/router/lib/infinity-periphery`.
- **Backends.** The `hp-transient` remapping is pinned per profile in `foundry.toml`. Never put it in
  `remappings.txt`.
- **Secrets.** Never commit keys, `.env` files or RPC URLs that carry a key.
- **Security problems** go to the private channel in `SECURITY.md`, not to an issue.
