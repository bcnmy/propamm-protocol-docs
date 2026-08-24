# Streaming boards

How a maker's prices reach the chain. You sign small EIP-712 messages that describe a board, one per pair and direction, and send them over a WebSocket. The network validates them, stores them and commits them to `PropAMMExecutor`, which holds one board per `(mm, tokenIn, tokenOut)` and prices every fill from it. You send no transactions and pay no gas. Onboarding, the provider contract and endpoints are in [integration.md](integration.md); this page is the message spec.

## Two forms of a board

| Form | Messages | When to use |
|---|---|---|
| Price ladder | `PriceLadder`: cumulative sizes with absolute 1e18-scaled prices | Your engine emits absolute prices by size and you are willing to re-sign the whole ladder on every price change |
| Offset ladder plus anchor | `OffsetLadder`: cumulative sizes with discounts below a reference price, plus a drift rate; `Anchor`: the reference price | Sizes and discounts change rarely, the price changes often. One anchor commit is one storage word and never re-opens consumed depth |

A price ladder and an offset ladder are both depth versions of the board and share one nonce sequence. A new depth version must carry a strictly higher nonce, replaces every level, rebinds the provider and resets the board's fill meter. Anchors have their own nonce sequence and never touch the meter. An offset board quotes only while both its ladder and its anchor are unexpired. You choose the form per pair and direction and may switch in either order: an anchor committed while the board is a price ladder is stored and unused until an offset ladder arrives; a price ladder committed over an offset board replaces it and ignores the stored anchor. Either switch is a depth commit and resets the meter.

## What you sign

Every message is signed against the executor's EIP-712 domain. The executor address is the same on every chain, so only `chainId` changes between chains.

| Field | Value |
|---|---|
| `name` | `PropAMMExecutor` |
| `version` | `2` |
| `chainId` | the chain the board lives on |
| `verifyingContract` | `0x000000F80660419ECcED6F86dBc762725371eb56` |

The digest your key signs is `keccak256(0x1901 || domainSeparator || structHash)`. `executor.DOMAIN_SEPARATOR()` returns the separator, and the executor exposes the exact digests (`ladderDigest`, `offsetLadderDigest`, `anchorDigest`) and struct hashes (`hashLadder`, `hashOffsetLadder`, `hashAnchor`) as views, so you can check a signer implementation against the contract without a transaction. Signatures are verified with `isValidSignatureNow(mm, digest, sig)`: a 65-byte ECDSA signature from an EOA `mm`, or any bytes an EIP-1271 contract at `mm` accepts.

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

