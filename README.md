# Biconomy PropAMM

Biconomy PropAMM is infrastructure for running a proprietary AMM (an AMM run by a market maker) on chain. The market maker brings pricing and inventory; the stack provides settlement, price commit and execution. Each trade settles against the maker's freshest committed price, inside the validity window the maker signed, from the maker's own inventory.

Live on Base (8453), BNB Smart Chain (56) and Base Sepolia (84532).

## For market makers

- Quote by streaming signed price updates at any cadence. No transactions to send, no gas to hold, no node to run on your side.
- Pricing stays in your own contract: it decides the output it delivers.
- Every price you sign carries its own expiry, and a fresher price cancels the one before it. A fill settles only against your freshest committed, unexpired price, so stale-price pickoff is bounded by the lifetime you chose.
- Depth is capped per signed price: a price ladder can fill at most its top level, once, ever, no matter how the flow is sliced or how many blocks it spans.

## For users

- You reach PropAMM prices through the aggregators and interfaces you already trade on; nothing new to install or sign up for.
- You receive at least the minimum the route promised, or the trade reverts. The floor is enforced by the contract, measured on your own balance.
- The price that fills you is the maker's freshest committed price, signed and inside its validity window. If the maker improved their price while your trade was in flight, you receive the improvement; you are never settled below the floor you accepted.

## For aggregators

- Integrate PropAMM like any pool: read maker boards in one eth_call, fill with a deterministic onchain swap. No API in the hot path, no per-consumer keys, boards kept fresh onchain by the network.
- Prefer RFQ? Take firm quotes over REST, returned as ready-to-execute calldata, with the quote window priced by the maker who signed it.
- What you simulate is what you settle: quotes are the settlement arithmetic, budgets and expiries are contract-enforced, and a fill below your floor reverts instead of delivering less.
- Charge your own fee by pointing delivery at your router and taking your cut on the delivered amount. Delivery floors stay enforced onchain.

## Docs

- [docs/architecture.md](docs/architecture.md): how Biconomy PropAMM is put together and how a fill works.
- [docs/integration.md](docs/integration.md): what a market maker implements, the provider contract and the signed price stream.
- [docs/maker-quickstart-base-weth-usdc.md](docs/maker-quickstart-base-weth-usdc.md): the runbook - zero to quoting WETH/USDC on Base with your own inventory.
- [docs/aggregator-api.md](docs/aggregator-api.md): how an aggregator integrates Biconomy PropAMM onchain as a liquidity source.

## Source

- [`bcnmy/erc8211-contracts`](https://github.com/bcnmy/erc8211-contracts): ERC-8211 reference contracts.
- [`@biconomy/smart-batching`](https://www.npmjs.com/package/@biconomy/smart-batching): SDK for building ERC-8211 composable batches.

## Maintainers

Maintained by [Biconomy](https://biconomy.io). Reach out at connect@biconomy.io.
