# PropAMM Protocol Docs

Documentation for **PropAMM**: an intent-based settlement layer for streaming-priced market makers on EVM L2s.

A user signs one EIP-712 intent. A market maker streams signed prices. Our orchestrator routes and our settlement contracts execute, with one guarantee: the receiver gets at least the minimum they signed for, or the intent reverts.

## Contents

- [docs/architecture.md](docs/architecture.md): high-level architecture. The three ideas (one-signature abstraction, ERC-8211 routing with user guards, same-block price freshness), the components, and what is guaranteed to whom.
- [docs/integration.md](docs/integration.md): what a market maker implements. The provider contract interface and the signed price stream, with the fill dynamics from the MM's point of view.

## Source

- [`bcnmy/erc8211-contracts`](https://github.com/bcnmy/erc8211-contracts): ERC-8211 reference contracts.
- [`@biconomy/smart-batching`](https://www.npmjs.com/package/@biconomy/smart-batching): SDK for building ERC-8211 composable batches.

Contract interfaces and reference provider templates are shared on request.

## Maintainers

Maintained by [Biconomy](https://biconomy.io). Reach out at connect@biconomy.io.
