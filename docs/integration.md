# propAMM Integration Guide

This document covers what an integrator needs to do to plug into the propAMM protocol — either as a market maker (deploying a provider contract and signing price updates and/or RFQ quotes) or as an aggregator (routing user orders through the settlement contract on behalf of an existing flow).

It assumes familiarity with the conceptual architecture described in the companion architecture document. It does not assume familiarity with the underlying implementation.

## Aggregator integration modes

The propAMM v1 settlement contract supports three aggregator integration patterns. Pick whichever fits the pair's liveness profile and your off-chain infrastructure budget, or support all three.

The three quote surfaces:

| Surface | Where | What it returns | Best for |
|---|---|---|---|
| `quoteSwap` | on-chain `view` | best routed `amountOut` + winning MM from stored anchors | contract-to-contract aggregators with zero off-chain HTTP dependency |
| `GET /quote/streaming` | orchestrator HTTP | `intentTemplate + PriceUpdate + mmSig + bestAmountOut + quoteId` | aggregators that want best-routed pricing including a fresh in-block anchor |
| `GET /quote/rfq` | orchestrator HTTP | `intentTemplate + MMQuote + quoteSig + amountOut + quoteId` | aggregators routing into pairs where streaming is unavailable, or where firm per-order pricing is preferred |

All three are accompanied by one of the five `payable` settle entry points:

- `settleSingle(bundle, priceUpdates, mmSigs)` — streaming.
- `settleBatch(bundles, priceUpdates, mmSigs)` — streaming.
- `settleBulk(IntentBatch[])` — streaming.
- `settleSingleWithQuote(bundle, quote, quoteSig)` — RFQ.
- `settleBatchWithQuotes(bundles, quotes, quoteSigs)` — RFQ.

### Mode 1 — Anchor-only (streaming, on-chain only)

Caller calls `quoteSwap(tokenIn, tokenOut, amountIn, feeAmount)` (a `view` function) to read the best routed quote out of all registered MMs' currently-stored anchors, then settles via `settleSingle(signedIntent, [], [])` with **empty `priceUpdates` and `mmSigs` arrays**. The contract reads each registered MM's stored anchor, filters to same-block ones, and routes among the survivors using `previewSwap`.

```solidity
// 1. Read the best routed quote from stored anchors.
(uint256 bestAmountOut, address bestMM) = IPropAMMSettlement(settlement)
    .quoteSwap(tokenIn, tokenOut, amountIn, feeAmount);

require(bestAmountOut >= userMinOut, "no route");

// 2. Settle. Empty priceUpdates / mmSigs — relying on stored anchors.
PriceUpdate[] memory emptyUpdates;
bytes[] memory emptySigs;
IPropAMMSettlement(settlement).settleSingle(signedIntent, emptyUpdates, emptySigs);
```

**When this works**: pairs where the orchestrator (or some other caller) is keeping anchors hot every block. If any settle in the current block has already committed a fresh `PriceUpdate` for the relevant MM × pair direction, this aggregator's tx sees that anchor. On Base with sub-block ordering and an active orchestrator, this is the common case on liquid pairs.

**No off-chain dependency.** The aggregator never needs to call the orchestrator's HTTP API, never needs a fresh `PriceUpdate` blob in calldata, never needs to know about MM signing keys.

**Failure mode.** If no MM has a same-block anchor (cold pair, low-volume hour, in-block ordering put the aggregator's tx before the orchestrator's first commit), `quoteSwap` returns `bestAmountOut == 0` and the aggregator should fall back to Mode 2 or Mode 3.

**Per-direction note.** `quoteSwap` is direction-specific. To quote `USDC → WETH`, you pass those as `tokenIn` / `tokenOut`; the contract does not infer the reverse from a stored `WETH → USDC` anchor.

### Mode 2 — Atomic-commit (streaming, with off-chain fresh anchor)

Caller calls `GET /quote/streaming?…` against the orchestrator, which returns a freshest `PriceUpdate + mmSig` bundle alongside an `intentTemplate` and an estimated `bestAmountOut`. The user signs the intent; the aggregator (or the orchestrator) submits `settleSingle(signedIntent, [priceUpdate], [mmSig])`. The contract verifies the MM signature, treats the price as the freshest available for routing, and lazily commits the consumed update to storage at the end of the tx.

```http
GET /quote/streaming?trader=…&tokenIn=…&tokenOut=…&amountIn=…&relayMode=self
```

