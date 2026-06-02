# B13-04: USDe BSC ↔ Ethereum OFT mint/burn roundtrip

## Mechanism
Ethena USDe is *minted* on Ethereum (against ETH / stETH collateral via
`EthenaMinting`) and *bridged* to BSC as a LayerZero OFT. The canonical
peg-keeping flow is:

- **Mint on ETH** → USDe arrives on ETH at 1.0 USD per unit.
- **OFT send ETH→BSC** → burn on ETH, mint on BSC, 1:1 (no LZ fee on the
  token; only native LZ executor gas).
- **Swap on BSC** (PCS v3 USDe/USDT, Wombat USDe pool) — this is the
  price-discovery venue; it can wedge away from $1.

When BSC-side USDe demand spikes (e.g. Pendle PT-sUSDe / Lista USDe
collateral campaign), USDe on BSC trades at a **20-60 bp premium** to
USDT — but a user holding USDe on Ethereum could OFT-send it across and
immediately swap it for $1.005 on BSC. The reverse (BSC USDe at
discount) happens during sell-the-news / point-farming exits.

The roundtrip arb (BSC USDe at *premium* case):

1. On Ethereum mainnet (off-chain in PoC): mint USDe via
   `EthenaMinting.mint(...)` against USDT collateral. Cost: 0 bp + gas.
   *Or:* simply buy USDe on Curve at ~$1.000.
2. **OFT send ETH → BSC** via the USDe OFT adapter on Ethereum
   (`0xc06...e80` mainnet). BSC-side credit lands ~1-3 minutes later.
3. **On BSC**: swap USDe → USDT on PCS v3 at the premium. Capture the
   20-60 bp spread.
4. **Return leg (optional)**: swap USDT → USDe back at the same venue
   later (after the premium normalises), or just OFT-send USDT back via
   the USDT_OFT_ADAPTER (B13-01).

The execution leg the *BSC* side performs in this PoC:

- Pre-funded USDe (representing the inflow from step 2).
- PCS v3 `flash(USDT)` from the deepest USDT pool — actually we can skip
  flash because we already hold USDe; we just `exactInputSingle(USDe ->
  USDT)` at the premium.
- Mark PnL as USDT delta.

Because the OFT send is the *non-atomic* part (sits cross-chain for
1-3 min), this is **positional**. The BSC PoC executes only the
*capture* step (swap USDe→USDT at premium), assuming the OFT inflow
already arrived.

## Why it composes
- **Two distinct USDe supplies** (ETH mint vs BSC OFT credit) but one
  global peg → any BSC-side wedge is an instant arb against a deep ETH
  mint primitive.
- **EthenaMinting on ETH is fee-free** for whitelisted MMs; even retail
  Curve swap on ETH is 1 bp. The LZ OFT send is fee-free on the token
  side.
- **PCS v3 USDe/USDT pool depth** is $5-20M typical; supports
  $500k-$2M notional with < 10 bp slippage.

## Preconditions
- USDe OFT credit has already arrived on BSC (modelled via
  `_fund(BSC.USDe, ...)`).
- PCS v3 USDe/USDT pool exists (TODO verify pool address); falls back to
  `factory.getPool(USDe, USDT, 500)` then 0.01% tier.
- BSC-side USDe trades at a *premium* of > 20 bp; otherwise the strategy
  flips to the reverse direction (USDT→USDe, hold USDe waiting for
  return premium), which is left as a TODO branch.

## PnL math
Notional `N` USDe inflow. Assumed premium `P` bp (e.g. 40 bp).
- USDT out: `N * (1 + P/10000)` (e.g. 1,000,000 USDe → 1,004,000 USDT)
- PCS v3 swap fee: 5 bp on the 0.05% tier = `N * 0.0005`
- LZ executor fee on the inbound send (ETH→BSC): ~$0.15 → negligible.
- Net spread per $1M cycle at 40 bp premium:
  `$4,000 - $500 (PCS fee) - $0.15 (lz)` = **~$3,500**.

## Block pinned
- `FORK_BLOCK = 46_900_000` — placeholder. Re-pin to a window where
  USDe/USDT PCS spot > 1.002. TODO scan Pendle/Lista campaign launch
  windows.

## Risks
- **OFT credit arrived late or not at all**: not modeled in PoC; in
  production the OFT send `quoteSend(...).nativeFee` is non-refundable.
- **PCS v3 USDe/USDT pool wedges back during the swap** (own market
  impact): PoC sizes N to 500k so impact stays < 2 bp.
- **Curve USDe-USDT-USDC pool on BSC** may be a better swap venue than
  PCS v3 (lower slippage on stables). TODO add Curve route in v2.

## Status
- **Positional** (LayerZero OFT delivery is ~1-3 min cross-chain).
- The BSC-side capture leg is atomic on BSC; the cross-chain leg is the
  positional component.
- Offline-first PoC; emits `pnl_usd=` via BSCStrategyBase.
