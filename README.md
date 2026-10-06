# Biconomy PropAMM

PropAMM lets a market maker run a proprietary AMM onchain from a signed price stream. The maker signs boards and keeps inventory in its own contract. The protocol stores the boards onchain, prices and meters every fill, enforces the maker's own risk limits, and exposes the merged liquidity to aggregators as one pool contract per chain and to end users through hosted settlement of signed intents.

## The protocol in one paragraph

A maker signs, per pair and direction, either a price ladder (cumulative sizes with absolute prices, 1e18-scaled tokenOut per tokenIn) or an offset ladder (cumulative sizes with offsets in parts per million below an anchor, with optional drift widening per second of anchor age) plus pair anchors (the reference price for both directions of a pair, ordered by a millisecond timestamp and with its own TTL, signed as often as every block, every pair the maker quotes under one signature). It may also sign one `BoardControls` message per board that caps how much a single block may take and widens the price with quote age and just after a price move. Anyone may commit those messages to `PropAMMExecutor` through `updatePrices`, `updateOffsets`, `updateAnchors` and `updateControls`; in practice the network does. The executor stores the whole board at commit and fills through one door, `fill(mm, tokenIn, tokenOut, amountIn, receiver)`, sweeping a cumulative meter that resets on depth commits and is untouched by anchors. Depth nonces, controls nonces and anchor timestamps strictly increase; a same or older one is a no-op, and a malformed, expired or badly signed message is skipped on its own with `CommitRejected` while the rest of the batch lands. Maker inventory stays in the maker's own provider contract (`IMMProvider`, reference implementation `BasicMMProvider`), which lets only the executor move it.

Two lanes fill through that door:

| Lane | Contract | Who uses it |
|---|---|---|
| Onchain | `PropAMMVenue`, one address on every chain | Aggregator routers. The `IPropAMM` pool interface (`getPairs`, `isActive`, `quote`, `swap`, the `Swapped` event) plus `IPropAMMFillable` (`quoteFillable`) and ERC-165, and `swapWithFee`, `levels`, `board`, `makers`, `feeBps`. Every registered maker's board merged best price first; `quote` equals measured delivery. |
| Hosted | `PropAMMHostedSettlement` | End users, through the network. Signed intents are settled with steps that transfer the input to the executor and call `fill`; the signed `minAmountOut` is enforced on the receiver's balance. |

## For market makers

- Quote by streaming signed messages over a WebSocket. You send no transactions and hold no gas.
- Inventory stays in a contract you own and can withdraw from at any time. It releases tokens only to the executor, and the executor only fills against a board you signed, at your prices, within your TTLs and within the depth you signed.
- Exposure per depth version is its top size, once, however the flow is sliced or spread across blocks and callers.
- Cap what a single block can take from a board, so one block of adverse flow is bounded even when your stream is behind.
- Make a stale quote cost more: the price widens with the square root of the quote's age, and carries a premium for the first blocks after you move it.
- Move the price every block for the cost of one storage word per pair by signing anchors: one signature covers every pair you quote, and one entry prices both directions of a pair, each side with its own skew. Re-sign the depth schedule only when sizes, offsets or drift change.

## For aggregators

- Integrate one venue address, the same on every chain, like any pool: read the merged book in one `eth_call`, fill with a push-payment `swap`. No API in the hot path. The venue implements the `IPropAMM` pool interface and `IPropAMMFillable`, reports both through ERC-165, and emits the standard `Swapped` event.
- `quote` is the settlement arithmetic itself, net of the protocol fee, and a size the venue cannot cover reverts in both `quote` and `swap`. `quoteFillable` returns how much of an order the venue fills and the output for exactly that amount, so a splitting router sizes it in one call.
- A maker's per-block limit is already netted into what you read: `remaining` and `quote` report what is fillable in this block, not what the ladder holds.
- Take your own fee with `swapWithFee`, paid to your wallet in the same transaction.

## For users

- PropAMM prices reach you through the aggregators and interfaces you already use.
- You receive at least the minimum the route promised, measured on your own balance, or the trade reverts.

## Addresses

Same addresses on Base (8453), BNB Smart Chain (56) and Base Sepolia (84532):

| Contract | Address |
|---|---|
| `PropAMMExecutor` | `0x000000Bb60AAE6f25cBD9Fc63BB677AB5b8C23dC` |
| `PropAMMVenue` | `0x0000008792fE035f85b03593e10cF8ee59e69Fa2` |
| `PropAMMHostedSettlement` | `0x0000002E6a90921B97A933deA6600f5e534f56b8` |

## Docs

- [docs/architecture.md](docs/architecture.md): the two lanes over one executor, boards, board controls, the fill door, the meter, trust boundaries.
- [docs/price-ladder-streaming.md](docs/price-ladder-streaming.md): what a maker signs and streams. All message forms, the wire format, validation, nonces, TTLs, drift, expiry.
- [docs/integration.md](docs/integration.md): maker onboarding. The provider contract, the signing key, the stream, risk controls, provider-side pricing on the hosted lane, inventory sizing, going dark.
- [docs/maker-quickstart-base-weth-usdc.md](docs/maker-quickstart-base-weth-usdc.md): the shortest path on Base Sepolia. Deploy `BasicMMProvider`, fund it, connect, stream, set your risk limits, verify with `board()`.
- [docs/aggregator-api.md](docs/aggregator-api.md): the venue surface, the read pattern for trackers, the swap recipe, fees, the `Swapped` and `PropAMMSwap` events.
- [docs/examples/](docs/examples/): `IMMProvider.sol`, `BasicMMProvider.sol`, `RouterVaultProvider.sol` (for makers who keep inventory in their own vault) and a reference client that samples a pricing curve into a price ladder.

## Related

- [ERC-8211](https://erc8211.com/): composable batch steps, which the hosted lane can run as post-hooks.

## Maintainers

Maintained by [Biconomy](https://biconomy.io). Reach out at connect@biconomy.io.