struct Anchor {
    address mm;         // signing address; the board key
    address tokenIn;    // pair token in
    address tokenOut;   // pair token out
    uint256 price;      // 1e18-scaled tokenOut per tokenIn
    uint256 nonce;      // anchor nonce, independent of the depth nonce
    uint256 timestamp;  // unix seconds the maker priced this anchor; the drift origin
    uint256 expiresAt;  // unix seconds; the board is dark past this
}
```

Type strings, verbatim from the contracts:

```
PriceLadder(address mm,address provider,address tokenIn,address tokenOut,Level[] levels,uint256 nonce,uint256 expiresAt)Level(uint256 size,uint256 price)
OffsetLadder(address mm,address provider,address tokenIn,address tokenOut,Rung[] rungs,uint256 nonce,uint256 expiresAt,uint256 driftPpmPerSecond)Rung(uint256 size,uint256 offsetPpm)
Anchor(address mm,address tokenIn,address tokenOut,uint256 price,uint256 nonce,uint256 timestamp,uint256 expiresAt)
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
  Anchor:       [
    { name: "mm", type: "address" }, { name: "tokenIn", type: "address" },
    { name: "tokenOut", type: "address" }, { name: "price", type: "uint256" },
    { name: "nonce", type: "uint256" }, { name: "timestamp", type: "uint256" },
    { name: "expiresAt", type: "uint256" },
  ],
} as const;
const domain = { name: "PropAMMExecutor", version: "2", chainId, verifyingContract: executor };
```

The anchor has no `provider`: the provider is bound by the depth message it re-prices.

## Validation rules

The stream rejects a message that fails any of these, and the executor would revert the commit if one reached it. Validate before signing.

| Rule | Applies to |
|---|---|
| `tokenIn != 0`, `tokenOut != 0`, `tokenIn != tokenOut`, `provider != 0` | ladders |
| `nonce` fits `uint128`, `expiresAt` fits `uint40` | ladders |
| `expiresAt` in the future at commit time | ladders and anchors |
| 1 to 20 levels or rungs | ladders |
| sizes strictly ascending, first size above zero, every size fits `uint128` | ladders |
| prices above zero, each at most the previous price, every price fits `uint128` | price ladders |
| offsets at least the previous offset and below `1_000_000` | offset ladders |
| `driftPpmPerSecond` fits `uint32` | offset ladders |
| `nonce` fits `uint48` | anchors |
| `price` above zero and fits `uint128` | anchors |
| `timestamp <= expiresAt` | anchors |
| signature verifies for `mm` under the executor's domain for `chainId` | all |
| `provider` equals the provider registered for you on that pair | ladders (stream only) |

## Nonce rules

| Nonce | Scope | Rule |
|---|---|---|
| depth nonce (`PriceLadder.nonce`, `OffsetLadder.nonce`) | one per board `(mm, tokenIn, tokenOut)`, shared by both ladder forms | strictly greater than the board's stored depth nonce to be applied; fits `uint128` |
| anchor nonce (`Anchor.nonce`) | one per board, independent of the depth nonce | strictly greater than the stored anchor nonce to be applied; fits `uint48` |

- A message whose nonce is not fresher than the stored one is a silent no-op onchain, skipped before validation and before the signature is checked. The stream rejects it with `STALE_NONCE`. Re-submitting an already committed message is therefore harmless and two committers racing never fail each other's transactions.
- The rule holds after expiry too: an older nonce never comes back. To restore a quote, sign it again with a fresh nonce.
- Never re-sign the same nonce to refresh a quote; it will be skipped. Sign a fresh nonce or rely on the TTL.
- Any strictly increasing sequence works. Millisecond timestamps fit both limits (the anchor nonce limit, `2^48 - 1`, holds millisecond timestamps for thousands of years); a per-board counter works as well. The two nonces do not need to be related. Nonce spaces are per board, so the same value may be reused across pairs and directions in one tick.
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
price = anchorPrice * (1e6 - offsetPpm - driftPpmPerSecond * (now - anchor.timestamp)) / 1e6, floored
```

`age` is the seconds since the anchor's signed `timestamp`, measured against the block timestamp. Drift is optional: with `driftPpmPerSecond = 0` the board quotes at exactly `anchor * (1e6 - offset) / 1e6` until the anchor expires, then goes dark. With drift the board keeps quoting between anchor updates at a price that worsens with staleness instead of going dark, and a fresh anchor snaps the discount back to the signed offsets. This lets you choose a longer anchor TTL without leaving a stale price exposed at full width.

A rung whose total discount reaches `1e6` prices at zero and drops off the end of the board, and every deeper rung with it (offsets never decrease with depth). When the first rung is gone the whole board is dark (`BoardInactive`), not exhausted.

Worked example with two 18-decimal tokens: anchor `2000e18`, first rung `offsetPpm = 500`, `driftPpmPerSecond = 2`.

| Anchor age | Discount | First rung fills at |
|---|---|---|
| 0 s | 500 ppm | `2000e18 * 999_500 / 1_000_000 = 1999e18` |
| 30 s | 500 + 2 * 30 = 560 ppm | `1998.88e18` |
| 300 s | 500 + 2 * 300 = 1100 ppm | `1997.8e18` |

Anchors are per direction. A maker with both sides of a pair signs two anchors per tick; the network commits both in one `updateAnchors` call.

Not every signed anchor lands onchain. The network commits an anchor when the price has moved since the last committed anchor or the committed one is close to expiring. Between commits the onchain board prices off the last committed anchor plus drift, so the anchor TTL and drift you sign are what bound the price a router sees.

## Prices are in raw token units

Each level's `price` converts raw amounts: `amountOut = amountIn * price / 1e18`, both sides in the tokens' smallest units. When the two tokens have different decimals, fold the difference into the price:

```
price = humanPrice * 1e18 * 10^(decimalsOut - decimalsIn)
```

