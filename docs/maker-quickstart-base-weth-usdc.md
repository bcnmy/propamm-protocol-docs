# Maker quickstart: WETH/USDC on Base

The shortest path from zero to quoting WETH/USDC on Base mainnet with your inventory in your
own contract. Full background lives in [integration.md](integration.md); this page is the
runbook.

## What you run, what we run

| Yours | Ours |
|---|---|
| One provider contract holding your inventory (your keys, your withdrawal rights) | The on-chain board (commit, supersede, revive, once-ever depth budgets) |
| One signing key streaming price ladders over WebSocket | Routing your quotes into both execution lanes: the onchain pool boards aggregator routers read and fill directly, and our hosted retail flow |
| Your pricing logic, TTLs and sizes - entirely your policy | The heartbeat that keeps your board live on-chain, fill settlement, monitoring |

## Step 1 - deploy your provider (one contract, ~30 lines of logic)

The provider is where your WETH and USDC sit. It must implement:

```solidity
function signer() external view returns (address);   // your stream's signing address
function executeSwap(
    address tokenIn, address tokenOut, uint256 amountIn,
    uint256 anchorPrice, uint256 amountOut, address receiver
) external;                                            // deliver amountOut of tokenOut to receiver
```

pinned to the executor at construction (`approvedExecutor =
0x000000Ab52Bdb44411777412fe938776a766cc6a`) so only real fills against your signed prices can
ever move your funds. The reference implementation in the contracts repo
(`BasicMMProvider.sol`) is production-shaped: constructor pins signer + executor + owner,
`executeSwap` is executor-only, and owner-only withdrawals mean listing is never custody.
Deploy it, fund it with your WETH and USDC on both sides you want to quote, done. There is no
approval to us, no deposit anywhere, and delisting is: stop signing, withdraw.

## Step 2 - the addresses (Base mainnet, 8453)

| What | Address |
|---|---|
| PropAMMExecutor (pin as `approvedExecutor`; EIP-712 verifying contract) | `0x000000Ab52Bdb44411777412fe938776a766cc6a` |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

EIP-712 domain for every ladder you sign:
`{ name: "PropAMMExecutor", version: "1", chainId: 8453, verifyingContract:
0x000000Ab52Bdb44411777412fe938776a766cc6a }`.

## Step 3 - sign and stream ladders

Each message is one signed `PriceLadder` per direction (WETH->USDC and USDC->WETH are
independent):

- `levels`: cumulative rungs `{size, price}`, price in tokenOut-wei per 1e18 tokenIn-wei
  (`out = in * price / 1e18`), best price first, sizes strictly increasing
- `nonce`: strictly monotonic per direction; unix milliseconds works
- `expiresAt`: unix seconds - YOUR freshness bound, nothing else expires your quote
- wire protocol, message shape and the runnable example client are in
  [integration.md, section 3](integration.md)
- if your engine already produces price levels, signing them as a ladder is the only new
  code
- if your engine is a curve (pmm math, clmm, any quote function), see the runnable
  [curve maker reference](examples/curve-maker-reference.ts): it samples the curve into a
  ladder that is conservative by construction, so discretization error always favors you

Sizing guidance that maps to how you get filled:

- **TTL**: 5-15s fast quotes; optionally interleave a 30-60s wider quote on the same nonce
  stream every ~10s (send it BEFORE the same-cycle fast one). The long quote is what
  aggregator pipelines carry; on-chain, anything superseded settles at your freshest
  committed price - repricing never burns an integrator's transaction, so tight TTLs cost
  you nothing in failed-fill goodwill.
- **Top level = per-version exposure cap**: across all routes and retries, one signed version
  can never fill more than its top level.

## Step 4 - go live

1. Send us: your **signer address** and your **provider address** (plus which sides you fund).
2. We register the pair, hand you the WebSocket endpoint and credentials, and (optional but
   recommended) run a Sepolia dry-run first against mock tokens so your stream and fills are
   verified end to end before mainnet.
3. First mainnet fill: you will see `executeSwap` on your provider and `MMFillExecuted` on
   the executor with your address, the consumed amount and the version cursor. From that
   moment your quotes are live in every lane simultaneously.
4. Optional pool lane: on request we deploy a `PropAMMPool` fronting your board and run its
   heartbeat. Routers then read your prices in one `eth_call` and fill you with a
   deterministic on-chain swap; no additional signing or infrastructure on your side, custody
   unchanged. The pool exposes the standard proprietary-AMM surface (`isActive`, `getPairs`,
   `quote`, `swap`), so routers that already integrate prop-AMM pools can use it as-is.

## What can and cannot happen to your inventory

- Funds leave your provider ONLY through `executeSwap`, called only by the executor, only
  against a ladder your key signed, only within that version's once-ever budget, and only
  with the matching tokenIn already delivered.
- Kill switch: stop signing and quotes die at their own TTL; for an immediate hard stop, sign
  a tombstone (dust top level, long TTL) and the board is dead until you resume.
- We never hold, pull or custody anything of yours at any point.

## Operating model

- One signed price feed serves every execution lane: the onchain pool boards aggregator
  routers read and fill directly, hosted retail intents, and - if you choose to sign
  long-TTL quotes - RFQ-style consumers who carry your signed ladder in their own
  transaction, with the quote window priced by you. Consumers integrate the stack directly;
  there is no per-consumer work on your side.
- You operate nothing onchain: no pool contract, no keeper, no price pushing. The code you
  add is a signer for the ladder schema, EIP-712 over WebSocket.
- Pricing logic and models stay in your systems. What becomes public is the ladders you
  sign, at settlement.
- Funds move only on fills against your signature, inside each version's once-ever budget.
  TTL and top-level size are set per message.
- No deposit, no exclusivity, no notice period. To delist, stop signing and withdraw.
- Gas costs and settlement behavior quoted in these docs are measured on the live
  deployments.
