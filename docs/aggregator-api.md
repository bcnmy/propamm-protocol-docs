# Biconomy PropAMM: Onchain Integration

> PropAMM is proprietary market-maker liquidity that quotes and settles fully onchain. Routers
> and aggregators integrate it the way they integrate any pool: read prices with an `eth_call`,
> fill with a deterministic onchain swap. No API in the hot path, no per-trade requests, no
> off-chain quote pipeline to keep alive.

## Properties

- **Firm prices, no slippage curve.** Fills settle against maker-signed prices with
  contract-enforced floors: all-or-nothing, revert before funds move, nothing to sandwich.
- **Low cost per pair.** A maker runs a pair with one inventory contract and a signed price
  stream; the network runs the board, the freshness, and the settlement. Long-tail pairs are
  economical to quote.
- **Permissionless consumption.** No per-consumer keys, signed reads, or allowlists.
  Integrate once; every maker who joins afterwards reaches you with no further work.

## The surfaces

| Contract | What it is |
|---|---|
| `PropAMMPool` | one maker's live board behind the standard prop-AMM pool interface: `getPairs`, `isActive`, `quote`, `swap` |
| `PropAMMVenue` | ONE pool, one interface, the whole venue: merges every member maker and splits fills across them internally |
| `PropAMMLens` | the read surface: every maker's live, unexpired board for a direction, merged, in one `eth_call` |

Deployed addresses are provided at onboarding.

## What a board is

Every price onchain is a maker-signed ladder: cumulative sizes and prices, a nonce, and an
expiry, committed under the maker's signature and mirrored into the pool. Three properties
follow, all contract-enforced:

- **Once-spent budgets.** A board version can never fill more than its signed top level,
  across every route and retry. What you read is what remains fillable.
- **Expiry.** A board past its `expiresAt` stops quoting and stops filling. Staleness is
  bounded by the maker's own signed window.
- **Simulation parity.** `quote` is the executor's exact settlement arithmetic. An `eth_call`
  on `swap` returns the exact amount a real transaction delivers on the same state: what you
  simulate is what you settle.

Boards are kept fresh onchain by the network's heartbeat. A direction with degraded pricing or
exhausted maker inventory goes dark (`isActive` false) rather than quoting numbers that will
not fill: an inactive board is the system working, never quote around it.

## Integration recipe

1. **Discovery.** `venue.getPairs()` (or `lens.pools()` for per-maker granularity) lists the
   tradeable pairs. Pairs appear and disappear as makers join and boards go live or dark.
2. **Tracking.** Per refresh, read the merged board in one call: `lens.merged(tokenIn,
   tokenOut)` or `venue.levels(tokenIn, tokenOut)` returns cumulative sizes, prices, and the
   earliest expiry. Feed it to your simulator like any ladder-shaped source.
3. **Execution.** Push-payment, UniV2-style: transfer `amountIn` of `tokenIn` to the venue,
   then call `swap(tokenIn, tokenOut, amountIn, minAmountOut, recipient, deadline)` in the
   same transaction. The venue splits across member pools internally and enforces
   `minAmountOut` on the TOTAL delivered. A `deadline` of 0 disables the deadline check.

Delivery floors are yours: a fill that cannot meet your `minAmountOut` reverts atomically.
The worst case anywhere is a reverted trade, never a bad fill.

## Fees (onchain lane)

Point `recipient` at your own router and take your fee on the delivered amount before
forwarding: the venue delivers the full output wherever you direct it.

## Firm quotes over REST (RFQ-style routers)

The same maker stream also serves classic firm quotes for routers that fetch calldata per
trade. The quote window is priced by the MAKER: long-TTL signed ladders exist because a maker
chose to sign them, so the spread on this lane is the maker's own risk price, not a network
markup. Everything below settles through the same contracts, budgets and floors as every
other lane.

You submit your own transaction (router, solver, settlement contract). Gas, submission and transaction construction are yours; we return calldata that is valid to execute.

```
GET /v1/firm-quote?chainId=8453&tokenIn=0x..&tokenOut=0x..
    &amountIn=1000000000000000000&receiver=0xWhereTokenOutGoes
```

```jsonc
{
  "quoteId": "0x7f3a...",          // deterministic: keccak256 of the calls payload
  "gasEstimate": "365000",         // indicative, for your tx budgeting (you pay your own gas)
  "chainId": 8453,
  "amountIn": "1000000000000000000",
  "amountOut": "2450123456",       // firm floor: delivered at least (more if the maker improved), or revert
  "receiver": "0x...",
  "calls": [                       // opaque; execute in order, inside ONE transaction
    { "to": "0x...", "value": "0", "data": "0x..." },
    { "to": "0x...", "value": "0", "data": "0x..." },
    { "to": "0x...", "value": "0", "data": "0x..." }
  ],
  "validUntil": 1751536030         // unix seconds
}
```

