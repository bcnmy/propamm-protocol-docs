# Biconomy PropAMM

PropAMM lets a market maker run a proprietary AMM onchain from a signed price stream. The maker signs boards and keeps inventory in its own contract. The protocol stores the boards onchain, prices and meters every fill, and exposes the merged liquidity to aggregators as one pool contract per chain and to end users through hosted settlement of signed intents.

## The protocol in one paragraph

A maker signs, per pair and direction, either a price ladder (cumulative sizes with absolute prices, 1e18-scaled tokenOut per tokenIn) or an offset ladder (cumulative sizes with offsets in parts per million below an anchor, with optional drift widening per second of anchor age) plus anchors (the reference price, with its own nonce and TTL, signed as often as every block). Anyone may commit those messages to `PropAMMExecutor` through `updatePrices`, `updateOffsets` and `updateAnchors`; in practice the network does. The executor stores the whole board at commit and fills through one door, `fill(mm, tokenIn, tokenOut, amountIn, receiver)`, sweeping a cumulative meter that resets on depth commits and is untouched by anchors. Depth nonces strictly increase; a same or older nonce is a no-op. Maker inventory stays in the maker's own provider contract (`IMMProvider`, reference implementation `BasicMMProvider`), which lets only the executor move it.

Two lanes fill through that door:

| Lane | Contract | Who uses it |
|---|---|---|
| Onchain | `PropAMMVenue`, one address per chain | Aggregator routers. `getPairs`, `isActive`, `quote`, `swap`, `swapWithFee`, `levels`, `board`, `makers`, `feeBps`. Every registered maker's board merged best price first; `quote` equals measured delivery. |
| Hosted | `PropAMMHostedSettlement` | End users, through the network. Signed intents are settled with steps that transfer the input to the executor and call `fill`; the signed `minAmountOut` is enforced on the receiver's balance. |

## For market makers

- Quote by streaming signed messages over a WebSocket. You send no transactions and hold no gas.
- Inventory stays in a contract you own and can withdraw from at any time. It releases tokens only to the executor, and the executor only fills against a board you signed, at your prices, within your TTLs and within the depth you signed.
- Exposure per depth version is its top size, once, however the flow is sliced or spread across blocks and callers.
- Move the price every block for the cost of one storage word by signing anchors; re-sign the depth schedule only when sizes, offsets or drift change.

## For aggregators

- Integrate one venue address per chain like any pool: read the merged book in one `eth_call`, fill with a push-payment `swap`. No API in the hot path.
- `quote` is the settlement arithmetic itself, net of the protocol fee, and a size the venue cannot cover reverts in both `quote` and `swap`.
- Take your own fee with `swapWithFee`, paid to your wallet in the same transaction.

## For users

- PropAMM prices reach you through the aggregators and interfaces you already use.
- You receive at least the minimum the route promised, measured on your own balance, or the trade reverts.

## Addresses

The same addresses are deployed on every chain.

| Contract | Address | Live on |
|---|---|---|
| `PropAMMExecutor` | `0x000000F80660419ECcED6F86dBc762725371eb56` | Base, BNB Smart Chain, Base Sepolia |
| `PropAMMVenue` | `0x000000445Dff11123a3BD8A4Dd03a351829aF892` | Base, BNB Smart Chain, Base Sepolia |
| `PropAMMHostedSettlement` | `0x0000009420a62D78de8bdCe89A12B8eccc37D19b` | Base, BNB Smart Chain, Base Sepolia |

The addresses are identical on Base (8453), BNB Smart Chain (56) and Base Sepolia (84532).

## Docs

- [docs/architecture.md](docs/architecture.md): the two lanes over one executor, boards, the fill door, the meter, trust boundaries.
- [docs/price-ladder-streaming.md](docs/price-ladder-streaming.md): what a maker signs and streams. Both message forms, the wire format, validation, nonces, TTLs, drift, expiry.
- [docs/integration.md](docs/integration.md): maker onboarding. The provider contract, the signing key, the stream, provider-side pricing on the hosted lane, inventory sizing, going dark.
- [docs/maker-quickstart.md](docs/maker-quickstart.md): the shortest path on Base Sepolia. Deploy `BasicMMProvider`, fund it, connect, stream, verify with `board()`.
- [docs/aggregator-api.md](docs/aggregator-api.md): the venue surface, the read pattern for trackers, the swap recipe, fees, the `PropAMMSwap` event.
- [docs/examples/](docs/examples/): `IMMProvider.sol`, `BasicMMProvider.sol` and a reference client that samples a pricing curve into a price ladder.

## Related

- [ERC-8211](https://erc8211.com/): composable batch steps, which the hosted lane can run as post-hooks.

## Maintainers

Maintained by [Biconomy](https://biconomy.io). Reach out at connect@biconomy.io.
