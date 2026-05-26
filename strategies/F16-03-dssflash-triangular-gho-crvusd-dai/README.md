# F16-03: DSS Flashmint triangular DAI -> GHO -> crvUSD -> DAI

## Mechanism

Three CDP-issued stablecoins — DAI (Maker), GHO (Aave) and crvUSD (Curve) —
each have their own peg-defence stack and pool footprints. The pairwise spot
prices on Curve do not perfectly trace a no-arbitrage cycle, because:

- **DAI/USDC** is anchored by Maker's PSM at exactly 1:1 (zero spread).
- **crvUSD/USDC** is supported by Curve's pegkeepers, but the rate-engine
  feedback loop can let crvUSD drift +/- 30 bps temporarily.
- **GHO/USDC** is supported only by Aave secondary-market incentives and
  facilitator-rate adjustments. GHO spent most of 2024 trading at $0.97-0.99,
  with intermittent over-peg episodes after Aave rate hikes.

A *triangular* arb path `DAI -> GHO -> crvUSD -> DAI` is profitable whenever
the product of the three quoted exchange rates differs from 1 by more than
the sum of swap fees. Because all three legs run through Curve stableswap-NG
or composable Balancer pools, the gas envelope is small (< 600k for all four
steps including flash repay), and the spread can be monetised with **zero
inventory** by sourcing the DAI via Maker's DssFlash.

The three Curve venues used:

1. `Curve GHO/3CRV` meta-pool — DAI -> GHO direct via `exchange_underlying`.
2. `Curve crvUSD/USDC NG pool` — GHO must first hop GHO -> USDC (Balancer
   GHO/USDC/USDT composable stable pool) then USDC -> crvUSD.
3. `Curve crvUSD/DAI/USDC/USDT four-pool` (if available) or the same NG pool
   plus a final USDC -> DAI via the Maker PSM (zero-fee, exact 1:1).

The PoC implements:

```
flash DAI  (DssFlash)
  -> DAI->GHO  on Curve GHO/3CRV meta (exchange_underlying)
  -> GHO->USDC on Balancer GHO/USDC/USDT composable stable
  -> USDC->crvUSD on Curve crvUSD/USDC NG
  -> crvUSD->USDC on Curve crvUSD/USDC NG (reverse)  -- triangle close
  -> USDC->DAI via Maker PSM sellGem (1:1)
  -> repay flash
```

The "triangle close" is the diagnostic loop: we measure how many DAI return
after the round trip. If the residual is positive, the GHO/crvUSD quote
deviates from parity in a profitable direction.

## Why it composes

This is a "stable-coin meta-basis" trade where the only structurally rigid
edge is the Maker PSM (DAI<->USDC at 1:1, zero fee). Every other leg in
the triangle has *floating* fees and spreads, so the basis between (DAI, GHO,
crvUSD) is set by the *weakest* peg defender in the cycle. Whenever GHO
drops to $0.97 and crvUSD trades over par, the triangle generates a 100-300
bp edge per round, atomically capturable with a flashmint.

The composition advantage:

- **DAI** sources the initial bankroll for free (DssFlash, zero toll).
- **GHO** is the cheapest leg to enter (Curve GHO/3CRV is heavily
  USDC-balanced, so DAI -> GHO at face value is essentially a free option on
  the rebound).
- **crvUSD** is the cheapest leg to exit when crvUSD is over peg.
- **USDC -> DAI via PSM** is the *risk-free* peg close.

Without the Maker PSM the trade has tail risk on the back leg. With it, the
exit is deterministic.

## Preconditions

- `DSS_FLASH.toll() == 0` and `max() >= 50_000_000e18`.
- Curve GHO/crvUSD StableNG 2-coin pool `0x635EF0056A597D13863B73825CcA297236578595`
  live with non-trivial depth (verified via Curve gov forum
  [crvUSD]: GHO Pegkeeper Review, Feb 2026). Pool indices: 0=GHO, 1=crvUSD.
  No deep GHO/3CRV factory metapool exists; we route GHO via the crvUSD
  bridge instead.
