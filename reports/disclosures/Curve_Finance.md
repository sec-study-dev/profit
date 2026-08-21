# Coordinated pre-publication research notice — Curve Finance

> **This is NOT a smart-contract vulnerability report.** Every function called
> is a documented, permissionless Curve function used exactly as designed. No
> Curve invariant is violated; no code bug is exploited. Shared ahead of an
> academic publication; comment welcome.

## 1. Summary
- **Protocol:** Curve Finance (crvUSD / LLAMMA soft-liquidation AMM + Curve stableswap pools), Ethereum mainnet.
- **Affected contracts (mainnet):**
  - crvUSD LLAMMAs: wstETH `0x37417B2238AA52D0DD2D6252d989E728e8f706e4` (Controller `0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE`); WBTC `0xE0438Eb3703bF871E31Ce639bd351109c88666ea` (Controller `0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67`); tBTC `0xf9bD9da2427a50908C4c6D1599D8e62837C2BCB0` (Controller `0x1C91da0223c763d2e0173243eAdaA0A2ea47E704`).
  - Stableswap pools: crvUSD/USDC `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E`; GHO/crvUSD `0x635EF0056A597D13863B73825CcA297236578595`; USDe/USDC `0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72`; cbETH/ETH `0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A`; stETH/ETH `0xDC24316b9AE028F1497c275EB9192a3Ea0f67022`.
- **Profit method (one line):** capture the band-vs-spot spread LLAMMA pays out during soft-liquidation, and the peg-restoration / adverse-selection spread Curve stableswap LPs pay to arbitrageurs, by composing a Curve leg with an external venue in one flow.
- **Severity:** **Informational / Low** (by-design and well-documented economic behaviour; see §2).
- **Realistic value captured (fork-measured, block/size-specific, NOT protocol-wide):** LLAMMA band capture ~$7k–$19k per active soft-liquidation window at the tested sizes (LlammaBandArbWsteth ~$18.8k; LlammaSoftLiqHarvestWbtc ~$8.0k; LlammaSoftLiqHarvestTbtc ~$7.0k); PegKeeper peg-arb ~$0.26k (CrvUsdPegKeeperArb); LLAMMA basis via wrapped LP ~$3.1k (CrvUsdLpVsLlammaBasis); stableswap adverse selection ~$0.13k–$37k depending on the dislocation (CbethRateUpdateArb ~$0.13k; SusdeCooldownArb ~$0.75k; StableBasisGhoSusdsArb ~$25.9k; StethDepegRedeemArb ~$37.2k on the May-2022 stETH depeg). These figures are the value transferred, per event, from soft-liquidating borrowers / stale-priced LPs to the strategy.

## 2. Technical details
### 2.1 Findings
- **C-1 — LLAMMA soft-liquidation band capture.** Functions: `LLAMMA.exchange()` / the controller soft-liquidation path, arbitraged against a Curve stableswap `exchange()` (crvUSD/USDC) and/or a UniV3 swap. When collateral price enters a user's LLAMMA bands, the AMM trades collateral across bands at band price; an actor trading the band against true spot pockets the band-vs-spot gap. PoCs: `LlammaBandArbWsteth`, `LlammaSoftLiqHarvestWbtc`, `LlammaSoftLiqHarvestTbtc`, and `CrvUsdLpVsLlammaBasis` (LLAMMA vs a Convex-wrapped crvUSD/USDC LP).
- **C-2 — crvUSD PegKeeper peg-arbitrage.** Restores the crvUSD/USDC pool toward peg via a DssFlash-funded round-trip through the PSM and the Curve pool, pocketing the deviation the PegKeeper is designed to reward. PoC: `CrvUsdPegKeeperArb`.
- **C-3 — Stableswap adverse selection / LVR.** The LP quoting a stale or dislocated price is picked off by an arbitrageur closing the gap against an external venue or a redemption path: stETH depeg vs Lido queue (`StethDepegRedeemArb`), Ethena sUSDe cooldown vs USDe/USDC (`SusdeCooldownArb`), GHO/sUSDS/crvUSD stable-basis (`StableBasisGhoSusdsArb`), cbETH/ETH priced off a lagged Coinbase rate (`CbethRateUpdateArb`).

