/**
 * Reference maker: stream signed price ladders sampled from a continuous curve.
 *
 * For makers whose pricing engine is a curve (pmm, clmm, any quote function) rather than a
 * ladder. The conversion below is CONSERVATIVE by construction: every promised amount is at or
 * below the true curve output, so discretization error always favors the maker.
 *
 * Why that holds: a ladder rung prices the interval between two sampled sizes at the average
 * marginal price of that interval (the chord). Any concave quote function (all AMM-style
 * curves) lies on or above its chords, so the ladder under-promises at every fill size, at the
 * rungs and between them. More rungs shrink the gap; 15-30 geometric rungs keep it sub-bps
 * across most of the size range. Exactness is not required, only the lower bound.
 *
 * Runtime: node 20+, `npm i viem ws`. Fill in the CONFIG block and `curveOut`.
 */
import { privateKeyToAccount } from "viem/accounts";
import WebSocket from "ws";

// ---------------------------------------------------------------- CONFIG
const ENDPOINT = "wss://propamm-staging.biconomy.io"; // production: wss://propamm.biconomy.io
const CHAIN_ID = 8453; // Base
const EXECUTOR = "0x000000Ab52Bdb44411777412fe938776a766cc6a"; // same address on every chain
const TOKEN_X = "0x4200000000000000000000000000000000000006"; // WETH
const TOKEN_Y = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"; // USDC
const PROVIDER = "0xYourInventoryContract"; // where fills pull your inventory
const TTL_SECONDS = 4; // you choose: how long each ladder update stays fillable
const RUNGS = 20;
const CAP_X = 10n * 10n ** 18n; // deepest size you quote, tokenIn wei

const account = privateKeyToAccount(process.env.MAKER_PK as `0x${string}`);

/**
 * Your pricing engine. Return the exact tokenOut amount your venue pays for `amountIn` of
 * `tokenIn` right now, in tokenOut wei. This is the only integration point: point it at your
 * internal curve state (or sample your public quoter).
 */
async function curveOut(tokenIn: string, tokenOut: string, amountIn: bigint): Promise<bigint> {
  throw new Error("wire me to your curve");
}

// ------------------------------------------------- curve -> conservative ladder
interface Level {
  size: bigint; // cumulative tokenIn wei
  price: bigint; // tokenOut wei per tokenIn wei, 1e18-scaled, for this rung's interval
}

/** Geometric cumulative sizes from cap/2^(n-1) up to cap: dense where quotes are small. */
function geometricSizes(cap: bigint, n: number): bigint[] {
  const sizes: bigint[] = [];
  for (let i = n - 1; i >= 0; i--) sizes.push(cap >> BigInt(i));
  return [...new Set(sizes.map(String))].map(BigInt);
}

async function curveToLadder(tokenIn: string, tokenOut: string, cap: bigint): Promise<Level[]> {
  const sizes = geometricSizes(cap, RUNGS);
  const levels: Level[] = [];
  let prevSize = 0n;
  let prevOut = 0n;
  let prevPrice = 0n;
  for (const size of sizes) {
    const out = await curveOut(tokenIn, tokenOut, size); // sample the true curve, cumulative
    const marginalIn = size - prevSize;
    const marginalOut = out - prevOut;
    if (marginalIn <= 0n || marginalOut <= 0n) break; // curve exhausted: stop the ladder here
    // Floor division: the rung promises at or under the curve's own average price for the
    // interval. This floor is the entire "accuracy" story - promised <= curve, always.
    let price = (marginalOut * 10n ** 18n) / marginalIn;
    if (prevPrice !== 0n && price > prevPrice) price = prevPrice; // guard numeric noise
    levels.push({ size, price });
    prevSize = size;
    prevOut = out;
    prevPrice = price;
  }
  return levels;
}

// ------------------------------------------------------------- sign + stream
const EIP712_DOMAIN = {
  name: "PropAMMExecutor",
  version: "1",
  chainId: CHAIN_ID,
  verifyingContract: EXECUTOR,
} as const;

const LADDER_TYPES = {
  PriceLadder: [
    { name: "mm", type: "address" },
    { name: "provider", type: "address" },
    { name: "tokenIn", type: "address" },
    { name: "tokenOut", type: "address" },
    { name: "levels", type: "Level[]" },
    { name: "nonce", type: "uint256" },
    { name: "expiresAt", type: "uint256" },
  ],
  Level: [
    { name: "size", type: "uint256" },
    { name: "price", type: "uint256" },
  ],
} as const;

let nonce = BigInt(Date.now()); // any strictly increasing sequence works

async function sendLadder(ws: WebSocket, tokenIn: string, tokenOut: string): Promise<void> {
  const levels = await curveToLadder(tokenIn, tokenOut, CAP_X);
  if (levels.length === 0) return; // nothing servable right now: publish nothing
  nonce += 1n;
  const expiresAt = BigInt(Math.floor(Date.now() / 1000) + TTL_SECONDS);
  const message = { mm: account.address, provider: PROVIDER, tokenIn, tokenOut, levels, nonce, expiresAt } as const;
  const signature = await account.signTypedData({
    domain: EIP712_DOMAIN,
    types: LADDER_TYPES,
    primaryType: "PriceLadder",
    message,
  });
  ws.send(
    JSON.stringify({
      type: "price-ladder",
      payload: {
        ...message,
        levels: levels.map((l) => ({ size: l.size.toString(), price: l.price.toString() })),
        nonce: nonce.toString(),
        expiresAt: expiresAt.toString(),
        signature,
        chainId: CHAIN_ID,
      },
    }),
  );
}

function main(): void {
  const ws = new WebSocket(ENDPOINT);
  ws.on("open", () => {
    ws.send(JSON.stringify({ type: "subscribe", data: { type: "price-ledger", mm: account.address } }));
    // Refresh on your own cadence: every curve move, every block, or a fixed interval. Each
    // update replaces the previous ladder; TTL bounds how long the last one stays fillable.
    const tick = async () => {
      await sendLadder(ws, TOKEN_X, TOKEN_Y);
      await sendLadder(ws, TOKEN_Y, TOKEN_X);
    };
    void tick();
    setInterval(() => void tick(), 1_000);
  });
  ws.on("message", (m) => console.log(m.toString()));
  ws.on("close", () => process.exit(1)); // let your supervisor restart for a clean reconnect
}

main();
