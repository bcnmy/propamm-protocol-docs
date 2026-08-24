# Maker quickstart

The shortest path from nothing to a live board on Base Sepolia: deploy `BasicMMProvider`, fund it, connect, stream, and read your board back from the chain. Background and the full message spec are in [integration.md](integration.md) and [price-ladder-streaming.md](price-ladder-streaming.md).

You need Foundry (`forge`, `cast`), Node 20 or later, a Base Sepolia RPC URL, a funded deployer key for one transaction, and a signing key for your stream. The two keys can be the same during testing.

## Addresses

| What | Address |
|---|---|
| `PropAMMExecutor` (sign against this; set it as `approvedExecutor`) | `0x000000F80660419ECcED6F86dBc762725371eb56` |
| `PropAMMVenue` (routers read and fill your board here) | `0x000000445Dff11123a3BD8A4Dd03a351829aF892` |
| MockWETH (18 decimals, mintable) | `0x8b414aD7005EeFd315aF2A16538885Eae229bab7` |
| MockUSDC (18 decimals, mintable) | `0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df` |

The contract addresses are the same on Base (8453) and BNB Smart Chain (56); only the chain id and the token addresses change.

```bash
export RPC_URL=<your Base Sepolia RPC>
export EXECUTOR=0x000000F80660419ECcED6F86dBc762725371eb56
export VENUE=0x000000445Dff11123a3BD8A4Dd03a351829aF892
export WETH=0x8b414aD7005EeFd315aF2A16538885Eae229bab7
export USDC=0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df
export SIGNER=<address of your signing key>
export OWNER=<address that will own the provider>
```

## Step 1: deploy the provider

Copy [`examples/IMMProvider.sol`](examples/IMMProvider.sol) to `src/interfaces/IMMProvider.sol` and [`examples/BasicMMProvider.sol`](examples/BasicMMProvider.sol) to `src/periphery/examples/BasicMMProvider.sol` in a Foundry project (the import path assumes that layout), install solady, and deploy with your signer, the executor and your owner:

```bash
forge install vectorized/solady
forge create src/periphery/examples/BasicMMProvider.sol:BasicMMProvider \
  --rpc-url $RPC_URL --interactive --broadcast \
  --constructor-args $SIGNER $EXECUTOR $OWNER
export PROVIDER=<the deployed address>
```

`--interactive` prompts for the deployer key so it never appears on the command line. The constructor pins the executor as the only address allowed to call `executeSwap`.

## Step 2: fund it

Mint test tokens straight into the provider. Inventory is the output token of each direction you quote, so fund USDC for WETH to USDC and WETH for the reverse:

```bash
cast send $USDC "mint(address,uint256)" $PROVIDER 1000000000000000000000000 --rpc-url $RPC_URL --interactive   # 1,000,000 MockUSDC
cast send $WETH "mint(address,uint256)" $PROVIDER 1000000000000000000000    --rpc-url $RPC_URL --interactive   # 1,000 MockWETH
```

## Step 3: register

Send the network your signer address, your provider address and the directions you will quote (here WETH to USDC and USDC to WETH on 84532). The stream rejects messages until this is done (`UNREGISTERED_MARKET_MAKER`, `UNSUPPORTED_PAIR`, `PROVIDER_MISMATCH`). For the onchain lane the venue owner also registers your signer on the venue; nothing on your side.

## Step 4: connect and stream

Connect to `wss://propamm-staging.biconomy.io`, subscribe as your signer, and send boards. Pick one of the two forms.

**A price ladder.** Sign a `PriceLadder` per direction on every tick: cumulative sizes, absolute prices, a strictly increasing nonce, a TTL of tens of seconds. With both mock tokens at 18 decimals, 2,000 USDC per WETH is `price = 2000e18` for WETH to USDC and `5e14` for USDC to WETH (`1e18 / 2000`).

```json
{
  "type": "price-ladder",
  "payload": {
    "mm": "<SIGNER>",
    "provider": "<PROVIDER>",
    "tokenIn": "0x8b414aD7005EeFd315aF2A16538885Eae229bab7",
    "tokenOut": "0xAbbdbbbd6d56593A9c5656c06cB30D61E4a544Df",
    "levels": [
      { "size": "1000000000000000000", "price": "1998000000000000000000" },
      { "size": "3000000000000000000", "price": "1995000000000000000000" }
    ],
    "nonce": "<unix milliseconds>",
    "expiresAt": "<unix seconds, now + 30>",
    "signature": "<EIP-712 signature>",
    "chainId": 84532
  }
}
```

**An anchor loop.** Sign one `OffsetLadder` per direction (sizes, offsets in ppm below the anchor, optional drift, a TTL of up to an hour), then an `Anchor` per direction every second with the reference price, its own nonce and a TTL of about 15 seconds. The runnable client in [integration.md, section 4](integration.md#4-the-stream) does exactly this against the addresses above; set `MM_SIGNER_KEY` and `PROVIDER` and run it.

Every accepted message is answered with `{ "type": "ack" }`. An `error` frame names the reason; the code table is in [integration.md](integration.md#error-codes).

## Step 5: verify with `board()`

Once the network has committed your board, read it from the venue. A live board returns your levels, `filled` zero, `remaining` equal to your top size, and the effective expiry:

```bash
cast call $VENUE "board(address,address,address)(uint256[],uint256[],uint256,uint256,uint256)" \
  $SIGNER $WETH $USDC --rpc-url $RPC_URL
```

The executor returns the same plus both nonces and the form (`1` price ladder, `2` offset ladder):

```bash
cast call $EXECUTOR "board(address,address,address)(uint256[],uint256[],uint256,uint256,uint256,uint256,uint256,uint8)" \
  $SIGNER $WETH $USDC --rpc-url $RPC_URL
```

What a router sees for the pair, merged across every registered maker and net of the protocol fee:

```bash
cast call $VENUE "isActive(address,address)(bool)" $WETH $USDC --rpc-url $RPC_URL
cast call $VENUE "quote(address,address,uint256)(uint256)" $WETH $USDC 1000000000000000000 --rpc-url $RPC_URL
cast call $VENUE "levels(address,address)(uint256[],uint256[],uint256)" $WETH $USDC --rpc-url $RPC_URL
```

If `board()` returns empty arrays and `remaining == 0`, the board is dark: not yet committed, expired, or (offset form) missing a live anchor. Check that your messages are acked, that `expiresAt` leaves enough life for the commit to land, and on an offset board that anchors keep flowing.

## Step 6: watch a fill

When a fill lands you will see `executeSwap` called on your provider, `MMFillExecuted` on the executor with your provider and signer, the amounts and `filledAfter` (the meter after the fill), and `Transfer` events on both tokens. `board()` shows `filled` advanced by the amount and `remaining` reduced. On an offset board the next anchors re-price the remaining depth without resetting the meter; a new offset ladder resets it.

## What can and cannot happen to your inventory

- Funds leave your provider only through `executeSwap`, called only by the executor, only against a board your key signed, only within that version's once-spent meter, and only with the matching `tokenIn` already delivered to the executor.
- Stop signing and your boards die at their TTLs. For an immediate stop, sign a tombstone (dust top size, fresher nonce) or rotate `approvedExecutor`. `withdraw` is yours at any time.
- Nothing is held, pulled or approved on your behalf at any point.
