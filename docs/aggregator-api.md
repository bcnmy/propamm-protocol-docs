# Onchain integration for aggregators

PropAMM is proprietary market-maker liquidity that quotes and settles onchain. Routers integrate it the way they integrate any pool: read prices with an `eth_call`, fill with a deterministic push-payment swap. No API in the hot path, no per-trade requests, no signatures to carry.

One contract per chain, `PropAMMVenue`, merges every registered maker's board best price first and fills through `PropAMMExecutor`, the one contract that can reach maker inventory. The venue stores no prices: it reads each maker's board from the executor on every quote and swap, so what you simulate is what the fill door prices, same levels, same floor rounding, minus the maker's consumed meter and minus whatever that maker's own per-block limit has already used up.

## Addresses

| Contract | Base (8453), BNB Smart Chain (56) | Base Sepolia (84532) |
|---|---|---|
| `PropAMMVenue` | `0x000000c3380954F805699A363a25AB374ceEb792` | `0x00000035a8a58f704ab0D567D6c67A486428E35a` |
| `PropAMMExecutor` | `0x000000e5Ba94f47C0Fd723F56f1678a841fd33c9` | `0x000000fFA5f8Ae192Ab65204f9B7E062CbF4e05D` |

Base Sepolia runs a newer executor whose commit doors skip a faulty message and emit `CommitRejected` instead of reverting the batch. Base and BNB Smart Chain move to it at the same addresses on their next deploy.

## The surface

```solidity
// discovery
function getPairs() external view returns (TokenPair[] memory);              // 0x767eb5ef; struct TokenPair { address token0; address token1; }, token0 < token1
function makers() external view returns (address[] memory);                  // 0x84bd1e70; registered makers by signer address
function isMaker(address mm) external view returns (bool);                   // 0xe75600c3
function isActive(address tokenIn, address tokenOut) external view returns (bool); // 0xae131deb; any registered maker has remaining depth
function feeBps() external view returns (uint16);                            // 0x24a9d853; protocol fee in bps of gross output
function feeRecipient() external view returns (address);
function EXECUTOR() external view returns (address);

// reads
function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut); // 0xb6466384
function levels(address tokenIn, address tokenOut) external view returns (uint256[] memory cumSizes, uint256[] memory prices, uint256 earliestExpiry); // 0x501dc709
function board(address mm, address tokenIn, address tokenOut) external view returns (uint256[] memory sizes, uint256[] memory prices, uint256 filled, uint256 remaining, uint256 expiresAt); // 0xa5588684; `remaining` is already net of the maker's per-block limit

// writes
function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline) external returns (uint256 amountOut); // 0x9908fc8b
function swapWithFee(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline, uint256 extraFeePpm, address feeReceiver) external returns (uint256 amountOut); // 0xc13993c2
```

| Function | What it is |
|---|---|
| `getPairs()` | the advertised pairs in canonical token order; both directions of a pair are tradeable when a maker quotes them |
| `makers()` | the registered makers, by signer address; the registry is owner-curated and capped at 16 |
| `isActive(tokenIn, tokenOut)` | true when any registered maker has remaining depth for the direction |
| `quote(tokenIn, tokenOut, amountIn)` | the exact settlement arithmetic over the merged book, net of the protocol fee; reverts `Inactive` when the venue cannot cover the size |
| `levels(tokenIn, tokenOut)` | the merged cumulative ladder (cumulative sizes, a price per segment, the earliest expiry among the live boards) in one call |
| `board(mm, tokenIn, tokenOut)` | one maker's live levels, consumed meter, remaining fillable size and effective expiry, for routers running their own optimizer |
| `swap(...)` | push-payment fill across makers, `minAmountOut` on the total delivered to `recipient` |
| `swapWithFee(..., extraFeePpm, feeReceiver)` | the same, with your own fee paid to your wallet in the same transaction |

## What a board is