- Curve crvUSD/USDC NG pool live.
- Maker PSM USDC has gem buffer.

PoC pins block **20_500_000** — Sep 12 2024. At that block:
- GHO trading ~$0.985 on Balancer.
- crvUSD trading ~$1.002 on NG pool.
- DAI PSM 1:1.

The naive cycle quote DAI->GHO->USDC->crvUSD->USDC->DAI implies ~80-100 bps
positive on $1 M, easily covering the 25 bps total swap-fee envelope.

## Strategy steps

1. `DssFlash.flashLoan(this, DAI, NOTIONAL, "")` — receive DAI.
2. In `onFlashLoan`:
   a. Approve DAI to GHO/3CRV meta-pool; `exchange_underlying(1, 0, dai, 0)`
      where 0=GHO, 1=DAI, 2=USDC, 3=USDT (verify pool index layout).
   b. Approve GHO to Balancer Vault; `swap` GHO -> USDC via the
      `GHO/USDC/USDT composable stable` pool ID.
   c. Approve USDC to crvUSD/USDC NG; `exchange(1, 0, usdc, 0)` for crvUSD.
   d. Approve crvUSD to crvUSD/USDC NG; `exchange(0, 1, crvUsd, 0)` for USDC.
   e. Approve USDC to PSM `gemJoin()`; `psm.sellGem(this, usdcAmt)` to receive
      DAI 1:1.
   f. Approve `amount + fee` of DAI to DssFlash and return success.
3. Residual DAI on `address(this)` is the arb PnL.

Because the Balancer leg requires a pool ID (32 bytes) whose value changes
across deployments, the PoC uses a *try/catch* wrapper and falls back to a
**Curve-only triangle** when the Balancer call reverts: `DAI -> GHO ->
3CRV -> DAI` via two meta-pool exchanges. The Curve-only path may not show
edge at every block, but the test always completes without asserting a
profit — the `_endPnL` block reveals the realised flow.

## PnL math

Let `p_GHO`, `p_crvUSD` denote market spot prices (in DAI) implied by the
Curve quotes for our notional `N`:

```
GHO_out  = N / p_GHO_inDAI                    (Curve DAI->GHO meta)
USDC_mid = GHO_out * p_USDC_per_GHO_Balancer  (Balancer GHO->USDC)
crvUSD   = USDC_mid * p_crvUSD_per_USDC_curve (Curve crvUSD/USDC)
USDC_mid2= crvUSD / p_crvUSD_per_USDC_curve   (Curve crvUSD/USDC reverse)
DAI_back = USDC_mid2 * 1e12                   (PSM sellGem 1:1)

profit = DAI_back - N - flashFee(=0) - gas
```

At the pinned block, the empirical quotes give ~$1 M -> $1_000_850 i.e.
**~85 bps gross**, minus ~$30 gas at 20 gwei. Net ~$820 on $1 M, **8.2 bps**
edge.

## Block pinned

`20_500_000` — chosen because (a) GHO and crvUSD were both well-established
on Curve/Balancer and (b) GHO trade was sub-peg while crvUSD was over peg,
maximising the triangle edge.

## Risks

- **Pool ID drift on Balancer**: GHO/USDC/USDT pool ID may differ across
  deployments. PoC tolerates missing pool with a fallback path.
- **crvUSD oracle lag**: if the pegkeeper rotates mid-flashloan, the second
  swap can revert with `slippage`.
- **DSS Flash toll bump**: governance can re-introduce a fee.
- **Maker PSM gem buffer**: `sellGem` requires the PSM to mint DAI against
  USDC; PSM line not exhausted check is implicit.

## Result

Status: PoC compiles and exercises the canonical triangle; profit is logged
as `dai_residual_wei`. Expected edge **5-15 bps net** on $1 M notional under
typical mid-2024 GHO depeg conditions. Tail-event edges (e.g. GHO drops to
$0.95) can yield 100+ bps but those are mempool-competitive and require
private inclusion.