Call it twice:

1. **When comparing quotes:** read `amountOut`, discard the rest.
2. **When building the transaction, immediately before broadcast:** call again and embed this response's `calls`.

Only the second response goes onchain. Responses are stateless and free; there is nothing to reserve or cancel.

Rules:

- Execute `calls` in order, all inside one transaction.
- **Deliver the input to settlement first.** The call list assumes `amountIn` of `tokenIn` is already at the settlement contract when the swap call runs. Two conventions, both supported, nothing to declare:
  - **Push (recommended):** transfer `amountIn` to settlement in the same transaction, immediately before the calls. Native ETH input instead arrives as `msg.value` on the swap call itself. This is the standard venue-adapter convention.
  - **Pull:** approve settlement and prepend your own `transferFrom(you, settlement, amountIn)` step. Keep that approval exact-amount and same-transaction: never grant settlement a standing allowance from a fund-holding address, the same caveat every arbitrary-call executor carries.
- **Treat `400 No routes found` as a decline.** Sizes below a maker's minimum, above available depth, or hitting a momentary maker gap return no quote rather than a degraded price. Route the trade elsewhere and retry later.
- `validUntil` is hard (typically tens of seconds out). Past or near it, refetch.
- Never replay an old response. Prices are versioned onchain and a superseded call list can never fill at its stale price: it settles at the maker's freshest committed price under the same floor, and past `validUntil` it reverts. Refetch instead.
- **We enforce a delivery floor onchain.** The call list carries `minAmountOut`, and settlement reverts unless `receiver`'s `tokenOut` balance grew by at least that much. You do not have to add your own min-received wrapper, though keeping one costs nothing.
- Size is bounded by maker inventory. If the bound moves before settlement the fill reverts; there are no partial fills.

Re-check the price on the second call before you commit. The two calls happen at different times and the preview `amountOut` is not a hold - makers stream fresh signed prices continuously. Compare the second call's `amountOut` against your preview: same or better, proceed; worse but inside your slippage tolerance, proceed; worse than your tolerance, fall back to your second-best route from preview time. We do not perform this check for you - a `calls` array quoting worse than your preview is still valid and will execute if you submit it.

Between broadcast and landing: if the maker re-streams a better price while your transaction is in flight, the fill settles at that fresher price and your user keeps the difference. If the maker re-streams worse, the floor in your calldata decides: within it the fill lands, below it the transaction reverts and you refetch. In-flight maker updates never burn your transaction on their own.

Depth can move after you submit. Between broadcast and landing, other fills against the same maker's signed ladder can consume depth your quote was priced against. Depth consumption is onchain state, invisible at quote time; if enough is consumed your transaction reverts rather than delivering less. On a revert, do not retry the same `calls`; call `/v1/firm-quote` again and resubmit fresh.

## Scaled quotes (one-offset partial fill)

Add `&scaled=true` to `/v1/firm-quote`. Alongside the normal `calls[]` you get:

```jsonc
"scaled": {
  "router": "0x0000004c86FBE08cC6A39c6D4C87b59F71dE31bc", // the scaled settlement; approve it for tokenIn
  "calldata": "0x...",
  "amountInOffset": 68,           // constant, forever: rewrite the 32 bytes here
  "quotedAmountIn": "1000000000000000000",
  "feeSalt": "0x..."              // present on fee quotes; reconciliation key
}
```

`calls` and `scaled` are alternative executions of one quote - run one, never both. Semantics:

- your `rfq_sender` approves `router` for `tokenIn`; the settlement PULLS the (possibly
  patched) amount - no pre-transfer, no second offset
- patch DOWN: the delivery floor scales proportionally with the patched size
- patch UP: the quoted floor holds absolutely (ladders deliver sublinearly upward, so a
  proportional floor would spuriously revert honest fills); output is priced by the maker's
  real signed rungs. Patching above the maker's signed depth reverts the whole transaction -
  the outcome partial-success routing expects
- fee quotes: the fee scales pro-rata with the patched size; the ratio is fixed inside our
  signature and cannot be changed by editing calldata. `AggregatorFeeCharged(token,
  feeReceiver, fee, salt)` carries the ACTUAL charged amount for reconciliation
- multi-maker legs and multihop chains are handled inside the calldata; one offset is always
  enough

## Adding your fee

Two ways, both supported. Pick either.

**1. Take it yourself (nothing to coordinate).** You hold the flow: point `receiver` at your own contract, keep your cut, forward the rest. The full `amountOut` is delivered to whichever `receiver` you pass, so there is nothing to reconcile with us.

