# Biconomy PropAMM

Biconomy PropAMM is the infrastructure for running a proprietary AMM on chain. A proprietary AMM is an AMM run by a market maker; Biconomy PropAMM is the stack that lets a market maker run one without building the on-chain settlement, price-commit, and execution machinery themselves.

The market maker brings the pricing and inventory. Biconomy PropAMM commits the market maker's fresh price on chain and settles each user trade against the market maker's inventory, in the same block.

## For market makers

- Quote by streaming signed price updates at any cadence. No transactions to send, no gas to hold, no node to run on your side.
- Pricing stays in your own contract: it decides the output it delivers.
- A fill settles only against a price committed in the same block, which limits stale-price pickoff during volatility.

## For users

- You reach PropAMM prices through the aggregators and interfaces you already trade on; nothing new to install or sign up for.
- You receive at least the minimum the route promised, or the trade reverts. The floor is enforced by the contract, measured on your own balance.
- The price that fills you was signed by the maker in the same block, so you cannot be settled against a stale quote.

## For aggregators

- Take firm quotes over a plain REST API, returned with ready-to-execute calldata, or stream signed price ladders and compute routes locally at your own cadence.
- Add your own fee in either mode: point delivery at your router, keep your cut, forward the rest. Delivery floors are enforced onchain.

## Docs

- [docs/architecture.md](docs/architecture.md): how Biconomy PropAMM is put together and how a fill works.
- [docs/integration.md](docs/integration.md): what a market maker implements, the provider contract and the signed price stream.
- [docs/aggregator-api.md](docs/aggregator-api.md): how an aggregator integrates Biconomy PropAMM as a liquidity source.

## Source

- [`bcnmy/erc8211-contracts`](https://github.com/bcnmy/erc8211-contracts): ERC-8211 reference contracts.
- [`@biconomy/smart-batching`](https://www.npmjs.com/package/@biconomy/smart-batching): SDK for building ERC-8211 composable batches.

## Maintainers

Maintained by [Biconomy](https://biconomy.io). Reach out at connect@biconomy.io.
