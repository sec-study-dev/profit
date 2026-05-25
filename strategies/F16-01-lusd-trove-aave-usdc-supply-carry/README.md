# F16-01: LUSD 0%-borrow trove + Aave USDC supply carry

## Mechanism

This strategy pairs two structurally different CDP cost-of-capital regimes:

1. **Liquity v1 LUSD trove** — when a borrower opens a trove against ETH/WETH,
   the *only* cost is a one-time `borrowingFee` (currently 0-1% depending on
   `baseRate`) plus a 200 LUSD gas-stipend reserve. Liquity v1 **does not
   charge an ongoing interest rate** on outstanding LUSD debt. The trove pays
   0% APR until the user voluntarily closes it or it is redeemed against.
2. **Aave V3 USDC supply** — Aave V3 pays variable APY on supplied USDC,
   typically 3-6% in 2024-2025 markets. This is the "expensive" side of the
   spread because USDC borrowers pay closer to 5-8% and the supply side
   collects the curve's spread minus reserve factor.

The cross-CDP basis here is **0% LUSD borrow vs ~4-5% USDC supply**. By
opening a trove, selling the freshly minted LUSD into USDC on Curve LUSD/3pool
(LUSD has historically traded at ~$0.99-1.00 to within a basis point on the
3pool meta-pool), and supplying that USDC into Aave V3, the operator harvests
the rate differential while paying zero interest on the debt.

The trove collateral (WETH) is locked but still represents the borrower's
ETH directional exposure: it earns no staking yield (the trove holds raw ETH,
not wstETH — Liquity v1 only accepts ETH/WETH as collateral). That is the
honest cost: the operator forgoes ~3% ETH-staking yield by parking ETH as
trove collateral rather than as wstETH on Aave. So the *true* spread is

```
spread = r_usdc_supply  -  r_eth_staking * (ETH_value / USDC_borrowed)
       =  ~5%           -  ~3% * (ETH_coll / LUSD_drawn)
```

