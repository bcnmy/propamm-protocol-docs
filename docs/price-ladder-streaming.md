# Streaming price levels

How pricing works on Biconomy PropAMM: you stream signed ladders of price levels off-chain, and fills settle on-chain against your freshest ladder. Nothing is posted on-chain to quote, and your inventory contract's execution logic computes the final fill. This page covers the pricing model; contract interface, wire protocol, and a runnable client are in [integration.md](integration.md).

## Why ladders

A ladder expresses how your price changes with size in one signed message. For example, USDC into WETH: up to 1k at one price, up to 10k slightly wider, up to 100k wider still. We read it directly, keep your prices in every precomputed route, and quote your liquidity instantly, with no RPC round trip to your contracts on the quote path. It is the levels format you likely already publish to other RFQ venues.

## What you sign and stream

One EIP-712 message per pair, direction, and update: `{ tokenIn, tokenOut, levels[], nonce, expiresAt }`, where each level is `(size, price)` with the standard meaning: `size` is the total volume available up to that level, `price` is the price for volume landing in it. EOA or EIP-1271 signer, ever-increasing nonce per pair-direction, wall-time expiry. You choose how many levels and what granularity; 5 to 20 is typical of RFQ level feeds. Re-stream whenever your pricing or inventory moves, at your normal cadence. A one-level ladder is simply a flat price.

Fills sweep your levels like an order book: an order overlapping levels blends across them, each consumed slice at its tranche's price, so your quoted depth is exactly what takers receive - no covering-level rounding up.

## What happens on chain

At settlement we commit the hash of your signed ladder (verified against your signature), and the contract itself determines which level applies from the volume already filled against your ladder, so only prices you signed can ever be used and nobody, including us, chooses the level. Fills consume your levels cumulatively: total volume filled against a ladder in its block cannot exceed your top level's size, each tranche pays the price you set for that depth, and your 1k price can never be applied to a 100k trade or to ten 10k trades stacked in one block. A fill can only use a ladder committed in that same block and inside its expiry, and nonces are monotonic on-chain, so a superseded price can never fill.

Your inventory contract's `executeSwap` keeps the final say: it receives the applicable price as a single anchor and computes the delivered amount with your own logic. The anchor is already size-appropriate (your own signed price for that depth), so size-dependent spread belongs in the ladder, not layered again in your contract.

We verify quotes by simulating the real execution path before returning them, and the taker's minimum-out floor is enforced at settlement.

## Your protections

- Your inventory, your keys, your kill switches: stop streaming and your ladder expires; cap your top level to decline larger sizes.
- Your top level caps the total volume any single block can fill against you.
- Size-aware quoting: be tight where you want, wide where you need.
- Within a committed ladder's one-block validity, fills are not restricted to our orchestrator; the one-block window, the depth cap, your cadence, and your contract's own logic are the protections.

## Fit checklist

1. Your pricing engine can emit size-indexed levels per pair and direction at your normal cadence and sign them as one message.
2. Your signer can sign an EIP-712 message containing a struct array (any standard `signTypedData` implementation works).
3. If your pricing depends on something a size-indexed ladder cannot express (per-counterparty pricing, execution-time logic), nothing breaks, since your contract keeps the final say. Tell us how far your streamed levels may sit from your executed price in practice so routing stays accurate.
