# B15-01 — Lista CDP + Pendle PT-USDe + Venus collateral stack

## Family

B15 · 三协议机制堆叠 (three-protocol mechanism stack). The BSC analogue of
F18's "Pendle + lending + CDP" pattern, anchored on Lista's BSC-native CDP.

## Thesis

Three independent BSC primitives, each contributing a distinct mechanism,
composed into a single carry position:

1. **Lista lisUSD CDP** mints `lisUSD` against `slisBNB` collateral
   (slisBNB still earns its native staking yield while locked).
2. **Pendle BSC PT-USDe** — the freshly-minted lisUSD is swapped to USDe
   on PCS StableSwap, then `swapExactTokenForPt(market=PT-USDe-26JUN2025)`
   locks a fixed yield to maturity.
3. **Venus Core** — the resulting PT-USDe is supplied to Venus as
   collateral (assumed listed; if not we fall back to depositing the
   underlying USDe to `vUSDC`/`vUSDT` via canonical swap). Venus
   `borrow(USDT)` is then used to short the float, with the borrowed USDT
   sold back into lisUSD to **repay part of the CDP**, freeing more
   slisBNB headroom.

The aggregate position simultaneously earns:
- slisBNB staking accrual on the CDP collateral leg (~3.2 % APR),
- Pendle PT fixed-yield (`1 - ptEntryPrice` annualised, typically
  ~12 % on BSC),
- minus Lista's lisUSD stability fee (~2 %),
- minus Venus's USDT borrow rate (~5 %),
- plus the slisBNB-yield boost re-applied to the freed collateral.

## Why it composes — the 3 mechanisms

1. **Lista CDP `Interaction.deposit + borrow`** — only BSC CDP that takes
   slisBNB directly. The mint of lisUSD is *gas-free* of any AMM hop
   (canonical mint vs an external buy).
2. **Pendle BSC Router V4 `swapExactTokenForPt`** — only protocol on BSC
   that exposes a tradable *fixed-yield* token. lisUSD → USDe → PT-USDe
   in one router call locks the carry at entry.
3. **Venus Core `vUSDT.borrow` (collateralised by PT or USDe)** — only
   BSC money market with deep USDT cash. Borrowing USDT against the PT
   leg lets us recycle that USDT back into the CDP, *unlocking
   slisBNB collateral without selling*.

**No 2-mechanism subset works:**
- (Lista + Pendle) alone: locks fixed yield but cannot recycle the
  borrowed stable back into the CDP without a money market.
- (Lista + Venus) alone: just a CDP loop (B03/B11 territory) — no fixed
  yield, only floating slisBNB-yield exposure.
- (Pendle + Venus) alone: a cash-and-carry (B04 territory) — no CDP
  amplification, smaller balance-sheet leverage.

The triple-stack is the only construction that earns slisBNB staking,
Pendle fixed yield, **and** lets the borrowed USDT be re-injected to
unlock more CDP capacity — a true 3-mechanism flywheel.

## Preconditions

- BSC block where: slisBNB Lista vault is live (post-2024), Pendle BSC
  router is deployed at `0x8888...8946` (canonical cross-chain address —
  `TODO verify` per `BSC.sol`), Venus Core vUSDT market is open for
  borrow.
- PCS StableSwap lisUSD↔USDe pool with > 1 M depth at the fork block.
- PT-USDe-26JUN2025 market resolvable on Pendle BSC subgraph.

## Strategy steps (PoC)

1. Fund equity: `100 slisBNB` (~$60 k @ $600/BNB).
2. **Leg A (Lista CDP)**: deposit slisBNB → mint `lisUSD` at `LTV=65%`
   (conservative buffer below the 80 % liquidation threshold).
3. **Leg B (PCS StableSwap)**: swap lisUSD → USDe.
4. **Leg C (Pendle)**: `swapExactTokenForPt(market=PT-USDe-26JUN2025,
   tokenIn=USDe, ...)`.
5. **Leg D (Venus)**: supply PT-USDe (or fall back to USDe → vUSDC if PT
   not listed) and `enterMarkets`. Borrow USDT at 50 % LTV of the PT
   value.
6. **Leg E (recycle)**: swap USDT → lisUSD on PCS StableSwap and
   `IListaInteraction.payback(slisBNB, ...)` to reduce CDP debt and free
   slisBNB headroom.
7. PnL = (slisBNB staking yield × held slisBNB) + (PT fixed yield × held
   PT) − Lista stability fee − Venus borrow rate. Modelled over a
   `HOLD_DAYS = 30` projection.

## PnL math

Per 100 slisBNB ≈ $60 k notional, 30 days, 65 % CDP LTV:
- lisUSD minted: 60 k × 0.65 = 39 k.
- After swap+PT: ~38.5 k of PT-USDe (10 bp PCS slip, 10 bp Pendle entry).
- Venus borrow against PT @ 50 % LTV: 19.25 k USDT.
- Recycled into CDP → frees 19.25 k of lisUSD headroom → another 32 k
  slisBNB-equivalent borrow potential (used once for a single recycle).

30-day carry:
- slisBNB yield on 60 k: 60 000 × 0.032 × 30/365 = **+$157**
- PT yield on 38.5 k: 38 500 × 0.12 × 30/365 = **+$380**
- − Lista stability on 39 k: 39 000 × 0.02 × 30/365 = **−$64**
- − Venus USDT borrow on 19.25 k: 19 250 × 0.05 × 30/365 = **−$79**
- **Net: ≈ +$394 / 30 d on $60 k = ~8 % APR**

## Block pinned

`FORK_BLOCK = 42_500_000` (mid-Q1 2025). Re-pin once BSC RPC is wired and
the `PT-USDe-26JUN2025` market is verified live.

## Addresses used

- `BSC.slisBNB`, `BSC.LISTA_INTERACTION`, `BSC.LISTA_STAKE_MANAGER`
- `BSC.PCS_STABLE_ROUTER`, `BSC.lisUSD`, `BSC.USDe`
- `BSC.PENDLE_ROUTER_V4` (// TODO verify)
- `BSC.VENUS_COMPTROLLER`, `BSC.vUSDC`, `BSC.vUSDT`, `BSC.USDT`
- `LOCAL_PT_USDE_MARKET` — inline placeholder; TODO verify on Pendle BSC.

## Risks

- **Lista liquidation**: if slisBNB/BNB depegs > 18 % the CDP is at risk.
  Mitigation: 65 % LTV target (vs 80 % limit) buys a 27 % buffer.
- **PT discount widen**: PT can be marked-to-market below entry intra-period.
  Held-to-maturity locks the entry yield regardless.
- **Venus collateral list**: PT-USDe may not be listed on Venus Core — the
  PoC `try/catch`'s and falls back to USDe→vUSDC, which gives up the PT yield
  on the supplied leg but keeps the CDP+borrow flywheel.
- **lisUSD/USDe peg**: depeg between mint and swap erodes the PT entry size;
  PCS StableSwap haircut typically < 5 bp.

## Result

Status: **offline-draft** (compiles; live run pending BSC RPC + verified
Pendle market). Expected PnL: ~$400 net / 30 d / $60 k notional ≈ **8 %
APR** with three live yield streams.

## TODO

- Verify `PENDLE_ROUTER_V4` on BSC (same address as mainnet by Pendle
  convention but unconfirmed).
- Verify Venus has a PT-USDe vToken listing; if not, the fallback path
  is the canonical one.
- Confirm `IListaInteraction.payback` selector for the recycle leg.