**2. Have settlement collect it.** If you would rather not run a splitter contract, settlement can take your fee inside the same swap and pay it to your fee wallet atomically. Add two parameters:

| Param | Meaning |
|---|---|
| `feeAmount` | your fee, as an absolute amount in **`tokenOut` units** |
| `taker` | the address that will submit the transaction - your executor / `rfq_sender`. Required alongside `feeAmount`, must be non-zero, and must be the `msg.sender` that executes |
| `feeReceiver` | optional. Your fee wallet. Omitted, the fee goes to a default wallet configured on our side, so pass it explicitly to collect to your own. Signed into the fee terms either way, so it cannot be altered in the calldata afterwards |
| `funding` | optional, `pull` (default) or `push`. See the execution notes below |

```
GET /v1/firm-quote?chainId=8453&tokenIn=0x..&tokenOut=0x..
    &amountIn=100000000000000000&receiver=0xUser
    &feeAmount=100000&taker=0xYourExecutor
```

Every amount in the response is **net of your fee**, and a `fee` object is added:

```jsonc
{
  "amountOut": "189716044",      // NET - what receiver actually gets
  "minAmountOut": "187818883",   // delivery floor, enforced onchain on the NET
  "fee": {
    "amount": "100000",          // your fee, in tokenOut units
    "salt": "0xabd2..9fd4",      // reconciliation key, see below
    "taker": "0x.."
  },
  "calls": [ { "to": "0x<settlement>", "value": "0", "data": "0x.." } ]
}
```

What differs at execution:

- The call list targets `swapWithFee` rather than `swap`.
- **The calldata we return pulls the input from `taker`.** The `calls` include a `transferFrom(taker, settlement, amountIn)` step, so approve `amountIn` of `tokenIn` to settlement (exact-amount, same transaction). The pull step is part of the route we build; the contract itself also settles pre-funded push routes. If push suits your adapter better, tell us and we will return push-shaped calldata for your key.
- **Whichever address calls settlement must be the `taker` you passed to `/v1/firm-quote`.** The fee terms are bound to it and a call from any other address reverts. Under the push convention that is your router or executor contract, not the end user's wallet. This binding is what stops a third party from consuming the quote's single-use `salt` before you land it.
- The route leaves the gross output at settlement, which pays your `feeAmount` to your fee wallet and the remainder to `receiver`, atomically. The delivery floor applies to the net, so your user is never delivered below the quoted floor.
- The fee terms are signed by us (EIP-712, single-use) and cannot be edited out of the calldata; a route that would not leave the fee at settlement reverts instead. Execute our calldata as returned.

Each fill emits `AggregatorFeeCharged(token, feeReceiver, fee, salt)`. The `salt` returned with your quote is the join key between issued quotes and collected fees, so reconciliation reads off chain state. Volume reports via `SwapExecuted` on the gross `amountIn` and via the canonical `PropAMMSwap` event (see Fill events below); the fee is a separate event and is not double counted.

Pass `feeReceiver` to name your fee wallet on each request. Omitted, the fee goes to a default wallet configured on our side, so pass it explicitly if you want the fee to land in your own. `feeAmount` is absolute rather than a rate because the rate and its rounding are yours to decide. Omit these parameters entirely if you do not use this option.

## Price levels feed

For integrators that compute route prices locally (orderbook-style consumption) instead of
calling a quote API in the routing hot path:

```
GET /v1/levels?chainId=8453&tokenIn=0x..&tokenOut=0x..
```

To fetch the whole chain in one request, omit the pair. The response carries every direction
the chain quotes, each entry with its own `tokenIn`, `tokenOut`, `merged` and `makers` in the
same shapes documented below:

```
GET /v1/levels?chainId=8453
```

```jsonc
{
  "chainId": 8453,
  "pairs": [
    { "tokenIn": "0x..", "tokenOut": "0x..", "merged": [ ... ], "makers": [ ... ] }
  ],
  "asOf": 1784889564
}
```

One poll per chain replaces one poll per direction; both forms serve the same data with the
same freshness.

```jsonc
{
  "chainId": 8453,
  "tokenIn": "0x..",
  "tokenOut": "0x..",
  "merged": [                        // the venue book: one merged view of all available liquidity,
    {                                // sorted best price first (highest tokenOut per tokenIn)
      "mm": "0x..",                  // per-segment maker attribution
      "price": "1878336917143556231943",   // 1e18-scaled tokenOut-wei per tokenIn-wei
      "size": "1000000000000000000",       // this segment's marginal size (tokenIn wei)
      "cumulativeSize": "1000000000000000000"
    }
  ],
  "makers": [                        // each maker's independent SIGNED ladder, for verification
    {                                // and custom routing (level counts differ per maker)
      "mm": "0x..",
      "inventoryContract": "0x..",
      "levels": [ { "size": "..", "price": ".." } ],   // cumulative sizes, ascending
      "nonce": "..",
      "expiresAt": 1784889564,       // unix seconds
      "minFill": "2000000000",       // smallest fill this maker executes
      "lotSize": "100000000000000",  // present only for venue-backed makers: execution granularity
      "lotSide": "in"                // which side of THIS direction the grid applies to
    }
  ],
  "minQuote": "1",                   // smallest amountIn currently servable for this pair
  "asOf": 1784889534
}
```

