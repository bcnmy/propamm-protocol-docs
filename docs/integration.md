# propAMM Integration Guide

This document covers what a market maker needs to do to integrate with the propAMM protocol: the provider contract you deploy, the EIP-712 payloads you sign, the WebSocket wire format you speak, and the operational considerations on your side.

It assumes familiarity with the conceptual architecture described in the companion architecture document. It does not assume familiarity with the underlying implementation.

## What you provide

Three pieces, deployed and configured before you go live:

1. **One on-chain provider contract** implementing the `IMMProvider` interface. This contract holds your inventory, expresses your pricing logic, and (optionally) enforces counterparty filtering, padding, freshness checks, fill caps, and anything else specific to your operation.
2. **One signing-and-connectivity process** that maintains a WebSocket connection to the protocol coordinator and signs EIP-712 payloads with your market-maker key.
3. **A market-maker registry entry** identifying your signing address, your provider contract address, the trading pairs you support, and which channel(s) you operate.

The protocol coordinator handles intent intake, matching, transaction submission, retry, and operational hardening. You do not need to operate any of that.

## The provider contract interface

Your provider contract implements the `IMMProvider` interface below. The settlement contract calls into it during every fill; you have full control over what to return or whether to revert.

```solidity
interface IMMProvider {
    /// @notice Returns the address that signs your wire-format payloads (PriceUpdate / MMQuote).
    /// @dev May differ from the contract's own address. Settlement compares ecrecover
    ///      output against this value.
    function mmAddress() external view returns (address);

    /// @notice Returns the address holding the tokenOut inventory the settlement contract
    ///         is allowed to pull. Most implementations return address(this); some MMs
    ///         prefer a separate vault.
    function inventory() external view returns (address);

    /// @notice Called per fill on the streaming channel.
    /// @dev Settlement passes the user intent details + the on-chain anchor price.
    ///      Your implementation must approve the settlement contract to pull the
    ///      returned amount from `inventory()`. The settlement contract enforces
    ///      `amountOut >= intent.minAmountOut` after this returns.
    function executeSwap(SwapParams calldata params) external returns (uint256 amountOut);

    /// @notice Read-only quote for the streaming channel. Used for tooling and dry-runs.
    function quote(SwapParams calldata params) external view returns (uint256);

    /// @notice Called per fill on the pin-RFQ channel.
    /// @dev Settlement passes the user intent + your signed quote. Your implementation
    ///      must approve settlement to pull the returned amount; settlement enforces
    ///      `amountOut >= mmQuote.amountOut AND amountOut >= intent.minAmountOut`.
    ///      If you only run streaming, revert with a clear reason and leave this stub.
    function executeSwapWithQuote(SwapParamsRFQ calldata params, uint256 mmQuoteAmountOut)
        external returns (uint256 amountOut);
}
```

`SwapParams` and `SwapParamsRFQ` carry the user-side fields (`trader`, `tokenIn`, `amountIn`, `tokenOut`, and the relevant anchor or quote fields). Their exact shape is provided alongside the deployment artifacts.

Three reference implementations are available for reference. Pick the one closest to your operational model and adapt, or write your own from scratch:

- A minimal implementation that returns `anchorPrice * amountIn` with no filtering — appropriate when you want maximum open access.
- A defensive implementation with a counterparty whitelist, bps-padding curve, same-block freshness check, and per-pair fill caps — appropriate when you want to preserve existing protective mechanisms.
- An RFQ implementation that honors your signed quote as a floor with optional price-improvement and an optional trader whitelist — appropriate for off-chain risk-gated quoting.

## EIP-712 payloads you sign

Every signed payload is bound to a fixed EIP-712 domain. The settlement contract's address is provided to you at integration; the domain looks like:

```json
{
  "name": "PropAMMSettlement",
  "version": "1",
  "chainId": <integer chain id>,
  "verifyingContract": "<settlement contract address>"
}
```

### Streaming channel: `PriceUpdate`

You sign one of these per pair, at whatever cadence your pricing requires.

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

Field semantics:

| Field | Meaning |
|---|---|
| `mm` | Your signing address. Must equal `provider.mmAddress()`. |
| `tokenIn`, `tokenOut` | The pair this price covers. |
| `price` | `(tokenOut wei per tokenIn wei) * 1e18`. So a price of 1 ETH = 3,000 USDC is `3000 * 1e18`. |
| `nonce` | Strictly monotonic per `(mm, tokenIn, tokenOut)`. A common choice is unix milliseconds; any strictly-increasing counter works. The protocol no-ops strictly older nonces (parallel-coordinator races settle cleanly) and rejects same-nonce-different-price. |
| `expiresAt` | Unix milliseconds. The on-chain anchor will not serve fills after this wall-time, even if the block-age gate would otherwise pass. |

### Pin-RFQ channel: `MMQuote`

You sign one of these per quote request you receive over WebSocket.