Every price onchain is a maker-signed board stored in the executor: cumulative sizes with a price per level (either signed absolutely, or as offsets below a maker-signed anchor that may widen with the anchor's age), a nonce and an expiry. Four properties follow, all contract-enforced:

- **Once-spent depth.** A board version can never fill more than its signed top size, across every caller and retry; the meter counts every fill and resets only when the maker commits a new depth version. What you read is what remains fillable.
- **Per-block limits.** A maker may sign a cap on the volume any single block may take from its board, and widening that grows with the quote's age or applies for a few blocks after it moves its price. All three only ever restrict a fill, and the cap is already netted into what you read: `remaining` is the smaller of the depth left and what the block has left under the cap, and the merge covers the rest of the order from other makers. The venue's own `quote` behaves as it does for any size it cannot cover: it reverts `Inactive` rather than returning a number, and only when the remaining makers cannot carry the order between them. You never have to model the limits yourself. The block's allowance behaves like depth: another trade landing ahead of yours can consume it, and the venue then routes around that maker or your floor reverts the swap, never fills it worse.
- **Expiry.** A board past its expiry stops quoting and stops filling. On an offset board the anchor has its own expiry and the board is dark when either has passed. `board()` and `levels()` report the effective expiry.
- **Quote parity.** `quote` replays the executor's per-level floor arithmetic, `out += floor(take * price / 1e18)`, over the same stored levels and the same meter. An `eth_call` on `swap` returns the exact amount a real transaction delivers on the same state.
- **Coverage.** A size is covered only if every maker it is allocated to would produce non-zero floored output. An allocation that floors to zero (a few wei landing on a maker at a sub-unit price) is dropped and the size is reported as not covered, so `quote` and `swap` both revert `Inactive` for the same sizes. The executor refuses to fill for nothing, and the venue never asks it to.

Boards are kept committed by the network. A direction whose makers have gone dark reads `isActive == false` rather than quoting numbers that will not fill.

## Read pattern for trackers

1. **Discovery.** `getPairs()` lists the advertised pairs; `makers()` the makers behind them. Pairs appear as makers join; a direction is live when `isActive` is true.
2. **Tracking.** Per refresh, either `levels(tokenIn, tokenOut)` for the merged ladder in one call, or `board(mm, tokenIn, tokenOut)` per maker in one multicall pinned to a block. Feed either to your simulator like any ladder-shaped source: cumulative sizes, a price per segment, floor division per segment. The merge is best price first, ties in registry order, each maker's consumed meter already netted.
3. **Freshness.** Offset boards re-price every second while their drift is non-zero, anchors may be committed every block, and a maker's per-block allowance resets with the block, so a read is exact for the block it was taken in. Re-read each block or on every `AnchorCommitted`, `LadderCommitted`, `OffsetsCommitted`, `ControlsCommitted` and `MMFillExecuted` event for the pairs you track. `earliestExpiry` from `levels` tells you when the merged book, as read, goes dark if nothing is committed.
4. **Simulation.** `quote` is the settlement arithmetic itself, protocol-fee-net. If you take your own fee, simulate `quote - quote * extraFeePpm / 1e6`; the contract performs the same integer operations, so the two agree to the wei.

## Swap recipe

Push payment: transfer exactly `amountIn` of `tokenIn` to the venue, then call `swap` or `swapWithFee` in the same transaction. Without the push, or with a short one, the call reverts when the venue forwards the input to the executor, before anything else moves. An over-push is not returned: the venue has no sweep, so the excess stays there and the next caller's swap spends it. Push the exact amount, atomically.

| Calldata bytes | Content |
|---|---|
| 0 to 3 | selector |
| 4 to 35 | `tokenIn` |
| 36 to 67 | `tokenOut` |
| 68 to 99 | `amountIn` |

`amountIn` sits at calldata byte offset 68 in both functions, so offset-splicing router actions that patch the input amount after an upstream hop work without custom encoding.

- `minAmountOut` is enforced on a measured balance delta, never a maker's reported number; a miss reverts `InsufficientOutput(delivered, minAmountOut)`. With both fees at zero the executor delivers straight to `recipient` and the delta is measured there. When a fee applies, the gross output lands at the venue, the delta is measured at the venue, the floor is checked on the fee-net amount, and that amount is then transferred to `recipient`. For a token that taxes transfers, that onward transfer is taxed once more, so the recipient receives less than the amount the floor checked. For such tokens set the floor with the tax in mind, or take your fee at your own router instead of through `swapWithFee`.
- `deadline == 0` disables the deadline check; otherwise `block.timestamp > deadline` reverts `DeadlinePassed`.
- `recipient` may not be zero or the venue itself (`BadRecipient`).
- The plan is recomputed at execution. A maker that expires or is exhausted between your quote and your swap is routed around if the rest cover the size; otherwise your floor reverts the swap. A board replaced by a better one delivers more; a worse one fails the floor. `swap` never accepts a size `quote` would refuse.
- The venue reverts `Inactive` before moving anything if the makers cannot cover `amountIn`. If a maker's provider reverts mid-execution, the executor's error bubbles through unchanged (`FillLegFailed`, `BoardInactive`, `LadderDepthExhausted`).
- With both fees at zero the executor delivers straight to `recipient` and the venue never touches the output. Both swaps are non-reentrant.

The worst case anywhere is a reverted transaction, never a bad fill.

## Fees

```
gross       = measured tokenOut balance delta of the delivery target
protocolFee = gross * feeBps / 10_000          feeBps is owner-set, capped at 100 bps; quote() is already net of it
net         = gross - protocolFee              what quote() returns
routerFee   = net * extraFeePpm / 1_000_000    your fee, swapWithFee only, capped at 50_000 ppm (5%)
amountOut   = net - routerFee                  what recipient receives; minAmountOut is checked here
```

`swapWithFee` pays `routerFee` to `feeReceiver` and `amountOut` to `recipient` in the same transaction. `extraFeePpm` above `50_000` reverts `ExtraFeeTooHigh`; a non-zero fee with a zero `feeReceiver` reverts `ZeroFeeReceiver`. There is no fee accrual and no claim function: the balance at `feeReceiver` is the ledger. Alternatively point `recipient` at your own router and take your cut there.

Neither fee touches what makers deliver; both come out of the taker's output. Read `feeBps()` rather than assuming it.

## Failure semantics

| Revert | Selector | Where | Meaning and action |
|---|---|---|---|
| `Inactive()` | `0x2e8acb0d` | `quote`, `swap`, `swapWithFee` | the registered makers cannot cover the size right now, or `amountIn` is zero; raised before any transfer. Route elsewhere |
| `InsufficientOutput(uint256 delivered, uint256 minAmountOut)` | `0x2c19b8b8` | swaps | the measured delivery missed your floor; the transaction reverts cleanly. Refetch |
| `DeadlinePassed()` | `0x70f65caa` | swaps | resubmit with a new deadline |
| `BadRecipient()` | `0x67a2cc26` | swaps | `recipient` is zero or the venue |
| `ExtraFeeTooHigh(uint256 extraFeePpm)` | `0x61539341` | `swapWithFee` | fee above 5% |
| `ZeroFeeReceiver()` | `0xb6802b7f` | `swapWithFee` | non-zero fee with no receiver |
| `FillLegFailed(address provider, bytes4 innerSelector, bytes inner)` | `0x33fd2c98` | executor, through the venue | a maker's provider reverted; `innerSelector` is its own selector. Transient: refetch and retry |
| `BoardInactive()` | `0x05f04ee8` | executor, direct `fill` only | a board went dark between your read and your fill. The venue plans and fills against the same reads inside one transaction, so its swaps raise `Inactive` instead |
| `LadderDepthExhausted()` | `0x3623b693` | executor, direct `fill` only | a leg ran past the version's remaining depth. Same reasoning: through the venue this is `Inactive` |
| `BlockCapExceeded(uint256 blockCap, uint256 attempted)` | `0x51c3dffc` | executor | a leg would take more than the maker allows in one block. Not reachable through `quote` and `swap`, which read the same bound; direct callers of `fill` should read `remaining` first |

## Events

Every user-facing trade on either lane emits one canonical event at the public entrypoint that settled it:

```solidity
event PropAMMSwap(
    address indexed sender,   // the calling router on the venue; the trader on the hosted lane
    address indexed receiver, // where tokenOut was delivered
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,        // measured delivery to receiver, fee-net
    bytes32 indexed lane      // entrypoint tag
);
```

| | Value |
|---|---|
| `topic0` | `0x20198e5e9a55297673b83a909cf489803a8e65b9b3b28f0336d7786201d88ced` |
| `lane` for venue swaps | `keccak256("propamm.lane.venue")` = `0x38bac6022d372bf52947085f84474211d0d8687b830ca07361b408294b503b24` |
| `lane` for hosted intents | `keccak256("propamm.lane.hosted")` = `0x31b7ece056a1abdd8bd77e942c4cc85ce61222caec6c666f01a980cd2b880cc3` |

The venue emits it once per swap however many makers filled it, and the hosted settlement once per settled intent, so summing one topic never double counts. Per-lane volume is a single indexed-topic filter; per-integrator attribution on the venue is `sender`.

Underneath, the executor emits `MMFillExecuted(address indexed mmProvider, address indexed mmSigner, address indexed receiver, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 avgPrice, uint128 filledAfter)` (`topic0` `0x5109ce085e22265a3a2f684f9491113ed3d388e9376388912537ddee1cd851c1`) once per maker leg. Use it for maker attribution, never add it to the `PropAMMSwap` total (a split is one trade and several fills), and note that its `amountOut` is the provider's reported figure, not a measured delta. Fees are ordinary `Transfer` events to `feeRecipient` and to your `feeReceiver`; there is no fee event.

Board commits emit on the executor: `LadderCommitted`, `OffsetsCommitted`, `AnchorCommitted` and `ControlsCommitted(address indexed mm, address indexed tokenIn, address indexed tokenOut, uint256 nonce, uint256 blockCap, uint32 widenPpmPerSqrtSecond, uint32 premiumPpm, uint16 premiumBlocks)` (`topic0` `0x69e8e8fb513d0e266a4625b592c740340ff2b78653cdc0ed28c76f82187cb04c`). A tracker that keeps a local book re-reads the affected pair on any of them.

Registry changes emit `MakerAdded(address indexed mm)`, `MakerRemoved(address indexed mm)`, `PairAdded(address indexed token0, address indexed token1)` and `ProtocolFeeUpdated(uint16 feeBps, address feeRecipient)`.

## Filling the executor directly

The executor's fill door is permissionless. A router that runs its own merge over per-maker `board()` reads can transfer `amountIn` to the executor and call `fill(address mm, address tokenIn, address tokenOut, uint256 amountIn, address receiver) returns (uint256 delivered)` (`0x3ad4d838`) per maker share in the same transaction. No venue fee applies on this path. Size each share against the `remaining` that `board()` reported, which already accounts for the maker's per-block limit; `controls(address mm, address tokenIn, address tokenOut)` (`0xa0459d51`) returns the limits and the block's tally if you want them separately. The return value is the provider's reported delivery; measure the receiver's balance delta if you enforce a floor, and note that the venue's `PropAMMSwap` is not emitted for direct fills.

## Testing on Base Sepolia

The venue on Base Sepolia advertises `MockWETH/MockUSDC` and `MockDAI/MockUSDC`; read `getPairs()` for the current list. All three test tokens have 18 decimals and are mintable by anyone through `mint(address,uint256)`:

| Token | Address |
|---|---|
| MockWETH | `0x8b414aD7005EeFd315aF2A16538885Eae229bab7` |
| MockUSDC | `0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df` |
| MockDAI | `0xa3Db3e064D74fF11e6E07b9869a67f1E4FCFEcFb` |

Consumption is permissionless; additional pairs are arranged with makers at their onboarding.

## Retail and intent flow

End-user flow routes through the hosted lane: signed intents settled by the network through `PropAMMHostedSettlement`, with the trader's `minAmountOut` enforced on the receiver's balance. Aggregators do not need it; it is described in [architecture.md](architecture.md).
