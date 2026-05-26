# F15-08: Symbiotic + EigenLayer + Pendle YT triple-stack

## Mechanism

Three distinct restaking / point primitives, each capturing a different
airdrop universe, on the same aggregate equity:

- **Symbiotic** (Leg A): wstETH `DefaultCollateral` vault deposit. Earns
  Symbiotic points → SYMB airdrop (TGE forecast late-2024/early-2025) +
  any AVS-curator (Mellow) rewards routed to the depositor.
- **EigenLayer** (Leg B): wstETH unwrapped to stETH, deposited into the
  canonical EL stETH strategy proxy. Earns EigenLayer points → EIGEN AVS
  reward stream + (once delegated) operator-routed AVS rewards.
- **Pendle YT-LRT** (Leg C): 30 ETH worth of WETH swapped into YT-rsETH
  (Kelp's restaking LRT) on Pendle. The YT carries the **full underlying
  point stream of 1 rsETH** until expiry, at ~3-5% of the underlying
  price — a 20-30× point-density uplift per ETH-of-cash spent. The cash
  leg is structurally negative (YT decays to zero at expiry); the entire
  upside is the airdrop expectation on the AMPLIFIED point stream.

## Why it composes (3-mechanism)

Three independent point-/reward-emitting protocols on three legs:

1. **Symbiotic restaking layer** — SYMB points + Mellow-curator yield.
2. **EigenLayer restaking layer** — EIGEN points + AVS reward distribution.
3. **Pendle YT yield-decoupling layer** — KELP/RSETH point amplification
   (plus EIGEN-via-Kelp via the LRT itself).

The legs are non-cannibalistic: Symbiotic and EigenLayer treat their
respective stakes independently (no double-credit, but they don't subtract
from each other either). Pendle's YT mechanism is a **third-party
amplifier** — by paying upfront for time-decay risk on a YT, the user
front-loads ~120-180 days of LRT points into a one-shot purchase at the
fork block.

The diversification: if EIGEN airdrop disappoints, SYMB and KELP backstop;
if Symbiotic governance falters, EL and Kelp carry; if Kelp's airdrop
under-delivers, the principal-decay was already known going in.

## Preconditions

- Block: 20,400,000 (Aug 2024). Symbiotic mainnet live; EL caps periodically
  open; Pendle's rsETH market has successor maturity trading.
- Symbiotic wstETH vault: `0xC329400492c6ff2438472D4651Ad17389fCb843a`
  (verified, see F15-04).
- EL stETH strategy: `0x93c4b944D05dfe6df7645A86cd2206016c51564D`.
- Pendle rsETH market: `0x4f43c77872Db6BA177c270986CD30c3381AF37Ee`
  (verified Pendle UI at FORK_BLOCK; successor maturity if Jun-2024 has
  expired by fork-time).
- 90 wstETH equity (non-rebasing → `deal()` works).
- 30 WETH funded directly to the contract as a stand-in for the
  Curve(stETH→ETH)→Pendle path; production must execute the swap on-chain
  (Curve stETH/ETH pool, see F03-01 for the wiring).

## Strategy steps

1. `_fund(WSTETH, address(this), 90 ether)`.
2. Snapshot PnL.
3. **Leg A** — approve 30 wstETH to Symbiotic vault; call
   `ISymbioticCollateral(vault).deposit(address(this), 30e18)`.
4. **Leg B** — `IWstETH.unwrap(30e18)` → ~31 stETH; approve to EL StrategyManager;
   `depositIntoStrategy(STETH_STRATEGY, stETH, amount)`.
5. **Leg C** — fund 30 WETH (PoC short-circuit; production swaps stETH→ETH on
   Curve); approve Pendle router; `swapExactTokenForYt(receiver, market,
   0, guess, TokenInput(WETH,...), LimitOrder())` → mints YT-rsETH at the
   prevailing implied APY (~3-5% of underlying for a 4-6mo maturity).
6. Log each leg's outputs.
7. End PnL.

Each leg is wrapped in try/catch; the test requires at least 2 of the 3
legs to land (a single-leg degenerate is not the trade).

## PnL math (forward, 90 wstETH ≈ 104 stETH-equiv ≈ $312k @ $3k ETH)

```
Equity per leg:    30 wstETH (≈ 31 stETH ≈ $93k).

Leg A (Symbiotic):
  Lido yield (wstETH compounding) 30 × 3.0%        = 0.90 wstETH ≈ $2,700
  Symbiotic points (early-launch density)
      30 × 100 pts/wstETH/d × 365 = 1,095,000 pts
      @ $0.02/pt (early TGE assumption)             ≈ $21,900
  Mellow curator yield (AVS rewards forwarded)     ≈ $1,200
  Subtotal:                                        ≈ $25,800

Leg B (EigenLayer):
  Lido yield (via stETH)  31 × 3.0%                = 0.93 stETH ≈ $2,790
  EL points  31 × 1pt/d × 365 = 11,315 pts
      @ $3.50/pt (EIGEN listing)                   ≈ $39,600
  AVS rewards (un-delegated baseline ~0.3%)        ≈ $279
  Subtotal:                                        ≈ $42,700

Leg C (Pendle YT-rsETH):
  Notional cash deployed: 30 ETH (~$90k).
  YT/SY price ratio (~4% for 4-mo maturity): 30 ETH buys ~750 YT
                                              (covers ~750 ETH of rsETH point notional).
  KELP/RSETH points: 750 × 50 pts/ETH/d × 120d = 4,500,000 pts
      @ $0.015/pt (TGE-discounted)                 ≈ $67,500
  EL pts (rsETH is restaked) 750 × 1 pt/d × 120 × $3.50 × 0.85 (LRT fee)
                                                   ≈ $267,750 (TVL-leveraged)
  YT principal decay over 120d:                    -30 ETH (-$90,000)
  Net Leg C (point - decay):                       ≈ +$245,250 (HIGH variance)

Total 1-year-equivalent (Leg A/B annualised, Leg C 120-day cycle):
  Base case (all 3 airdrops realise mid-range): ~$313k on $312k equity (~100%/yr)
  Bear case (Leg C YT decays full, no airdrop): -$90k + $11k + $5k = -$74k
  Bull case (Leg C airdrop hits $200k):         ~$500k

The asymmetry comes entirely from Leg C. Legs A+B together earn ~$68k/yr on
$186k equity (37%/yr). Leg C is the lottery ticket; it can quadruple total
PnL or zero out, depending on Kelp + EL airdrop monetisation.
```

## Block pinned

- Fork block: 20,400,000.

## Risks

- **YT decay risk (Leg C dominant).** YT principal goes to 0 at expiry.
  If the KELP and EL airdrops realise less than the YT cost
  (~$90k for 30 ETH @ 4% YT/SY ratio), Leg C is net-negative.
- **Symbiotic vault cap.** Vault may be at-cap; Leg A degrades.
- **EL stETH cap.** Same risk as F15-01..04; PoC's try/catch handles.
- **Pendle market liquidity.** YT swap eats slippage if the market is
  thin. Production must size the swap to <1% of pool reserves or use
  Pendle's limit-order book.
- **Triple slashing surface.** The user is exposed to slashing in ALL
  THREE protocols simultaneously. Probability remains low historically
  but the surface is wider than any single-protocol bet.
- **rsETH market maturity rolling.** If the chosen market expires during
  the hold period, the user must redeem YT for SY-rsETH (which is just
  rsETH at expiry, yielding 0 cash) — the point claim still counts up to
  the snapshot date.

## Result

Status: **mechanically reproducible at fork-time**, modulo the Curve
swap short-circuit for Leg C input. Both EL and Symbiotic legs replay
end-to-end; the Pendle leg executes the router call (any router-internal
revert is logged and the strategy degrades to 2-leg).

PnL (1y, 90 wstETH equity ≈ $312k):
- Bull (all 3 airdrops + YT amplification hits): ~+$500k (160%/yr).
- Base (median realisation): ~+$313k (100%/yr).
- Bear (YT decays full, point markets flat): ~-$74k (-24%/yr).

The variance is dominated by Leg C. Without Leg C the strategy degrades
to F15-04's 2-leg model with ~+$68k/yr expected. Including Leg C the
strategy converts the package into a long-vol airdrop bet on top of the
two-leg base carry.
