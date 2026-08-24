# Streaming price levels

How pricing works on Biconomy PropAMM: you stream signed ladders of price levels off-chain, and fills settle on-chain against your freshest ladder. Nothing is posted on-chain to quote, and your inventory contract's execution logic computes the final fill. This page covers the pricing model; contract interface, wire protocol, and a runnable client are in [integration.md](integration.md).

## Why ladders

A ladder expresses how your price changes with size in one signed message. For example, USDC into WETH: up to 1k at one price, up to 10k slightly wider, up to 100k wider still. We read it directly, keep your prices in every precomputed route, and quote your liquidity instantly, with no RPC round trip to your contracts on the quote path. It is the levels format you likely already publish to other RFQ venues.

## What you sign and stream

One EIP-712 message per pair, direction, and update: `{ tokenIn, tokenOut, levels[], nonce, expiresAt }`, where each level is `(size, price)` with the standard meaning: `size` is the total volume available up to that level, `price` is the price for volume landing in it. EOA or EIP-1271 signer, ever-increasing nonce per pair-direction, wall-time expiry. You choose how many levels and what granularity; 5 to 20 is typical of RFQ level feeds. Re-stream whenever your pricing or inventory moves, at your normal cadence. A one-level ladder is a flat price.

Fills sweep your levels like an order book: an order overlapping levels blends across them, each consumed slice at its tranche's price, so your quoted depth is exactly what takers receive - no covering-level rounding up.

## What happens on chain

At settlement we commit the hash of your signed ladder (verified against your signature), and the contract itself determines which level applies from the volume already filled against your ladder, so only prices you signed can ever be used and nobody, including us, chooses the level. Fills consume your levels cumulatively, and the depth budget is per signed ladder, once, ever: total volume filled against one ladder can never exceed its top level's size no matter how the flow is sliced or how many blocks it spans, each tranche pays the price you set for that depth, and your 1k price can never be applied to a 100k trade or to ten stacked 10k trades. Freshness is versioned: a fill settles only against your freshest committed ladder, inside the expiry you signed; committing a fresher ladder cancels the previous one on the spot, and a superseded ladder can never fill while its replacement lives. If your newest ladder expires with an older one still inside its own signed validity, that older quote can take over, resuming whatever depth it had left, never with fresh depth. This is what lets you serve short-lived ticks and longer-lived quotes from one signing key and one nonce sequence.

Your inventory contract's `executeSwap` keeps the final say: it receives the applicable price as a single anchor and computes the delivered amount with your own logic. The anchor is already size-appropriate (your own signed price for that depth); put size-dependent spread in the ladder rather than applying it again in your contract.

We verify quotes by simulating the real execution path before returning them, and the taker's minimum-out floor is enforced at settlement.

## Your protections

- Your inventory, your keys, your kill switches: stop streaming and your ladders die at the expiries you signed; commit a replacement to cancel everything outstanding at once; cap your top level to decline larger sizes.
- Your top level caps the total volume any signed ladder can ever fill against you, once, across its whole life.
- The expiry is yours per message: sign seconds-long ticks for hot flow and longer windows for aggregator pipelines, from the same key and nonce sequence, pricing the longer option into its spread.
- Per-size pricing: each depth tranche carries its own price.
- Within a committed ladder's validity, fills are not restricted to our orchestrator; the expiry you signed, the supersede rule, the per-ladder depth cap, and your contract's own logic are the protections.

## Fit checklist

1. Your pricing engine can emit size-indexed levels per pair and direction at your normal cadence and sign them as one message.
2. Your signer can sign an EIP-712 message containing a struct array (any standard `signTypedData` implementation works).
3. If your pricing depends on something a size-indexed ladder cannot express (per-counterparty pricing, execution-time logic), nothing breaks, since your contract keeps the final say. Tell us how far your streamed levels may sit from your executed price in practice so routing stays accurate.