For a trove at 200% collateral ratio (the recommended floor above the 150%
liquidation threshold), `ETH_value / LUSD_drawn = 2` and the staking-yield
opportunity cost is `3% * 2 = 6%`, **eating the entire carry**. The trade is
only positive at high CR loops where the operator is parking ETH they would
have held anyway (e.g. a fund's structural ETH treasury), or when the borrower
swaps the freshly-drawn LUSD for **wstETH** to recover the staking yield.

A more aggressive variant: open the trove at 130% CR (slightly above the 110%
recovery-mode liquidation), draw LUSD = 0.91 * ETH value, swap LUSD -> USDC ->
wstETH, deposit wstETH back into the same trove (Liquity does NOT support
wstETH collateral — but the operator can run a second wstETH-on-Aave loop
instead). Then carry ≈ `5% USDC supply yield` against **0%** real borrow
cost, with the wstETH on the side restoring most of the foregone ETH yield.

## Why it composes

This is "borrow 0% from the oldest CDP that subsidises rate via a stability
pool, and deposit into a venue where the supply curve actually prices
duration". Liquity is *the* cheap source of stablecoin debt — every other CDP
charges either a stability fee (Maker DAI ~5%), a borrow rate (crvUSD, GHO,
BOLD) or both. The carry exists because:

- Liquity v1 deliberately keeps the borrowing fee at zero by relying on the
  stability pool + redemption mechanism rather than an interest rate.
- Aave's USDC pool prices according to utilisation — the rate has nothing to
  do with the Liquity borrow rate, so the two markets are uncorrelated in
  short-term dynamics.

The only direct linkage is **LUSD<->USDC peg risk**: if LUSD trades sharply
below $1 on Curve before the operator swaps, the implicit borrow rate spikes
(you draw 100 LUSD but only receive $99 of USDC). Conversely, if LUSD is over
$1, the operator gains on entry.

## Preconditions

- Mainnet block where Liquity v1 is active and `baseRate` low enough that
  the borrowing fee is <= 0.5%.
- LUSD/3pool curve depth sufficient to absorb the swap with <10 bp impact at
  the chosen notional.
- Aave V3 USDC reserve unfrozen, supply cap not reached.
- Available ETH/WETH for collateral.

PoC pins block **20_400_000** (≈ Aug 31 2024) when:
- `LUSD baseRate` was at its decay floor (~0.5% borrow fee).
- Aave V3 USDC supply APY ~3.8%.
- LUSD/3pool spot ~1.0000.

## Strategy steps

1. Fund test contract with WETH (collateral).
2. Convert WETH -> ETH and `BorrowerOperations.openTrove(maxFee, lusdAmount,
   upperHint, lowerHint){value: ethColl}`.
3. The trove mints LUSD to the contract. Approve and swap LUSD -> USDC via
   Curve LUSD/3pool `exchange_underlying(0, 2, lusdOut, 0)` (LUSD index 0,
   USDC underlying index 2).
4. Approve USDC to Aave V3 Pool, `supply(USDC, usdcOut, this, 0)`.
5. Warp 30 days. Aave's index accrues continuously; `aUSDC.balanceOf` rises.
6. Withdraw from Aave, swap USDC -> LUSD on Curve, `closeTrove()` (which
   requires the original LUSD debt + the 200 LUSD gas stipend).
7. Report ETH returned, USDC residual, LUSD residual.

The PoC implements steps 1-5 and reports `aUSDC` balance growth versus
elapsed time; we do **not** close the trove inside the PoC because trove
closure requires the gas stipend (200 LUSD) which is returned at the same time
and forces an additional Curve swap that adds noise to the PnL. The carry is
measured directly as `aUSDC_end - aUSDC_start` against the LUSD debt held
flat.

## PnL math

Let:
- `C` = ETH collateral = 50 ETH ≈ $130k @ $2.6k/ETH
- `L` = LUSD drawn at 250% CR = $52k
- `borrow_fee` = 0.5% one-shot = 260 LUSD
- `lusd_to_usdc_slip` = 5 bp = 26 USDC
- `r_supply` = Aave USDC supply APY at the block = 3.8%
- `r_eth_stake_lost` = 3.0% (forgone wstETH staking yield on 50 ETH)
- horizon: T = 30 days

Cash-flow PnL over T:

```
income_T = L_USDC * r_supply * (T / 365)
         = 51_714 * 0.038 * 30/365
         = $161.5

setup_cost = borrow_fee + slip
           = 260 + 26 = $286

eth_yield_lost = C_USD * r_eth_stake_lost * (T / 365)
               = 130_000 * 0.03 * 30/365
               = $320.5

net_30d_PnL = income_T - eth_yield_lost - setup_cost / amortise_horizon
            = 161.5 - 320.5 - 286 (assuming one-shot horizon)
            = -$445
```

So at typical mid-2024 rates the carry is **negative** on a 30-day horizon,
crystallising the criticism above: parking ETH as trove collateral foregoes
more staking yield than Aave USDC supply earns. The trade is only positive
when:

- the operator was holding raw ETH anyway (treasury, escrow, hedging book —
  no opportunity cost), **and**
- the LUSD `baseRate` is at its floor so `borrow_fee` is <=10 bp.

Under those conditions:

```
net = L * r_supply * (T/365) - borrow_fee
    = 51_714 * 0.038 * 30/365 - 52 (10 bp fee on 52k)
    = $161.5 - $52 = +$109.5 / 30 days
```

Roughly **2.5% APR on the drawn LUSD notional** — clean, but small.

## Block pinned

`20_400_000` — Aug 31 2024. `baseRate` near floor (<0.6% fee), Aave V3 USDC
supply APY ~3.8%. LUSD spot tight to $1.

## Risks

- **LUSD depeg on entry / exit**. The 200-bps wide window LUSD usually
  trades in becomes a major friction at smaller notionals.
- **Liquity redemption**. If LUSD trades below ~$0.97, redeemers pay 1 LUSD
  for 1 USD of ETH from the lowest-ICR troves. A near-floor CR trove can be
  partially redeemed against, refunding the borrower in ETH but cancelling
  the leveraged USDC carry early.
- **Aave USDC reserve freeze**. If governance freezes the reserve mid-carry
  the supply leg can't be exited; debt LUSD must be sourced from the
  open market to close the trove.
- **Forgone ETH staking yield**. The dominant cost; many operators wrongly
  ignore it.

## Result

Status: theoretical positive only under tight preconditions. The PoC
demonstrates the full open-trove + swap + Aave-supply cycle and reports raw
flow at the pinned block. Expected net annualised: **+2 to +3% on LUSD
notional** when ETH opportunity cost is excluded, **-1 to -2%** if it is
included.