```jsonc
// response
{
  "intentTemplate": {
    "trader": "0x...",
    "receiver": "0x...",
    "tokenIn": "0x...",
    "amountIn": "1000000000000000000",
    "tokenOut": "0x...",
    "minAmountOut": "...",
    "feeAmount": "0",            // self-relay
    "deadline": "...",
    "nonce": "...",
    ...
  },
  "priceUpdate": { "mm": "0x...", "tokenIn": "0x...", "tokenOut": "0x...",
                   "price": "...", "nonce": "...", "expiresAt": "..." },
  "mmSig": "0x...",
  "bestAmountOut": "...",
  "quoteId": "uuid"
}
```

```solidity
// 2. Settle with the fetched PriceUpdate + mmSig in the arrays.
PriceUpdate[] memory updates = new PriceUpdate[](1);
updates[0] = priceUpdate;
bytes[] memory sigs = new bytes[](1);
sigs[0] = mmSig;
IPropAMMSettlement(settlement).settleSingle(signedIntent, updates, sigs);
```

**When this works**: always, as long as the orchestrator can reach at least one streaming MM for the pair direction. Routing still considers every other registered MM's stored anchors alongside the caller-supplied update — the route picks the best `amountOut` across all eligible MMs.

**Cost.** Approximately 3k extra gas for MM signature verification, plus a 2-SSTORE lazy commit for the consumed update, amortised across however many intents land in the same batch.

**Off-chain dependency.** One HTTP call to the orchestrator's `/quote/streaming` endpoint.

**Relay mode.** `relayMode=self` returns an intent with `feeAmount = 0` for the user/wallet/aggregator to submit. `relayMode=orchestrator` returns an intent with `feeAmount > 0` that the orchestrator will submit after `POST /intents`.

### Mode 3 — Pin-RFQ (firm signed quote)

For pairs where streaming is unavailable, large fills with bespoke pricing, or aggregators that prefer firm per-order quotes over best-routed averages: call `GET /quote/rfq?…` to receive a signed `MMQuote` plus an `intentTemplate`. The user signs the intent; the aggregator submits `settleSingleWithQuote(signedIntent, quote, quoteSig)`.

```http
GET /quote/rfq?trader=…&tokenIn=…&tokenOut=…&amountIn=…&relayMode=orchestrator
```

```jsonc
// response
{
  "intentTemplate": {
    "trader": "0x...",
    "tokenIn": "0x...",         // may be NATIVE_SENTINEL for native
    "amountIn": "1000000000000000000",
    "tokenOut": "0x...",
    "minAmountOut": "...",
    "feeAmount": "500000000000000",   // orchestrator-relay
    "deadline": "...",
    "nonce": "...",
    ...
  },
  "mmQuote": {
    "mm": "0x...",
    "trader": "0x...",
    "tokenIn": "0x...",          // LOGICAL — WETH for native, never the sentinel
    "tokenOut": "0x...",
    "amountIn":   "999500000000000000",   // NET — gross - feeAmount - protocolFee
    "amountOut":  "2998500000000",        // firm commitment
    "expiresAt":  "1733000010000",
    "nonce":      "1733000001234"
  },
  "quoteSig": "0x...",
  "quoteId": "uuid"
}
```

```solidity
// 2. Settle with the signed MMQuote.
IPropAMMSettlement(settlement).settleSingleWithQuote(signedIntent, mmQuote, quoteSig);
```

**When this works**: any time the MM is online and willing to quote. Settlement validates the quote signature, resolves `quote.mm` to its registered provider, and enforces the cryptographic fee binding (`netAmountIn == quote.amountIn`). No on-chain routing; no anchor read or write.

**Cost.** Per-intent gas anchored by the user sig check + quote sig check + tokenIn split + executeSwap hook + tokenOut pull — roughly ~95k for an ERC-20 → ERC-20 RFQ fill on Base.

**Off-chain dependency.** One HTTP call to `/quote/rfq` per intent. The MM round-trip happens on the orchestrator side; the aggregator sees only the bundled response.

**Critical pairing requirement.** `mmQuote.amountIn` is the **net** amount. If the aggregator changes `intent.feeAmount` between fetching the quote and submitting, or if the protocol's `protocolFeeBps` changes between sign and settle, the settlement contract's `netAmountIn == quote.amountIn` check fails and the intent reverts with `QuoteNetAmountInMismatch`. The orchestrator returns a `quoteId` so the aggregator can re-fetch on drift.

