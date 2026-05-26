# F01-03: rETH on Aave v3 eMode, one-shot via Aave flashLoanSimple

## Mechanism
Rocket Pool's rETH is a non-rebasing LST whose exchange rate
(`IRETH.getExchangeRate()`) appreciates as Rocket node operators earn
consensus + execution rewards. Net of the protocol fee, rETH historically
yields **3.0-3.4% APR**, slightly above wstETH because of a higher MEV share
flowing to the rETH/RPL minipool stack.

Aave v3 on Ethereum mainnet lists rETH and includes it in the **ETH-correlated
e-mode category (id 1)**, the same category that hosts wstETH and WETH. In
e-mode the rETH/WETH borrow LTV is **93%** with liquidation threshold 95%.
The strategy is to build a leveraged rETH-vs-WETH position whose carry
captures `K * (rETH_yield - WETH_borrow_apy)`.

To avoid the gas footprint of N sequential `borrow -> swap -> supply` loops,
the PoC uses Aave v3's own **`flashLoanSimple`** facility. It costs a 5 bp
premium (0.05% one-time), but a single call delivers `(K - 1) * principal`
WETH whose proceeds are converted to rETH (via Curve rETH/ETH for liquidity,
since the Rocket deposit pool has a small per-block cap), supplied as
collateral, and then borrowed back to repay the flash. The premium of 5 bp
amortises against the leveraged yield in well under one week.

## Why it composes
Aave's e-mode mechanic and Rocket Pool's rETH economics compose because the
rETH/ETH price feed used inside Aave (Chainlink rETH/ETH composition) is
*backed by a smart-contract rate*, not an AMM price. That means Aave's
collateral valuation tracks Rocket's internal exchange rate function
exactly, eliminating the AMM-mispricing tail risk that plagues earlier LST
collateral types. The 93% LTV ceiling is meaningful precisely because the
oracle is provably non-manipulable in a single block.

Adding the flashLoanSimple primitive on top means the strategy can switch
from a slow capital-deploy schedule (multi-tx, multi-day to amortise gas) to
a one-shot open-and-park position. That changes the strategy's economic
profile: it becomes accessible at much smaller principal because the gas
amortisation is one fixed cost rather than N variable ones, and the 5 bp
flash premium is bounded by Aave's own configuration rather than depending
on third-party flash providers. The composition is therefore Rocket Pool +
Aave money market + Aave flashloan, three modules from two protocols
reinforcing each other in a single transaction.

## Preconditions
- Mainnet block where rETH is in Aave v3 e-mode category 1 (since rETH was
  added to Aave v3 Ethereum in mid-2023).
- Curve rETH/ETH pool has enough depth that the WETH -> rETH conversion of
  size `K * principal` is within ~10 bps of NAV. At `K=10`, principal=100
  ETH, this is a 1000 ETH swap — pool depth typically holds.
- Block snapshot: rETH yield > Aave variable WETH borrow APY in e-mode.

## Strategy steps
1. Encode loop params and call `Aave.flashLoanSimple(WETH, (K-1)*P, ...)`.
2. In `executeOperation`:
   a. The pool has just sent `(K-1)*P` WETH to the strategy; combine with
      the user's `P` of principal -> `K*P` WETH on hand.
   b. Swap `K*P` WETH -> rETH on Curve rETH/ETH (pool address
      `0x0f3159811670c117c372428D4E69AC32325e4D0F`).
   c. Approve and `supply` all rETH to Aave v3.
   d. `setUserEMode(1)`.
   e. `borrow` `(K-1)*P + premium` WETH from Aave at variable rate.
   f. Approve Aave to pull back the flashloan repayment.
3. After the callback returns, position is open: `K*P` rETH collateral,
   `(K-1)*P + premium` WETH debt.
4. Park for the desired horizon; wstETH-style accrual happens via the rETH
   exchange-rate plus Aave's debt-index drift.

## PnL math
Let:
- `s` = rETH yield ≈ 0.032
- `b` = Aave variable WETH borrow APY (e-mode) ≈ 0.022
- `L` = 0.90 chosen LTV (buffer below 93% cap)
- `K = 1/(1-L) = 10`
- `f` = 0.0005 (5 bp Aave flashloan premium, one-time)

Annualised:
```
net_apy = K * s - (K-1) * b
        = 10 * 0.032 - 9 * 0.022
        = 0.320 - 0.198
        = 0.122 (~12.2% APY)

cost_one_time = (K-1) * f = 9 * 0.0005 = 0.0045 (45 bp of principal)
breakeven_days = 0.0045 / 0.122 * 365 ~= 13.5 days
```

So any holding period beyond ~14 days nets positive even after the flash
premium. Per 100 ETH over 30 days: `100 * 0.122 * 30/365 - 100 * 0.0045 ~=
1.00 - 0.45 = +0.55 ETH` gross of gas.

## Block pinned
**21_000_000** (Nov 2024) — rETH e-mode active on Aave v3, Curve rETH/ETH
pool depth healthy, rETH yield observed at ~3.1% via Rocket scan.

## Risks
- **Curve rETH/ETH discount**: if the pool prices rETH below NAV at the
  moment of the loop, the strategy converts at the discount and re-marks
  to NAV inside Aave, which is a one-off slippage drag.
- **Aave flash premium changes**: governance-controlled; 5 bp is current.
- **rETH peg / Rocket smart-contract risk**: rETH withdrawal queue is gated;
  exit liquidity in stress relies on the Curve secondary.
- **Borrow rate spike**: same as F01-01.
- **Aave debt cap**: WETH borrow cap in e-mode is enforced; large positions
  must check `availableBorrowsBase`.

## Result
Status: theoretical (rETH e-mode listing on Aave v3 verified; Curve rETH/ETH
pool address verified; PoC not run).
Expected PnL: **+0.45% to +0.65% over 30 days** on 100 ETH principal net of
flash premium, ~$1.1-1.6k @ $2.5k/ETH.
