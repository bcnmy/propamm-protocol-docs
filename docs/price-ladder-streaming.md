# Streaming boards

How a maker's prices reach the chain. You sign small EIP-712 messages that describe a board, one per pair and direction, and send them over a WebSocket. The network validates them, stores them and commits them to `PropAMMExecutor`, which holds one board per `(mm, tokenIn, tokenOut)` and prices every fill from it. You send no transactions and pay no gas. Onboarding, the provider contract and endpoints are in [integration.md](integration.md); this page is the message spec.

## Two forms of a board

| Form | Messages | When to use |
|---|---|---|
| Price ladder | `PriceLadder`: cumulative sizes with absolute 1e18-scaled prices | Your engine emits absolute prices by size and you are willing to re-sign the whole ladder on every price change |
| Offset ladder plus pair anchor | `OffsetLadder`: cumulative sizes with discounts below a reference price, plus a drift rate; `AnchorBatch`: the reference price of every pair you quote, one entry per pair, both directions of a pair from one entry, under one signature | Sizes and discounts change rarely, the price changes often. One anchor commit is one storage word per pair and never re-opens consumed depth |

Either form may carry a fourth message, `BoardControls`, the risk limits the executor applies to every fill of that board. It is optional, has its own nonce sequence, and outlives depth and anchor commits. See [board controls](#board-controls).

A price ladder and an offset ladder are both depth versions of the board and share one nonce sequence. A new depth version must carry a strictly higher nonce, replaces every level, rebinds the provider and resets the board's fill meter. Anchors are ordered by their own millisecond timestamp, per pair, and never touch the meter. An offset board quotes only while both its ladder and its pair anchor are unexpired. You choose the form per pair and direction and may switch in either order: an anchor committed while the board is a price ladder is stored and unused until an offset ladder arrives; a price ladder committed over an offset board replaces it and ignores the stored anchor. Either switch is a depth commit and resets the meter.

## What you sign

Every message is signed against the executor's EIP-712 domain. The executor address is the same on Base, BNB Smart Chain and Base Sepolia, so only `chainId` changes between chains.

| Field | Value |
|---|---|
| `name` | `PropAMMExecutor` |
| `version` | `2` |
| `chainId` | the chain the board lives on |
| `verifyingContract` | `0x000000Bb60AAE6f25cBD9Fc63BB677AB5b8C23dC` |

The digest your key signs is `keccak256(0x1901 || domainSeparator || structHash)`. `executor.DOMAIN_SEPARATOR()` returns the separator, and the executor exposes the exact digests (`ladderDigest`, `offsetLadderDigest`, `anchorBatchDigest`, `controlsDigest`) and struct hashes (`hashLadder`, `hashOffsetLadder`, `hashAnchorEntry`, `hashAnchorBatch`, `hashControls`) as views, so you can check a signer implementation against the contract without a transaction. Signatures are verified with `isValidSignatureNow(mm, digest, sig)`: a 65-byte ECDSA signature from an EOA `mm`, or any bytes an EIP-1271 contract at `mm` accepts.

Structs, with field order as the encoding order:

```solidity
struct Level {
    uint256 size;   // cumulative tokenIn volume available up to this level
    uint256 price;  // 1e18-scaled tokenOut per tokenIn for volume landing in this level
}

struct PriceLadder {
    address mm;        // signing address; the board key, and the recovered signer of this ladder
    address provider;  // the IMMProvider contract that must fill it; signed, so callers cannot swap it
    address tokenIn;   // pair token in, a real ERC20 address
    address tokenOut;  // pair token out
    Level[] levels;    // ascending cumulative sizes, prices non-improving with depth
    uint256 nonce;     // depth nonce, strictly increasing per (mm, tokenIn, tokenOut)
    uint256 expiresAt; // unix seconds; wall-time TTL on the signed ladder
}

struct Rung {
    uint256 size;       // cumulative tokenIn volume available up to this rung
    uint256 offsetPpm;  // discount below the anchor, parts per million
}

struct OffsetLadder {
    address mm;                 // signing address; the board key and the recovered signer
    address provider;           // the IMMProvider contract that fills this board
    address tokenIn;            // pair token in
    address tokenOut;           // pair token out
    Rung[] rungs;               // ascending cumulative sizes, offsets non-decreasing with depth
    uint256 nonce;              // depth nonce, shared with price ladders for the same board
    uint256 expiresAt;          // unix seconds; wall-time TTL on the schedule
    uint256 driftPpmPerSecond;  // offset widening per second of anchor age; 0 for none
}

struct AnchorEntry {
    address tokenIn;        // the direction `price` is quoted for
    address tokenOut;
    uint256 price;          // 1e18-scaled tokenOut per tokenIn
    uint256 timestampMs;    // unix milliseconds the maker priced this anchor; strictly increasing per pair
    uint256 ttl;            // seconds the anchor lives after timestampMs
    uint256 skewPpm;        // extra discount on the tokenIn -> tokenOut side, ppm
    uint256 reverseSkewPpm; // extra discount on the tokenOut -> tokenIn side, ppm
}

struct AnchorBatch {
    address mm;             // signing address; the board key for every entry
    AnchorEntry[] entries;  // one per pair
}

struct BoardControls {
    address mm;                     // signing address; the board key
    address tokenIn;                // pair token in
    address tokenOut;               // pair token out
    uint256 nonce;                  // controls nonce, its own sequence
    uint256 blockCap;               // most tokenIn one block may fill from this board; 0 for no cap
    uint256 widenPpmPerSqrtSecond;  // extra discount per square root of a second of quote age; 0 for none
    uint256 premiumPpm;             // extra discount inside the premium window; 0 for none
    uint256 premiumBlocks;          // blocks the premium covers after a commit; 0 for none
}
```

Type strings, verbatim from the contracts:

```
PriceLadder(address mm,address provider,address tokenIn,address tokenOut,Level[] levels,uint256 nonce,uint256 expiresAt)Level(uint256 size,uint256 price)
OffsetLadder(address mm,address provider,address tokenIn,address tokenOut,Rung[] rungs,uint256 nonce,uint256 expiresAt,uint256 driftPpmPerSecond)Rung(uint256 size,uint256 offsetPpm)
AnchorBatch(address mm,AnchorEntry[] entries)AnchorEntry(address tokenIn,address tokenOut,uint256 price,uint256 timestampMs,uint256 ttl,uint256 skewPpm,uint256 reverseSkewPpm)
BoardControls(address mm,address tokenIn,address tokenOut,uint256 nonce,uint256 blockCap,uint256 widenPpmPerSqrtSecond,uint256 premiumPpm,uint256 premiumBlocks)
```

With a standard EIP-712 library (viem or ethers `signTypedData`) the `types` object is:

```ts
const types = {
  Level:        [{ name: "size", type: "uint256" }, { name: "price", type: "uint256" }],
  PriceLadder:  [
    { name: "mm", type: "address" }, { name: "provider", type: "address" },
    { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" },
    { name: "levels", type: "Level[]" }, { name: "nonce", type: "uint256" },
    { name: "expiresAt", type: "uint256" },
  ],
  Rung:         [{ name: "size", type: "uint256" }, { name: "offsetPpm", type: "uint256" }],
  OffsetLadder: [
    { name: "mm", type: "address" }, { name: "provider", type: "address" },
    { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" },
    { name: "rungs", type: "Rung[]" }, { name: "nonce", type: "uint256" },
    { name: "expiresAt", type: "uint256" }, { name: "driftPpmPerSecond", type: "uint256" },
  ],
  AnchorEntry:  [
    { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" },
    { name: "price", type: "uint256" }, { name: "timestampMs", type: "uint256" },
    { name: "ttl", type: "uint256" }, { name: "skewPpm", type: "uint256" },
    { name: "reverseSkewPpm", type: "uint256" },
  ],
  AnchorBatch:  [{ name: "mm", type: "address" }, { name: "entries", type: "AnchorEntry[]" }],
  BoardControls: [
    { name: "mm", type: "address" }, { name: "tokenIn", type: "address" },
    { name: "tokenOut", type: "address" }, { name: "nonce", type: "uint256" },
    { name: "blockCap", type: "uint256" }, { name: "widenPpmPerSqrtSecond", type: "uint256" },
    { name: "premiumPpm", type: "uint256" }, { name: "premiumBlocks", type: "uint256" },
  ],
} as const;
const domain = { name: "PropAMMExecutor", version: "2", chainId, verifyingContract: executor };
```

Sign the anchor message with `primaryType: "AnchorBatch"`: one signature covers every entry, so nobody can add, drop or alter an entry without invalidating it. Neither the anchor nor the controls carry a `provider`: the provider is bound by the depth message they apply to. An anchor entry carries a `ttl` in place of `expiresAt`: it lives until `timestampMs / 1000 + ttl`. Controls carry no expiry, because they hold until a fresher controls nonce replaces them and they never make a board quote more.

## Validation rules

The stream rejects a message that fails any of these, and the executor skips one that reaches it and emits `CommitRejected`. Validate before signing.

| Rule | Applies to |
|---|---|
| `tokenIn != 0`, `tokenOut != 0`, `tokenIn != tokenOut`, `provider != 0` | ladders |
| `nonce` fits `uint128`, `expiresAt` fits `uint40` | ladders |
| `expiresAt` in the future at commit time | ladders |
| 1 to 20 levels or rungs | ladders |
| sizes strictly ascending, first size above zero, every size fits `uint128` | ladders |
| prices above zero, each at most the previous price, every price fits `uint128` | price ladders |
| offsets at least the previous offset and below `1_000_000` | offset ladders |
| `driftPpmPerSecond` fits `uint32` | offset ladders |
| `tokenIn != 0`, `tokenOut != 0`, `tokenIn != tokenOut` | anchor entries |
| `price` above zero and fits `uint120` | anchor entries |
| `timestampMs` fits `uint48`; the stream also refuses one more than an hour ahead | anchor entries |
| `ttl` above zero and fits `uint16`; the stream caps it at 3600 | anchor entries |
| `skewPpm` and `reverseSkewPpm` below `1_000_000` | anchor entries |
| `timestampMs / 1000 + ttl` in the future at commit time | anchor entries |
| 1 to 32 entries, at most one per pair | anchor messages (stream only) |
| every entry names a pair registered for you, in either direction | anchor messages (stream only) |
| `nonce` fits `uint48` | controls |
| `blockCap` fits `uint128`, `widenPpmPerSqrtSecond` fits `uint32`, `premiumPpm` below `1_000_000`, `premiumBlocks` fits `uint16` | controls |
| signature verifies for `mm` under the executor's domain for `chainId` | all |
| `provider` equals the provider registered for you on that pair | ladders (stream only) |

## Nonce rules

| Nonce | Scope | Rule |
|---|---|---|
| depth nonce (`PriceLadder.nonce`, `OffsetLadder.nonce`) | one per board `(mm, tokenIn, tokenOut)`, shared by both ladder forms | strictly greater than the board's stored depth nonce to be applied; fits `uint128` |
| anchor timestamp (`AnchorEntry.timestampMs`) | one per pair, whichever direction an entry is signed for | strictly greater than the pair's stored `timestampMs` to be applied; fits `uint48`; `board()` reports it as `anchorNonce` |
| controls nonce (`BoardControls.nonce`) | one per board, independent of both | strictly greater than the stored controls nonce to be applied; fits `uint48` |

- A message whose nonce is not fresher than the stored one is a silent no-op onchain, skipped before validation and before the signature is checked. The stream rejects it with `STALE_NONCE`. An anchor batch is checked per entry: stale entries are skipped, the rest apply, and the stream answers `STALE_NONCE` only when every entry is stale. Re-submitting an already committed message is therefore harmless and two committers racing never fail each other's transactions.
- The rule holds after expiry too: an older nonce never comes back. To restore a quote, sign it again with a fresh nonce.
- Never re-sign the same nonce to refresh a quote; it will be skipped. Sign a fresh nonce or rely on the TTL.
- Any strictly increasing sequence works for the depth and controls nonces. Millisecond timestamps fit both limits (the `uint48` limit holds millisecond timestamps for thousands of years); a per-board counter works as well. The nonces do not need to be related. Nonce spaces are per board, so the same value may be reused across pairs and directions in one tick.
- An anchor's `timestampMs` is both the time you priced it and its ordering key, so it must be a real unix millisecond timestamp: drift and age-based widening count from it, and its expiry is `timestampMs / 1000 + ttl`. Two anchors for the same pair in the same millisecond need distinct values; add one to the later.
- A depth commit resets the meter to zero. Re-sign the offset ladder only when the shape or the provider changes or when consumed depth should re-open; move the price with anchors.

## The meter

Each board carries one `filled` cursor: cumulative tokenIn consumed in the current depth version. It resets to zero on every accepted depth commit and is untouched by anchor commits. Consecutive fills consume depth cumulatively: fill N+1 starts where fill N ended and pays the deeper levels. Splitting one large trade into many small ones yields exactly what one fill yields, and every fill from every caller and lane counts against the same meter.

The worst case at any depth version is its top size, once. Past that the sweep reverts `LadderDepthExhausted`; nothing can give a version more depth than you signed. The sweep arithmetic is `out += floor(take * price / 1e18)` per consumed level, and your provider is handed that exact total.

Two consequences for how you stream:

- On a price ladder every price move is a depth commit, so consumed depth re-opens on every commit. Size the top level as the exposure you accept per tick, not per hour.
- On an offset board the price moves with anchors and the meter stays put. Consumed depth stays consumed until you sign a new offset ladder. A maker who pushes the anchor every block re-prices every block without re-exposing consumed depth.

## Offset boards, anchors and drift

An offset board's rung prices are derived at read time:

```
anchor = entry.price on the signed direction, 1e36 / entry.price (rounded down) on the reverse
skew   = skewPpm on the signed direction, reverseSkewPpm on the reverse
age    = now - timestampMs / 1000, in whole seconds
price  = anchor * (1e6 - offsetPpm - driftPpmPerSecond * age - skew) / 1e6, floored
```

`age` is the whole seconds since the anchor's signed `timestampMs`, measured against the block timestamp. Board controls add their discount to the same sum. Drift is optional: with `driftPpmPerSecond = 0` and no skew the board quotes at exactly `anchor * (1e6 - offset) / 1e6` until the anchor expires, then goes dark. With drift the board keeps quoting between anchor updates at a price that worsens with staleness instead of going dark, and a fresh anchor snaps the discount back to the signed offsets. This lets you choose a longer anchor TTL without leaving a stale price exposed at full width.

A rung whose total discount reaches `1e6` prices at zero and drops off the end of the board, and every deeper rung with it (offsets never decrease with depth). When the first rung is gone the whole board is dark (`BoardInactive`), not exhausted.

Worked example with two 18-decimal tokens: anchor `2000e18`, first rung `offsetPpm = 500`, `driftPpmPerSecond = 2`, skew zero.

| Anchor age | Discount | First rung fills at |
|---|---|---|
| 0 s | 500 ppm | `2000e18 * 999_500 / 1_000_000 = 1999e18` |
| 30 s | 500 + 2 * 30 = 560 ppm | `1998.88e18` |
| 300 s | 500 + 2 * 300 = 1100 ppm | `1997.8e18` |

Anchors are per pair. One entry prices both directions: the direction it is signed for at `price`, the reverse at `1e36 / price` rounded down, in your favour. With two 18-decimal tokens, an entry for WETH to USDC at `2000e18` prices USDC to WETH at `1e36 / 2000e18 = 5e14`. Each side carries its own extra discount, `skewPpm` for the signed direction and `reverseSkewPpm` for the reverse, so you can lean one side without moving the other; with both at zero the two sides are exact inverses before offsets. Skew applies only to offset boards; a price ladder ignores anchors.

A maker signs every pair it quotes on a chain into one `anchor` message, one entry per pair, at most 32 entries, under one signature. The network commits the batch whole, because the signature covers every entry; the executor checks the signature once and applies each fresher entry on its own.

Not every signed anchor batch lands onchain. The network commits an anchor when the price has moved since the last committed anchor or the committed one is close to expiring. Between commits the onchain board prices off the last committed anchor plus drift, so the anchor TTL and drift you sign are what bound the price a router sees.

## Board controls

One optional message per board carries the limits the executor applies to every fill of it. Sign it once and it holds until you sign a fresher controls nonce: depth commits and anchors do not clear it. Every field only ever restricts a fill, so a board with no controls, or with all four fields at zero, prices exactly as this page describes everywhere else.

| Field | Units | Effect |
|---|---|---|
| `blockCap` | tokenIn, smallest units | The most any single block may fill from this board, counting every caller and both lanes. `0` for no cap |
| `widenPpmPerSqrtSecond` | ppm per square root of a second | Extra discount of `widenPpmPerSqrtSecond * floor(sqrt(age))`, where `age` is the quote's age in seconds. `0` for none |
| `premiumPpm` | ppm | Extra discount for the first blocks after you commit depth, an anchor or the controls. `0` for none |
| `premiumBlocks` | blocks | How many blocks that premium covers, counting the commit block as the first. `0` for none |

The extra discount is `widenPpmPerSqrtSecond * floor(sqrt(age)) + premiumPpm` inside the premium window and the widening term alone outside it. It applies on top of what the board already prices: it multiplies a price ladder's level prices and adds to an offset ladder's offsets, after drift. On an offset board `age` runs from the anchor's signed `timestampMs`; on a price ladder it runs from the commit that wrote the board. Committing controls restarts both clocks, the age origin and the premium window, so the board is treated as freshly priced from that block. A first level whose total discount reaches `1e6` takes the board dark (`BoardInactive`) rather than quoting at zero, exactly as a drifted-out first rung does.

`widenPpmPerSqrtSecond` is not itself capped below `1e6`: what it produces is bounded by the board going dark, which is the intended outcome for a quote old enough for the widening to swallow the price.

### The block cap is visible before the transaction

The cap is not a revert that integrators discover by failing. `board()` reports `remaining` as the smaller of the depth left in the version and what the block has left under the cap, the executor's `quote` returns zero for a size above that, and the venue reads the same number, so the merged book offers you only what you can still fill this block and routes the rest to other makers. A fill that does pass the cap reverts `BlockCapExceeded(blockCap, attempted)`.

The tally is per block and resets with the block, not with a commit. Two lanes and any number of callers share it.

One boundary worth knowing: a cap binds from the block it is committed in. A board carrying no cap keeps no block meter, so fills that already landed earlier in that same block are not charged against a cap armed after them. From the next fill onward the cap is exact.

### Choosing the numbers

- `blockCap` is the size of one block of adverse flow you accept while your stream is behind. A cap well below the board's top size keeps the ladder deep for ordinary flow and still bounds a single bad block. It is not a substitute for the top size, which bounds the whole depth version.
- `widenPpmPerSqrtSecond` prices staleness. The square root means the first seconds cost the most in relative terms and a long-dead quote does not run away to absurd numbers: at 100 ppm per square root of a second, a one-second quote widens 100 ppm, a four-second quote 200 ppm, a twenty-five-second quote 500 ppm.
- `premiumPpm` with `premiumBlocks` of 1 or 2 prices the race against your own update, so the block in which you move your price is not the cheapest block in which to take you.
- All three compose with the TTLs and the drift you already sign. Controls narrow a board, they never widen what it offers.

## Prices are in raw token units

Each level's `price` converts raw amounts: `amountOut = amountIn * price / 1e18`, both sides in the tokens' smallest units. When the two tokens have different decimals, fold the difference into the price:

```
price = humanPrice * 1e18 * 10^(decimalsOut - decimalsIn)
```

Example, WETH (18 decimals) to USDC (6 decimals) at 2,000 USDC per WETH: `price = 2000 * 1e18 * 10^(6-18) = 2000e6`. The inverse direction, USDC to WETH, is `(1/2000) * 1e18 * 10^(18-6) = 5e26`. Same-decimals pairs reduce to `humanPrice * 1e18`. Anchor prices use the same scale, quoted for the direction the entry names. Sizes are in `tokenIn` smallest units and cumulative; a one-level ladder is a single price up to `size`. Check a new pair against a live board with `executor.board` or `venue.board` before going live.

## TTL guidance

`expiresAt` is unix seconds, must be in the future, and may be at most one hour ahead; the stream rejects anything further out as a likely units mistake (milliseconds instead of seconds). An anchor entry's expiry is `timestampMs / 1000 + ttl`, with `ttl` in seconds and at most 3600.

`BoardControls` has no TTL. It holds until replaced, so it cannot expire into a gap where the board is suddenly uncapped.

| Message | Typical TTL | Why |
|---|---|---|
| Anchor (`ttl`) | a few seconds to tens of seconds | The price is re-signed as often as every block; the TTL bounds how long a stale price stays fillable if your stream stops. Add drift if you want a longer TTL with a price that widens instead of going dark. |
| Offset ladder | minutes, up to the one-hour cap | Sizes and offsets change rarely. The ladder's TTL is not the freshness bound of the price; the anchor's is. |
| Price ladder | a few seconds to about a minute | The TTL is the freshness bound and every price move is a new ladder. |

A message is committed only while it still has a few seconds of life left, so a TTL of one or two seconds rarely reaches the chain. Messages signed with at least 15 seconds of life are kept separately for the onchain lane, where routers need a board that outlives their own quote-to-swap window; a maker who only ever signs very short ticks serves the hosted lane well and the onchain lane poorly. Price the longer window into the spread of the message that carries it.

## What happens when a message expires

| Situation | Effect |
|---|---|
| Price ladder past `expiresAt` | Board is dark: `board()` returns no levels and zero `remaining`, `quote` returns zero, `fill` reverts `BoardInactive`, the venue skips the maker and `isActive` drops to false if no other maker is live. A same or older nonce cannot bring it back; a fresher signed ladder can. |
| Offset ladder past `expiresAt`, anchor fresh | Dark the same way. Only a new offset ladder (fresher depth nonce) makes it live again; that resets the meter. |
| Anchor past `timestampMs / 1000 + ttl`, offset ladder fresh | Dark the same way, in both directions of the pair. A fresh anchor (fresher `timestampMs`) makes the board live again immediately, priced off the new anchor, with the meter exactly where it was. |
| Every rung drifted to a discount of `1e6` or more | Dark (`BoardInactive`), not exhausted. A fresh anchor resets the drift origin. |
| The block's fill tally has reached `blockCap` | `remaining` reads zero and `quote` returns zero for the rest of the block; the venue routes around you. The next block starts the tally at zero with the same board. |
| Deeper rungs drifted to `1e6`, shallower rungs not | The effective board ends before the first saturated rung; `board()` returns only the live rungs. |
| Depth fully consumed (`filled == top size`) | Board is live but empty: `remaining` is zero, `fill` reverts `LadderDepthExhausted`. Anchors do not re-open it; a new depth version does. |

`board()` reports the earlier of the depth and anchor expiries as the effective `expiresAt` on an offset board, so a consumer can read one number for "when does this go dark".

Two ways to go dark on purpose, both unilateral. Stop streaming, and every board dies at the TTLs you signed. To kill outstanding quotes before their TTL, sign a tombstone: a depth version with a fresher nonce, a dust top size and a TTL covering the longest outstanding quote. The fresher nonce replaces every level and resets the meter; anything already in flight fills at most the dust.

## Wire format

Connect to the price stream with your API key in the `x-api-key` header of the connection request (the server refuses the connection with HTTP 401 without a valid key), subscribe to the `price-ledger` channel as the maker, then send any of the four board messages. Every payload carries the struct fields verbatim, the maker's EIP-712 signature under the executor's domain, and the chain the board lives on. Numeric fields are decimal strings (JSON integers are accepted too); addresses are hex.

Messages are JSON text frames. One signer per connection: every message's `mm` must equal the subscribed `mm`. A connection can carry boards for several chains; `chainId` selects the domain the signature is verified against.

```json
{ "type": "subscribe", "data": { "type": "price-ledger", "mm": "0x1111111111111111111111111111111111111111" } }
```

The server answers `{ "type": "ack" }`. It may also send informational frames of other types after the subscription; ignore frame types you do not handle.

### `price-ladder`

```json
{
  "type": "price-ladder",
  "payload": {
    "mm": "0x1111111111111111111111111111111111111111",
    "provider": "0x2222222222222222222222222222222222222222",
    "tokenIn": "0x8b414aD7005EeFd315aF2A16538885Eae229bab7",
    "tokenOut": "0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df",
    "levels": [
      { "size": "1000000000000000000", "price": "1998000000000000000000" },
      { "size": "3000000000000000000", "price": "1995000000000000000000" }
    ],
    "nonce": "1753290000123",
    "expiresAt": "1753290030",
    "signature": "0x…65 bytes…",
    "chainId": 84532
  }
}
```

### `offsets`

```json
{
  "type": "offsets",
  "payload": {
    "mm": "0x1111111111111111111111111111111111111111",
    "provider": "0x2222222222222222222222222222222222222222",
    "tokenIn": "0x8b414aD7005EeFd315aF2A16538885Eae229bab7",
    "tokenOut": "0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df",
    "rungs": [
      { "size": "1000000000000000000", "offsetPpm": "1000" },
      { "size": "3000000000000000000", "offsetPpm": "2500" }
    ],
    "nonce": "1753290000124",
    "expiresAt": "1753293600",
    "driftPpmPerSecond": "10",
    "signature": "0x…65 bytes…",
    "chainId": 84532
  }
}
```

### `anchor`

```json
{
  "type": "anchor",
  "payload": {
    "mm": "0x1111111111111111111111111111111111111111",
    "entries": [
      {
        "tokenIn": "0x8b414aD7005EeFd315aF2A16538885Eae229bab7",
        "tokenOut": "0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df",
        "price": "2000000000000000000000",
        "timestampMs": "1753290000000",
        "ttl": "30",
        "skewPpm": "0",
        "reverseSkewPpm": "0"
      }
    ],
    "signature": "0x…65 bytes…",
    "chainId": 84532
  }
}
```

### `board-controls`

```json
{
  "type": "board-controls",
  "payload": {
    "mm": "0x1111111111111111111111111111111111111111",
    "tokenIn": "0x8b414aD7005EeFd315aF2A16538885Eae229bab7",
    "tokenOut": "0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df",
    "nonce": "88214",
    "blockCap": "5000000000000000000",
    "widenPpmPerSqrtSecond": "100",
    "premiumPpm": "500",
    "premiumBlocks": "1",
    "signature": "0x…65 bytes…",
    "chainId": 84532
  }
}
```

| Field | Type | Notes |
|---|---|---|
| `mm` | address | Signing key; the board key. Must equal the subscribed maker and the recovered signer |
| `provider` | address | The inventory contract that fills the board. Ladders only; must equal the provider registered for you on the pair |
| `tokenIn`, `tokenOut` | address | Real ERC20 addresses, distinct. In an anchor entry, the direction `price` is quoted for |
| `levels[].size`, `rungs[].size` | uint128 as string | Cumulative tokenIn depth, strictly ascending |
| `levels[].price` | uint128 as string | 1e18-scaled tokenOut per tokenIn, non-increasing with depth |
| `rungs[].offsetPpm` | string | Discount below the anchor in ppm, non-decreasing with depth, below 1e6 |
| `driftPpmPerSecond` | uint32 as string | Offset widening per second of anchor age; `"0"` disables drift |
| `nonce` | string | Depth nonce (uint128) for ladders, controls nonce (uint48) for controls; strictly increasing per board |
| `expiresAt` | unix seconds as string | Ladders only. uint40; at most one hour ahead |
| `entries` | array | Anchors only. 1 to 32 entries, at most one per pair |
| `entries[].price` | uint120 as string | Anchor reference price for the signed direction, positive |
| `entries[].timestampMs` | unix milliseconds as string | When the maker priced the anchor; the drift origin and the pair's ordering key. uint48 |
| `entries[].ttl` | seconds as string | The anchor lives `ttl` seconds after `timestampMs`; 1 to 3600 |
| `entries[].skewPpm`, `entries[].reverseSkewPpm` | string | Extra discount on the signed side and on the reverse side, ppm, below `1e6`; `"0"` disables |
| `blockCap` | uint128 as string | Controls only. Most tokenIn one block may fill; `"0"` for no cap |
| `widenPpmPerSqrtSecond`, `premiumPpm` | uint32 as string | Controls only. Extra discount terms in ppm, below `1e6`; `"0"` disables |
| `premiumBlocks` | uint16 as string | Controls only. Blocks the premium covers; `"0"` disables |
| `signature` | hex | 65-byte EIP-712 signature by `mm` |
| `chainId` | number | The chain the board lives on |

Responses are `{ "type": "ack" }` or `{ "type": "error", "code", "message" }`. Error codes: `INVALID_JSON`, `INVALID_MESSAGE` (schema), `NOT_SUBSCRIBED`, `MARKET_MAKER_MISMATCH`, `RATE_LIMITED`, `UNSUPPORTED_CHAIN`, `UPDATE_EXPIRED`, `INVALID_TOKEN_PAIR`, `UNREGISTERED_MARKET_MAKER`, `INVALID_SIGNATURE`, `UNSUPPORTED_PAIR`, `PROVIDER_MISMATCH`, `STALE_NONCE`, `STORE_FAILED`. At most 20 levels or rungs per message.

An `ack` means the message was validated and stored; the network commits it when the board it belongs to is due. A rejected message changes nothing: the last accepted message for that board stays in force until its TTL. An anchor message is accepted or refused as a whole: an entry for a pair not registered for you (`UNSUPPORTED_PAIR`) or an expired entry (`UPDATE_EXPIRED`) refuses the message.

| Limit | Value |
|---|---|
| Rate limit | 300 board messages per second per connection (token bucket, 300 burst) |
| Max frame size | 64 KB |
| Inactivity | a connection with no inbound traffic for 60 seconds is closed; reconnect and re-subscribe. The server sends protocol-level pings every 10 seconds, which standard libraries answer automatically; a client may also send `{ "type": "ping" }` |
| Levels or rungs per message | 20 |
| Entries per anchor message | 32 |
| `expiresAt` | in the future, at most one hour ahead |
| Anchor `ttl` | 1 to 3600 seconds |

## Example: an offset board over one minute

One offset ladder, then an anchor message every second with one entry for the pair. Only the anchor is re-signed; the depth nonce does not move, so the meter is preserved across every price tick.

```
t = 0    offsets    nonce 1753290000124   rungs [(1e18, 1000 ppm), (3e18, 2500 ppm)]   drift 10   expiresAt t + 1800
t = 0    anchor     timestampMs 1000 * t            price 2000e18     ttl 15
t = 1    anchor     timestampMs 1000 * (t + 1)      price 2000.4e18   ttl 15
t = 2    anchor     timestampMs 1000 * (t + 2)      price 1999.9e18   ttl 15
...
```

With the board committed and a fill of 0.5 tokenIn at `t = 5` against the anchor from `t = 2` (age 3 s, discount `1000 + 10 * 3 = 1030` ppm), the first rung fills at `1999.9e18 * 998_970 / 1_000_000` and the meter reads `0.5e18`. Every later anchor re-prices the remaining `2.5e18` of depth, and the reverse direction's board if you quote it; none of them resets either meter. When you want the full `3e18` back, sign a new offset ladder with a fresher depth nonce.

## Verifying onchain

Everything the network commits is public state on the executor and readable through the venue:

- `executor.board(mm, tokenIn, tokenOut)` returns `(sizes, prices, filled, remaining, expiresAt, nonce, anchorNonce, mode)`: the levels a fill prices at right now (offset boards resolved against the anchor and drift), the meter, remaining depth, the effective expiry, the depth nonce, `anchorNonce` (the pair's latest `timestampMs`) and the form (`1` price ladder, `2` offset ladder, `0` never committed).
- `venue.board(mm, tokenIn, tokenOut)` returns the first five of those.
- `executor.quote(mm, tokenIn, tokenOut, amountIn)` returns what a fill would deliver right now, or zero when the board is dark, cannot cover the size, or the size is above what the block has left under your cap.
- `executor.controls(mm, tokenIn, tokenOut)` returns `(blockCap, widenPpmPerSqrtSecond, premiumPpm, premiumBlocks, controlsNonce, filledThisBlock, lastCommitBlock, committedAt)`: your limits as stored, how much this block has already filled, and the stamps the premium window runs from.
- Events: `LadderCommitted`, `OffsetsCommitted`, `AnchorCommitted` (one per accepted entry, naming the signed direction) and `ControlsCommitted` when a message is accepted onchain; `CommitRejected(mm, tokenIn, tokenOut, kind, reason)` when a fresher message is refused on its own; `MMFillExecuted(mmProvider, mmSigner, receiver, tokenIn, tokenOut, amountIn, amountOut, avgPrice, filledAfter)` per fill, with `filledAfter` the meter after the fill.