### Native ETH input/output (all modes)

The settlement contract uses a single sentinel address for native ETH:

```solidity
address constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEEeEeEeeeEeEeeeeEEeEEeE;
```

Set `intent.tokenIn = NATIVE_SENTINEL` for native input, or `intent.tokenOut = NATIVE_SENTINEL` for native output. The sentinel appears only in `SwapIntent`. In the `MMQuote` and in `PriceUpdate`, the tokens are always logical (WETH for native pairs).

- **Native input**: requires self-relay structurally. The user calls a `payable` settle entry point with `msg.value == intent.amountIn`, and the contract enforces `msg.sender == intent.trader`. Settlement deposits to WETH and splits net WETH to the MM inventory + fee recipients. The orchestrator cannot relay a native-input intent because it does not custody user ETH.
- **Native output**: works in both relay modes. Settlement pulls WETH from MM inventory, calls `WETH.withdraw`, and forwards ETH to the user's receiver. The orchestrator can carry an ERC-20 → native intent on behalf of the user.

Aggregator-side checklist:

- Quote endpoints take `tokenIn` / `tokenOut` as either the sentinel (user-facing) or the logical token; the orchestrator normalises and returns a bundle that matches the user-facing intent.
- For self-relay with native input, your settle call must be a `payable` call with `msg.value = intent.amountIn` and `msg.sender = intent.trader`. Wallet integration: the wallet performs the call directly; aggregator contracts cannot relay native input.
- For native output via orchestrator-relay: just request `GET /quote/rfq?...&tokenOut=NATIVE_SENTINEL` or the streaming equivalent; the orchestrator handles submission.

### Recommended pattern

Aggregators should implement **Mode 1 first** for the common case (liquid pairs, hot orchestrator, on-chain only), with **Mode 2 fallback** for cold streaming pairs and **Mode 3 fallback** for pairs where no MM streams. Native-input intents should be routed directly through the user's wallet via self-relay; the aggregator can still construct the intent template and approval but cannot perform the on-chain submission for native-input intents on the user's behalf.

### `IPropAMMSettlement` — the stable integrator interface

```solidity
interface IPropAMMSettlement {
    // The single on-chain quote view in v1.
    // Reads each registered MM's currently-stored anchor (filtered to same-block),
    // returns the best routed amountOut after fee deductions.
    function quoteSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 feeAmount)
        external view returns (uint256 bestAmountOut, address bestMM);

    // Streaming settle paths (all payable to support native input via msg.value).
    function settleSingle(
        SignedIntent calldata signedIntent,
        PriceUpdate[] calldata priceUpdates,
        bytes[] calldata mmSigs
    ) external payable;

    function settleBatch(
        SignedIntent[] calldata signedIntents,
        PriceUpdate[] calldata priceUpdates,
        bytes[] calldata mmSigs
    ) external payable;

    function settleBulk(IntentBatch[] calldata pairs) external payable;

    // RFQ settle paths.
    function settleSingleWithQuote(
        SignedIntent calldata signedIntent,
        MMQuote calldata quote,
        bytes calldata quoteSig
    ) external payable;

    function settleBatchWithQuotes(
        SignedIntent[] calldata signedIntents,
        MMQuote[] calldata quotes,
        bytes[] calldata quoteSigs
    ) external payable;

    // Direct anchor commit (orchestrator + aggregator hot-path).
    function commitPrice(PriceUpdate calldata update, bytes calldata sig) external;

    // Lifecycle.
    function cancelIntent(uint256 nonce) external;

    // Registry views.
    function isRegisteredMM(address mm) external view returns (bool);
    function registeredMMCount() external view returns (uint256);
    function registeredMMAt(uint256 index) external view returns (address);
    function providerForSigner(address signingKey) external view returns (address);

    // Fee views.
    function protocolFeeBps() external view returns (uint256);
    function gasFeeRecipient() external view returns (address);

    // Events.
    event IntentSettled(
        bytes32 indexed intentHash,
        address indexed trader,
        address indexed selectedMM,
        address payoutTarget,
        address tokenIn,       // user-facing (may be NATIVE_SENTINEL)
        address tokenOut,      // user-facing (may be NATIVE_SENTINEL)
        uint256 amountIn,      // gross
        uint256 amountOut,     // pulled amount (bestOut or quote.amountOut)
        uint256 nonce,
        uint256 mmAnchorNonce  // streaming: bestAnchor.nonce; RFQ: quote.nonce
    );
    event IntentFailed(bytes32 indexed intentHash, bytes4 errorSelector, string reason);
    event PriceCommitted(
        address indexed mm,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 price,
        uint256 nonce,
        uint64 commitBlock
    );
    event RfqSettled(address indexed mm, address indexed trader, uint256 quoteNonce);
}
```

