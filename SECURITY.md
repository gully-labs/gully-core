# Security policy

## Reporting a vulnerability

Email **labsgully@gmail.com** with the subject `Gully Core security`. Please do not open a public
issue, pull request or discussion for a vulnerability.

Include the affected contract and package, the chain and address if it is deployed, the impact, and
steps or a test that reproduces it. A Foundry test is the most useful form.

We will acknowledge a report as soon as we can and keep you informed while it is fixed. Please give us
reasonable time to fix a problem before disclosing it, and do not test against mainnet contracts,
including Anubis, or other people's funds; use a local fork or Gully Chain Testnet.

## Scope

- The contracts in `packages/`, at the addresses in `deployments/`.
- Third-party code in the `lib/` submodules belongs to its own project; report it there. If it affects
  Gully Core, tell us as well.

## Audit status

Gully Core is built on PancakeSwap Infinity's audited core.
