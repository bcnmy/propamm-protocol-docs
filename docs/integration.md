# propAMM Integration Guide

This document covers what an integrator needs to do to plug into the propAMM protocol — either as a market maker (deploying a provider contract and signing price updates) or as an aggregator (routing user orders through the settlement contract on behalf of an existing flow).

It assumes familiarity with the conceptual architecture described in the companion architecture document. It does not assume familiarity with the underlying implementation.

## Aggregator integration modes

The propAMM v1 settlement contract supports two equivalent on-chain integration patterns for aggregators (1inch, ParaSwap, KyberSwap, Matcha, etc.) — or any contract routing a user through propAMM. Pick whichever fits the pair's liveness profile, or support both. Both modes call the same `settleSingle` (or `settleBatch`) entry point; the only difference is what the caller passes in `priceUpdates[]` and `mmSigs[]`.

### Mode 1 — Anchor-only

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

**When this works**: pairs where the orchestrator (or some other caller) is keeping anchors hot every block. If any settle in the current block has already committed a fresh `PriceUpdate` for the relevant MM × pair, this aggregator's tx sees that anchor. On Base with sub-block ordering and an active orchestrator, this is the common case on liquid pairs.

**No off-chain dependency.** The aggregator never needs to call the orchestrator's HTTP API, never needs a fresh `PriceUpdate` blob in calldata, never needs to know about MM signing keys.

**Failure mode.** If no MM has a same-block anchor (cold pair, low-volume hour, in-block ordering put the aggregator's tx before the orchestrator's first commit), `quoteSwap` returns `bestAmountOut == 0` and the aggregator should fall back to Mode 2.

### Mode 2 — Atomic-commit

Caller calls `quoteSwapWithPrice(tokenIn, tokenOut, amountIn, feeAmount, priceUpdate, mmSig)` (also a `view` function) with a caller-supplied `PriceUpdate + mmSig` from the chosen MM's published feed, then settles via `settleSingle(signedIntent, [priceUpdate], [mmSig])`. The contract verifies the MM signature, treats the price as the freshest available for routing, and lazily commits the consumed update to storage at the end of the tx.

```solidity
// 1. Fetch a signed PriceUpdate off-chain (MM feed, orchestrator API, etc.).
//    Bring it in calldata.

(uint256 bestAmountOut, address bestMM) = IPropAMMSettlement(settlement)
    .quoteSwapWithPrice(tokenIn, tokenOut, amountIn, feeAmount, priceUpdate, mmSig);

require(bestAmountOut >= userMinOut, "no route");

// 2. Settle with the same priceUpdate + mmSig in the arrays.
PriceUpdate[] memory updates = new PriceUpdate[](1);
updates[0] = priceUpdate;
bytes[] memory sigs = new bytes[](1);
sigs[0] = mmSig;
IPropAMMSettlement(settlement).settleSingle(signedIntent, updates, sigs);
```

**When this works**: always. Whether the orchestrator is live, offline, or asleep on this pair, the aggregator brings a fresh `PriceUpdate` and the contract trusts the MM signature directly. Routing still considers every other registered MM's stored anchors alongside the caller-supplied update — the route picks the best `amountOut` across all eligible MMs.

**Cost.** Approximately 3k extra gas for MM signature verification, plus a 2-SSTORE lazy commit for the consumed update, amortised across however many intents land in the same batch.

**Off-chain dependency.** The aggregator needs a fresh signed `PriceUpdate` from somewhere — typically the MM's published price feed or an orchestrator API endpoint.

### Recommended pattern

Aggregators should implement **Mode 1 first** for the common case (liquid pairs, hot orchestrator), with a **Mode 2 fallback** for cold pairs or when Mode 1 returns `bestAmountOut == 0`.

### `IPropAMMSettlement` — the stable integrator interface