The first lock's `quoteSwapWithPrice` and `quoteSwapBestOfAll` are removed in v1. Atomic-commit aggregator integration now uses the off-chain `/quote/streaming` endpoint (returns a `PriceUpdate + mmSig` bundle in calldata); per-MM breakdowns are not in the v1 surface (can return additively if a partner needs them).

---

## Market-maker integration

### What you provide

Three pieces, deployed and configured before you go live:

1. **One on-chain provider contract** implementing the `IMMProvider` interface. This contract holds your inventory, expresses your pricing logic, and (optionally) enforces counterparty filtering, padding, freshness checks, fill caps, and anything else specific to your operation.
2. **One signing-and-connectivity process** that maintains a WebSocket connection to the protocol coordinator and signs EIP-712 `PriceUpdate` payloads (streaming) and/or `MMQuote` payloads (RFQ) with your market-maker key.
3. **A market-maker registry entry** identifying your signing address, your provider contract address, the channels you serve, and the trading pairs you support. The protocol owner registers your provider via `registerMM` on-chain. The registration populates `providerForSigner[mmAddress] = provider`, which is the lookup the RFQ path uses to resolve your signed quotes.

The protocol coordinator handles intent intake, matching, transaction submission, retry, and operational hardening. You do not need to operate any of that.

### The provider contract interface

Your provider contract implements the `IMMProvider` interface below. The settlement contract calls into it during every routing decision (`supportsPair`, `previewSwap`) and every fill (`executeSwap`); you have full control over what to return or whether to revert.

```solidity
interface IMMProvider {
    /// @notice Returns the address that signs your wire-format PriceUpdate and MMQuote payloads.
    /// @dev    May differ from the contract's own address. Settlement verifies signatures
    ///         against this value. Same identity covers both channels.
    function mmAddress() external view returns (address);

    /// @notice Cheap pair-support check used by the settlement router.
    /// @dev    MUST be a pure read; gas budget < 5k. Receives logical tokens (WETH for
    ///         native pairs, never the sentinel). Settlement iterates registered MMs
    ///         and skips any provider whose `supportsPair` returns false before calling
    ///         `previewSwap`.
    function supportsPair(address tokenIn, address tokenOut) external view returns (bool);

    /// @notice Read-only quote. Streaming routing + public `quoteSwap` view.
    /// @dev    Implementations MUST NOT mutate state. SHOULD return 0 to decline
    ///         (counterparty filter, insufficient inventory, paused, etc.).
    ///         `params.routedAmountOut` is 0 here (settlement hasn't picked a winner yet).
    function previewSwap(SwapParams calldata params) external view returns (uint256 amountOut);

    /// @notice Void hook executed once settlement has picked you for the fill.
    ///         Your responsibilities, in order:
    ///           1. Optional per-fill state updates (inventory accounting, risk hooks).
    ///           2. Optional last-look rejection: revert to decline. Settlement treats a
    ///              revert as per-intent failure, caught by try/catch.
    ///           3. FINAL STEP: grant settlement an exact `params.routedAmountOut`
    ///              allowance on `params.tokenOut` from `inventory()`:
    ///                IERC20(params.tokenOut).approve(params.settlement, params.routedAmountOut);
    /// @dev    MUST require msg.sender == params.settlement. No return value;
    ///         settlement is the sole authority over the pulled amount.
    function executeSwap(SwapParams calldata params) external;

    /// @notice Address holding tokenOut inventory. Settlement pulls tokenIn (or WETH) here;
    ///         settlement pulls tokenOut from here AFTER your executeSwap has granted the
    ///         per-fill allowance.
    function inventory() external view returns (address);
}

struct SwapParams {
    address trader;
    address tokenIn;          // LOGICAL (WETH for native intents) — never the sentinel
    uint256 amountIn;         // NET (after feeAmount + protocolFee)
    address tokenOut;         // LOGICAL — never the sentinel
    address receiver;         // resolved payout target; == settlement on native-out path
    uint256 anchorPrice;      // streaming path; 0 on RFQ path
    uint64  anchorCommitBlock;// streaming path; 0 on RFQ path
    uint256 routedAmountOut;  // settlement's chosen amount; what executeSwap should approve.
                              // 0 inside previewSwap; populated for executeSwap.
    address settlement;
}
```

