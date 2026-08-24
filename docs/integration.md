# Maker integration

What a market maker runs to quote on PropAMM: a provider contract that holds inventory, a signing key, and a WebSocket connection that streams signed boards. Someone else always submits the transaction and pays the gas.

1. [The provider contract](#1-the-provider-contract)
2. [The signing key](#2-the-signing-key)
3. [Registration with the network](#3-registration-with-the-network)
4. [The stream](#4-the-stream)
5. [Provider-side pricing on the hosted lane](#5-provider-side-pricing-on-the-hosted-lane)
6. [Inventory sizing](#6-inventory-sizing)
7. [Going dark](#7-going-dark)
8. [Addresses](#8-addresses)

## 1. The provider contract

You deploy one contract that holds your `tokenOut` inventory and exposes a single fill hook. It implements `IMMProvider`, three functions:

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

Two ways to have one:

- **Off the shelf.** [`examples/BasicMMProvider.sol`](examples/BasicMMProvider.sol), with [`examples/IMMProvider.sol`](examples/IMMProvider.sol), is the reference implementation: inventory holder, executor gate, owner-controlled signer and executor rotation, owner-only withdrawals, no price logic. Both files are byte-for-byte copies of the contracts repository; the import in `BasicMMProvider.sol` assumes the layout `src/interfaces/IMMProvider.sol` and `src/periphery/examples/BasicMMProvider.sol`, and the contract depends on [solady](https://github.com/Vectorized/solady). Deploy it with `(signer, executor, owner)`, fund it, done. You write no Solidity.
- **Your own contract.** If your inventory already lives onchain (a pool, a vault, a position), implement the three functions on your existing contract instead. Your funds never move to a new address.

### What `executeSwap` does

The executor calls it once per fill, after approving your contract for exactly `amountIn`:

1. Require `msg.sender == approvedExecutor`. This is the entire security boundary on your side: no other address can move inventory.
2. Pull `amountIn` of `tokenIn` from `msg.sender` with `transferFrom`.
3. Deliver `tokenOut` to `receiver` and return the amount delivered.

`amountOut` is the exact total the executor swept across your signed levels from the board's meter, floored per level, so `BasicMMProvider` delivers it as-is. `anchorPrice` is the volume-weighted average of the same sweep, 1e18-scaled tokenOut per tokenIn, for implementations that shape an order from a price. The executor imposes no output cap of its own; the taker's floor is enforced where the trade settles, so a fill that pays less than the board reverts rather than settling worse. Your contract never sees the ladder, only the resolved output for its fill.

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
| Staging | `wss://propamm-staging.biconomy.io` | Base Sepolia (84532), mintable test tokens |
| Production | `wss://propamm.biconomy.io` | Base (8453) and BNB Smart Chain (56) |

Same protocol and message shapes on both. A client validated against staging moves to production by changing the endpoint, `chainId` and the token addresses.

Open a connection, subscribe once for your signer, then send `price-ladder`, `offsets` and `anchor` messages as described in [price-ladder-streaming.md](price-ladder-streaming.md). Every accepted message is answered with `{ "type": "ack" }`, every rejected one with `{ "type": "error", "code", "message" }`.

### Minimal client

An offset board: one offset ladder per direction at start, then an anchor per direction every second. Replace `yourPrice()` with your engine's reference price in raw units (see [prices in raw token units](price-ladder-streaming.md#prices-are-in-raw-token-units)).

```ts
import WebSocket from "ws";
import { privateKeyToAccount } from "viem/accounts";

const ENDPOINT = "wss://propamm-staging.biconomy.io";
const CHAIN_ID = 84532;
const EXECUTOR = "0x000000F80660419ECcED6F86dBc762725371eb56"; // identical on every chain
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
  Anchor: [
    { name: "mm", type: "address" }, { name: "tokenIn", type: "address" },
    { name: "tokenOut", type: "address" }, { name: "price", type: "uint256" },
    { name: "nonce", type: "uint256" }, { name: "timestamp", type: "uint256" },
    { name: "expiresAt", type: "uint256" },
  ],
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

async function sendAnchor(ws: WebSocket) {
  const t = now();
  const message = {
    mm: account.address, tokenIn: TOKEN_IN, tokenOut: TOKEN_OUT,
    price: yourPrice(),
    nonce: BigInt(Date.now()),          // anchor nonce, independent of the depth nonce; fits uint48
    timestamp: t,                       // when this price was produced; the drift origin
    expiresAt: t + 15n,                 // dark 15 seconds after this tick if no fresher anchor lands
  };
  const signature = await account.signTypedData({ domain, types, primaryType: "Anchor", message });
  ws.send(frame({ type: "anchor", payload: { ...message, signature, chainId: CHAIN_ID } }));
}

const ws = new WebSocket(ENDPOINT);
ws.on("message", (m) => console.log(m.toString()));
ws.on("open", async () => {
  ws.send(JSON.stringify({ type: "subscribe", data: { type: "price-ledger", mm: account.address } }));
  await sendOffsets(ws);                                   // once, and again only when sizes, offsets or drift change
  setInterval(() => void sendAnchor(ws), 1000);            // the price, every second
});
ws.on("close", () => process.exit(1));                     // let a supervisor restart for a clean reconnect
```

A price-ladder maker replaces the two senders with one that signs `PriceLadder` (`levels` of `{ size, price }`, `primaryType: "PriceLadder"`) on every tick and sends it as `type: "price-ladder"`. A runnable variant that samples a pricing curve into a ladder is in [`examples/curve-maker-reference.ts`](examples/curve-maker-reference.ts). Stream both directions of a pair if you want to serve both; each direction is its own board with its own nonces, meter and anchor.

### Error codes

| Code | Meaning | Fix |
|---|---|---|
| `INVALID_JSON` | frame is not valid JSON | check encoding |
| `INVALID_MESSAGE` | schema mismatch, or a validation rule failed (a size not ascending, an offset at or above `1e6`, `expiresAt` more than an hour out) | see the rules in [price-ladder-streaming.md](price-ladder-streaming.md#validation-rules) |
| `NOT_SUBSCRIBED` | a board message before the subscribe `ack` | subscribe first |
| `MARKET_MAKER_MISMATCH` | payload `mm` differs from the subscribed `mm` | one signer per connection |
| `RATE_LIMITED` | over 300 board messages per second on the connection | back off |
| `UNSUPPORTED_CHAIN` | `chainId` not served by this environment | check the environment table |
| `UPDATE_EXPIRED` | `expiresAt` already in the past | clock skew or TTL too short |
| `INVALID_TOKEN_PAIR` | `tokenIn` equals `tokenOut` | fix the pair |
| `UNREGISTERED_MARKET_MAKER` | signer not registered | complete registration |
| `INVALID_SIGNATURE` | recovered signer does not match `mm` | check the domain: version `2`, executor address, `chainId`, and the types object |
| `UNSUPPORTED_PAIR` | pair or direction not registered for you on that chain | register it, check addresses and `chainId` |
| `PROVIDER_MISMATCH` | signed `provider` differs from the one registered for the pair | sign the registered provider or update the registration |
| `STALE_NONCE` | nonce at or below the last accepted one for this board | keep nonces strictly increasing; unix milliseconds work |
| `STORE_FAILED` | transient server-side failure | safe to continue; the next message replaces it |

### Limits

| Item | Value |
|---|---|
| Rate limit | 300 board messages per second per connection |
| Max frame size | 64 KB |
| Inactivity | 60 seconds without inbound traffic closes the connection; the server pings every 10 seconds and standard libraries answer automatically |
| Levels or rungs per message | 20 |
| `expiresAt` | in the future, at most one hour ahead |

### Verify

Your board is onchain when `board(mm, tokenIn, tokenOut)` on the executor or the venue returns your levels with `remaining` equal to your top size. The exact calls are in [maker-quickstart.md](maker-quickstart.md).

## 5. Provider-side pricing on the hosted lane

On the hosted lane the network quotes each maker from the maker's own contract: it calls `previewSwap(tokenIn, tokenOut, amountIn, anchorPrice)` with the price the board resolves to for that size, and the intent's `minAmountOut` is computed from what your contract says. That lets a provider price fills from its own state:

- `previewSwap` may apply any deterministic curve over the price it is handed (inventory-dependent spread, a spread that widens with time since your last update) or ignore it and price from onchain state. `executeSwap` then delivers what the curve says. Keep the two consistent so quotes equal execution.
- Return `0` from `previewSwap` to decline a quote (inventory too thin, paused, off-hours); the network skips you for that route instead of surfacing a failing quote.
- The taker's floor and the board's meter still bound every fill: a signing key can never make your contract pay more than its own math allows, and your board's top size still caps the volume any version fills.

On the onchain lane the venue quotes from the board, not from `previewSwap`. A provider that delivers less than the swept total there fails the router's floor and the fill reverts, so provider-side dynamics that pay below the board are a hosted-lane feature only. `BasicMMProvider` delivers exactly the swept total and serves both lanes identically.

## 6. Inventory sizing

- Inventory is `tokenOut` per direction. A WETH to USDC board pays from your USDC; the incoming WETH lands in your provider and funds the reverse direction if you quote it.
- The top size of a depth version is your exposure cap for that version: across every route, lane and retry, one version never fills more than its top size, and the most `tokenOut` it can pay is the sum over its levels of `(size_i - size_{i-1}) * price_i / 1e18`. Keep at least that much in the provider, or `executeSwap` reverts and the fill fails (the trade reverts; nothing is lost).
- Both lanes draw on one meter. A hosted fill and a venue fill of the same version consume the same depth.
- On price ladders every commit re-opens the full top size. On offset boards depth re-opens only when you re-sign the offset ladder, so the top size is exposure per offset-ladder version, however many anchors you push.
- A fill whose output floors to zero is refused by the executor, and the venue never allocates such a size; there is no dust drain.
- Tracking: your provider's balances are public state, every fill emits `MMFillExecuted(provider, signer, receiver, tokenIn, tokenOut, amountIn, amountOut, avgPrice, filledAfter)` on the executor and `Transfer` on your tokens, and `board()` shows the meter live. An engine that wants fills and balances as inputs reads chain events and needs no API of ours.

## 7. Going dark

Every path is unilateral and needs no permission from anyone.

| Method | Effect | Latency |
|---|---|---|
| Stop streaming | Each board dies at the TTL you signed. `board()` returns no levels, `quote` returns zero, `fill` reverts `BoardInactive`, the venue skips you. | one TTL |
| Tombstone | Sign a depth version with a fresher nonce, a dust top size and a TTL covering the longest outstanding quote. Replaces every level and resets the meter; anything in flight fills at most the dust. | one commit |
| `setApprovedExecutor` to another address | Every fill reverts at your provider's gate, whatever boards are committed. | one transaction |
| `withdraw` | Empties the provider; fills revert for lack of inventory. | one transaction |

To resume after a stop, stream fresh messages with fresher nonces; an older nonce never comes back, even after expiry. The venue owner can also remove a maker from the registry; that changes nothing for the hosted lane or for direct callers of the executor while the board is live.

## 8. Addresses

The executor is the address that matters to you: your messages are signed against it and it is the only address your provider trusts. The venue is where routers read and fill your board. Both are identical on every chain.

| Contract | Address | Live on |
|---|---|---|
| `PropAMMExecutor` | `0x000000F80660419ECcED6F86dBc762725371eb56` | Base, BNB Smart Chain, Base Sepolia |
| `PropAMMVenue` | `0x000000445Dff11123a3BD8A4Dd03a351829aF892` | Base, BNB Smart Chain, Base Sepolia |
| `PropAMMHostedSettlement` | `0x0000009420a62D78de8bdCe89A12B8eccc37D19b` | Base, BNB Smart Chain, Base Sepolia |

The addresses are identical on Base (8453), BNB Smart Chain (56) and Base Sepolia (84532). Because the executor address and the EIP-712 domain are identical everywhere, a signing setup carries over by changing `chainId`; the one value to recompute is the raw price, which depends on each chain's token decimals.

Base Sepolia test tokens, mintable by anyone through `mint(address,uint256)`:

| Token | Address | Decimals |
|---|---|---|
| MockWETH | `0x8b414aD7005EeFd315aF2A16538885Eae229bab7` | 18 |
| MockUSDC | `0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df` | 18 |
| MockDAI | `0xa3Db3e064D74fF11e6E07b9869a67f1E4FCFEcFb` | 18 |