Example, WETH (18 decimals) to USDC (6 decimals) at 2,000 USDC per WETH: `price = 2000 * 1e18 * 10^(6-18) = 2000e6`. The inverse direction, USDC to WETH, is `(1/2000) * 1e18 * 10^(18-6) = 5e26`. Same-decimals pairs reduce to `humanPrice * 1e18`. Anchor prices use the same scale. Sizes are in `tokenIn` smallest units and cumulative; a one-level ladder is a single price up to `size`. Check a new pair against a live board with `executor.board` or `venue.board` before going live.

## TTL guidance

`expiresAt` is unix seconds, must be in the future, and may be at most one hour ahead; the stream rejects anything further out as a likely units mistake (milliseconds instead of seconds).

| Message | Typical TTL | Why |
|---|---|---|
| Anchor | a few seconds to tens of seconds | The price is re-signed as often as every block; the TTL bounds how long a stale price stays fillable if your stream stops. Add drift if you want a longer TTL with a price that widens instead of going dark. |
| Offset ladder | minutes, up to the one-hour cap | Sizes and offsets change rarely. The ladder's TTL is not the freshness bound of the price; the anchor's is. |
| Price ladder | a few seconds to about a minute | The TTL is the freshness bound and every price move is a new ladder. |

A message is committed only while it still has a few seconds of life left, so a TTL of one or two seconds rarely reaches the chain. Messages signed with at least 15 seconds of life are kept separately for the onchain lane, where routers need a board that outlives their own quote-to-swap window; a maker who only ever signs very short ticks serves the hosted lane well and the onchain lane poorly. Price the longer window into the spread of the message that carries it.

## What happens when a message expires

| Situation | Effect |
|---|---|
| Price ladder past `expiresAt` | Board is dark: `board()` returns no levels and zero `remaining`, `quote` returns zero, `fill` reverts `BoardInactive`, the venue skips the maker and `isActive` drops to false if no other maker is live. A same or older nonce cannot bring it back; a fresher signed ladder can. |
| Offset ladder past `expiresAt`, anchor fresh | Dark the same way. Only a new offset ladder (fresher depth nonce) makes it live again; that resets the meter. |
| Anchor past `expiresAt`, offset ladder fresh | Dark the same way. A fresh anchor (fresher anchor nonce) makes the board live again immediately, priced off the new anchor, with the meter exactly where it was. |
| Every rung drifted to a discount of `1e6` or more | Dark (`BoardInactive`), not exhausted. A fresh anchor resets the drift origin. |
| Deeper rungs drifted to `1e6`, shallower rungs not | The effective board ends before the first saturated rung; `board()` returns only the live rungs. |
| Depth fully consumed (`filled == top size`) | Board is live but empty: `remaining` is zero, `fill` reverts `LadderDepthExhausted`. Anchors do not re-open it; a new depth version does. |

`board()` reports the earlier of the depth and anchor expiries as the effective `expiresAt` on an offset board, so a consumer can read one number for "when does this go dark".

Two ways to go dark on purpose, both unilateral. Stop streaming, and every board dies at the TTLs you signed. To kill outstanding quotes before their TTL, sign a tombstone: a depth version with a fresher nonce, a dust top size and a TTL covering the longest outstanding quote. The fresher nonce replaces every level and resets the meter; anything already in flight fills at most the dust.

## Wire format

