# B15-09 — Triple-LST restake: slisBNB + BNBx + asBNB on Venus·Lista·Astherus

## Family

B15 · 三协议机制堆叠. BSC analogue of mainnet F18-05 (triple-LST
restake): three sister LSTs from three different issuers, two
collateral venues (Lista CDP + Venus), one BNB-denominated equity.

## Thesis

The three major BNB-side LSTs on BSC have **uncorrelated risk
profiles**:

- **slisBNB** (Lista) — validator LST, Lista validator set, redeemable
  via 7-day unstake queue.
- **BNBx** (Stader) — validator LST, Stader validator set, exchange-
  rate based.
- **asBNB** (Astherus) — restaked LST with Babylon points and higher
  base APR (~9.5%), but newer protocol risk.

Splitting equity across all three smooths validator-slashing risk and
captures all three issuers' staking premia. Both slisBNB and asBNB
serve as *collateral simultaneously*: slisBNB lives in the Lista CDP
(mints lisUSD), while BNBx + asBNB live in Venus (borrows USDT).
Net result: 1× BNB exposure with three independent staking yield
streams *plus* the lisUSD+USDT working capital recyclable for further
loops.

## The 3 mechanisms

1. **Lista StakeManager (slisBNB mint)** + **Lista CDP** — mint slisBNB
   and lock it into the CDP to mint lisUSD.
2. **Stader BNBx mint** + **Venus collateral** — convert 30% of seed
   BNB to BNBx, supply to Venus.
3. **Astherus asBNB mint** + **Venus collateral** — convert 30% of
   seed BNB to asBNB, supply to Venus; co-borrow USDT against the
   combined BNBx + asBNB collateral.

## Why distinct from B15-01..06

- B01-04 is a *single-protocol* multi-LST basket on Venus only — no
  Lista CDP leg, no Astherus, single collateral venue.
- B15-01/05 use slisBNB alone in the Lista CDP, no Stader / Astherus.
- B15-04 holds asBNB alone, no slisBNB / BNBx leg.
- B15-09 is the only strategy that *splits a single BNB seed across
  three issuers* and combines two collateral venues.

## TODO

- Confirm Stader BNBx `deposit()` ABI; the PoC uses a raw `call`
  fallback and `_fund` if it reverts.
- Verify Venus actually accepts BNBx as collateral at the pinned
  block (vBNBx address in `BSC.sol` is suspicious — looks identical
  to the Comptroller).
- Refine allocation split via on-chain APR snapshot at block
  42_820_000 (the 40/30/30 here is conservative defaults).
