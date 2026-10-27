# Venue board feed

The board feed sends every maker's board on each block, the same boards `board()` returns onchain. When a maker signs a new board, the feed sends it right away, before it lands onchain, so you can price the next block's book without reading the venue.

| Environment | Stream | Snapshot | Chains |
|---|---|---|---|
| Staging | `wss://propamm-staging.biconomy.io/venue-stream` | `GET https://propamm-staging.biconomy.io/v1/venue/boards?chainId=84532` | Base Sepolia (84532) |
| Production | `wss://propamm.biconomy.io/venue-stream` | `GET https://propamm.biconomy.io/v1/venue/boards?chainId=8453` | Base (8453) |

Send your API key in the `x-api-key` header, on the WebSocket connection request and on REST. Ask us for a key.

## Stream

Connect, then subscribe to a chain:

```json
{ "type": "subscribe", "chainId": 8453 }
```

| You send | Reply |
|---|---|
| `{"type":"subscribe","chainId":8453}` | `{"type":"subscribed","chainId":8453}`, the latest snapshot, then every new one |
| `{"type":"unsubscribe","chainId":8453}` | `{"type":"unsubscribed","chainId":8453}` |
| `{"type":"ping"}` | `{"type":"pong"}` |

Errors arrive as `{"type":"error","code":"...","message":"..."}`, with `code` one of `RATE_LIMITED`, `INVALID_JSON`, `INVALID_MESSAGE` or `UNSUPPORTED_CHAIN`. The server pings every 15 seconds and closes connections that miss a pong. Ignore message types you do not know; new ones may be added.

## Snapshot over REST

`GET /v1/venue/boards?chainId=8453` returns the latest message, the same JSON the stream sends, or `503` with `Retry-After` while the feed starts. The feed runs while someone reads it: after 30 seconds without a subscriber or a request it stops, and the next request starts it within about 5 seconds. Poll every few seconds, or hold a stream subscription, to keep it running.

## Message

An example message on Base, with one board shown:

```json
{
  "type": "boards",
  "chainId": 8453,
  "venue": "{{VENUE}}",
  "executor": "{{EXECUTOR}}",
  "blockNumber": "52847598",
  "stateBlock": "52847598",
  "timestamp": "1792484543",
  "nextTimestamp": "1792484545",
  "feeBps": 0,
  "makers": ["0x960f1e3181E928210C02a34EE29bf3d354dD2FF5", "0x72A2df03AeeF2A8343f9Fb86bd65193A3008890C"],
  "boards": [
    {
      "mm": "0x72A2df03AeeF2A8343f9Fb86bd65193A3008890C",
      "tokenIn": "0x4200000000000000000000000000000000000006",
      "tokenOut": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      "committed": true,
      "lastCommitBlock": "52847598",
      "mode": "prices",
      "sizes": ["645755065000000", "1291510130000000", "1937265195000000", "2583020261000000"],
      "prices": ["2385958388", "2385719769", "2385481149", "2385242529"],
      "filled": "0",
      "remaining": "645822708000000",
      "expiresAt": "1792484548",
      "depthNonce": "1792484540974",
      "anchorNonce": "0",
      "controlsNonce": "1792483363"
    }
  ],
  "builtAtMs": 1792484543150
}
```

Here WETH has 18 decimals and USDC 6, so `2385958388` is 2,385.958388 USDC per WETH. `remaining` is below the board's depth because the maker's per-block cap is smaller.

| Field | Meaning |
|---|---|
| `blockNumber`, `timestamp` | the last sealed block the feed read the chain at, and its timestamp in unix seconds; committed boards read there are priced for it |
| `stateBlock` | the block the boards are as of: `blockNumber`, or usually one block later when a board landed in a flashblock after that read; every committed board's signed version is onchain from `stateBlock` on, while `filled` and `remaining` are as of the block the board was read or landed in |
| `nextTimestamp` | the next block's timestamp, from the last two blocks' spacing; pending boards are priced for it, since that is the earliest block they land in |
| `feeBps` | the venue's protocol fee: `out - out * feeBps / 10000` on the merged output |
| `makers` | registered makers in registry order; the venue breaks price ties in this order |
| `builtAtMs` | when the message was built, unix milliseconds; use it to detect a stale feed |

Each entry of `boards`:

| Field | Meaning |
|---|---|
| `mm`, `tokenIn`, `tokenOut` | maker and direction |
| `committed` | `true`: the board onchain as of `stateBlock` (when `lastCommitBlock` is after `blockNumber`, it landed in a flashblock after the chain read and is priced for `nextTimestamp`); `false`: signed, not yet onchain |
| `lastCommitBlock` | block of the board's last commit; `null` when pending |
| `mode` | `prices`, `offsets` or `none` |
| `sizes` | cumulative `tokenIn` amounts, one per level |
| `prices` | `tokenOut` per `1e18` `tokenIn` at each level, after drift, widening and premium |
| `filled` | `tokenIn` already filled from this board; fills continue from here |
| `remaining` | most `tokenIn` the board takes in one block: depth left, per-block cap and maker inventory, whichever is smallest; `0` when dark |
| `expiresAt` | unix seconds; dark after it |
| `depthNonce`, `anchorNonce`, `controlsNonce` | versions of the board's signed parts, for change detection |

Integers are decimal strings. A dark board (maker paused, expired, or its inventory contract no longer names the maker) has no levels and `remaining` `0`. A direction a maker has never quoted is not listed.

## Price a swap

One board, sweeping from `filled`, exactly as the venue does:

```text
out = 0; cursor = filled; left = amountIn            // amountIn <= remaining
for each level i:
    if cursor >= sizes[i]: continue
    take = min(sizes[i] - cursor, left)
    out += take * prices[i] / 1e18                     // round down, per level
    cursor += take; left -= take
    if left == 0: break
```

Across makers, take the best next level first, ties in `makers` order, and stop each maker at its `remaining`. Drop an allocation whose output rounds to zero. Then take the protocol fee off the total. `quote()` onchain runs the same steps, so you can check your implementation against it at `stateBlock`, once that block is sealed.

## Committed or pending

A pending board lands onchain shortly after the maker signs it. On Base, 299 sampled commits from 20 October 2026 all landed within 3 seconds of signing (median 2.1 seconds), so one to two blocks.

| Your swap lands | Price with |
|---|---|
| a few seconds after you quote, for example a route a user signs in a wallet | the pending board when there is one |
| in the very next block, and the quote must hold either way | the lower output of the committed and the pending board, per maker |

If a commit fails, the pending board disappears from the next message and the committed board stays. A board without a pending entry has nothing waiting.

## Time

Committed prices are for `timestamp` and pending prices for `nextTimestamp`. Prices move between blocks without a new board:

- an `offsets` board's price falls with each block its anchor ages (drift counts blocks since the anchor's commit);
- a board with widening falls with the square root of its age in blocks;
- a board with a premium is priced lower for a few blocks after each commit, then rises when the premium ends.

Use the newest message and treat one whose `builtAtMs` is more than a few seconds old as stale. To execute, call the venue as in [aggregator-api.md](aggregator-api.md); the feed only replaces the reads.
