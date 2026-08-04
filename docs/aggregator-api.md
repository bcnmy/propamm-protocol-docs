# Biconomy PropAMM: Aggregator API

> PropAMM is RFQ-style maker liquidity that settles fully onchain: firm prices, no slippage curve, all-or-nothing fills, revert before funds move. You integrate it as a venue: we return a call list, you embed it in your own transaction and submit it yourself.

## Why route here

- **Cost advantage:** running a pair costs a maker close to nothing. MMs plug in with one small inventory contract and a signed-price stream: no per-venue contracts, no keeper bots, no standing onchain price feed to fund.
- **Support for many pairs:** that architecture makes stock pairs and long-tail pairs alike economical to quote, not just majors. You get firm RFQ prices on assets where you otherwise only find thin pools.
- **Better prices for users:** the same low cost per pair keeps maker spreads tight on everything they run: better execution on every route you send here.
- **User protection:** fills settle against the maker's freshest signed price, committed onchain in the same block as the fill. A stale or superseded quote reverts instead of filling, enforced by the contract, not by policy.
- **No MEV surface:** prices are firm, so there is no slippage curve to sandwich, and the same-block rule leaves no stale quote to snipe. Base's sequencer keeps its mempool private, so there is no pending-transaction feed for anyone to observe your calldata in.

| | |
|---|---|
| Base URL | `https://propamm-staging.biconomy.io/v1` |
| Chains | Base mainnet (8453), Base Sepolia (84532, test tokens) |
| Auth | None on staging; keys issued at production onboarding |

```
GET  /v1/health                -> chains and node status
GET  /v1/token-pairs           -> tradable pairs per chain
GET  /v1/firm-quote            -> price + executable call list
GET  /v1/levels                -> live maker price ladders (local pricing / orderbook-style)
```

## Integrating

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
  "amountOut": "2450123456",       // firm: delivered exactly, or the fill reverts
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
- **Deliver the input to settlement first.** The call list assumes `amountIn` of `tokenIn` is already at the settlement contract when the swap call runs, so transfer it in the same transaction, immediately before. This matches the venue-adapter convention where input tokens are transferred to the venue before it is called. If your router works differently, talk to us.
- `validUntil` is hard (typically tens of seconds out). Past or near it, refetch.
- Never replay an old response. Prices are versioned onchain; a superseded call list reverts instead of filling at a stale price.
- **We enforce a delivery floor onchain.** The call list carries `minAmountOut`, and settlement reverts unless `receiver`'s `tokenOut` balance grew by at least that much. You do not have to add your own min-received wrapper, though keeping one costs nothing.
- Size is bounded by maker inventory. If the bound moves before settlement the fill reverts; there are no partial fills.

Re-check the price on the second call before you commit. The two calls happen at different times and the preview `amountOut` is not a hold - makers stream fresh signed prices continuously. Compare the second call's `amountOut` against your preview: same or better, proceed; worse but inside your slippage tolerance, proceed; worse than your tolerance, fall back to your second-best route from preview time. We do not perform this check for you - a `calls` array quoting worse than your preview is still valid and will execute if you submit it.

Depth can move after you submit. Between broadcast and landing, other fills against the same maker's inventory in the same block can consume depth your quote was priced against. That is not a price change you would have seen - it is an onchain state change, and if enough depth is consumed your transaction reverts rather than delivering less. Treat it as distinct from the price re-check: on a revert, do not retry the same `calls`; call `/v1/firm-quote` again and resubmit fresh.

## Price levels feed

For integrators that compute route prices locally (orderbook-style consumption) instead of
calling a quote API in the routing hot path:

```
GET /v1/levels?chainId=8453&tokenIn=0x..&tokenOut=0x..
```

```jsonc
{
  "chainId": 8453,
  "tokenIn": "0x..",
  "tokenOut": "0x..",
  "merged": [                        // the venue book: one already-merged view across makers,
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
      "expiresAt": 1784889564,       // unix seconds; expired makers are filtered server-side
      "lotSize": "100000000000000",  // present only for venue-backed makers: execution granularity
      "lotSide": "in"                // which side of THIS direction the grid applies to
    }
  ],
  "asOf": 1784889534
}
```

