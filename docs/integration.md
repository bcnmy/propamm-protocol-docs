# PropAMM Integration Guide

This document covers what an integrator needs to do to plug into PropAMM — as a market maker (deploying a provider contract + signing PriceUpdates), as an aggregator/wallet (routing user orders through the orchestrator's HTTP intake), or as a trader self-relaying intents without orchestrator dependency.

It assumes familiarity with the conceptual architecture from the companion architecture document.

---

## For market makers

You bring pricing and inventory. The protocol provides the settlement substrate, the streaming-MM module, and the orchestrator. Plugging in is small.

### TL;DR onboarding

1. **Deploy** `BasicMMProvider` with constructor args `(signer, executor, owner)` where `executor = PropAMMExecutor` address.
2. **Fund** the provider with `tokenOut` inventory for every pair you'll quote.
3. **Connect** your signer process to the orchestrator's WebSocket and stream signed `PriceUpdate`s.

No on-chain registration tx. The orchestrator decides routing off-chain — it consumes your signed price stream and includes your PUs in batch preHooks.

### The provider contract

The reference template (`BasicMMProvider`) is ~100 LoC. Two functions matter:

```solidity
function signer() external view returns (address);  // EOA or EIP-1271

function executeSwap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    address receiver
) external {
    require(msg.sender == approvedExecutor);
    SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
    SafeTransferLib.safeTransfer(tokenOut, receiver, amountOut);
}
```

Only `approvedExecutor` (the `PropAMMExecutor` address) may call `executeSwap`. The MM controls `approvedExecutor` via the owner key. If the executor is ever compromised, the MM can rotate to a new executor in one tx.

For an MM with non-trivial pricing logic (curves, inventory skew, drift), override `previewSwap` (off-chain quote helper) and override `executeSwap` to enforce the MM's actual delivery math.

### PriceUpdate format

```solidity
struct PriceUpdate {
    address mm;         // your signer; matches IMMProvider.signer()
    address tokenIn;
    address tokenOut;
    uint256 price;      // 1e18-scaled: amountOut = amountIn * price / 1e18
    uint256 nonce;      // monotonic per (mm, tokenIn, tokenOut)
    uint256 expiresAt;  // unix milliseconds
}
```

Signed against `PropAMMExecutor`'s EIP-712 domain (`name: "PropAMMExecutor"`, `version: "1"`, `verifyingContract: <PropAMMExecutor>`). Reference signing helper: `_signPriceUpdate` in the protocol test base.

**Nonce hygiene:**
- Monotonic per `(mm signer, tokenIn, tokenOut)`. Don't reuse.
- Stale-nonce PUs (lower than the committed anchor) are silent no-ops on chain — safe to mempool-stack.
- Same-block re-commits with the same nonce are also no-ops. Parallel orchestrator workers race-free.

**Same-block freshness:**
The orchestrator includes your latest PU in the batch's preHook. `PropAMMExecutor` enforces `anchor.commitBlock == block.number` at fill time. Your PU is therefore committed in the same tx that consumes it — you never need to land transactions yourself.

### Rotating keys

- Rotate the signing key: `mmProvider.setSigner(newSigner)`. One owner tx. Subsequent PUs must be signed by the new key.
- Rotate the trusted executor (e.g. on protocol upgrade): `mmProvider.setApprovedExecutor(newExecutor)`. One owner tx.

Use an owner multisig in production.

---

## For aggregators / wallets

You want users to swap through the orchestrator with one signature.

### The flow

1. **Quote.** Hit the orchestrator's `/v3/quote` with `(trader, tokenIn, tokenOut, amountIn)`. Get back an Intent template (`executor`, `minAmountOut`, `deadline`, `nonce`).

2. **Sign.** Trader EIP-712 signs ONE `PermitWitnessTransferFrom` whose witness is the `Intent` struct. Your wallet integration code constructs the digest and calls `signTypedData`.

   The witness type string:
   ```
   Intent(address trader,address receiver,address tokenIn,uint256 amountIn,address tokenOut,uint256 minAmountOut,address executor,uint256 deadline,uint256 nonce)
   ```

3. **Submit.** POST `{ intent, signature }` to the orchestrator's `/v3/intents`. Watch for `IntentSettled` on the settlement contract.

### Approvals

The trader's only on-chain approval, ever, is `tokenIn.approve(Permit2, max)`. Once per token, lifetime. If they've used any other Permit2-based protocol (Uniswap X, 1inch, …) with that token, the approval is already in place.

For first-time users on tokens with EIP-2612 permit support, chain the permit into the intent's Step[]:
```
preHook: [updatePrices(...)]
steps: [
    tokenIn.permit(owner=trader, spender=Permit2, value=max, deadline, v, r, s),
    Permit2.permitWitnessTransferFrom(...),
    ...
]
```

Validated live: a trader with `Permit2 allowance == 0` can settle their intent in one tx by chaining a signed permit + the intent witness. Fully gasless from the trader's perspective.

### Failure modes the UI should handle

| Selector | Error | Meaning | UI guidance |
|---|---|---|---|
| `0x905c74a0` | `ExecutorMismatch` | UI submitted to wrong settle entry | Bug — verify orchestrator config |
| `0x408b2234` | `IntentExpired` | Trader took too long between quote and submit | Re-quote |
| `0x2c19b8b8` | `InsufficientOutput` | Price moved against the trader | Re-quote; offer looser slippage |
| `0x9090268d` | `AnchorStale` | preHook didn't commit an anchor in this block | Orchestrator-side; transient |
| `0x1ba4f179` | `InvalidPriceUpdateSignature` | MM key drifted or wrong domain | Operator-side |

`IntentFailed(intentHash, errorSelector, reason)` events carry the per-intent failure. `IntentSettled(intentHash, ..., amountOut, ...)` carry the success. Both are indexed by `intentHash` — derive it client-side as `keccak256(abi.encode(Intent))` to correlate.

---

## For traders self-relaying

You can bypass the orchestrator entirely. Two patterns:

### Self-PU: trader supplies the PriceUpdate

Used when you want zero orchestrator dependency. You sign the PU as well as the Intent.

```
preHook: [PropAMMExecutor.updatePrices([yourPU], [yourPUSig])]
steps:   [Permit2.permitWitnessTransferFrom,
          tokenIn.transfer(executor),
          PropAMMExecutor.fillFromAnchor(yourMMProvider, ...)]
```

Requires that you have an MM key (or queried one off-chain from an MM willing to sign). 100% reliable.

### Piggyback: trader supplies no PU, relies on orchestrator activity

You submit `preHook = []`. Your `fillFromAnchor` call expects an anchor with `commitBlock == block.number` — which will be present only if the orchestrator's batch lands in the same block as yours.

Reliable for pairs with sustained orchestrator activity (orchestrator commits anchors in every block). For sparse pairs the user's tx may fail `AnchorStale` and need to retry.

### Native ETH input

Self-relay only. The trader sends `msg.value == amountIn` with `settleBatch`; the first Step is `WETH9.deposit{value: amountIn}` to wrap. Rest of the route treats WETH as the input token.

```
steps: [
    { to: WETH, value: amountIn, data: deposit() },
    { to: WETH, value: 0, data: transfer(executor, amountIn) },
    { to: PropAMMExecutor, value: 0, data: fillFromAnchor(...) }
]
```

---

## Step[] reference shapes

### Streaming-MM (production default)

```
preHook: [updatePrices([pu], [puSig])]
perIntentSteps: [[
    Permit2.permitWitnessTransferFrom(...),
    tokenIn.transfer(PropAMMExecutor, amountIn),
    PropAMMExecutor.fillFromAnchor(mmProvider, tokenIn, tokenOut, amountIn, receiver)
]]
```

### External venue (Uniswap V3 example)

```
preHook: []
perIntentSteps: [[
    Permit2.permitWitnessTransferFrom(...),
    tokenIn.approve(UniswapRouter, amountIn),
    UniswapRouter.exactInputSingle(...),
    tokenIn.approve(UniswapRouter, 0)
]]
```

### Mixed PropAMM + external venue (split route)

```
preHook: [updatePrices(...)]
perIntentSteps: [[
    Permit2.permitWitnessTransferFrom(...),
    tokenIn.transfer(PropAMMExecutor, half),
    PropAMMExecutor.fillFromAnchor(..., half, ...),
    tokenIn.approve(UniswapRouter, half),
    UniswapRouter.exactInputSingle(half, ...),
    tokenIn.approve(UniswapRouter, 0)
]]
```

### ERC-8211 fee-split (runtime balance read)

Use the `@biconomy/smart-batching` SDK:

```ts
import { createComposableBatch } from "@biconomy/smart-batching";

const batch = createComposableBatch(publicClient, SETTLEMENT);
const usdc = batch.erc20Token(USDC);
batch.add([
  usdc.write({ functionName: "transfer", args: [FEE_COLLECTOR, FIXED_FEE] }),
  usdc.write({
    functionName: "transfer",
    args: [user, usdc.runtimeBalance({ owner: SETTLEMENT })],
  }),
]);
const composableCalls = await batch.toCalls();
const compCalldata = encodeFunctionData({
  abi: COMP_MODULE_DELEGATE_ABI,
  functionName: "executeComposableDelegateCall",
  args: [composableCalls],
});

// Then include in your Step[]:
const steps = [
    Permit2.permitWitnessTransferFrom(...),
    tokenIn.transfer(PropAMMExecutor, amountIn),
    PropAMMExecutor.fillFromAnchor(mmProvider, ..., receiver=SETTLEMENT),
    { to: COMP_MODULE, value: 0, data: compCalldata, isDelegatecall: true }
];
```

The ERC-8211 module (whitelisted as a delegatecall target) reads settlement's balance at execution time and splits dynamically. User gets `(totalOut - FIXED_FEE)`, fee collector gets `FIXED_FEE`, settlement holds zero residual. The user's `minAmountOut` is checked against the receiver's net delta.

---

## Reference

- `bcnmy/propamm-protocol` — settlement, executor, MM provider templates, orchestrator
- `@biconomy/smart-batching` — ERC-8211 SDK
- `bcnmy/erc8211-contracts` — ERC-8211 reference contracts
- ERC-8211 standard: <https://erc8211.com/>