The canonical `executeSwap` body — short enough to copy verbatim:

```solidity
function executeSwap(SwapParams calldata params) external {
    require(msg.sender == params.settlement, "OnlySettlement");
    // [optional risk hook / last-look: revert here to decline]
    IERC20(params.tokenOut).approve(params.settlement, params.routedAmountOut);
}
```

Two reference implementations are available. Pick the one closest to your operational model and adapt, or write your own from scratch:

- A minimal implementation that returns `anchorPrice * amountIn` from `previewSwap` with no filtering — appropriate when you want maximum open access.
- A defensive implementation with a counterparty whitelist, bps-padding curve, same-block freshness check, and per-pair fill caps — appropriate when you want to preserve existing protective mechanisms.

### Pull-model fund flow (what this means for your provider)

The settlement contract never holds tokens at rest, with one transient exception on the native-output unwrap path. The flow on each leg:

- **`tokenIn`** (ERC-20): settlement `transferFrom`s gross from the user in three independent transfers — `netAmountIn` to your `inventory()`, `feeAmount` to the `gasFeeRecipient` (or the relayer caller if unset), and (if configured) `protocolFee` to the protocol fee recipient.
- **`tokenIn`** (native): user sends `msg.value`; settlement deposits to WETH then `safeTransfer`s WETH from itself to the same three destinations. Settlement returns to zero WETH balance at end of intent.
- **`tokenOut`** (ERC-20): your `executeSwap` grants settlement an exact `routedAmountOut` allowance from `inventory()`; settlement `safeTransferFrom`s exactly that amount to the receiver. `tokenOut` does not flow through settlement.
- **`tokenOut`** (native): settlement pulls WETH from your inventory to itself, calls `WETH.withdraw`, and forwards ETH to the user's receiver. Transient WETH/ETH balance for the span of three opcodes; zero at end of intent.

If you hold inventory in `address(this)`, no extra approvals are required — your `executeSwap` can call `approve` directly. If you hold inventory in a separate vault contract, the vault must already have approved your provider contract to spend `tokenOut` (so your `executeSwap` can in turn `approve` settlement on the vault's behalf — usually via a delegated `approve` or by holding the vault's allowance to settlement upfront and re-asserting it per fill).

For **RWA tokens** with whitelist-gated transfers: settlement needs to be on the issuer's whitelist as a **spender** (it `transferFrom`s tokenIn from the user and tokenOut from your inventory). User, MM inventory, and `gasFeeRecipient` remain in their normal whitelist positions. If `gasFeeRecipient` is not whitelisted with the issuer, the `feeAmount` transfer reverts at the token level — operator either whitelists the recipient or runs that pair self-relay-only (`feeAmount = 0` skips the transfer entirely).

### EIP-712 payloads you sign

You can sign one or both of two payload types, depending on which channel(s) you serve:

- **Streaming**: `PriceUpdate` — continuous publication, anchor-based routing.
- **RFQ**: `MMQuote` — per-request firm quote, bound to `(trader, tokens, netAmountIn, amountOut, …)`.

Every signed payload is bound to a fixed EIP-712 domain:

```json
{
  "name": "PropAMMSettlement",
  "version": "1",
  "chainId": <integer chain id>,
  "verifyingContract": "<settlement contract address>"
}
```

`PriceUpdate` type:

```
PriceUpdate(
    address mm,
    address tokenIn,
    address tokenOut,
    uint256 price,
    uint256 nonce,
    uint256 expiresAt
)
```

| Field | Meaning |
|---|---|
| `mm` | Your signing address. Must equal `provider.mmAddress()`. |
| `tokenIn`, `tokenOut` | The pair this price covers. Logical token (WETH for native pairs), never the sentinel. |
| `price` | `(tokenOut wei per tokenIn wei) * 1e18`. So a price of 1 ETH = 3,000 USDC is `3000 * 1e18`. |
| `nonce` | Strictly monotonic per `(mm, tokenIn, tokenOut)` direction. A common choice is unix milliseconds; any strictly-increasing counter works. The protocol no-ops strictly older nonces and rejects same-nonce-different-price. |
| `expiresAt` | Unix milliseconds. The on-chain anchor will not serve fills after this wall-time, even if the block-age gate would otherwise pass. |

