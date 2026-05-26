# F08-01: sUSDe leveraged supply on Morpho with USDC debt (loop)

## Mechanism

Ethena's USDe is a synthetic dollar collateralised on-chain by ETH + a
delta-neutral perp short executed via off-exchange custody. Funding-rate
income from the perp leg (positive when the perp basis is in contango,
which is the historical norm) accrues to the protocol; **sUSDe** is an
ERC-4626 receipt that distributes that funding stream to stakers by
inflating its `convertToAssets()` ratio over time. Realised funding-rate
APY ranges from ~5% in low-funding regimes to >40% during ETH bull
mark-ups; the 90-day trailing yield through May 2024 was ~17-22%.

sUSDe is treated as a *yield-bearing stable collateral* by Morpho Blue
isolated markets. The MEV-Capital and Gauntlet-curated `sUSDe / USDC`
markets at 86%–91.5% LLTV let a sUSDe holder borrow USDC at the Morpho
adaptive-curve IRM rate (typically 7-12% APY). When `sUSDe_yield >
USDC_borrow_APY`, looping the position multiplies the spread.

Loop construction:

```
supply S0 sUSDe -> borrow B0 = LLTV * S0 USDC -> swap USDC -> USDe on
Curve USDe/USDC pool -> stake USDe -> sUSDe -> supply -> ...
```

With per-loop LTV `L` and N rounds, total collateral converges to
`S0 / (1 - L)` and total debt to `S0 * L / (1 - L)`. The PoC uses
`L = 0.88` (88%, leaving a ~3.5% buffer below the 91.5% LLTV).

### Why we do *not* call EthenaMinting directly

The canonical EthenaMinting v2 contract lives at
`0xE3490297a08d6fC8Da46Edb7B6142E4F461b62D3` (verified via Etherscan
tags + Ethena docs) — note the central constants file
`Mainnet.ETHENA_MINTING` was historically a placeholder pointing at the
sUSDe vault and so this strategy inlines the v2 address locally
(`LOCAL_ETHENA_MINTING_V2`). The real EthenaMinting contract gates
mint/redeem on an EIP-712 signed RFQ workflow co-signed by an Ethena
whitelisted market maker, which cannot be replayed in a forge fork. So
we acquire fresh USDe from **Curve USDe/USDC stableswap** (the
canonical secondary venue, ~$200M TVL in mid-2024). At a peg of
$1.0000 ± 5 bps the swap is functionally equivalent to a mint with a
few-bp Curve fee. F08-09 implements the structural Ethena-mint arb
that does call into EthenaMinting (with a simulated signature path).

## Why it composes

Three protocol primitives stack precisely:

1. **Ethena sUSDe (4626 carry token)** — payee of perp funding, no
   liquidation risk on the underlying because the position is funded by
   on-exchange counterparties, not via on-chain debt.
2. **Morpho Blue isolated market** — purpose-built for stable-stable
   collateral pairs, with adaptive-curve IRM that lets utilisation
   self-stabilise without permissioned rate-setter intervention. The
   isolated market ensures sUSDe risk doesn't bleed into broader
   liquidity pools.
3. **Curve USDe/USDC** — the deepest secondary market for USDe at the
   fork block. Provides the "mint surrogate" leg and is the only on-fork
   path to acquire USDe without an off-chain signature.

The loop is delta-neutral on the USDe peg: collateral and debt are both
~$1 stables, so the only directional risk is sUSDe NAV vs USDe (which
only ratchets upward in absence of a clawback event — see Risks).

## Preconditions

- Mainnet fork at a block where the sUSDe/USDC Morpho market exists with
  meaningful supply liquidity and a USDC borrow APY < the trailing sUSDe
  APY. Block `19_800_000` (May 2024) satisfies both.
- Curve USDe/USDC pool has > $50M depth so a 1M USDC swap is < 5 bps slippage.
- `LLTV_915 = 0.915e18` market is live; if oracle/IRM addresses changed,
  override the `_market` struct in `setUp`.

## Strategy steps

