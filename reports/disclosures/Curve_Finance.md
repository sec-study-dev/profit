# Coordinated pre-publication research notice — Curve Finance

> **This is NOT a smart-contract vulnerability report.** Every function called
> is a documented, permissionless Curve function used exactly as designed. No
> Curve invariant is violated; no code bug is exploited. We are sharing this
> ahead of an academic publication and welcome your comment.

## 1. Summary
- **Protocol:** Curve Finance (crvUSD / LLAMMA lending-liquidation AMM + Curve stableswap pools), Ethereum mainnet.
- **Affected contracts (mainnet):**
  - crvUSD LLAMMA (soft-liquidation AMMs): wstETH `0x37417B2238AA52D0DD2D6252d989E728e8f706e4` (Controller `0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE`); WBTC LLAMMA `0xE0438Eb3703bF871E31Ce639bd351109c88666ea` (Controller `0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67`); tBTC LLAMMA `0xf9bD9da2427a50908C4c6D1599D8e62837C2BCB0` (Controller `0x1C91da0223c763d2e0173243eAdaA0A2ea47E704`).
  - Curve stableswap pools: crvUSD/USDC `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E`; GHO/crvUSD `0x635EF0056A597D13863B73825CcA297236578595`; USDe/USDC `0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72`; cbETH/ETH `0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A`; stETH/ETH `0xDC24316b9AE028F1497c275EB9192a3Ea0f67022`.
- **Profit method (one line):** capture the band-vs-spot spread that LLAMMA pays out during soft-liquidation, and the adverse-selection / peg-restoration spread that Curve stableswap LPs pay to arbitrageurs, by composing a Curve leg with an external venue in one flow.
- **Severity:** **Informational / Low** (by-design and well-documented economic behaviour; see §2 root cause).
- **Realistic value captured (fork-measured, block- and size-specific — NOT protocol-wide):** soft-liquidation band capture ≈ **$7k–$19k per active soft-liquidation window** at the tested sizes (F05-01 wstETH $18.8k, F05-02 WBTC $8.0k, F05-06 tBTC $7.0k); crvUSD peg-arb ≈ **$0.26k** (F05-04); Convex-crvUSD-LP-vs-LLAMMA basis ≈ **$3.1k** (F12-09); stableswap adverse selection ≈ **$0.13k–$37k** depending on the dislocation captured (F03-07 cbETH rate-update $0.13k; F08-06 sUSDe cooldown $0.75k; F16-05 GHO/sUSDS basis $25.9k; F03-01 the May-2022 stETH depeg $37.2k). These are the value *transferred from* soft-liquidating borrowers / stale-priced LPs to the strategy, per event.

## 2. Technical details
### 2.1 Findings
- **C-1 — LLAMMA soft-liquidation band capture** (F05-01 wstETH, F05-02 WBTC, F05-06 tBTC; and F12-09 as a Convex-LP-vs-LLAMMA basis variant). Functions: `LLAMMA.exchange()` / the controller soft-liquidation path, arbitraged against a Curve stableswap `exchange()` (crvUSD/USDC) and/or a UniV3 swap. When collateral price moves into a user's LLAMMA bands, the AMM sells/buys collateral across bands at band price; an arbitrageur who trades the band against the true spot pockets the band-vs-spot gap.
- **C-2 — crvUSD PegKeeper peg-arbitrage** (F05-04). Restores the crvUSD/USDC pool toward peg (via a DssFlash-funded round-trip through the PSM and the Curve pool) and pockets the deviation the PegKeeper is designed to reward.
- **C-3 — Stableswap adverse selection / LVR** (F03-01 stETH depeg via stETH/ETH pool + Lido queue; F08-06 sUSDe cooldown vs USDe/USDC pool; F16-05 GHO/crvUSD & sUSDS stable-basis; F03-07 cbETH/ETH pool priced off a lagged Coinbase rate). The LP quoting a stale or dislocated price is picked off by an arbitrageur who closes the gap against an external venue or a redemption/cooldown path.