**Per-direction commits**: if you serve both `WETH → USDC` and `USDC → WETH`, you publish two separate `PriceUpdate`s with the same `mm` field but different `(tokenIn, tokenOut)`. Each has its own nonce stream.

`MMQuote` type:

```
MMQuote(
    address mm,
    address trader,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,       // NET — what reaches your inventory after fees
    uint256 amountOut,      // FIRM commitment; settlement pulls exactly this
    uint256 expiresAt,
    uint256 nonce
)
```

| Field | Meaning |
|---|---|
| `mm` | Your signing address. Must equal `provider.mmAddress()`. |
| `trader` | The user this quote is committed to. Settlement enforces `intent.trader == quote.trader`. |
| `tokenIn`, `tokenOut` | Logical token (WETH for native pairs). Settlement translates the user's sentinel-bearing intent to logical and enforces equality. |
| `amountIn` | **NET** amount — `grossAmountIn − feeAmount − protocolFee`. The orchestrator pre-computes net for the chosen relay mode and gives it to you in the `quote-request`. Sign against the net number. Settlement enforces `netAmountIn == quote.amountIn` on-chain. |
| `amountOut` | Firm commitment. Settlement pulls exactly this from your inventory after `executeSwap` returns. |
| `expiresAt` | Unix milliseconds (wall-time). Set tight on fast-pricing pairs (200–500 ms), seconds on slow pairs. |
| `nonce` | Strictly monotonic **per MM**, global across pairs and across relay modes. Separate stream from `PriceUpdate.nonce`. |

### Why MMQuote signs against net, not gross

The MM signs against what actually reaches your inventory. Three protections follow from this single design choice:

- A quote is **automatically invalidated** if `protocolFeeBps` drifts between sign and settle.
- A quote signed for orchestrator-relay (with `feeAmount > 0` baked into the net) **cannot be replayed** under self-relay (where `feeAmount = 0`). The net amounts differ; the settlement equality fails.
- Your pricing logic only thinks about "for N net tokenIn into my inventory I commit M tokenOut". You never think about gas fees or protocol fees.

### User intents (for your reference)

You do not sign user intents; users do. The schema is included here so you understand what gets passed into your provider on every fill.

```
SwapIntent(
    address trader,
    address receiver,
    address tokenIn,             // may be NATIVE_SENTINEL for native input
    uint256 amountIn,            // GROSS — includes feeAmount + protocolFee
    address tokenOut,            // may be NATIVE_SENTINEL for native output
    uint256 minAmountOut,
    address executor,
    uint256 exclusivityDeadline,
    uint256 feeAmount,           // 0 = self-relay; > 0 = orchestrator-relay
    uint256 deadline,
    uint256 nonce
)
```

Note that `SwapIntent` does **not** include an `mmProvider` field — v1 picks the filling MM at settle time. The user's intent is portable across MMs on streaming; on RFQ, it pairs with a signed `MMQuote` whose `quote.mm` resolves the provider.

Fields that matter for your provider:

- `trader`: the address being filled. Use this for counterparty filtering inside `previewSwap` / `executeSwap`.
- `tokenIn`, `amountIn`: settlement pulls `amountIn` gross from the user and splits it. Your provider receives `params.amountIn` which is the net.
- `tokenOut`, `minAmountOut`: settlement enforces `routedAmountOut >= minAmountOut` after your `executeSwap` grants the allowance.
- `receiver`: settlement resolves to either `intent.receiver` (if non-zero) or `intent.trader`, and passes it to your provider as `params.receiver`. On the native-output path, `params.receiver == address(settlement)` and the unwrap-forward happens after the pull.

Anchor freshness on streaming is enforced by the settlement contract: every fill requires `block.number == anchor.commitBlock`. There is no user-tunable staleness tolerance. RFQ uses `quote.expiresAt` (wall-time, unix ms).

### Settlement modes (user-side reference)

End users or their wallets / aggregators choose between two relay modes when signing an intent. Market makers see the same `executeSwap` call regardless; this is informational.

