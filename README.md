# propAMM Protocol — Docs

Public documentation for the propAMM Protocol: a coordinated settlement layer for proprietary market makers on EVM L2s.

The protocol gives market makers a shared on-chain substrate for settlement plus a per-market-maker layer for proprietary pricing, inventory, and counterparty policy. Users sign a single intent and get atomic execution; market makers keep their pricing logic in a contract they own and operate.

## Contents

- [docs/architecture.md](docs/architecture.md) — conceptual model, components, trust boundaries, and the operational properties the protocol guarantees.
- [docs/integration.md](docs/integration.md) — what a market maker needs to do to integrate: provider contract interface, EIP-712 payloads, WebSocket protocol, operational notes.

## Maintainers

Maintained by [Biconomy](https://biconomy.io). Reach out at connect@biconomy.io.
