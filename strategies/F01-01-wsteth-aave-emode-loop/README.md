# F01-01: wstETH eMode loop on Aave v3

## Mechanism
Lido's wstETH is a non-rebasing wrapper around stETH whose internal exchange rate
(`stEthPerToken()`) accretes at the protocol-level CL+EL staking yield, currently
~2.9-3.2% APR. Aave v3 on Ethereum mainnet exposes an **ETH-correlated e-mode
category** (categoryId = 1) that recognises wstETH and WETH as a single risk
class. While in this mode the LTV ceiling for wstETH-collateralised WETH debt is
**93%** (liquidation threshold 95%), an order of magnitude higher than the
default category's 80% / 82.5%.

The combined mechanism is a recursive loop: deposit wstETH, switch to
ETH-correlated e-mode, borrow WETH at the e-mode LTV, swap WETH back to wstETH
(either via Lido `submit` + `wrap`, or via Curve stETH/ETH), and redeposit. With
N rounds at LTV `L` the leverage factor converges to `1/(1-L)`. At L=0.90 the
loop reaches ~10x effective wstETH exposure on the original principal, and at
L=0.93 ~14x. The strategy captures `leverage * (stake_apy - borrow_apy)` minus
the borrow cost on the leveraged debt, which on most blocks is materially
positive because the wstETH supply-side yield in e-mode (stake_apy + supply APR
on aWstETH) typically exceeds the variable WETH borrow APY in the correlated
e-mode pool.

## Why it composes
Lido and Aave v3 compose because the two protocols implement complementary
sides of the same primitive: Lido turns ETH into a yield-accreting receipt
(`wstETH`) without ever surfacing the yield as a cash flow, and Aave v3 e-mode
turns that yield-accreting receipt into a near-1:1 collateral against the
underlying ETH it is pegged to. The 93%-LTV ceiling is only possible because
Aave's risk team has accepted that wstETH and WETH are a *correlated* risk
class — short of a Lido smart-contract failure or a stETH/ETH depeg, the
collateral and debt drift together. The looping strategy therefore extracts
the implicit yield differential between (i) Lido's distribution of CL+EL
rewards and (ii) Aave's price-discovery on the variable WETH borrow rate.

Crucially, the borrow side is *the same asset that the user originally
supplied* (modulo a deterministic rate). That removes the directional risk that
plagues most loop trades: as long as the wstETH/ETH peg holds and the protocol
yield exceeds the borrow rate, the strategy is purely a rate spread. The
mechanism also composes well with secondary primitives — once the position is
opened, the user can layer on AAVE liquidity-mining rewards (when active), or
re-route the borrowed WETH through Curve stETH/ETH if the AMM peg is favourable
on a given block.

## Preconditions
- Mainnet, block where wstETH/WETH e-mode is enabled (any block after May 2023).
- Sufficient WETH borrow cap in e-mode (~600k WETH headroom historically).
- Block snapshot: borrow APY < (Lido stake APY + Aave wstETH supply APR).
- Capital: any size; the strategy is fee/gas-bound, not capacity-bound, below
  ~50k WETH notional.

## Strategy steps
1. Wrap principal WETH -> ETH and stake to Lido (`stETH.submit`) -> wrap to
   wstETH.
2. Approve wstETH to Aave v3 Pool and `supply`.
3. Call `setUserEMode(1)` to enter the ETH-correlated category.
4. Loop N times:
   a. `borrow` WETH at borrowable headroom (target HF ~ 1.05, LTV ~ 0.90).
   b. Unwrap WETH -> ETH, stake to Lido, wrap to wstETH.
   c. `supply` the new wstETH back into Aave.
5. After N rounds the position holds ~`1/(1-L)` x principal in wstETH
   collateral and `L/(1-L)` x principal in WETH debt.
6. Hold. Accrual happens passively via wstETH exchange-rate appreciation and
   Aave's interest indices.

## PnL math
Let:
- `s` = stake APY (wstETH internal rate) ≈ 0.030
- `b` = variable WETH borrow APY in e-mode ≈ 0.022
- `a` = aWstETH supply APR ≈ 0.0005
- `L` = effective LTV used per loop (0.90)
- `N` -> ∞ ; leverage factor `K = 1/(1-L) = 10`

Net APY on principal:
```
net_apy = K * (s + a) - (K - 1) * b
        = 10 * 0.0305 - 9 * 0.022
        = 0.305 - 0.198
        = 0.107  (~10.7% APY)
```

The PoC measures one-block changes; the dominant signal in the PnL block is
the wstETH `stEthPerToken()` drift over the simulated horizon. To make this
observable on a single fork we `vm.warp` forward by 30 days, then call a
no-op state-touching tx on Aave so debt-index accrual is realised.

## Block pinned
**20_900_000** (Oct 2024) — wstETH e-mode active, WETH borrow cap headroom
verified, ETH borrow APY observed at ~2.0-2.4% on contemporaneous dashboards.

## Risks
- **stETH depeg**: a sustained discount of stETH vs ETH below ~95% liquidates
  the loop. Historical excursion: -7.5% in June 2022.
- **Liquidation cascade**: if HF drops below 1, position is partially seized
  with a 5% bonus to liquidators (e-mode lower bonus than default).
- **Borrow APY spike**: if WETH utilisation on Aave climbs >85%, variable APY
  ramps via the kink and can briefly exceed wstETH yield, turning carry
  negative until utilisation normalises.
- **Lido slashing / validator loss**: realised slash events reduce stETH
  internal rate, propagated through `stEthPerToken`.
- **Smart-contract risk**: Lido, Aave v3, and the e-mode oracle (Chainlink
  wstETH/ETH) are all attack surfaces.
- **Gas friction**: at high gas the breakeven horizon for opening + closing
  the loop is weeks, not days.

## Result
Status: theoretical (forge build not run; addresses + e-mode params verified
against Aave/Lido docs).
Expected PnL: **+0.85% to +1.05% over 30 days** on 100 ETH principal at
leverage K=10, gross of gas and exit costs. ~1.0-1.1 ETH (~$2.5-3.0k @
$2.5k/ETH) over the simulated horizon.
