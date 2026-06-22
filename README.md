# PropAMM Protocol Docs

Documentation for **PropAMM**: an intent-based settlement layer for streaming-priced market makers on EVM L2s.

A market maker streams signed prices. Our orchestrator settles user intents and handles the on-chain execution against the MM's inventory, with one guarantee: the user gets at least the minimum they signed for, or the trade reverts.

## Contents

- [docs/architecture.md](docs/architecture.md): high-level architecture. What we operate (off-chain orchestrator + on-chain settlement contracts using ERC-8211), what you control versus what we handle, same-block price freshness, and what you get as an MM.
- [docs/integration.md](docs/integration.md): what a market maker implements. The provider contract interface and the signed price stream, with the fill dynamics from the MM's point of view.

## Source

- [`bcnmy/erc8211-contracts`](https://github.com/bcnmy/erc8211-contracts): ERC-8211 reference contracts.
- [`@biconomy/smart-batching`](https://www.npmjs.com/package/@biconomy/smart-batching): SDK for building ERC-8211 composable batches.

Contract interfaces and reference provider templates are shared on request.

## Maintainers

Maintained by [Biconomy](https://biconomy.io). Reach out at connect@biconomy.io.