```solidity
interface IPropAMMSettlement {
    // Quote views (call these to get a routed quote)
    function quoteSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 feeAmount)
        external view returns (uint256 bestAmountOut, address bestMM);

    function quoteSwapWithPrice(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 feeAmount,
        PriceUpdate calldata priceUpdate,
        bytes calldata mmSig
    ) external view returns (uint256 bestAmountOut, address bestMM);

    function quoteSwapBestOfAll(address tokenIn, address tokenOut, uint256 amountIn, uint256 feeAmount)
        external view returns (address[] memory mms, uint256[] memory amountsOut);

    // Settle paths
    function settleSingle(
        SignedIntent calldata signedIntent,
        PriceUpdate[] calldata priceUpdates,
        bytes[] calldata mmSigs
    ) external;

    function settleBatch(
        SignedIntent[] calldata signedIntents,
        PriceUpdate[] calldata priceUpdates,
        bytes[] calldata mmSigs
    ) external;

    function settleBulk(IntentBatch[] calldata pairs) external;

    // Direct commit (orchestrator + aggregator hot-path)
    function commitPrice(PriceUpdate calldata update, bytes calldata sig) external;

    // Lifecycle
    function cancelIntent(uint256 nonce) external;

    // Registry views
    function isRegisteredMM(address mm) external view returns (bool);
    function registeredMMCount() external view returns (uint256);
    function registeredMMAt(uint256 index) external view returns (address);

    // Fee views
    function protocolFeeBps() external view returns (uint256);
    function gasFeeRecipient() external view returns (address);

    // Events
    event IntentSettled(
        bytes32 indexed intentHash,
        address indexed trader,
        address indexed selectedMM,
        address payoutTarget,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 nonce,
        uint256 mmAnchorNonce
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
}
```

---

## Market-maker integration

### What you provide

Three pieces, deployed and configured before you go live:

1. **One on-chain provider contract** implementing the `IMMProvider` interface. This contract holds your inventory, expresses your pricing logic, and (optionally) enforces counterparty filtering, padding, freshness checks, fill caps, and anything else specific to your operation.
2. **One signing-and-connectivity process** that maintains a WebSocket connection to the protocol coordinator and signs EIP-712 `PriceUpdate` payloads with your market-maker key.
3. **A market-maker registry entry** identifying your signing address, your provider contract address, and the trading pairs you support. The protocol owner registers your provider via `registerMM` on-chain.

The protocol coordinator handles intent intake, matching, transaction submission, retry, and operational hardening. You do not need to operate any of that.

### The provider contract interface

Your provider contract implements the `IMMProvider` interface below. The settlement contract calls into it during every routing decision (`supportsPair`, `previewSwap`) and every fill (`executeSwap`); you have full control over what to return or whether to revert.

```solidity
interface IMMProvider {
    /// @notice Returns the address that signs your wire-format PriceUpdate payloads.
    /// @dev May differ from the contract's own address. Settlement verifies signatures
    ///      against this value.
    function mmAddress() external view returns (address);

    /// @notice Cheap pair-support check used by the settlement router.
    /// @dev MUST be a pure read; gas budget < 5k. Settlement iterates registered MMs
    ///      and skips any provider whose `supportsPair` returns false before calling
    ///      `previewSwap`.
    function supportsPair(address tokenIn, address tokenOut) external view returns (bool);

    /// @notice Read-only quote. Used by settlement to route between MMs per order,
    ///         and by the public quoteSwap views for on-chain aggregators.
    /// @return amountOut The MM commits to providing this amountOut if `executeSwap`
    ///         is called with the same params in the same block.
    /// @dev    Implementations MUST NOT mutate state. SHOULD return 0 to decline
    ///         (counterparty filter, insufficient inventory, paused, etc.).
    function previewSwap(SwapParams calldata params) external view returns (uint256 amountOut);

    /// @notice Execute the swap. Settlement has already moved tokenIn (netAmountIn)
    ///         from the user to inventory() before calling this. The provider is
    ///         responsible for pushing the resolved amountOut of tokenOut from
    ///         inventory() to params.receiver.
    /// @dev    MUST require msg.sender == settlement.
    function executeSwap(SwapParams calldata params) external returns (uint256 amountOut);

    /// @notice Returns the address holding the tokenOut inventory. Settlement pulls
    ///         tokenIn into this address; this address pushes tokenOut to the receiver.
    function inventory() external view returns (address);
}

struct SwapParams {
    address trader;          // who is trading (MM may apply per-trader rules)
    address tokenIn;
    uint256 amountIn;        // NET — after feeAmount and protocolFee deducted from gross
    address tokenOut;
    address receiver;        // resolved payout target; MM transfers tokenOut directly here
    uint256 anchorPrice;     // verified MM-signed price (pending or stored)
    uint64  anchorCommitBlock;
    address settlement;      // address of the settlement contract calling executeSwap
}
```

Two reference implementations are available. Pick the one closest to your operational model and adapt, or write your own from scratch:

- A minimal implementation that returns `anchorPrice * amountIn` with no filtering — appropriate when you want maximum open access.
- A defensive implementation with a counterparty whitelist, bps-padding curve, same-block freshness check, and per-pair fill caps — appropriate when you want to preserve existing protective mechanisms.

### Pure-proxy fund flow (what this means for your provider)

The settlement contract never holds tokens at rest. The flow looks like:

- **`tokenIn`**: settlement `transferFrom`s from the user in three independent transfers — `netAmountIn` to your `inventory()`, `feeAmount` to the `gasFeeRecipient` (or the relayer if unset), and (if configured) `protocolFee` to the protocol fee recipient.
- **`tokenOut`**: your `executeSwap` reads `params.receiver` and pushes `amountOut` directly from `inventory()` to that address. No intermediate hop through settlement.

This means: if you hold inventory in a separate vault, the vault must approve your provider contract (not the settlement contract) to push `tokenOut`. The settlement contract only pulls `tokenIn`; it never touches `tokenOut`.

For RWA tokens with whitelist-gated transfers, settlement does **not** need to be on the issuer's whitelist; user → MM-inventory and user → fee-recipient transfers go through the RWA's normal permission gates as if the user invoked them directly.

### EIP-712 payloads you sign

You sign one type of payload: `PriceUpdate`. (RFQ-style per-order quoting is not part of v1 — revival is planned for v2.)

Every signed payload is bound to a fixed EIP-712 domain. The settlement contract's address is provided to you at integration; the domain looks like:

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

Field semantics:

| Field | Meaning |
|---|---|
| `mm` | Your signing address. Must equal `provider.mmAddress()`. |
| `tokenIn`, `tokenOut` | The pair this price covers. |
| `price` | `(tokenOut wei per tokenIn wei) * 1e18`. So a price of 1 ETH = 3,000 USDC is `3000 * 1e18`. |
| `nonce` | Strictly monotonic per `(mm, tokenIn, tokenOut)`. A common choice is unix milliseconds; any strictly-increasing counter works. The protocol no-ops strictly older nonces (parallel-coordinator races settle cleanly) and rejects same-nonce-different-price. |
| `expiresAt` | Unix milliseconds. The on-chain anchor will not serve fills after this wall-time, even if the block-age gate would otherwise pass. |

### User intents (for your reference)

You do not sign user intents; users do. The schema is included here so you understand what gets passed into your provider on every fill.

```
SwapIntent(
    address trader,
    address receiver,
    address tokenIn,
    uint256 amountIn,
    address tokenOut,
    uint256 minAmountOut,
    address executor,
    uint256 exclusivityDeadline,
    uint256 feeAmount,
    uint256 deadline,
    uint256 nonce
)
```

Note that `SwapIntent` does **not** include an `mmProvider` field — v1 routes per-order across all registered MMs based on `previewSwap`. The user's intent is portable across MMs; whichever provider returns the best `amountOut` wins.

Fields that matter for your provider:

- `trader`: the address being filled. Use this for counterparty filtering inside `previewSwap` / `executeSwap`.
- `tokenIn`, `amountIn`: settlement pulls `amountIn` gross from the user and splits it. Your provider receives `params.amountIn` which is `amountIn - feeAmount - protocolFee` (the net).
- `tokenOut`, `minAmountOut`: settlement enforces `amountOut >= minAmountOut` after your `executeSwap` returns.
- `receiver`: settlement resolves this to either `intent.receiver` (if non-zero) or `intent.trader`, and passes it to your provider as `params.receiver`. Your provider pushes `tokenOut` to that address directly.

Anchor freshness is enforced by the settlement contract: every fill requires `block.number == anchor.commitBlock`. There is no user-tunable staleness tolerance.

### Settlement modes (user-side reference)

End users or their wallets / aggregators choose between two settlement paths when signing an intent. Market makers see the same `executeSwap` call regardless; this is informational.

With `feeAmount > 0`, the orchestrator submits the settle transaction and recovers gas from the user's input token. UX is gasless from the user side.

With `feeAmount = 0`, the user or an aggregator submits the settle transaction themselves and pays gas in ETH directly.

The `executor` and `exclusivityDeadline` fields can be set to grant a specific submitter first-look during a chosen window, for flows that need it.

### WebSocket protocol

A single WebSocket connection per signing key.

After connect, send:

```json
{
  "type": "subscribe",
  "mm": "<your signing address>",
  "channels": ["streaming"]
}
```

The server replies with:

```json
{ "type": "ack", "channels": ["streaming"] }
```

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

### Deploying your provider contract

The shape of the deployment depends on which reference implementation you fork (if any). Constructor arguments are typically:

| Argument | Meaning |
|---|---|
| `settlement` | The deployed settlement contract address. Provided at integration. |
| `mmSigningKey` | The address whose private key signs your wire-format payloads. EOA, multisig, or smart-account wallet (EIP-1271 / EIP-6492 counterfactual) all work. Must equal what `provider.mmAddress()` returns. |
| `owner` | Manages your provider's configuration (whitelist, padding, fill caps, etc.). A multisig is strongly recommended for production. |