```
MMQuote(
    address mm,
    bytes32 intentHash,
    uint256 amountOut,
    uint256 expiresAt,
    uint256 nonce
)
```

Field semantics:

| Field | Meaning |
|---|---|
| `mm` | Your signing address. Must equal the value in the quote request. |
| `intentHash` | The EIP-712 digest of the user intent this quote is bound to. Must equal the value in the quote request — settlement reverts otherwise. |
| `amountOut` | The minimum amount you commit to deliver. Your `executeSwapWithQuote` may pay more (price improvement); it must not pay less. |
| `expiresAt` | Unix milliseconds. The quote is not honored on-chain after this moment. |
| `nonce` | Strictly monotonic per `mm` on the RFQ channel only. Independent of your streaming `PriceUpdate` nonces. |

### User intents (for your reference only)

You do not sign user intents; users do. The schema is included here so you understand what gets passed into your provider on every fill.

```
SwapIntent(
    address trader,
    address receiver,
    address tokenIn,
    uint256 amountIn,
    uint256 feeAmount,
    address tokenOut,
    uint256 minAmountOut,
    address mmProvider,
    address executor,
    uint256 exclusivityDeadline,
    uint256 deadline,
    uint256 nonce
)
```

Fields that matter for your provider:

- `trader`: the address being filled. Use this for counterparty filtering inside `executeSwap*`.
- `tokenIn`, `amountIn`: what gets transferred to your `inventory()`. Note that `amountIn` is the input the MM provider receives; the protocol fee (`feeAmount`) is taken from the user separately and does not pass through your provider.
- `tokenOut`, `minAmountOut`: the settlement contract enforces `amountOut >= minAmountOut` after your provider returns.
- `mmProvider`: must equal your provider contract address for the intent to match against you.
- `feeAmount`: protocol fee in `tokenIn` units paid by the user to the protocol fee recipient. Independent of the MM's pricing. The MM receives `amountIn` and is not affected by this field.

Anchor freshness is enforced by the settlement contract: every fill requires `block.number == anchor.commitBlock`. There is no user-tunable staleness tolerance.

## Settlement modes (user-side reference)

End users or their wallets / aggregators choose between two settlement paths when signing an intent. Market makers see the same `executeSwap*` call regardless; this is informational.

With `feeAmount > 0`, the orchestrator submits the settle transaction and recovers gas from the user's input token. UX is gasless from the user side.

With `feeAmount = 0`, the user or an aggregator submits the settle transaction themselves and pays gas in ETH directly.

The `executor` and `exclusivityDeadline` fields can be set to grant a specific submitter first-look during a chosen window, for flows that need it.

## WebSocket protocol

A single WebSocket connection per signing key, multiplexing both channels if you operate both.

### Subscription

After connect, send:

```json
{
  "type": "subscribe",
  "mm": "<your signing address>",
  "channels": ["streaming"]
}
```

`channels` is an array; values are `"streaming"`, `"rfq"`, or both. Omitting `channels` defaults to `["streaming"]`. The server replies with:

```json
{ "type": "ack", "channels": ["streaming"] }
```

### Streaming: publish prices

You send price updates as fast as your pricing demands. Bigint fields are JSON strings to avoid precision loss.

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

### Pin-RFQ: receive requests, reply with quotes

For each user intent that targets your provider, the server sends:

```json
{
  "type": "quote-request",
  "payload": {
    "requestId": "<uuid>",
    "intent": {
      "trader": "0x...",
      "receiver": "0x...",
      "tokenIn": "0x...",
      "amountIn": "1000000000000000000",
      "tokenOut": "0x...",
      "minAmountOut": "2997000000000000000000",
      "mmProvider": "0x...",
      "feeAmount": "1500000000000000",
      "executor": "0x...",
      "exclusivityDeadline": "0",
      "deadline": "1730000060000",
      "nonce": "1729999999999"
    },
    "intentHash": "0x<32-byte hex>",
    "expiresAt": "1730000005000"
  }
}
```

Reply with a signed quote within the advisory `expiresAt` window:

```json
{
  "type": "quote-response",
  "payload": {
    "requestId": "<uuid from request>",
    "mmQuote": {
      "mm": "0x...",
      "intentHash": "0x...",
      "amountOut": "3000000000000000000000",
      "expiresAt": "1730000005000",
      "nonce": "42"
    },
    "signature": "0x..."
  }
}
```

Or decline cleanly:

```json
{
  "type": "quote-pass",
  "payload": {
    "requestId": "<uuid from request>",
    "reason": "inventory drained"
  }
}
```

If you neither respond nor pass within the request's `expiresAt` (typically about 1.5 seconds), the request times out from the coordinator's perspective. The user intent stays in the pool — the coordinator will reprompt you on the next tick. Transient passes or timeouts are not missed fills.

## Deploying your provider contract

The shape of the deployment depends on which reference implementation you fork (if any). Constructor arguments are typically:

| Argument | Meaning |
|---|---|
| `settlement` | The deployed settlement contract address. Provided at integration. |
| `mmSigningKey` | The address whose private key signs your wire-format payloads. EOA, multisig, or smart-account wallet (EIP-1271) all work. Must equal what `provider.mmAddress()` returns. |
| `owner` | Manages your provider's configuration (whitelist, padding, fill caps, etc.). A multisig is strongly recommended for production. |

Plus any implementation-specific parameters (e.g., padding bps, max anchor age) that your provider needs.

## Inventory and approvals

Your provider holds inventory in the address returned by `inventory()`. Most implementations return `address(this)` and hold tokens directly; some prefer a separate vault contract.

When `executeSwap*` is called, the settlement contract pulls `amountOut` of `tokenOut` from `inventory()` immediately after your function returns. Two approval patterns are supported:

- **Per-call approval.** Your `executeSwap*` calls `tokenOut.approve(settlement, amountOut)` before returning. Simpler and easier to reason about per fill, but costs ~5,000 gas per fill on the approval.
- **Long-lived infinite approval.** Your owner-level setup calls `tokenOut.approve(settlement, type(uint256).max)` once per token. Saves gas per fill; equivalent in safety because settlement only pulls during a fill it has already validated.

You also need to seed `inventory()` with the relevant `tokenOut` before going live for each pair you quote.

## Market-maker registry entry

Once your provider is deployed and your signing process is running, send Biconomy a registry entry per `(provider, channel)`:

```json
{
  "mmAddress": "0x<your signing address>",
  "providerContract": "0x<your provider contract>",
  "supportedPairs": [
    { "tokenIn": "0x...", "tokenOut": "0x..." }
  ],
  "channel": "streaming"
}
```

`channel` is `"streaming"` or `"rfq"`. Omitting it defaults to `"streaming"`. If you operate both channels under the same signing key, send two entries pointing at the relevant provider contracts. The registry is hot-reloadable; no orchestrator restart is required to add or update an entry.

## Operational notes

### Liveness

If your WebSocket disconnects or your signing process stops responding, your fills stop within roughly a second:

- **Streaming.** The on-chain anchor for any pair where you have stopped publishing fresh prices will eventually fall out of the same-block window the contract enforces, and new fills will stop until you resume signing. Practically: keep your signing process running at one signature per block or faster on pairs you want fillable.
- **Pin-RFQ.** Each quote request times out individually (typically ~1.5 seconds). The user intent stays in the pool and re-prompts; if you remain unresponsive, those intents eventually expire from the user's `deadline`.

Neither path produces silent under-the-radar fills against a stale operation.

### Nonce persistence

Both nonce streams must be strictly monotonic and must survive your process restarts:

- **Streaming `PriceUpdate.nonce`** — persisted per `(tokenIn, tokenOut)`. Common pattern is to use unix milliseconds as the source, which restarts above any prior value.
- **RFQ `MMQuote.nonce`** — persisted per signing key across all pairs and intents. Recommended pattern is a Redis or database counter that increments and writes atomically before each signature.

Signing two payloads with the same nonce is treated as a soft-replay attempt by the settlement contract: the second one reverts.

### Kill switch

You retain full control over fills via your provider's owner key, with no protocol coordination required to disable:

- Drop counterparties from your whitelist (if your implementation has one).
- Set per-pair fill caps to zero.
- Spike padding bps to a value that makes all fills uncompetitive.
- Withdraw inventory.
- Pause your provider via whatever owner-level switch you build in.

Any of these stops fills against your provider immediately on the next call.

### Monitoring

Useful signals to track on your side:

- `executeSwap*` revert rate and revert reasons — sustained reverts indicate an inventory, pricing, or configuration issue.
- `inventory()` balances per `tokenOut` — refill before depletion.
- Per-pair fill volume — feeds your hedging.
- WebSocket connection health — reconnect promptly on disconnect; the coordinator does not push backlogged state on reconnect (you simply resume publishing from your latest nonce).

## Trust summary

The settlement contract is the only privileged on-chain component, and its privileges are deliberately minimal:

- No upgrade path.
- No withdrawal path.
- Owner can pause settlement (emergency response). Owner cannot drain user or market-maker funds.
- Ownership transfer is two-step (transfer is queued, must be explicitly accepted by the new owner).

Your signing key is the trust root for everything you do. The protocol layer cannot forge payloads on your behalf. The coordinator can forward your fills selectively (act as a censor), but cannot manufacture them. Reentrancy guards and a zero-balance invariant inside settlement prevent a malicious provider from extracting more than the user-signed `amountIn` per intent.

## Going live

1. Deploy your provider contract and seed inventory.
2. Bring your signing process online and verify it connects, subscribes, and (for RFQ) responds to test quote requests within the timeout window.
3. Send Biconomy your registry entry.
4. The coordinator hot-loads the entry. User intents targeting your provider start being routed to you.
5. Monitor the signals above as you ramp.

Open questions, signing-infrastructure specifics, or integration-time review of your provider implementation: contact Biconomy directly.
