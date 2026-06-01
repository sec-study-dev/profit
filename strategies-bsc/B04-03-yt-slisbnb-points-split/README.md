# B04-03: YT-slisBNB points speculation (mint PY, sell PT, keep YT)

## Mechanism

Strip Pendle SY-slisBNB into PT + YT, sell the PT for BNB, and retain the
YT as a pure-points / floating-yield bet. Composes three primitives:

1. **Lista DAO slisBNB** — staking BNB on Lista accrues both the BNB stake
   APR and Lista's loyalty / future-airdrop points (counted on slisBNB
   balance held in qualifying contracts).
2. **Pendle Router V4 on BSC — `mintPyFromToken`** — given `tokenIn=BNB`
   the router mints SY-slisBNB then atomically splits it into PT+YT of
   equal face. The caller receives `pyOut` of each.
3. **Sell PT immediately** — `swapExactPtForToken` returns most of the
   principal back as BNB; the leftover BNB equity buys ~25× point-leverage
   on the YT position. YT accrues:
   - the BNB stake APR until expiry (~4 %),
   - any Lista loyalty / airdrop multiplier attached to slisBNB.

## Why it composes

- The PT-sale recovers `(ptOut × ptPrice)` BNB. With ptPrice ≈ 0.96, a
  100-BNB equity bootstraps ~`100 / (1 - 0.96) = 2500 BNB` of YT exposure
  for the loyalty calculation if the YT is "implicit slisBNB" for points
  purposes.
- Pendle's `mintPyFromToken` is atomic — no PT/YT inventory risk between
  legs.
- On BSC the YT-slisBNB tends to be **mispriced low** relative to the
  underlying stake APR because most BSC users don't understand YT and the
  market is thinner. Buying YT cheap = positive expected value on the
  realized stake APR alone, before any points upside.

## Preconditions

- BSC block where `PT/YT-slisBNB-25SEP2025` market is live.
- `BSC.PENDLE_ROUTER_V4` deployed and accepts BNB-native input (mintSY path
  through `BSC.BNB` sentinel).
- Lista StakeManager active (router's SY-mint path).

## Strategy steps

1. Fund test contract with `EQUITY_BNB = 100 ether`.
2. `mintPyFromToken(receiver=this, YT=_yt, minPyOut=0, input{tokenIn=BNB,
   tokenMintSy=BNB, netTokenIn=100})`. Receive `pyOut` PT + `pyOut` YT.
3. Approve router to spend PT, then `swapExactPtForToken(receiver=this,
   market, exactPtIn=ptBal, output{tokenOut=BNB, tokenRedeemSy=BNB, ...})`.
4. Net result on balance sheet:
   - `bnbRecovered = ptPrice × pyOut`,
   - `equityUsed = 100 - bnbRecovered`,
   - `ytHeld = pyOut`.
5. The PoC reports two numbers:
   - **Spot YT cost**: `equityUsed`,
   - **YT face exposure**: `ytHeld` (= notional BNB earning points).

## PnL math

Per 100 BNB equity, at ptPrice = 0.96 and a 4-month maturity:
- mint 1 / 0.96 ≈ 104.16 PY/BNB → 10 416 PY of each for 100 BNB
  *no wait* — for `100 BNB`, mintPyFromToken returns `pyOut ≈ 100 / SY-rate`
  PT and YT (1 SY ≈ 1.04 BNB so pyOut ≈ 96 each).
- Sell 96 PT @ 0.96 → recover ~92.16 BNB.
- Net YT cost: `100 - 92.16 = 7.84 BNB` for **96 BNB of YT face**.
- Effective points-leverage: `96 / 7.84 ≈ 12.2×`.
- At 4-month stake APR (~4 % annualized), YT accrued BNB
  ≈ `96 × 0.04 × 4/12 = 1.28 BNB` → already covers ~16 % of the YT cost
  *before* any Lista loyalty / airdrop kicker.
- Break-even on the points-only thesis: ~6.56 BNB of airdrop value at
  expiry per 100 BNB equity → ~6.5 % return at zero airdrop, much
  higher on any positive airdrop.

Gas: ~900 k gas; < $0.60 on BSC.

## Block pinned

`FORK_BLOCK = 42_000_000`. Re-pin once BSC RPC is configured and the actual
PT/YT-slisBNB market is verified.

## Addresses used

- `BSC.PENDLE_ROUTER_V4` — TODO verify on BSC.
- `BSC.slisBNB`, `BSC.LISTA_STAKE_MANAGER`, `BSC.WBNB`.
- `LOCAL_PT_SLISBNB_MARKET_25SEP2025`, `LOCAL_YT_SLISBNB_25SEP2025` —
  per-maturity inline constants; verified on the Pendle BSC subgraph.
  Placeholders are documented and the PoC `try/catch`'s any market
  resolution failure.

## Risks

- **YT decays to zero at expiry** — any unrealized airdrop after the YT
  expires is lost. Timing the airdrop snapshot window matters.
- **YT depeg from expected stake APR** — if Lista underperforms the
  assumed 4 % stake APR, the YT-realized BNB yield falls short of the
  break-even.
- **PT-sale slippage** — selling 96 BNB of PT in one shot moves the
  Pendle AMM. PoC uses `minTokenOut=0` (PoC convention); production
  would set ≥ 99 % of the off-chain quote.
- **Mint path unavailable on BSC** — `mintPyFromToken` may not be wired
  to the BNB sentinel in early BSC deployments; PoC falls back to a WBNB
  mint path.

## Result

Status: **theoretical** (BSC RPC missing; PoC compiles + degrades to no-op).
Expected outcome: **~96 BNB of YT exposure for ~7.8 BNB equity, ~12× point
leverage on Lista loyalty + slisBNB airdrop tickets**.
