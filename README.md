# Biconomy PropAMM

PropAMM lets a market maker run a proprietary AMM onchain from a signed price stream. The maker signs boards and keeps inventory in its own contract. The protocol stores the boards onchain, prices and meters every fill, enforces the maker's own risk limits, and exposes the merged liquidity to aggregators as one pool contract per chain and to end users through hosted settlement of signed intents.

## The protocol in one paragraph

A maker signs, per pair and direction, either a price ladder (cumulative sizes with absolute prices, 1e18-scaled tokenOut per tokenIn) or an offset ladder (cumulative sizes with offsets in parts per million below an anchor, with optional drift widening per second of anchor age) plus anchors (the reference price, with its own nonce and TTL, signed as often as every block). It may also sign one `BoardControls` message per board that caps how much a single block may take and widens the price with quote age and just after a price move. Anyone may commit those messages to `PropAMMExecutor` through `updatePrices`, `updateOffsets`, `updateAnchors` and `updateControls`; in practice the network does. The executor stores the whole board at commit and fills through one door, `fill(mm, tokenIn, tokenOut, amountIn, receiver)`, sweeping a cumulative meter that resets on depth commits and is untouched by anchors. Depth nonces strictly increase; a same or older nonce is a no-op. Maker inventory stays in the maker's own provider contract (`IMMProvider`, reference implementation `BasicMMProvider`), which lets only the executor move it.

Two lanes fill through that door:

| Lane | Contract | Who uses it |
|---|---|---|
| Onchain | `PropAMMVenue`, one address per chain | Aggregator routers. `getPairs`, `isActive`, `quote`, `swap`, `swapWithFee`, `levels`, `board`, `makers`, `feeBps`. Every registered maker's board merged best price first; `quote` equals measured delivery. |
| Hosted | `PropAMMHostedSettlement` | End users, through the network. Signed intents are settled with steps that transfer the input to the executor and call `fill`; the signed `minAmountOut` is enforced on the receiver's balance. |

## For market makers

- Quote by streaming signed messages over a WebSocket. You send no transactions and hold no gas.
- Inventory stays in a contract you own and can withdraw from at any time. It releases tokens only to the executor, and the executor only fills against a board you signed, at your prices, within your TTLs and within the depth you signed.
- Exposure per depth version is its top size, once, however the flow is sliced or spread across blocks and callers.
- Cap what a single block can take from a board, so one block of adverse flow is bounded even when your stream is behind.
- Make a stale quote cost more: the price widens with the square root of the quote's age, and carries a premium for the first blocks after you move it.
- Move the price every block for the cost of one storage word by signing anchors; re-sign the depth schedule only when sizes, offsets or drift change.

## For aggregators

- Integrate one venue address per chain like any pool: read the merged book in one `eth_call`, fill with a push-payment `swap`. No API in the hot path.
- `quote` is the settlement arithmetic itself, net of the protocol fee, and a size the venue cannot cover reverts in both `quote` and `swap`.
- A maker's per-block limit is already netted into what you read: `remaining` and `quote` report what is fillable in this block, not what the ladder holds.
- Take your own fee with `swapWithFee`, paid to your wallet in the same transaction.

## For users

- PropAMM prices reach you through the aggregators and interfaces you already use.
- You receive at least the minimum the route promised, measured on your own balance, or the trade reverts.

## Addresses

| Contract | Base (8453), BNB Smart Chain (56) | Base Sepolia (84532) |
|---|---|---|
| `PropAMMExecutor` | `0x000000e5Ba94f47C0Fd723F56f1678a841fd33c9` | `0x000000fFA5f8Ae192Ab65204f9B7E062CbF4e05D` |
| `PropAMMVenue` | `0x000000c3380954F805699A363a25AB374ceEb792` | `0x00000035a8a58f704ab0D567D6c67A486428E35a` |
| `PropAMMHostedSettlement` | `0x00000011d9e27864CBc458566eAbA42109fF4b0e` | `0x00000011d9e27864CBc458566eAbA42109fF4b0e` |

Base Sepolia runs a newer executor whose commit doors skip a faulty message and emit `CommitRejected` instead of reverting the batch. Base and BNB Smart Chain move to it at the same addresses on their next deploy.

## Docs

- [docs/architecture.md](docs/architecture.md): the two lanes over one executor, boards, board controls, the fill door, the meter, trust boundaries.
- [docs/price-ladder-streaming.md](docs/price-ladder-streaming.md): what a maker signs and streams. All message forms, the wire format, validation, nonces, TTLs, drift, expiry.
- [docs/integration.md](docs/integration.md): maker onboarding. The provider contract, the signing key, the stream, risk controls, provider-side pricing on the hosted lane, inventory sizing, going dark.
- [docs/maker-quickstart-base-weth-usdc.md](docs/maker-quickstart-base-weth-usdc.md): the shortest path on Base Sepolia. Deploy `BasicMMProvider`, fund it, connect, stream, set your risk limits, verify with `board()`.
- [docs/aggregator-api.md](docs/aggregator-api.md): the venue surface, the read pattern for trackers, the swap recipe, fees, the `PropAMMSwap` event.
- [docs/examples/](docs/examples/): `IMMProvider.sol`, `BasicMMProvider.sol` and a reference client that samples a pricing curve into a price ladder.

## Related

- [ERC-8211](https://erc8211.com/): composable batch steps, which the hosted lane can run as post-hooks.

## Maintainers

Maintained by [Biconomy](https://biconomy.io). Reach out at connect@biconomy.io.
