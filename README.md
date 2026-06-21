# PropAMM Protocol — Public Docs

Public documentation for **PropAMM**: an intent-based settlement protocol for streaming-priced market makers on EVM L2s.

A trader signs one EIP-712 message. An orchestrator builds the calldata that achieves the intent at the best price. Settlement enforces a single guarantee — the receiver gets at least `minAmountOut` of `tokenOut`, or the intent reverts.

## Contents

- [docs/architecture.md](docs/architecture.md) — conceptual model, components, trust boundaries, three relay modes (orchestrator / self / permissionless), composability via `Step[]` (cross-MM, cross-external-venue, ERC-8211 delegatecall).
- [docs/integration.md](docs/integration.md) — what each integrator type needs: market maker provider contract + PriceUpdate signing, aggregator/wallet `/v3/intents` flow, trader-side self-relay patterns, EIP-2612 + Permit2 chain for gasless first-time users.

## Source repositories

- [`bcnmy/propamm-protocol`](https://github.com/bcnmy/propamm-protocol) — contracts (`PropAMMSettlement`, `PropAMMExecutor`, `OrchestratorRelay`, MM provider templates), orchestrator, load harness, e2e scenarios.
- [`bcnmy/erc8211-contracts`](https://github.com/bcnmy/erc8211-contracts) — ERC-8211 reference contracts (composable execution module, library, types).
- [`@biconomy/smart-batching`](https://www.npmjs.com/package/@biconomy/smart-batching) — TypeScript SDK for building ERC-8211 composable batches (runtime balance reads, fee splits, post-condition checks).

## Maintainers

Maintained by [Biconomy](https://biconomy.io). Reach out at connect@biconomy.io.