- With `feeAmount > 0`, the orchestrator submits the settle transaction and recovers gas from the user's input token. UX is gasless from the user side. Available on both channels.
- With `feeAmount = 0`, the user or an aggregator submits the settle transaction themselves and pays gas in ETH directly. Required for native-input intents.

The `executor` and `exclusivityDeadline` fields can be set to grant a specific submitter first-look during a chosen window, for flows that need it.

### WebSocket protocol

A single WebSocket connection per signing key.

After connect, send:

```json
{
  "type": "subscribe",
  "mm": "<your signing address>",
  "channels": ["streaming", "rfq"]
}
```

Pick either or both channels. The server replies with:

```json
{ "type": "ack", "channels": ["streaming", "rfq"] }
```

#### Streaming — publish prices

You then send price updates as fast as your pricing demands. Bigint fields are JSON strings to avoid precision loss.

```json
{
  "type": "price",
  "payload": {
    "update": {
      "mm": "0x...",
      "tokenIn": "0x...",
      "tokenOut": "0x...",
      "price": "3000000000000000000000",
      "nonce": "1730000000123",
      "expiresAt": "1730000010000"
    },
    "signature": "0x..."
  }
}
```

No reply is sent per update.

#### RFQ — respond to quote requests

The orchestrator pushes `quote-request` messages when a user requests an RFQ:

```jsonc
// orchestrator → you
{
  "type": "quote-request",
  "payload": {
    "requestId": "uuid",
    "intentTemplate": {
      "trader": "0x...",
      "tokenIn": "0x...",     // WETH for native pairs (translated at boundary)
      "tokenOut": "0x...",
      "netAmountIn": "999500000000000000",   // already net (gross - feeAmount - protocolFee)
      "relayMode": "orchestrator"            // or "self"
    },
    "deadlineMs": 400
  }
}

// you → orchestrator
{
  "type": "quote-response",
  "payload": {
    "requestId": "uuid",
    "quote": {
      "mm":       "0x...",
      "trader":   "0x...",
      "tokenIn":  "0x...",
      "tokenOut": "0x...",
      "amountIn":   "999500000000000000",      // NET — MUST equal request's netAmountIn
      "amountOut":  "2998500000000",           // firm commitment
      "expiresAt":  "1730000010000",
      "nonce":      "1730000001234"
    },
    "signature": "0x..."
  }
}
```

**Silent decline** is supported: not responding before `deadlineMs` elapses is the standard "no fill" signal. No explicit decline message needed.

### Deploying your provider contract

Constructor arguments are typically:

| Argument | Meaning |
|---|---|
| `settlement` | The deployed settlement contract address. Provided at integration. |
| `mmSigningKey` | The address whose private key signs your wire-format payloads. EOA, multisig, or smart-account wallet (EIP-1271 / EIP-6492 counterfactual) all work. Must equal what `provider.mmAddress()` returns. Same identity for streaming and RFQ. |
| `owner` | Manages your provider's configuration (whitelist, padding, fill caps, etc.). A multisig is strongly recommended for production. |

Plus any implementation-specific parameters (e.g., padding bps) that your provider needs.

### Inventory and approvals

Your provider holds inventory in the address returned by `inventory()`. Most implementations return `address(this)` and hold tokens directly; some prefer a separate vault contract.

The pull-model flow: when `executeSwap` is called, your provider grants settlement an exact `routedAmountOut` allowance on `tokenOut` from `inventory()`; settlement immediately consumes it via `safeTransferFrom`. If `inventory() == address(this)`, the approve call is direct. If `inventory()` is a separate vault, the vault's pre-existing allowance pattern must let your provider grant settlement-bound allowances per fill.

You also need to seed `inventory()` with the relevant `tokenOut` before going live for each pair (and each direction) you quote.

### Market-maker registry entry

Once your provider is deployed and your signing process is running, send Biconomy a registry entry per provider:

```json
{
  "mmAddress": "0x<your signing address>",
  "providerContract": "0x<your provider contract>",
  "channels": ["streaming", "rfq"],
  "supportedPairs": [
    { "tokenIn": "0x...", "tokenOut": "0x..." },
    { "tokenIn": "0x...", "tokenOut": "0x..." }
  ]
}
```

List each direction separately if you serve both sides of a pair. Biconomy (settlement owner) calls `registerMM(provider)` on-chain. This populates `providerForSigner[mmAddress] = provider`, which is the lookup used by the RFQ path to resolve your signed quotes. Once that lands, your provider participates in streaming routing on its supported directions and your `MMQuote`s are settleable from the next block forward. To remove your provider, the owner calls `unregisterMM(provider)`; that takes effect immediately for new orders, but any in-flight tx that already picked you up completes.