Plus any implementation-specific parameters (e.g., padding bps, max anchor age) that your provider needs.

### Inventory and approvals

Your provider holds inventory in the address returned by `inventory()`. Most implementations return `address(this)` and hold tokens directly; some prefer a separate vault contract.

The pure-proxy flow: when `executeSwap` is called, your provider pushes `amountOut` of `tokenOut` from `inventory()` directly to `params.receiver`. The settlement contract does not pull `tokenOut` itself — it only pulls `tokenIn` from the user. Your inventory address must therefore have approved your provider contract (not the settlement contract) to spend `tokenOut`, or your provider must hold `tokenOut` directly in `address(this)` and call `transfer`.

You also need to seed `inventory()` with the relevant `tokenOut` before going live for each pair you quote.

### Market-maker registry entry

Once your provider is deployed and your signing process is running, send Biconomy a registry entry per provider:

```json
{
  "mmAddress": "0x<your signing address>",
  "providerContract": "0x<your provider contract>",
  "supportedPairs": [
    { "tokenIn": "0x...", "tokenOut": "0x..." }
  ]
}
```

Biconomy (settlement owner) calls `registerMM(provider)` on-chain. Once that lands, your provider participates in routing on its supported pairs from the next block forward. To remove your provider, the owner calls `unregisterMM(provider)`; that takes effect immediately for new orders, but any in-flight tx that already picked you up completes.

### Operational notes

#### Liveness

If your WebSocket disconnects or your signing process stops responding, your fills stop within roughly a second. The on-chain anchor for any pair where you have stopped publishing fresh prices will fall out of the same-block window the contract enforces, and your provider will be skipped by the router (other registered MMs that are still publishing continue to compete normally). Practically: keep your signing process running at one signature per block or faster on pairs you want fillable.

Neither path produces silent under-the-radar fills against a stale operation.

#### Nonce persistence

`PriceUpdate.nonce` must be strictly monotonic per `(mm, tokenIn, tokenOut)` and must survive your process restarts. Common pattern is to use unix milliseconds as the source, which restarts above any prior value. A Redis or database counter that increments and writes atomically before each signature also works.

Signing two payloads with the same nonce is treated as a soft-replay attempt by the settlement contract: the second one reverts if the price differs; it no-ops if the price is identical (parallel-worker safe).

#### Kill switch

You retain full control over fills via your provider's owner key, with no protocol coordination required to disable:

- Drop counterparties from your whitelist (if your implementation has one) — your `previewSwap` returns 0 for them.
- Set per-pair fill caps to zero.
- Spike padding bps to a value that makes all `previewSwap` returns uncompetitive.
- Withdraw inventory.
- Pause your provider via whatever owner-level switch you build in.

Any of these stops fills against your provider immediately on the next call. Alternatively, ask the settlement owner to call `unregisterMM(provider)`; that removes you from the routing loop directly on the next block.

#### Monitoring

Useful signals to track on your side:

- `IntentFailed` event rate where `selectedMM` would have been you (failed previews / executes) — sustained reverts indicate an inventory, pricing, or configuration issue.
- `inventory()` balances per `tokenOut` — refill before depletion.
- Per-pair fill volume — feeds your hedging.
- WebSocket connection health — reconnect promptly on disconnect; the coordinator does not push backlogged state on reconnect (you simply resume publishing from your latest nonce).

### Trust summary

The settlement contract is the only privileged on-chain component, and its privileges are deliberately minimal:

- No upgrade path.
- No withdrawal path.
- Owner can pause settlement (emergency response), register/unregister MMs, and set fee parameters. Owner cannot drain user or market-maker funds.
- Ownership transfer is two-step (transfer is queued, must be explicitly accepted by the new owner).

Your signing key is the trust root for everything you do. The protocol layer cannot forge payloads on your behalf. The coordinator can forward your fills selectively (act as a censor), but cannot manufacture them. Per-MM anchor namespacing means another registered MM cannot overwrite or read your stored anchor. Reentrancy guards and the pure-proxy fund flow inside settlement prevent a malicious provider from extracting more than the user-signed `amountIn` per intent.

### Going live

1. Deploy your provider contract and seed inventory.
2. Bring your signing process online and verify it connects, subscribes, and publishes valid `PriceUpdate`s.
3. Send Biconomy your registry entry.
4. Biconomy registers your provider on-chain. User intents land in routing immediately; whichever provider's `previewSwap` wins per order takes the fill.
5. Monitor the signals above as you ramp.

Open questions, signing-infrastructure specifics, or integration-time review of your provider implementation: contact Biconomy directly.