Most consumers read `merged` like an orderbook: consume prefix-first until your size is covered;
the per-segment attribution gives each maker's consumed amount, which maps to one fill leg. To
reproduce executed prices exactly, apply the onchain sweep per maker: sum floor(take * price /
1e18) over its consumed tranches, then avg = floor(totalOut * 1e18 / amountIn) and delivered =
floor(amountIn * avg / 1e18).

Honest semantics of this feed: prices are INDICATIVE and GROSS OF GAS (apply your own gas model
for ranking, as for any venue), and ladder sizes are maker price commitments, not solvency
proofs. Execution and feasibility live in `/v1/firm-quote`, which simulates the real call and re-resolves
the freshest ladder at build time.

When a maker publishes `lotSize`, it fills through a venue that executes in whole lots, so a fill
amount off that grid can deliver slightly less than the ladder implies and revert. Snap the fill to
the grid (`lotSide: "in"` snaps `amountIn`; `"out"` snaps the deliverable output) and the remainder
stays with the payer. At normal routing sizes the effect is under a basis point and can be ignored;
it only matters for small trades. `/v1/firm-quote` handles this for you.

## Adding your fee

You hold the flow, so take your fee yourself: point `receiver` at your own contract, keep your cut, forward the rest. The full `amountOut` is delivered to whichever `receiver` you pass, so nothing needs coordinating with us and there is nothing to reconcile.

## Contracts

Identical addresses on Base mainnet (8453) and Base Sepolia (84532):

| Contract | Address |
|---|---|
| PropAMMSettlement (you call this) | `0x0000000030AD6bFE5f66fC7c05FA849e3A5FAEd3` |
| PropAMMExecutor (fills route through it) | `0x000000004D941fc97c6d29d466FdF8Fd93Ab20a6` |

The call list we return targets settlement. You never need to encode it yourself, but for reference the
entrypoint is:

```solidity
struct SwapParams {
    address tokenIn;       // address(0) for native ETH, arriving as msg.value
    address tokenOut;      // address(0) for native ETH
    uint256 amountIn;
    uint256 minAmountOut;  // enforced onchain against receiver's balance delta
    address receiver;
}

struct Step { address to; uint256 value; bytes data; bool isDelegatecall; }

function swap(SwapParams calldata p, Step[] calldata steps)
    external payable returns (uint256 delivered);
```

Volume is observable from one event, indexed on caller and pair:

```solidity
event SwapExecuted(
    address indexed caller,
    address indexed tokenIn,
    address indexed tokenOut,
    address receiver,
    uint256 amountIn,
    uint256 amountOut,
    uint256 steps
);
```

## Behavior

| Property | Behavior |
|---|---|
| Price firmness | Exactly `amountOut` delivered at settlement, or revert |
| Freshness | Enforced onchain; stale or superseded quotes cannot fill |
| Partial fills | None |
| Failure cost | Revert before any funds move; a failed fill costs only gas |
| Fees | None; the quoted price is the full economics |

## Testing

Base Sepolia is live end to end with mintable test tokens: MockWETH `0x8b414aD7005EeFd315aF2A16538885Eae229bab7`, MockUSDC `0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df` (`mint(address,uint256)`, open). Base mainnet quoting is live against verified contracts.

Production onboarding (API keys, pairs, inventory scope): reach out and we will scope it together.

## Pricing and fairness under the hood

Three protocol properties worth knowing when you evaluate us:

- **Nobody picks the price, including us.** Quotes come from market-maker signed price levels (standard RFQ levels), and the level applied to a fill is resolved on chain from cumulative filled volume. Committed levels ride in public calldata, so any execution price is recomputable by anyone from the transaction alone.
- **No sandwich surface.** Fills execute against prices signed before the transaction and touch no AMM curve, so there is no slippage to extract. Base's sequencer keeps its mempool private, so your calldata is not observable while pending, and the same-block rule means a ladder is dead the moment its block closes.
- **The floor is contractual.** `minAmountOut` is enforced against the receiver's own balance delta. A trade reverts rather than filling worse, and a revert costs only gas because nothing moves before the check.