### 2.2 Root cause — a combination of in-spec mechanisms, not a bug
No Curve contract behaves incorrectly. Profit arises because: (i) LLAMMA is *designed* to be continuously arbitraged — that arbitrage *is* the soft-liquidation mechanism, and the band-vs-spot spread is the compensation it offers; a fast, well-capitalised actor captures more of it. (ii) The PegKeeper is *designed* to reward arbitrageurs for restoring peg. (iii) Constant-A stableswap pools holding a fixed/slow price for a rate-bearing or redeemable asset incur standard **loss-versus-rebalancing (LVR)** — LPs knowingly accept adverse selection. The contribution we document is only that these are *composed across protocols* (Curve × Lido queue / Coinbase-rate / Ethena cooldown / Maker PSM+DssFlash / Convex) into single reproducible flows, and quantified.

### 2.3 Preconditions
- A real dislocation must exist (an open soft-liquidation window; a crvUSD peg deviation; or a stale/dislocated LP price). With none, the flows net ~0. Working capital or a flash source (Maker DssFlash / Balancer / UniV3 flash) funds the leg. No governance rights or special permissions are required.

## 3. Reproduction / PoC
- **Environment:** Foundry (`forge`) + an archive RPC for the chain. A self-contained, runnable proof-of-concept is attached (the `disclosure_pocs` bundle: `pocs/<file>.t.sol` plus a minimal harness, `foundry.toml`, `src/`, `test/`, `lib/` and a README). No external repository is required. To run: set the RPC env var, then `forge test --match-path "pocs/<file>.t.sol" -vv`. Each PoC forks the chain at the pinned block below, executes the strategy, and logs the realised result. **Not executed on mainnet; no funds moved on-chain; no real party incurred any loss.**
- **Attached PoCs & pinned blocks:** `LlammaBandArbWsteth` / `LlammaSoftLiqHarvestWbtc` / `LlammaSoftLiqHarvestTbtc` / `CrvUsdLpVsLlammaBasis` @ 19_643_500; `CrvUsdPegKeeperArb` @ 18_500_000; `StethDepegRedeemArb` @ 14_900_000; `SusdeCooldownArb` @ 20_800_000; `StableBasisGhoSusdsArb` @ 21_100_000; `CbethRateUpdateArb` @ 19_000_000. Ethereum mainnet fork, `RPC_URL` = archive endpoint.
- **Steps (C-1 example):** (1) fork at a block with an active soft-liquidation; (2) read the LLAMMA band price vs Curve/UniV3 spot; (3) if the gap exceeds fees, trade the band against spot; (4) settle and measure the captured spread.

## 4. Impact assessment
- **Worst case:** bounded by the size of the dislocation — soft-liquidation volume in the window (C-1), crvUSD peg gap x pool depth (C-2), or the LP's quoted size at the stale price (C-3). Not an unbounded drain; cannot exceed what the mechanism is designed to pay out.
- **Who bears it:** borrowers being soft-liquidated (C-1) get marginally worse execution; crvUSD/stableswap **LPs** bear the LVR (C-2, C-3).
- **Repeatability:** per dislocation event, not at zero cost — each execution needs a real gap and pays gas/fees; in efficient conditions the flows net ~0.

## 5. Remediation suggestions (concrete)
- **C-1/C-3 for rate-bearing assets:** price LST/redeemable-asset pools from the asset's on-chain rate provider rather than a lagging spot, and/or enable a **dynamic fee** that widens with realised volatility (Curve's NG pools already support rate oracles and dynamic fees — extending this to the cbETH/ETH and similar pools removes the rate-lag adverse-selection leg specifically).
- **C-1 (LLAMMA):** if band-capture is considered excessive, raise the AMM's dynamic fee inside active liquidation bands, or route soft-liquidation through a short **batch auction** so the band spread is competed away and returned to the borrower rather than to the fastest searcher.
- **C-2 (PegKeeper):** tune PegKeeper debt ceilings / action-size caps so the per-call reward is small relative to gas.
- For pure-LVR legs (C-3), no code change fully removes adverse selection; dynamic fees only reduce it.

## 6. Disclosure timeline & publication plan
- We intend to publish an academic paper cataloguing these cross-protocol strategies. We propose a **90-day embargo** from your acknowledgement before public release and will incorporate any correction or context you provide.
- Please confirm receipt and whether the 90-day window is acceptable, or propose an alternative. Contact: luofeng7777@gmail.com.
