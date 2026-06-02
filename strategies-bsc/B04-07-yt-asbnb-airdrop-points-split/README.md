# B04-07: YT-asBNB Astherus airdrop / points speculation

## Mechanism

PY-split trade isolating Astherus restaking points and the upcoming Astherus
governance-token airdrop:

1. **Astherus asBNB** — restaked BNB whose holders accrue "asPoints"
   (snapshot-claimable) plus the eventual Astherus token TGE airdrop.
2. **Pendle PY split** — `mintPyFromToken` splits 1 asBNB-equivalent BNB
   into 1 PT-asBNB + 1 YT-asBNB. The YT carries 100 % of the underlying's
   variable yield + points for the remaining time-to-maturity.
3. Sell the PT back to BNB immediately (`swapExactPtForToken`) — recover
   ~94-96 % of equity. Net cost of the YT = `1 - PT_sell_price`.

Result: ~4-6 % of equity buys exposure to 100 % of the points / airdrop
that the FULL principal would have earned. Implied points leverage =
1 / (1 - ptPrice) ≈ 16-25x.

## Why it composes

- Astherus airdrop expected: rumored Q3-Q4 2025, snapshot likely tied to
  total point balance. Buying YT pre-snapshot front-loads exposure.
- Pendle YT-asBNB embeds the snapshot eligibility because Pendle's SY
  wraps asBNB without forfeiting yield/points rights.
- PT market on Pendle BSC has reasonable depth at major maturities; the
  PT sell impact at $60k notional is ~10 bp.

## Strategy steps

1. Fund test contract with `EQUITY_BNB = 100 ether`.
2. `mintPyFromToken(receiver=this, YT=YT-asBNB, minPyOut=0, input{tokenIn=BNB})`
   to atomically mint PT + YT.
3. `swapExactPtForToken(market=PT-asBNB-25SEP2025, exactPtIn=ptBal, output{tokenOut=BNB})`
   to recover most equity as BNB.
4. Net cost = `EQUITY_BNB - recovered_BNB`; this is the "premium" paid for
   the YT.
5. Compute points-leverage = `ytBal / netCost`.
6. (Optional) Warp to expiry and redeem residual YT interest +
   reward-token claims.
7. The Astherus token airdrop, when received, is on top of this calculation.

## PnL math

Per 100 BNB ≈ $60k equity, 3-month maturity:
- PT-asBNB entry price (sell side): ~0.955 BNB per PT
- Net YT cost: 100 − 95.5 = 4.5 BNB ≈ $2,700
- YT held: 100 (one YT per BNB minted)
- Points leverage: 100 / 4.5 ≈ **22x**
- Implied airdrop break-even: Astherus airdrop must exceed $2.7k value per
  100 BNB principal-equivalent points → very low bar if Astherus FDV > $200M.
- Downside: capped at 4.5 BNB (YT expires worthless). Upside: unbounded
  in airdrop terms.

## Block pinned

`FORK_BLOCK = 44_500_000` — mid-Q2 2025, ~3 months before assumed
25-SEP-2025 expiry.

## Addresses used

- `BSC.PENDLE_ROUTER_V4` = `0x888888888889758F76e7103c6CbF23ABbF58F946`
- `BSC.asBNB` = `0x77734e70b6E88b4d82fE632a168EDf6e700912b6`
- `LOCAL_PT_ASBNB_MARKET_25SEP2025` — placeholder; **TODO verify**.

## Risks

- **No airdrop materializes / smaller than priced**: maximum loss = YT
  cost (4.5 BNB per 100 BNB notional). The YT also accrues asBNB
  restaking yield (~2 % APR) which partially offsets.
- **Points eligibility forfeited by Pendle SY wrap**: a known Pendle YT
  caveat — verify Astherus snapshot logic accepts Pendle SY positions.
  If not, this strategy is invalidated.
- **YT illiquidity**: cannot easily sell YT mid-life if airdrop news
  changes; must hold to expiry.

## Result

Status: **theoretical** — depends on Astherus airdrop occurring. PoC
compiles + logs points-leverage metric. Expected payoff distribution:
**0 (downside, cost ~$2.7k) to +$20-50k per 100 BNB if airdrop strong**.
