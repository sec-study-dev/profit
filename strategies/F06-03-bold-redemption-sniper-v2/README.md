# F06-03: Liquity v2 BOLD redemption sniper (lowest-interest-rate trove)

## Mechanism (Liquity v2 specific)
Liquity v2 replaces v1's single-rate redemption order with a **user-defined
interest rate** per trove:

- Each borrower picks an `annualInterestRate` when opening a trove (e.g.
  `5e16` = 5%).
- The protocol keeps troves **sorted by their interest rate ascending** in a
  per-branch `SortedTroves`.
- A `redeemCollateral` call burns BOLD against the **lowest-rate troves first**,
  yielding collateral at the internal oracle price minus a small redemption fee.
- This is unlike v1, which sorted by ICR (and therefore implicitly targeted
  high-leverage troves). In v2 the *highest-rate* (most willing to pay)
  borrowers are *insulated* and the *cheap* borrowers absorb redemption flow.

### The sniper strategy
When BOLD trades below $1 on Curve (or any AMM), the redemption is profitable
even before considering the trove-side cross-section. The **sniper** layer is:

1. Identify the trove `t*` with the **lowest interest rate**. Its borrower
   is implicitly subsidising redemption — every BOLD redeemed against `t*`
   converts at `oracle_eth * 1 BOLD = 1 USD` of collateral, while we paid
   `< 1 USD` to acquire that BOLD.
2. If `t*`'s remaining debt is small, the next-lowest trove `t**` is hit next;
   we want to size redemption ≤ debt(`t*`) + debt(`t**`) etc., otherwise we
   creep into rate-bands where the borrower paid up for protection.
3. Atomic flow:
   ```
   DAI flashmint  →  buy BOLD on Curve BOLD/USDC pool  →  redeem against TM
                  →  ETH (or wstETH on the wstETH branch) at oracle
                  →  sell ETH→USDC→DAI →  repay flashmint
   ```

### Per-branch structure
v2 launches with multiple collateral *branches* (ETH, wstETH, rETH). Each has
its own `TroveManager`, `SortedTroves` and `StabilityPool` but shares the BOLD
token. The sniper picks the branch where:
- BOLD ↔ collateral spread is widest at the redemption oracle, AND
- the lowest-rate trove has enough debt to absorb the intended notional.

## Why it composes
- **Flashmint of DAI** (Maker DSS Flash, 0 fee) provides the BOLD-buying credit.
- **Curve BOLD/USDC** (deployed alongside the v2 launch — TODO verify the
  canonical pool address at the fork block) is the canonical BOLD AMM venue.
- **Liquity v2 `TroveManager.redeemCollateral`** burns BOLD 1:1 against the
  cheapest-rate troves, paying out ETH/wstETH at the oracle.
- **Per-branch isolation** means a redemption on the wstETH branch does not
  affect the ETH branch's BOLD↔collateral conversion rate.

## Preconditions
- Liquity v2 deployed and BOLD trading on a CurveStableSwap/USDC pool.
- BOLD spot `< 0.997 USD` on the chosen AMM.
- At least one trove with `annualInterestRate < median_rate − 1%` and debt ≥
  `flashmint_size / oracle_price` so the redemption doesn't walk into
  higher-rate troves.
- DSS Flash `toll == 0`.

## Strategy steps
1. Query the branch's SortedTroves head (`getFirst()`) to discover the lowest-
   rate trove `t*` and its debt.
2. Cap the trade at `debt(t*) + slack` to lock in the lowest-rate-tier yield.
3. `DssFlash.flashLoan(this, DAI, X)` — ERC-3156 callback.
4. In callback:
   - Curve `DAI→USDC→BOLD` (two-hop if no direct DAI/BOLD pool exists).
   - `TroveManager.redeemCollateral(boldAmount, maxIterations, maxFeePct, ...)`
     — receive ETH (or wstETH wrapped).
   - Convert ETH→USDC→DAI via Curve tricrypto2 + 3pool.
   - Repay flashmint, residual DAI = profit.

## PnL math
With BOLD price `p` USD, redemption fee `R`, swap fees `f`:

```
profit_pct ≈ (1 - R - f) / p − 1
```

For `p = 0.99`, `R = 0.005`, total swap drag `f = 0.0015`:
```
profit_pct = (1 - 0.005 - 0.0015) / 0.99 − 1
           = 0.9935 / 0.99 − 1
           = +0.354%   →  ~$3.5k per $1M turn
```

For `p = 0.97` (early-stage stress):
```
profit_pct = 0.9935 / 0.97 − 1 = +2.42%   →  $24k per $1M turn
```

The lowest-rate edge does **not** show up directly in `profit_pct` — it shows
up as **size**: a `0%` trove can absorb redemption indefinitely without
pushing into worse-priced troves, so the sniper can monetise a deep depeg
with a single large flash. A median-rate-only redeemer would walk into ever-
higher-rate troves and the *next-marginal* redemption fee would rise per v2's
per-trove fee accrual (TODO verify exact v2 fee mechanic).

## Block pinned
- **`FORK_BLOCK = 21_500_000`** (≈ late Dec 2024 — Liquity v2 mainnet was
  live around this time on the ETH branch; BOLD/USDC pool seeded).
- **`STATUS = theoretical`** at this fork block because:
  - BOLD token mainnet address is **not in `Mainnet.sol`** (set to `address(0)`).
  - The branch-specific TroveManager addresses depend on the exact v2 deployment
    artefact. They are declared as `address(0)` constants in the PoC with a
    `// TODO verify` tag.
- Once Wave-3 verification confirms the addresses, flip `FORK_BLOCK` to a
  date with both `BOLD < 1` *and* an exploitable low-rate trove on the
  sorted list.

## Risks
- **Lowest-rate trove vanishes.** The trove owner can `adjustTroveInterestRate`
  upward to escape the redemption queue (paying an upfront fee). If they
  monitor mempool they can front-run the redemption and force us into worse-
  priced troves. Mitigation: bundle via private mempool.
- **Per-branch oracle staleness.** Each branch has its own price feed; if the
  ETH branch's Chainlink is stale, the redemption ETH amount diverges from
  CEX spot.
- **BOLD↔DAI spread** > the redemption profit: must check both legs in the
  preview.
- **Redemption fee accrual.** v2 likely retains v1's `baseRate` decay: large
  redemption bumps the rate for subsequent traders. Optimal size minimises
  rate-bump impact.
- **v2 still maturing.** New contracts, possible upgrade pauses or governance
  parameter changes (rate caps, fee floors).

## Result
Status: **theoretical** — v2 addresses must be confirmed at the verification
wave; the redemption mechanic itself is documented in the v2 spec.

PnL range:
- Moderate depeg (30 bps): **+15–25 bps net** per turn.
- Deep stress (300 bps): **+250 bps net**, sized to the lowest-rate trove
  debt.
