# Maker integration

What a market maker runs to quote on PropAMM: a provider contract that holds inventory, a signing key, and a WebSocket connection that streams signed boards. Someone else always submits the transaction and pays the gas.

1. [The provider contract](#1-the-provider-contract)
2. [The signing key](#2-the-signing-key)
3. [Registration with the network](#3-registration-with-the-network)
4. [The stream](#4-the-stream)
   - [The ladder is your pricing curve](#the-ladder-is-your-pricing-curve)
   - [Minimal client](#minimal-client)
   - [Risk controls](#risk-controls)
   - [Error codes](#error-codes)
5. [Provider-side pricing on the hosted lane](#5-provider-side-pricing-on-the-hosted-lane)
6. [Inventory sizing](#6-inventory-sizing)
   - [Tracking your inventory](#tracking-your-inventory)
7. [Going dark](#7-going-dark)
8. [Addresses](#8-addresses)

## 1. The provider contract

You deploy one contract that holds your `tokenOut` inventory and exposes a single fill hook. It implements `IMMProvider`, four functions:

```solidity
interface IMMProvider {
    // The address whose key signs your boards. EOA or EIP-1271 contract.
    function signer() external view returns (address);

    // View the network quotes hosted flow from. Return the output executeSwap would deliver
    // for these inputs right now, or 0 to decline.
    function previewSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 anchorPrice
    ) external view returns (uint256 amountOut);

    // How much of token you can pay out right now. The executor caps your boards at this.
    function available(address token) external view returns (uint256);

    // The fill. Pull amountIn from msg.sender (the executor), deliver tokenOut to receiver,
    // return the amount delivered.
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 anchorPrice,
        uint256 amountOut,
        address receiver
    ) external returns (uint256 delivered);
}
```

Three ways to have one:

- **Off the shelf.** [`examples/BasicMMProvider.sol`](examples/BasicMMProvider.sol), with [`examples/IMMProvider.sol`](examples/IMMProvider.sol), is the reference implementation: inventory holder, executor gate, owner-controlled signer and executor rotation, owner-only withdrawals, no price logic. Both files are byte-for-byte copies of the contracts repository; the import in `BasicMMProvider.sol` assumes the layout `src/interfaces/IMMProvider.sol` and `src/periphery/examples/BasicMMProvider.sol`, and the contract depends on [solady](https://github.com/Vectorized/solady). Deploy it with `(signer, executor, owner)`, fund it, done. You write no Solidity.
- **The vault you already run.** If your inventory sits in a vault that trusts one router through an ERC-20 allowance, deploy [`examples/RouterVaultProvider.sol`](examples/RouterVaultProvider.sol) with `(vault, signer, executor, owner)`, then from the vault's admin point its router at it and set an allowance per token. The vault keeps the inventory and needs no code change: each fill takes your output from the vault to the receiver and sends the taker's input into the vault, and the allowance is your hard cap. Same layout as above, at `src/periphery/providers/RouterVaultProvider.sol`.
- **Your own contract.** If your inventory already lives onchain (a pool, a vault, a position), implement the four functions on your existing contract instead. Your funds never move to a new address.

### What `executeSwap` does

The executor calls it once per fill, after approving your contract for exactly `amountIn`:

1. Require `msg.sender == approvedExecutor`. This is the entire security boundary on your side: no other address can move inventory.
2. Pull `amountIn` of `tokenIn` from `msg.sender` with `transferFrom`.
3. Deliver `tokenOut` to `receiver` and return the amount delivered.

`amountOut` is the exact total the executor swept across your signed levels from the board's meter, floored per level, so `BasicMMProvider` delivers it as-is. `anchorPrice` is the volume-weighted average of the same sweep, 1e18-scaled tokenOut per tokenIn, for implementations that shape an order from a price. The executor imposes no output cap of its own; the taker's floor is enforced where the trade settles, so a fill that pays less than the board reverts rather than settling worse. Your contract never sees the ladder, only the resolved output for its fill.

### What `available` reports

`available(token)` is how much of `token` your contract can pay out right now: `BasicMMProvider` returns its own balance, `RouterVaultProvider` the smaller of the vault's balance and its allowance. The executor sizes every board to it: `board()` caps `remaining` at what you can pay and `quote()` returns zero for a larger size, so the venue quotes only what makers can pay and a router is not quoted into a fill that would revert. Keep it a cheap view. The executor reads it with a 50,000 gas budget and uses only the first 32 bytes; a revert, an out-of-gas or a short return counts as unbounded. A wrong answer only shrinks or over-states your own board, never another maker's.

### Owner controls on `BasicMMProvider`

| Function | Effect |
|---|---|
| `setSigner(address)` | Rotate the signing key. Boards signed by the old key stop filling at once, because the executor checks `provider.signer() == mm` on every fill. Stream fresh boards under the new key. |
| `setApprovedExecutor(address)` | Rotate the trusted executor. Pointing it anywhere but the executor is an instant hard stop: every fill reverts at your gate. |
| `withdraw(token, amount, to)` | Withdraw inventory at any time. |

Use an owner multisig in production.

## 2. The signing key

The key that signs your boards is `mm` in every message: the board key onchain, the address the venue registers, and the value your provider's `signer()` must return. An EOA works with a 65-byte ECDSA signature; a contract works through EIP-1271. One key can sign for many pairs, directions and chains. The EIP-712 domain is the executor's (`PropAMMExecutor`, version `2`, the chain id, the executor address), and the executor address is the same on every chain, so a signer validated on Base Sepolia moves to another chain by changing `chainId`.

Signatures are standard EIP-712 (`signTypedData` in viem or ethers); the types object and struct layouts are in [price-ladder-streaming.md](price-ladder-streaming.md).

## 3. Registration with the network

Share with the network, per chain: your signer address, your provider address and the pairs and directions you will quote. The stream rejects messages from an unregistered signer (`UNREGISTERED_MARKET_MAKER`), for an unregistered pair (`UNSUPPORTED_PAIR`) or whose signed `provider` differs from the one registered for the pair (`PROVIDER_MISMATCH`).

Nothing onchain is required of you beyond the provider. The hosted lane routes to any registered maker whose board is live. For the onchain lane the venue owner registers your signer on `PropAMMVenue` (`addMaker`) and advertises the pair if it is new; routers then read and fill your board with no further work on your side. Registration is by signer, not by provider: the provider is whatever your signed ladders name.

## 4. The stream

| Environment | WebSocket | Chains |
|---|---|---|
| Staging | `wss://propamm-staging.biconomy.io/v1/ws` | Base Sepolia (84532), mintable test tokens |
| Production | `wss://propamm.biconomy.io/v1/ws` | Base (8453) and BNB Smart Chain (56) |

Same protocol and message shapes on both. A client validated against staging moves to production by changing the endpoint, `chainId` and the token addresses.

Open a connection with your API key in the `x-api-key` header (without a valid key the server refuses the connection with HTTP 401), subscribe once for your signer, then send `price-ladder`, `offsets`, `anchor` and `board-controls` messages as described in [price-ladder-streaming.md](price-ladder-streaming.md). Every accepted message is answered with `{ "type": "ack" }`, every rejected one with `{ "type": "error", "code", "message" }`.

### The ladder is your pricing curve

A board is a curve, expressed as the points a contract can evaluate for free. Each level is a cumulative size and the price that volume up to it fills at, so the board is a step function: the executor sweeps it level by level and floors each segment, `out += floor(take * price / 1e18)`. Twenty levels are enough to track a smooth curve closely; at each level you decide how much size you are showing and what you charge for it.

That has three consequences worth designing around.

- **The shape is yours.** Nothing in the protocol assumes a constant product, a constant sum, or any other formula. A flat top level and a steep tail is a curve. A single level is a flat quote up to a size. A curve your engine already runs offchain becomes a board by sampling it: evaluate your price at each cumulative size you want to show, and sign the result. [`examples/curve-maker-reference.ts`](examples/curve-maker-reference.ts) does exactly that, and samples conservatively so a sampled level never promises more than the curve.
- **Depth is priced, not free.** Prices never improve with depth, so a taker sweeping deeper always pays more. That is what makes splitting an order pointless: consecutive fills continue from the meter and pay the deeper levels, so five small fills never beat one large fill.
- **The curve moves by re-signing, not by trading.** An AMM's price moves because its reserves change. Your board moves because you sign a new anchor or a new ladder. Between your updates the board is exactly what you last signed, which is why the risk controls below exist: age widening and the post-move premium make a quote you have not refreshed cost more, and the block cap bounds how much of it one block can take.

### Minimal client

An offset board: one offset ladder for WETH to USDC at start, then every second one anchor message whose single entry prices both directions of the pair. To quote USDC to WETH as well, sign an offset ladder for that direction; the same anchor entry prices it. Replace `yourPrice()` with your engine's reference price in raw units (see [prices in raw token units](price-ladder-streaming.md#prices-are-in-raw-token-units)).

```ts
import WebSocket from "ws";
import { privateKeyToAccount } from "viem/accounts";

const ENDPOINT = "wss://propamm-staging.biconomy.io/v1/ws";
const CHAIN_ID = 84532;
const EXECUTOR = "0x000000d4d7CB15E0FA9aB2B1fd49ca8537CDCA26"; // same address on every chain
const PROVIDER = "0xYourProviderContract";
const TOKEN_IN = "0x8b414aD7005EeFd315aF2A16538885Eae229bab7";  // MockWETH, 18 decimals
const TOKEN_OUT = "0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df"; // MockUSDC, 18 decimals

const account = privateKeyToAccount(process.env.MM_SIGNER_KEY as `0x${string}`);
const domain = { name: "PropAMMExecutor", version: "2", chainId: CHAIN_ID, verifyingContract: EXECUTOR } as const;
const types = {
  Rung: [{ name: "size", type: "uint256" }, { name: "offsetPpm", type: "uint256" }],
  OffsetLadder: [
    { name: "mm", type: "address" }, { name: "provider", type: "address" },
    { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" },
    { name: "rungs", type: "Rung[]" }, { name: "nonce", type: "uint256" },
    { name: "expiresAt", type: "uint256" }, { name: "driftPpmPerSecond", type: "uint256" },
  ],
  AnchorEntry: [
    { name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" },
    { name: "price", type: "uint256" }, { name: "timestampMs", type: "uint256" },
    { name: "ttl", type: "uint256" }, { name: "skewPpm", type: "uint256" },
    { name: "reverseSkewPpm", type: "uint256" },
  ],
  AnchorBatch: [{ name: "mm", type: "address" }, { name: "entries", type: "AnchorEntry[]" }],
} as const;

const now = () => BigInt(Math.floor(Date.now() / 1000));
// bigint fields go on the wire as decimal strings; chainId stays a number.
const frame = (o: unknown) => JSON.stringify(o, (_, v) => (typeof v === "bigint" ? v.toString() : v));

function yourPrice(): bigint {
  return 2000n * 10n ** 18n; // 2000 tokenOut per tokenIn, both 18 decimals
}

async function sendOffsets(ws: WebSocket) {
  const message = {
    mm: account.address, provider: PROVIDER, tokenIn: TOKEN_IN, tokenOut: TOKEN_OUT,
    rungs: [
      { size: 1n * 10n ** 18n, offsetPpm: 1000n },  // first 1 tokenIn at 10 bps below the anchor
      { size: 3n * 10n ** 18n, offsetPpm: 2500n },  // next 2 tokenIn at 25 bps below
    ],
    nonce: BigInt(Date.now()),          // depth nonce; shared with price ladders for this board
    expiresAt: now() + 1800n,           // the schedule lives 30 minutes
    driftPpmPerSecond: 10n,             // widen 1 bp per second of anchor age
  };
  const signature = await account.signTypedData({ domain, types, primaryType: "OffsetLadder", message });
  ws.send(frame({ type: "offsets", payload: { ...message, signature, chainId: CHAIN_ID } }));
}

let lastTimestampMs = 0n;

async function sendAnchors(ws: WebSocket) {
  const t = BigInt(Date.now());
  lastTimestampMs = t > lastTimestampMs ? t : lastTimestampMs + 1n; // strictly increasing per pair
  const entries = [
    {
      tokenIn: TOKEN_IN, tokenOut: TOKEN_OUT,
      price: yourPrice(),               // TOKEN_IN to TOKEN_OUT; the reverse prices at 1e36 / price
      timestampMs: lastTimestampMs,     // when this price was produced; the drift origin and ordering key
      ttl: 15n,                         // dark 15 seconds after timestampMs if no fresher anchor lands
      skewPpm: 0n,                      // extra discount on TOKEN_IN to TOKEN_OUT
      reverseSkewPpm: 0n,               // extra discount on TOKEN_OUT to TOKEN_IN
    },
    // one entry per further pair you quote, up to 32 per message
  ];
  const message = { mm: account.address, entries };
  const signature = await account.signTypedData({ domain, types, primaryType: "AnchorBatch", message });
  ws.send(frame({ type: "anchor", payload: { ...message, signature, chainId: CHAIN_ID } }));
}

const ws = new WebSocket(ENDPOINT, { headers: { "x-api-key": process.env.PROPAMM_API_KEY as string } });
ws.on("message", (m) => console.log(m.toString()));
ws.on("open", async () => {
  ws.send(JSON.stringify({ type: "subscribe", data: { type: "price-ledger", mm: account.address } }));
  await sendOffsets(ws);                                   // once, and again only when sizes, offsets or drift change
  setInterval(() => void sendAnchors(ws), 1000);           // every pair's price, every second
});
ws.on("close", () => process.exit(1));                     // let a supervisor restart for a clean reconnect
```

A price-ladder maker replaces the two senders with one that signs `PriceLadder` (`levels` of `{ size, price }`, `primaryType: "PriceLadder"`) on every tick and sends it as `type: "price-ladder"`. A runnable variant that samples a pricing curve into a ladder is in [`examples/curve-maker-reference.ts`](examples/curve-maker-reference.ts). Stream both directions of a pair if you want to serve both; each direction is its own board with its own depth nonce, meter and controls, and one anchor entry prices both.

### Risk controls

Between two of your ticks the board is a firm quote that anyone may take. Three optional limits, all signed by you in one `BoardControls` message with its own nonce and an `expiresAt` commit deadline, bound what that costs. Once committed they hold until you sign a fresher controls nonce: depth and anchor commits do not clear them, and each one only ever restricts a fill, so adding them can never make your board offer more than it does today.

| Control | What it does | A reasonable starting point |
|---|---|---|
| `blockCap` | Bounds the tokenIn any single block may fill from the board, counting every caller and both lanes | A fraction of your top size, sized to one block of adverse flow you accept |
| `widenPpmPerSqrtSecond` | Adds `widenPpmPerSqrtSecond * floor(sqrt(age))` ppm of discount, where `age` is the quote's age in seconds | 50 to 200 ppm, depending on how fast the pair moves |
| `premiumPpm` with `premiumBlocks` | Adds `premiumPpm` of discount for that many blocks after you commit depth, an anchor or the controls, counting the commit block as the first | A few hundred ppm for 1 or 2 blocks. If you anchor every block or flashblock, the premium applies almost continuously: size it for that or keep it at 0 and rely on widening |

```ts
const CONTROLS = [
  { name: "mm", type: "address" }, { name: "tokenIn", type: "address" },
  { name: "tokenOut", type: "address" }, { name: "nonce", type: "uint256" },
  { name: "blockCap", type: "uint256" }, { name: "widenPpmPerSqrtSecond", type: "uint256" },
  { name: "premiumPpm", type: "uint256" }, { name: "premiumBlocks", type: "uint256" },
  { name: "expiresAt", type: "uint256" },
] as const;

async function sendControls(ws: WebSocket) {
  const message = {
    mm: account.address, tokenIn: TOKEN_IN, tokenOut: TOKEN_OUT,
    nonce: BigInt(Date.now()),           // controls nonce, its own sequence
    blockCap: 5n * 10n ** 18n,           // at most 5 tokenIn from this board in any one block
    widenPpmPerSqrtSecond: 100n,         // 100 ppm after 1 s, 200 after 4 s, 500 after 25 s
    premiumPpm: 500n,                    // 5 bps extra
    premiumBlocks: 1n,                   // for the block in which the price moves
    expiresAt: now() + 300n,             // commit deadline, not a lifetime; committed controls hold until replaced
  };
  const signature = await account.signTypedData({
    domain, types: { BoardControls: CONTROLS }, primaryType: "BoardControls", message,
  });
  ws.send(frame({ type: "board-controls", payload: { ...message, signature, chainId: CHAIN_ID } }));
}
```

Send it once after your first board and again only when the numbers change. Sign `expiresAt` a few minutes ahead: after it the commit is rejected with `ControlsExpired()` (`CommitRejected` kind 4) and the nonce is not consumed, so sign a fresh message if that happens. The cap is visible to integrators before they send anything: `board()` reports `remaining` as the smallest of your depth left, what the block has left under the cap and what your provider's `available` reports, the executor's `quote` returns zero above that, and the venue routes the rest of an order to other makers instead of failing it. Read your own state back with `controls(mm, tokenIn, tokenOut)`, which also returns how much this block has already filled.

Full field semantics, validation rules and the wire frame are in [price-ladder-streaming.md](price-ladder-streaming.md#board-controls).

### Error codes

| Code | Meaning | Fix |
|---|---|---|
| `INVALID_JSON` | frame is not valid JSON | check encoding |
| `INVALID_MESSAGE` | schema mismatch, or a validation rule failed (a size not ascending, an offset at or above `1e6`, `expiresAt` more than an hour out) | see the rules in [price-ladder-streaming.md](price-ladder-streaming.md#validation-rules) |
| `NOT_SUBSCRIBED` | a board message before the subscribe `ack` | subscribe first |
| `MARKET_MAKER_MISMATCH` | payload `mm` differs from the subscribed `mm` | one signer per connection |
| `RATE_LIMITED` | over 300 board messages per second on the connection | back off |
| `UNSUPPORTED_CHAIN` | `chainId` not served by this environment | check the environment table |
| `UPDATE_EXPIRED` | `expiresAt` (on a ladder or on controls), or an anchor entry's `timestampMs / 1000 + ttl`, already in the past | clock skew or TTL too short |
| `INVALID_TOKEN_PAIR` | `tokenIn` equals `tokenOut` | fix the pair |
| `UNREGISTERED_MARKET_MAKER` | signer not registered | complete registration |
| `INVALID_SIGNATURE` | recovered signer does not match `mm` | check the domain: version `2`, executor address, `chainId`, and the types object |
| `UNSUPPORTED_PAIR` | pair or direction not registered for you on that chain; for an anchor message, any entry whose pair is not registered in either direction refuses the whole message | register it, check addresses and `chainId` |
| `PROVIDER_MISMATCH` | signed `provider` differs from the one registered for the pair | sign the registered provider or update the registration |
| `STALE_NONCE` | nonce at or below the last accepted one for this board; the depth and controls sequences are counted separately; an anchor message is stale only when every entry is at or below its pair's last `timestampMs` | keep nonces and anchor timestamps strictly increasing; unix milliseconds work |
| `STORE_FAILED` | transient server-side failure | safe to continue; the next message replaces it |

### Limits

| Item | Value |
|---|---|
| Rate limit | 300 board messages per second per connection |
| Max frame size | 64 KB |
| Inactivity | 60 seconds without inbound traffic closes the connection; the server pings every 10 seconds and standard libraries answer automatically |
| Levels or rungs per message | 20 |
| Entries per anchor message | 32, at most one per pair |
| `expiresAt` | in the future, at most one hour ahead, on ladders and on board controls |
| Anchor `ttl` | 1 to 3600 seconds |

### Verify

Your board is onchain when `board(mm, tokenIn, tokenOut)` on the executor or the venue returns your levels with `remaining` equal to your top size. The exact calls are in [maker-quickstart-base-weth-usdc.md](maker-quickstart-base-weth-usdc.md).

## 5. Provider-side pricing on the hosted lane

On the hosted lane the network quotes each maker from the maker's own contract: it calls `previewSwap(tokenIn, tokenOut, amountIn, anchorPrice)` with the price the board resolves to for that size, and the intent's `minAmountOut` is computed from what your contract says. That lets a provider price fills from its own state:

- `previewSwap` may apply any deterministic curve over the price it is handed (inventory-dependent spread, a spread that widens with time since your last update) or ignore it and price from onchain state. `executeSwap` then delivers what the curve says. Keep the two consistent so quotes equal execution.
- Return `0` from `previewSwap` to decline a quote (inventory too thin, paused, off-hours); the network skips you for that route instead of surfacing a failing quote.
- The taker's floor and the board's meter still bound every fill: a signing key can never make your contract pay more than its own math allows, and your board's top size still caps the volume any version fills.

On the onchain lane the venue quotes from the board, not from `previewSwap`. A provider that delivers less than the swept total there fails the router's floor and the fill reverts, so provider-side dynamics that pay below the board are a hosted-lane feature only. `BasicMMProvider` delivers exactly the swept total and serves both lanes identically. Its `previewSwap` returns `amountIn * anchorPrice / 1e18` from the sweep's floored average price, which is never above the swept total and at most a wei below it across levels, so a hosted floor computed from it always clears.

## 6. Inventory sizing

- Inventory is `tokenOut` per direction. A WETH to USDC board pays from your USDC; the incoming WETH lands in your provider and funds the reverse direction if you quote it.
- The top size of a depth version is your exposure cap for that version: across every route, lane and retry, one version never fills more than its top size, and the most `tokenOut` it can pay is the sum over its levels of `(size_i - size_{i-1}) * price_i / 1e18`. Holding less is safe: the executor caps each board at what `available` reports, so a short provider shows less depth instead of failing fills. If `executeSwap` still cannot pay, the fill reverts and nothing is lost.
- Both lanes draw on one meter. A hosted fill and a venue fill of the same version consume the same depth.
- On price ladders every commit re-opens the full top size. On offset boards depth re-opens only when you re-sign the offset ladder, so the top size is exposure per offset-ladder version, however many anchors you push. One anchor entry re-prices both directions of a pair, and each direction keeps its own meter.
- A fill whose output floors to zero is refused by the executor, and the venue never allocates such a size; there is no dust drain.
- A block cap does not reduce your depth. It bounds the rate at which a version can be consumed, not the total: an order larger than the cap fills up to the cap this block and the rest of the board is still there in the next one.

### Tracking your inventory

Everything you need to follow your own position is public chain state, so an engine that wants fills and balances as inputs reads the chain and needs no API of ours.

| What you want to know | Where to read it |
|---|---|
| Current inventory | `balanceOf` on your provider address, per token, or `available(token)` on the provider, the figure the executor sizes your boards to |
| How much of the live version has been filled | `board(mm, tokenIn, tokenOut)`: `filled` is the meter, `remaining` is what is still fillable right now |
| What is left under your block cap | `controls(mm, tokenIn, tokenOut)`: `filledThisBlock`, against your `blockCap` |
| Each fill as it happens | `MMFillExecuted(mmProvider, mmSigner, receiver, tokenIn, tokenOut, amountIn, amountOut, avgPrice, filledAfter, caller, nonce, anchorNonce)` on the executor, plus `Transfer` on both tokens |
| Which of your messages reached the chain | `LadderCommitted`, `OffsetsCommitted`, `AnchorCommitted` and `ControlsCommitted` on the executor |
| Whether a trade came through a router or a user intent | `PropAMMSwap` at the entrypoint that settled it, with an indexed `lane` topic |

`filledAfter` on `MMFillExecuted` is the meter after that fill, so a single event stream tells you both the trade and the depth left without a follow-up call. `caller` is the address that called `fill` (the venue, a hosted settlement or a direct taker), `nonce` the depth version that priced the fill and `anchorNonce` the pair anchor's `timestampMs` that priced it. Filter the executor by your provider address or your signer address, both indexed. `MMFillExecuted` is one maker leg: a single trade split across makers emits one per maker, so never sum it against `PropAMMSwap` totals.

## 7. Going dark

Every path is unilateral and needs no permission from anyone.

| Method | Effect | Latency |
|---|---|---|
| Stop streaming | Each board dies at the TTL you signed. `board()` returns no levels, `quote` returns zero, `fill` reverts `BoardInactive`, the venue skips you. | one TTL |
| Tighten the controls | Sign a fresher controls nonce with a small `blockCap`, or with widening large enough to take the board dark. Applies to every board version until you replace it. | one commit |
| Tombstone | Sign a depth version with a fresher nonce, a dust top size and a TTL covering the longest outstanding quote. Replaces every level and resets the meter; anything in flight fills at most the dust. | one commit |
| `executor.setPaused(true)` from your signing address | Every board of yours goes dark at once: fills revert `BoardInactive`, `quote` returns zero, `board()` shows nothing remaining, the venue skips you. Emits `MakerPaused(mm, true)`; `setPaused(false)` brings back whatever is still live, and `makerPaused(mm)` reads the state. Needs no signed message or keeper, so it works even if the network is down; the signing address sends the transaction and pays its gas. | one transaction |
| `setApprovedExecutor` to another address | Every fill reverts at your provider's gate, whatever boards are committed. | one transaction |
| `withdraw` | Empties the provider; fills revert for lack of inventory. | one transaction |

To resume after a stop, stream fresh messages with fresher nonces; an older nonce never comes back, even after expiry. The venue owner can also remove a maker from the registry; that changes nothing for the hosted lane or for direct callers of the executor while the board is live.

## 8. Addresses

The executor is the address that matters to you: your messages are signed against it and it is the only address your provider trusts. The venue is where routers read and fill your board.

Same addresses on Base (8453), BNB Smart Chain (56) and Base Sepolia (84532):

| Contract | Address |
|---|---|
| `PropAMMExecutor` | `0x000000d4d7CB15E0FA9aB2B1fd49ca8537CDCA26` |
| `PropAMMVenue` | `0x000000Da21a0f02b2626874870b6447Db220C1EF` |
| `PropAMMHostedSettlement` | `0x0000002E6a90921B97A933deA6600f5e534f56b8` |

The executor address is the EIP-712 `verifyingContract`, so a board signed for an earlier executor does not verify against this one; your provider's `approvedExecutor` must also be this executor. Between chains only `chainId` changes in the domain. The other value to recompute per chain is the raw price, which depends on that chain's token decimals.

Base Sepolia test tokens, mintable by anyone through `mint(address,uint256)`:

| Token | Address | Decimals |
|---|---|---|
| MockWETH | `0x8b414aD7005EeFd315aF2A16538885Eae229bab7` | 18 |
| MockUSDC | `0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df` | 18 |
| MockDAI | `0xa3Db3e064D74fF11e6E07b9869a67f1E4FCFEcFb` | 18 |