### 2.2 Root cause — a *combination of in-spec mechanisms*, not a bug
No Curve contract behaves incorrectly. The profit arises because:
- LLAMMA is **designed** to be continuously arbitraged — that arbitrage *is* the soft-liquidation mechanism. The band-vs-spot spread is the compensation LLAMMA offers arbitrageurs to perform liquidation; a well-capitalised, low-latency actor captures more of it.
- The PegKeeper is **designed** to let arbitrageurs restore peg for a reward.
- Constant-A stableswap pools with a fixed or slowly-updated price for a rate-bearing / redeemable asset (stETH, cbETH, sUSDe, GHO/sUSDS) incur standard **loss-versus-rebalancing (LVR)**: LPs knowingly accept adverse selection.
The novelty we are documenting is only that these are **composed across protocols** (Curve × Lido queue / Coinbase-rate / Ethena cooldown / Maker PSM+DssFlash / Convex) into single reproducible flows, and quantified.

### 2.3 Preconditions
- A real dislocation must exist: an open soft-liquidation window (C-1), a crvUSD peg deviation (C-2), or a stale/dislocated LP price (C-3). With no dislocation the flows net ≈ 0 (they hold flat).
- Working capital or a flash source (Maker DssFlash / Balancer / UniV3 flash) to fund the leg. No governance rights, admin keys, or special permissions are required.

## 3. Reproduction / PoC
- **Environment:** Foundry fork of Ethereum mainnet (`vm.createSelectFork($RPC_URL, block)`), archive RPC required. Not executed on mainnet; no funds moved on-chain; no real party incurred loss.
- **Runnable PoCs (already in the research repo):** `strategies/F05-01-*`, `F05-02-*`, `F05-06-*`, `F12-09-*`, `F05-04-*`, `F03-01-*`, `F08-06-*`, `F16-05-*`, `F03-07-*` (each a `PoC.t.sol`). Pinned blocks: 19_643_500 (LLAMMA/F12-09), 18_500_000 (F05-04), 14_900_000 (F03-01, stETH depeg), 20_800_000 (F08-06), 21_100_000 (F16-05), 19_000_000 (F03-07).
- **Run:** `forge test --match-path "strategies/F05-01-*/PoC.t.sol" -vv` (set `RPC_URL` to a mainnet archive endpoint).
- **Steps (C-1 example):** (1) fork at a block with an active soft-liquidation; (2) read the LLAMMA band price vs Curve/UniV3 spot; (3) if the gap exceeds fees, trade the band against spot; (4) settle and measure the captured spread.

## 4. Impact assessment
- **Worst case:** bounded by the size of the dislocation — the soft-liquidation volume in the window (C-1), the crvUSD peg gap × pool depth (C-2), or the LP's quoted size at the stale price (C-3). It is *not* an unbounded drain and cannot exceed the value the mechanism is designed to pay out.
- **Who bears it:** borrowers being soft-liquidated (C-1) receive marginally worse execution; crvUSD/stableswap **LPs** bear the LVR (C-2, C-3).
- **Repeatability:** repeatable *per dislocation event*, not at zero cost — each execution requires an actual gap and pays gas/fees; in efficient conditions the flows net ≈ 0.

## 5. Remediation suggestions (concrete)
- **C-1/C-3 for rate-bearing assets:** price LST/redeemable-asset pools from the asset's on-chain rate provider rather than a lagging spot, and/or enable a **dynamic fee** that widens with realised volatility (Curve's newer NG pools already support rate oracles and dynamic fees — extending this to the cbETH/ETH and similar pools would remove the rate-lag adverse-selection leg specifically).
- **C-1 (LLAMMA):** if the band-capture is considered excessive, raise the AMM's dynamic fee inside active liquidation bands, or route soft-liquidation through a short **batch auction** so the band spread is competed away and returned to the borrower rather than to the fastest searcher.
- **C-2 (PegKeeper):** tune PegKeeper debt ceilings / action size caps so the per-call reward is small relative to gas, reducing extractable peg-arb without harming peg stability.
- Note: for the pure-LVR legs (C-3), no code change fully removes adverse selection — it is inherent to constant-function market making; dynamic fees only reduce it.

## 6. Disclosure timeline & publication plan
- We intend to publish an academic paper cataloguing these cross-protocol strategies.
- We propose a **90-day embargo** from your acknowledgement of this notice before public release, and will incorporate any correction or context you provide.
- Please confirm receipt and whether the 90-day window is acceptable, or propose an alternative. Contact: <your email>.