Most consumers read `merged` like an orderbook: consume prefix-first until your size is covered;
the per-segment attribution gives each maker's consumed amount, which maps to one fill leg. To
reproduce executed prices exactly, apply the onchain sweep per maker: sum floor(take * price /
1e18) over its consumed tranches, then avg = floor(totalOut * 1e18 / amountIn) and delivered =
floor(amountIn * avg / 1e18).

The book is filtered to what `/v1/firm-quote` will serve your key at response time: makers too
stale for your key's quote floor are excluded, advertised depth is capped at what route
construction can allocate across the live makers, and `minQuote` is the smallest servable
size. Prices are indicative and gross of gas (apply your own gas model for ranking, as for
any venue); execution goes through `/v1/firm-quote`, which simulates the real call and
re-resolves the freshest ladder at build time.

When a maker publishes `lotSize`, it fills through a venue that executes in whole lots, so a fill
amount off that grid can deliver slightly less than the ladder implies and revert. Snap the fill to
the grid (`lotSide: "in"` snaps `amountIn`; `"out"` snaps the deliverable output) and the remainder
stays with the payer. At normal routing sizes the effect is under a basis point and can be ignored;
it only matters for small trades. `/v1/firm-quote` handles this for you.

## Behavior

| Property | Behavior |
|---|---|
| Price firmness | At least `amountOut` delivered at settlement (more if the maker improved in flight), or revert |
| Freshness | Enforced onchain; an expired quote cannot fill, and a superseded quote settles at the freshest committed price under the same floor |
| Partial fills | None |
| Failure cost | Revert before any funds move; a failed fill costs only gas |
| Declines | Unquotable sizes return `400 No routes found`, never a worse price |
| Fees | None charged by the protocol. Optionally, your own fee collected inside the swap (`feeAmount` + `taker`) and paid to your fee wallet |

## Fill events (indexing)

Every fill, on every lane, emits one canonical event at the public entrypoint that settled it:

```solidity
event PropAMMSwap(
    address indexed sender,   // caller of the entrypoint
    address indexed receiver, // where tokenOut was delivered
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,        // actually delivered
    bytes32 indexed lane
);
```

`topic0 = 0x20198e5e9a55297673b83a909cf489803a8e65b9b3b28f0336d7786201d88ced`. The `lane` tag
is `keccak256` of `propamm.lane.hosted` / `propamm.lane.venue` / `propamm.lane.self` /
`propamm.lane.adapter`, so per-lane volume attribution is a single indexed-topic filter.
Aggregating wrappers never emit it, so summing one topic can never double count. Legacy
per-lane events (`SwapExecuted`, `IntentSettled`) continue to fire unchanged.

## Testing

Base Sepolia is live end to end with mintable test tokens: MockWETH `0x8b414aD7005EeFd315aF2A16538885Eae229bab7`, MockUSDC `0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df` (`mint(address,uint256)`, open).

Pairs quoting on mainnet, both directions:

| Chain | Pairs |
|---|---|
| Base (8453) | WETH/USDC, cbBTC/USDC, cbBTC/WETH |
| BNB Smart Chain (56) | WBNB/USDT, BTCB/USDT |

API keys, additional pairs and inventory scope are arranged at onboarding.

## How pricing is determined

- **Prices come from makers.** Quotes are built from maker-signed price levels, and the level applied to a fill is resolved onchain from cumulative filled volume. Committed levels travel in public calldata, so any execution price is recomputable from the transaction alone.
- **Nothing is priced against a curve.** Fills execute against prices signed before the transaction, so there is no slippage to extract. A ladder is unusable once it expires or once a fresher one is committed and live, and execution always prices from the maker's freshest committed, unexpired ladder.
- **The floor is enforced by the contract.** `minAmountOut` is checked against the receiver's balance delta. A trade reverts rather than filling worse, and a revert costs only gas because nothing moves before the check.

## Retail and intent flow

End-user flow routes through the hosted lane: gasless signed intents, settlement-enforced
floors, submission handled by the network. Aggregators do not need it; it is described in
[architecture.md](architecture.md) for completeness.