Connect to the price stream, subscribe to the `price-ledger` channel as the maker, then send any of the three board messages. Every payload carries the struct fields verbatim, the maker's EIP-712 signature under the executor's domain, and the chain the board lives on. Numeric fields are decimal strings (JSON integers are accepted too); addresses are hex.

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
    "tokenIn": "0x8b414aD7005EeFd315aF2A16538885Eae229bab7",
    "tokenOut": "0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df",
    "price": "2000000000000000000000",
    "nonce": "88213",
    "timestamp": "1753290000",
    "expiresAt": "1753290030",
    "signature": "0x…65 bytes…",
    "chainId": 84532
  }
}
```

| Field | Type | Notes |
|---|---|---|
| `mm` | address | Signing key; the board key. Must equal the subscribed maker and the recovered signer |
| `provider` | address | The inventory contract that fills the board. Ladders only; must equal the provider registered for you on the pair |
| `tokenIn`, `tokenOut` | address | Real ERC20 addresses, distinct |
| `levels[].size`, `rungs[].size` | uint128 as string | Cumulative tokenIn depth, strictly ascending |
| `levels[].price` | uint128 as string | 1e18-scaled tokenOut per tokenIn, non-increasing with depth |
| `rungs[].offsetPpm` | string | Discount below the anchor in ppm, non-decreasing with depth, below 1e6 |
| `driftPpmPerSecond` | uint32 as string | Offset widening per second of anchor age; `"0"` disables drift |
| `nonce` | string | Depth nonce (uint128) for ladders, anchor nonce (uint48) for anchors; strictly increasing per board |
| `timestamp` | unix seconds as string | When the maker priced the anchor; the drift origin. Not after `expiresAt` |
| `expiresAt` | unix seconds as string | uint40; at most one hour ahead |
| `price` | uint128 as string | Anchor reference price, positive |
| `signature` | hex | 65-byte EIP-712 signature by `mm` |
| `chainId` | number | The chain the board lives on |

Responses are `{ "type": "ack" }` or `{ "type": "error", "code", "message" }`. Error codes: `INVALID_JSON`, `INVALID_MESSAGE` (schema), `NOT_SUBSCRIBED`, `MARKET_MAKER_MISMATCH`, `RATE_LIMITED`, `UNSUPPORTED_CHAIN`, `UPDATE_EXPIRED`, `INVALID_TOKEN_PAIR`, `UNREGISTERED_MARKET_MAKER`, `INVALID_SIGNATURE`, `UNSUPPORTED_PAIR`, `PROVIDER_MISMATCH`, `STALE_NONCE`, `STORE_FAILED`. At most 20 levels or rungs per message.

An `ack` means the message was validated and stored; the network commits it when the board it belongs to is due. A rejected message changes nothing: the last accepted message for that board stays in force until its TTL.

| Limit | Value |
|---|---|
| Rate limit | 300 board messages per second per connection (token bucket, 300 burst) |
| Max frame size | 64 KB |
| Inactivity | a connection with no inbound traffic for 60 seconds is closed; reconnect and re-subscribe. The server sends protocol-level pings every 10 seconds, which standard libraries answer automatically; a client may also send `{ "type": "ping" }` |
| Levels or rungs per message | 20 |
| `expiresAt` | in the future, at most one hour ahead |

## Example: an offset board over one minute

One offset ladder, then anchors every second. Only the anchor is re-signed; the depth nonce does not move, so the meter is preserved across every price tick.

```
t = 0    offsets    nonce 1753290000124   rungs [(1e18, 1000 ppm), (3e18, 2500 ppm)]   drift 10   expiresAt t + 1800
t = 0    anchor     nonce 1              price 2000e18   timestamp t       expiresAt t + 15
t = 1    anchor     nonce 2              price 2000.4e18 timestamp t + 1   expiresAt t + 16
t = 2    anchor     nonce 3              price 1999.9e18 timestamp t + 2   expiresAt t + 17
...
```

With the board committed and a fill of 0.5 tokenIn at `t = 5` against the anchor from `t = 2` (age 3 s, discount `1000 + 10 * 3 = 1030` ppm), the first rung fills at `1999.9e18 * 998_970 / 1_000_000` and the meter reads `0.5e18`. Every later anchor re-prices the remaining `2.5e18` of depth; none of them resets the meter. When you want the full `3e18` back, sign a new offset ladder with a fresher depth nonce.

## Verifying onchain

Everything the network commits is public state on the executor and readable through the venue:

- `executor.board(mm, tokenIn, tokenOut)` returns `(sizes, prices, filled, remaining, expiresAt, nonce, anchorNonce, mode)`: the levels a fill prices at right now (offset boards resolved against the anchor and drift), the meter, remaining depth, the effective expiry, both nonces and the form (`1` price ladder, `2` offset ladder, `0` never committed).
- `venue.board(mm, tokenIn, tokenOut)` returns the first five of those.
- `executor.quote(mm, tokenIn, tokenOut, amountIn)` returns what a fill would deliver right now, or zero when the board is dark or cannot cover the size.
- Events: `LadderCommitted`, `OffsetsCommitted` and `AnchorCommitted` when a message is accepted onchain; `MMFillExecuted(mmProvider, mmSigner, receiver, tokenIn, tokenOut, amountIn, amountOut, avgPrice, filledAfter)` per fill, with `filledAfter` the meter after the fill.
