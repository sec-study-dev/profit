# B09-06: Wombat slisBNB sidecar + Lista CDP + PCS Stable lisUSD unwind

## Mechanism
3-mechanism composition that turns a transient Wombat-sidecar dislocation
into a stable, USDT-marked position via a one-way pass through Lista's CDP:

1. **Wombat dynamic-asset-weight (slisBNB/WBNB sidecar)** — buy slisBNB when
   the sidecar pool's `cov_BNB < 0.9` (i.e. the pool is desperate for BNB and
   over-pays slisBNB).
2. **Lista DAO CDP** — deposit the freshly-acquired slisBNB as collateral
   and mint lisUSD up to a safe 70% LTV.
3. **PCS Stable lisUSD/USDT** — swap minted lisUSD into USDT to lock the
   majority of the position value in a dollar-stable.

The strategy isolates three mechanically-distinct surfaces:
- The Wombat skew bonus is an **atomic** AMM dislocation.
- The CDP step converts the rate-marked LST collateral into a synthetic
  dollar position (lisUSD), exploiting the fact that Lista's slisBNB market
  allows up to 75% LTV — close to the maximum useful leverage.
- The PCS step monetizes the lisUSD at the prevailing peg, which on a given
  day may be at a 0-30 bp discount (PoC assumes 20 bp discount as a
  conservative model).

The residual 30% of slisBNB sits in the CDP as over-collateralization. On the
PnL line this shows up as "slisBNB consumed" (since CDP deposits don't return
slisBNB to the test contract), and the harvested upside is the **USDT
realized plus the documented over-collateralization claim**.

## Why it composes
- **Wombat skew is the alpha**: B09-04 documents 7-12 bp over-quote on
  slisBNB out at `cov_BNB=0.88`. That bonus is realized in slisBNB units,
  marked at the Lista internal rate.
- **Lista CDP unlocks dollar liquidity**: instead of holding slisBNB and
  waiting for the redemption queue, the CDP converts it to lisUSD
  immediately, with full collateral retention.
- **PCS Stable closes the dollar leg**: lisUSD's $1 peg is enforced by the
  CDP soft floor + PCS Stable arb; trading lisUSD to USDT crystallizes the
  arb at a known discount.

## Mechanism count
**3-mechanism**: (1) Wombat sidecar, (2) Lista CDP, (3) PCS StableSwap.

## Preconditions
- Wombat slisBNB/WBNB sidecar pool exists and has `cov_BNB < 0.9`. **TODO**
  verify the canonical sidecar pool address (same as B09-04 placeholder).
- Lista CDP slisBNB market enabled and accepts 75% LTV.
- PCS Stable lisUSD/USDT pool exists. **TODO verify** indices.
- The funder is OK leaving slisBNB locked as CDP collateral for the duration
  of the position (this is *not* atomic on the exit side; the exit requires
  repaying lisUSD then `Interaction.withdraw`).

## PnL math
At `cov_BNB = 0.88`, BNB = $600, internal rate = 1.078 BNB/slisBNB:

- 500 WBNB notional -> 463.8 slisBNB fair, +7 bp = 464.1 slisBNB.
- Rate-marked BNB-equivalent: 464.1 * 1.078 = 500.3 BNB ≈ $300,200.
- CDP mint at 70% LTV: 210,140 lisUSD.
- PCS Stable lisUSD -> USDT at 0.998: ~209,720 USDT.
- WBNB consumed: 500 ($300,000).
- Net realized USDT: $209,720. Slipped slisBNB collateral held in CDP:
  $90,200 over-collateralization claim (not in `pnl_usd=` line).

For the **realized arb leg** (treating the CDP residue as held collateral,
not profit), the bonus is `(464.1 * 1.078 - 500) * $600 = ~$180` per 500 WBNB
position. Add the lisUSD discount (-$420) and the picture is: the CDP-and-
unwind path costs ~$240 in net frictions for the privilege of accelerating
the collateral monetization vs holding slisBNB to the Lista queue.

Realistic dislocations (where the strategy actually clears > 0 net):
- Sidecar `cov_BNB < 0.80` (deep skew): 15-25 bp Wombat bonus + 0-10 bp
  lisUSD premium -> +$500 to +$1,500 net per 500 WBNB.
- Lista queue freeze (slisBNB premium on PCS) compounds the bonus when the
  CDP collateral retains a market premium.

## Block pinned
- `FORK_BLOCK = 46_000_000` (placeholder). **TODO** pin a block where
  Wombat slisBNB sidecar has `cov_BNB < 0.9` AND Lista lisUSD trades at < 0.999
  on PCS Stable.

## Risks
- **CDP liquidation** if BNB drops > 30% before the position is unwound
  (mitigated by the 70% LTV target which leaves ~30% headroom).
- **lisUSD depeg widening** during stress -> the PCS leg sells at a worse
  discount; partially hedged by leaving 30% over-collateral.
- **Wombat pool address unverified**: same placeholder caveat as B09-04.
- **Lista CDP selectors**: `borrow(token, amount)` selector signature is
  inferred from `IListaInteraction.sol`; **TODO** verify against the live
  proxy.

## Result
- Status: **theoretical / offline-first**.
- Expected PnL: **+$0 to +$1,500 per 500 WBNB notional** depending on
  Wombat skew depth and lisUSD discount. The strategy is *most attractive*
  when the operator needs to convert LST exposure to USDT immediately
  without going through the Lista 7-day unbond queue.

## TODO
- Verify Wombat slisBNB sidecar pool address (shared with B09-04).
- Verify `IListaInteraction.borrow` selector / argument ordering on the
  deployed proxy.
- Verify the PCS Stable lisUSD/USDT pool address & `i,j` indices.
- Add an unwind branch (`payback` + `withdraw` + `slisBNB.swap` back to BNB)
  for a fully round-tripped PnL.
- Pin a real block with `cov_BNB < 0.9` and lisUSD < 0.999.