1. Receive `EQUITY_USDE = 1_000_000e18` USDe via `deal()`.
2. `sUSDe.deposit(EQUITY_USDE, this)` to obtain `S0` shares.
3. `Morpho.supplyCollateral(sUSDe, S0)`.
4. Loop 4 times:
   - Compute borrowable USDC = `collateral_NAV * 0.88 - existing_debt`.
   - `Morpho.borrow(USDC, borrowAmt)`.
   - `Curve.exchange(USDC->USDe, borrowAmt, minOut=99.5%)`.
   - `sUSDe.deposit(usdeOut)` -> new shares `Si`.
   - `Morpho.supplyCollateral(sUSDe, Si)`.
5. Warp 30 days; `accrueInterest` to crystallise Morpho debt growth and
   surface the sUSDe NAV via `convertToAssets()`.
6. Read `position` + `market` from Morpho; log `equity = collateralNAV - debt`.

## PnL math

Let:
- `y_s` = sUSDe trailing APY ≈ 0.18 (May 2024 era)
- `y_b` = Morpho USDC borrow APY ≈ 0.095
- `L` = 0.88 (per-loop LTV)
- `K` = `1 / (1 - L) = 8.33` (limit leverage)
- `N = 4` loops -> realised leverage ≈ `(1 - L^N) / (1 - L) ≈ 4.83`

Net APY on the initial 1M USDe equity:

```
net_apy = K * y_s - (K - 1) * y_b
        ≈ 4.83 * 0.18 - 3.83 * 0.095
        ≈ 0.869 - 0.364
        ≈ 0.505    (~50.5% APY on equity)
```

Over the 30-day horizon simulated: `net_30d ≈ 50.5% * 30/365 ≈ 4.15%`,
or ~$41.5k of equity gain on the $1M initial position, gross of:

- Curve swap fees: 4 swaps × ~4 bps × ~$880k cumulative notional ≈ $1.4k
- Morpho borrow accrual (already netted above)
- Gas: ~600k gas × 20 gwei × $2.5k/ETH = $30

The dominant variable is `y_s`. If funding flips negative for a
sustained period, `y_s` collapses or even goes negative and the loop
becomes loss-making — see Risks.

## Block pinned

**19_800_000** (~May 13 2024). Verifications:
- Morpho sUSDe/USDC 91.5% LLTV market live (created Apr 2024).
- Curve USDe/USDC pool TVL > $200M, peg within 3 bps.
- sUSDe trailing 30d APY ≈ 17.5% per Ethena dashboard.
- Morpho USDC borrow utilisation ~85% → borrow APY ≈ 9-10%.

## Risks

- **Funding-rate flip**: extended negative perp funding (ETH bear,
  high carry-trade unwind) can take sUSDe APY below the borrow rate.
  The loop's PnL goes from `+50%` to `-N%` in that regime; passive
  unwind costs ≈ 4 × Curve fee.
- **USDe depeg**: a discount drives Morpho oracle to mark collateral
  below par, triggering liquidations at 91.5% LLTV. Historical USDe
  excursions have been < 30 bps; LLTV buffer is sized for that.
- **Custody / off-exchange settlement (OES) failure**: Ethena uses
  Copper/Ceffu/Cobo for the perp short collateral. A custodian failure
  or partial loss of margin reduces USDe backing.
- **Morpho borrow rate spike**: if USDC borrow utilisation pins at the
  kink, IRM ramps the rate ~3x. Sustained spike turns carry negative.
- **Cooldown timer**: sUSDe has a **7-day cooldown** on unstake; an
  emergency exit must instead sell sUSDe on a secondary AMM (Curve
  sUSDe/USDe or Pendle SY market) which can incur 1-3% slippage.
- **Curve pool drain**: a depeg event that drains USDe out of the USDC
  pool reduces the cheap-mint surrogate; subsequent loops would have
  to fall back to the USDe/USDT or USDe/DAI/sDAI/FRAX pool.
- **Smart-contract risk**: Ethena vaults, Morpho singleton, Curve
  factory pool. Each is a separate audit surface.

## Result

Status: theoretical (forge build not run; oracle and market id from
Morpho subgraph at the fork block — verify before going live).

Expected PnL: **~+4.1% over 30 days** on $1M USDe equity at ~4.83x
realised leverage. Equity-USD gain ~$41.5k gross of ~$1.5k swap fees
and ~$30 gas. Net ~$40k.
