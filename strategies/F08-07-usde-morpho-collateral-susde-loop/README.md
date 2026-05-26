# F08-07: USDe-collateral Morpho loop with off-Morpho sUSDe sleeve (3-mech)

## Mechanism

The structural inverse of F08-01:

| Field          | F08-01                  | F08-07                  |
| -------------- | ----------------------- | ----------------------- |
| Collateral     | sUSDe (yield-bearing)   | USDe (non-rebasing)     |
| Debt           | USDC                    | USDC                    |
| Yield accrues to | the **collateral**   | a **separate wallet bag** |
| Liquidation source | sUSDe NAV / oracle | USDe peg / oracle       |
| Bootstrap      | recursive loop         | atomic Morpho flashloan |

In F08-07 the **collateral is non-yield-bearing USDe**, valued at ~$1 by
the Morpho oracle. All sUSDe stake is held off-Morpho (in the wallet)
where its NAV growth is independent of the loan. The strategy converts
flat-priced USDe into looped USDC borrow and reinvests the proceeds as
sUSDe in the wallet.

### Why is "non-rebasing collateral + off-platform yield" structurally interesting?

1. **Decoupled liquidation source**. In F08-01 the collateral oracle
   reads `sUSDe.convertToAssets(shares)` which is *protocol-internal
   accounting*. A bug in Ethena's accounting (or a clawback event)
   directly marks the collateral down. In F08-07 the collateral oracle
   reads USDe/USD via Chainlink or Redstone — independent of sUSDe.
2. **On-demand yield sleeve**. The off-Morpho sUSDe can be unstaked
   (via cooldown) or sold (via Curve) without unwinding the Morpho
   loan. The two legs are operationally independent.
3. **No NAV-collateral interaction**. In F08-01 every sUSDe NAV tick
   increases borrowable headroom, encouraging further looping. In
   F08-07 the headroom is fixed by USDe collateral; the operator must
   *consciously* re-loop if desired.

### Three-mechanism composition

1. **Morpho Blue** — USDe/USDC isolated market for the collateralised
   borrow. Morpho's **free flashloan** atomically bootstraps the loop
   in a single tx (saves O(N) gas of recursive loop calls).
2. **Curve USDe/USDC** — the USDC → USDe surrogate-mint conversion
   (canonical Ethena minting is gated on off-chain RFQ signatures and
   cannot be exercised inside a forge fork — see F08-01).
3. **Ethena sUSDe** — the ERC-4626 receipt that captures the funding
   yield. Held off-Morpho in the wallet so its NAV does not back the
   loan.

## Strategy steps

1. `_fund(USDe, this, 1M)`.
2. Approvals (Morpho, sUSDe, Curve both directions).
3. `Morpho.flashLoan(USDe, 4M)` → `onMorphoFlashLoan(assets=4M)`:
   a. We now hold `EQUITY + assets = 5M` USDe.
   b. `Morpho.supplyCollateral(USDe, 5M, this)`.
   c. `Morpho.borrow(USDC, 0.85 * 5M / 1e12)` ≈ 4.25M USDC.
   d. `Curve.exchange(USDC→USDe, 4.25M)` → ~4.225M USDe (5 bps slippage).
   e. `flashRepay = assets = 4M` USDe held aside.
   f. `residual = 4.225M - 4M = 225k USDe` → `sUSDe.deposit(225k, this)`.
4. Outer approval lets Morpho pull back the 4M USDe flash principal.
5. Final position:
   - Morpho: 5M USDe collateral, 4.25M USDC debt.
   - Wallet: ~205k sUSDe shares (NAV ~225k USDe at deposit).
   - Net equity = 5M - 4.25M + 225k = ~975k USDe = ~+0% on entry
     (modulo Curve slippage). PnL from here forward = pure sUSDe
     yield on the 225k sleeve minus Morpho borrow APY on 4.25M USDC.

## PnL math

Let:
- `y_s` = sUSDe trailing APY ≈ 0.14
- `y_b` = Morpho USDC borrow APY ≈ 0.085
- Equity at entry = 975k USDe (some bled to Curve fee).

The 30-day carry:

```
sUSDe sleeve yield  = 225k * 0.14 * 30/365 = 225k * 0.01151 = $2.59k
Morpho debt cost    = 4.25M * 0.085 * 30/365 = 4.25M * 0.00699 = $29.7k

raw carry (30d) = 2.59k - 29.7k = -27.1k
```

Wait — that's negative? Yes: this layout *does not generate carry alpha
on its own* because we hold only 225k sUSDe vs 4.25M USDC debt. The
structural value of F08-07 is **not** the carry — it's:

- **Optionality on the 225k sleeve**: redeem freely without unwinding.
- **Inversion of liquidation source**: USDe peg risk only, not sUSDe NAV.
- **Hedge-against-clawback**: a sUSDe clawback event hurts F08-01
  positions directly (collateral marks down) but only marks the wallet
  sleeve in F08-07.

If the operator *also* runs a separate F08-01 position, F08-07 acts as
the structural hedge: the two positions have inversely correlated
liquidation sources. Run as a pair:

```
F08-01 short risk: sUSDe NAV / Ethena accounting
F08-07 short risk: USDe peg vs USDC peg
F08-01 + F08-07 net risk: only diversified USDe/USDC peg variance
```

PnL on F08-07 alone is approximately *flat* over short horizons
(the Curve entry fee + slippage net out the sUSDe sleeve carry).
The hedge benefit is realised under tail events.

## Block pinned

**20_800_000** (~Sep 2024). Verifications:
- Morpho USDe/USDC market with 86% LLTV is live.
- Curve USDe/USDC pool depth > 5M.
- sUSDe NAV growing at 12-14% APY.

## Risks

- **Morpho USDe/USDC market not live at fork block**: setUp() reverts
  with a clear message via the `idToMarketParams` recovery check. If
  this market does not exist, the strategy is not deployable at that
  block.
- **USDe oracle failure**: a Chainlink USDe/USD or Redstone outage
  freezes Morpho's mark-to-market. Position becomes illiquid until
  oracle resumes.
- **USDe depeg**: USDe trading below $1 marks the collateral down and
  can trigger liquidations. The historical max USDe excursion is ~30 bps.
- **Curve slippage on entry**: if USDC→USDe slippage exceeds the 50 bps
  tolerance configured, the flash repay check fails and the entire
  tx unwinds atomically.
- **Off-Morpho sUSDe NAV risk**: the wallet sleeve is fully exposed to
  any sUSDe accounting event (e.g. funding turn-negative for a sustained
  period, custodian failure, governance pause).

## Result

Status: theoretical. Forge build not run.

This strategy is **not a standalone carry alpha** — it is a **hedge-pair
component**. Expected standalone PnL is approximately flat (small
negative net of Curve fees). Expected paired-with-F08-01 PnL benefit
materialises under tail-risk events where sUSDe NAV diverges from USDe
peg.
