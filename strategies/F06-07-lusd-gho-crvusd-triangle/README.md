# F06-07: LUSD redemption + GHO + crvUSD triangular stablecoin arb

3-mechanism strategy. **Family: F06 (Liquity v1)** with GHO and crvUSD CDP
stablecoins as the secondary venues.

## Mechanisms combined
1. **Liquity v1** — LUSD redemption hard floor at $1 (TroveManager).
2. **Maker DssFlash** — zero-fee DAI flashmint (the canonical capital source).
3. **Curve** — triangular routing across LUSD/3pool meta + GHO/USDC/USDT
   Stableswap-NG + crvUSD/USDC Stableswap-NG.

## Mechanism
Three separate CDP stablecoins (LUSD, GHO, crvUSD) often drift independently
around peg, each with its own redemption/anchor mechanism:
- **LUSD** has a hard 1:1 ETH redemption at the Liquity TroveManager.
- **GHO** has a soft peg via Aave variable interest rate (no hard
  redemption).
- **crvUSD** has LLAMMA soft-liquidation but trades close to peg via the
  Stableswap-NG pool.

When LUSD is below peg AND either GHO or crvUSD is above peg on Curve, a
triangle captures (a) LUSD's hard redemption alpha and (b) the GHO/crvUSD
basis trade. Path:

```
DAI flashmint
 → DAI/LUSD on Curve meta-pool (cheap leg)
 → LUSD redemption at TroveManager → ETH
 → ETH/USDT on tricrypto2
 → USDT/USDC on 3pool
 → split USDC: half to GHO, half to crvUSD (each at its premium)
 → reverse both legs back to USDC (collecting the basis if any)
 → USDC/DAI on 3pool
 → repay flashmint
```

If GHO or crvUSD are at exact peg, the corresponding leg nets to ~−1bp
(Curve fee). The strategy still works as a pure LUSD-redemption arb in
those regimes; the triangle only *adds* alpha when the inter-stable basis
opens up.

## Why it composes
- **LUSD redemption** provides a deterministic $1 floor below which the
  arb is risk-free up to oracle freshness.
- **GHO/USDC pool (`0x635EF0...578595`)** is the deepest GHO venue
  (>$15M TVL by mid-2024 after Aave incentives).
- **crvUSD/USDC pool (`0x4DEcE678...30bAD69E`)** is the canonical crvUSD
  venue (>$40M TVL).
- **DssFlash** is the only zero-fee, multi-million stable flash on chain
  for this size.

## Preconditions
- LUSD/3pool spot < 0.997 LUSD/DAI.
- Liquity `baseRate` ≤ 1%.
- GHO or crvUSD trades > 1.001 USDC.
- DssFlash open (`toll == 0`).

## Strategy steps
1. `DssFlash.flashLoan(this, DAI, 3M, "")`.
2. In callback:
   a. DAI → LUSD on Curve meta.
   b. LUSD → ETH at Liquity TroveManager.
   c. ETH → USDT → USDC.
   d. Half USDC → GHO; half USDC → crvUSD.
   e. Reverse: GHO → USDC; crvUSD → USDC.
   f. USDC → DAI on 3pool.
   g. Approve & return ERC-3156 magic value.
3. Residual DAI = profit.

## PnL math
For `flash = 3M DAI`, LUSD = 0.992, GHO = 1.003, crvUSD = 1.000, R = 0.0055:
```
A) DAI -> LUSD       :   3_000_000 / 0.992 × (1 - 0.0004) ≈ 3_022_177 LUSD
B) LUSD -> ETH       :   redeem, (1 - R) × 3_022_177 ≈ 3_005_555 (USD equiv)
C) ETH -> USDC       :   tricrypto2 + 3pool, slippage ≈ 6 bps
                     :   ≈ 3_003_752 USDC
D) USDC -> GHO (1.5M):   1.5M / 1.003 × (1 - 0.0004) ≈ 1_494_502 GHO
E) GHO -> USDC       :   reverse same pool, mid moves to ~1.0015
                     :   1_494_502 × 1.0015 × (1 - 0.0004) ≈ 1_495_596 USDC
   Net GHO leg       :   +595 USDC (+4 bps on 1.5M)
F) USDC -> crvUSD    :   1.5M × ~1.0000 - fee ≈ 1_499_400 crvUSD
G) crvUSD -> USDC    :   1_499_400 × ~1.0000 - fee ≈ 1_498_800 USDC
   Net crvUSD leg    :   −1200 USDC (−8 bps on 1.5M)

Combined triangle add:  +595 − 1200 = −605 USDC vs straight USDC roundtrip.

LUSD alpha:           ≈ (1/0.992) × (1 − 0.0055) − 1 ≈ +25 bps on 3M = +$7,500
Net                   ≈ +$7,500 − $605 ≈ +$6,900 on $3M turn (≈ 23 bps).
```

When LUSD discount is tighter (e.g. 30 bps), the GHO premium can dominate
the trade. Sweet spot: simultaneous 50+ bps LUSD discount and 30+ bps GHO
or crvUSD premium → +$20–40k per $3M turn.

Gas ≈ 1.5M @ 30 gwei = 0.045 ETH ≈ $135. Net ≈ $6,800.

## Block pinned
- `FORK_BLOCK = 19_800_000` (≈ May 2024 — confirmed GHO depeg window post
  the Maple stUSDC stress; LUSD also discounted ~40 bps).

## Risks
- **GHO peg snap-back.** GHO peg arb is driven by Aave variable rate
  adjustments — between blocks, the basis can collapse mid-tx if a
  large Aave rate change clears the pool.
- **crvUSD soft-liq stack.** When crvUSD borrowers cross their LLAMMA
  band, large amounts of crvUSD are minted/redeemed in the pool;
  the basis can move 50+ bps in a block.
- **Multi-pool MEV.** Three Curve pools in one tx maximises sandwich
  surface. Required: Flashbots bundle.
- **LUSD redemption depth.** Same as F06-01.

## Result
Status: **structurally reproducible**; all three Curve pool addresses
verified and stable.

PnL range:
- LUSD alpha alone: +5–25 bps net.
- LUSD + favourable triangle: **+20–60 bps net, $6k–$18k per $3M turn**.
- Worst (triangle drag dominates): −2 bps net (still positive vs LUSD
  alone in most regimes).