### Operational notes

#### Liveness

- **Streaming**: if your WebSocket disconnects or your signing process stops responding, your streaming fills stop within roughly a second. The on-chain anchor for any direction where you have stopped publishing fresh prices will fall out of the same-block window the contract enforces, and your provider will be skipped by the router (other registered MMs that are still publishing continue to compete normally). Practically: keep your signing process running at one signature per block or faster on directions you want fillable.
- **RFQ**: if you stop responding to `quote-request`s, RFQ routing falls back to silent decline; users get "no fill" responses on `/quote/rfq` until you resume.

Neither path produces silent under-the-radar fills against a stale operation.

#### Nonce persistence

- `PriceUpdate.nonce` must be strictly monotonic per `(mm, tokenIn, tokenOut)` direction.
- `MMQuote.nonce` must be strictly monotonic per `mm` (global across pairs and directions).

Both must survive your process restarts. Common pattern is to use unix milliseconds as the source, which restarts above any prior value. A Redis or database counter that increments and writes atomically before each signature also works. The streaming and RFQ counters are independent on-chain; manage them as separate state.

Signing two streaming payloads with the same nonce is treated as a soft-replay attempt by the settlement contract: the second one reverts if the price differs; it no-ops if the price is identical (parallel-worker safe). RFQ never accepts a stale or same-or-lower nonce.

#### Kill switch

You retain full control over fills via your provider's owner key, with no protocol coordination required to disable:

- Drop counterparties from your whitelist (if your implementation has one) — your `previewSwap` returns 0 for them; RFQ signing process simply declines.
- Set per-pair fill caps to zero.
- Spike padding bps to a value that makes all `previewSwap` returns uncompetitive.
- Stop responding to RFQ requests.
- Withdraw inventory.
- Pause your provider via whatever owner-level switch you build in (the canonical `executeSwap` body can revert when paused).

Any of these stops fills against your provider immediately on the next call. Alternatively, ask the settlement owner to call `unregisterMM(provider)`; that removes you from the routing loop and from `providerForSigner` directly on the next block.

#### Monitoring

Useful signals to track on your side:

- `IntentFailed` event rate where `selectedMM` would have been you (failed previews / executes) — sustained reverts indicate an inventory, pricing, or configuration issue.
- `inventory()` balances per `tokenOut` — refill before depletion.
- `tokenOut` allowance from `inventory()` to settlement after each fill — should always be 0. A non-zero residual is a provider bug.
- Per-pair, per-direction fill volume — feeds your hedging.
- WebSocket connection health — reconnect promptly on disconnect; the coordinator does not push backlogged state on reconnect (you simply resume publishing from your latest nonce on each channel).

### Trust summary

The settlement contract is the only privileged on-chain component, and its privileges are deliberately minimal:

- No upgrade path.
- No withdrawal path.
- Owner can pause settlement (emergency response), register/unregister MMs, and set fee parameters. Owner cannot drain user or market-maker funds.
- Ownership transfer is two-step (transfer is queued, must be explicitly accepted by the new owner).

Your signing key is the trust root for everything you do. The protocol layer cannot forge payloads on your behalf. The coordinator can forward your fills selectively (act as a censor), but cannot manufacture them. Per-MM anchor namespacing means another registered MM cannot overwrite or read your stored anchor; per-MM RFQ nonce stream means another MM cannot consume your RFQ nonce space. Reentrancy guards and the pull-model fund flow inside settlement prevent a malicious provider from over- or under-delivering — settlement is the sole authority over the pulled amount on `tokenOut`.

### Going live

1. Deploy your provider contract and seed inventory for each direction you serve.
2. Bring your signing process online and verify it connects, subscribes to the channel(s) you serve, and publishes valid `PriceUpdate`s and/or responds to `quote-request`s with valid `MMQuote`s.
3. Send Biconomy your registry entry.
4. Biconomy registers your provider on-chain. User intents land in routing immediately; whichever provider's `previewSwap` wins per order takes the streaming fill, and your signed `MMQuote`s are settleable via the RFQ path.
5. Monitor the signals above as you ramp.

Open questions, signing-infrastructure specifics, or integration-time review of your provider implementation: contact Biconomy directly.
