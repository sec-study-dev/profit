# Coordinated pre-publication research notice — Wombat Exchange

> **This is NOT a smart-contract vulnerability report — and, on our reading, not
> even an unintended behaviour.** The strategy uses Wombat's dynamic-weight
> rebalancing incentive exactly as designed. Shared for completeness ahead of an
> academic publication; you may reasonably classify it "working as intended."

## 1. Summary
- **Protocol:** Wombat Exchange, BNB Smart Chain.
- **Affected contracts (BSC):** BNB-LST side pool `0x6F1c689235580341562cdc3304E923cC8fad5bFa` (ankrBNB `0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827`); lisUSD "smartHAY" side pool `0x0520451B19AD0bb00eD35ef391086A692CFC74B2`. Via `swap()` / `quotePotentialSwap()`.
- **Profit method (one line):** swap **into** an under-weighted asset in a Wombat pool to collect the coverage-ratio restoration bonus the pool is designed to pay for improving its balance.
- **Severity:** **Informational** — this is Wombat's intended rebalancing incentive; there is no victim beyond the ordinary asymmetry the mechanism deliberately creates.
- **Realistic value captured (fork-measured):** `WombatLisUsdSkewArb` ~$58, `WombatAnkrBnbSkewArb` ~$12, at the tested sizes/blocks; bounded by how far the pool coverage ratios are from balance.

## 2. Technical details
- **Findings W-1 (`WombatAnkrBnbSkewArb`, WBNB->ankrBNB) and W-2 (`WombatLisUsdSkewArb`, USDC->lisUSD):** Wombat prices swaps by coverage ratio; a swap moving an under-weighted asset toward target gets a better-than-rate-fair execution (a bonus). The strategy performs that bonus-earning direction when a pool is skewed.
- **Root cause (by design):** the coverage-ratio-dependent price *is* Wombat's core rebalancing mechanism — it deliberately pays traders to restore balance. No contract misbehaves; there is no stale price and no bug. The only "cost" is borne by LPs on the over-weighted side, which is exactly the rebalancing transfer the design intends.
- **Preconditions:** the pool must be skewed (a coverage-ratio gap); capital under the per-swap coverage cap. No permissions. A balanced pool yields ~0.

## 3. Reproduction / PoC
- **Environment:** Foundry (`forge`) + an archive RPC for the chain. A self-contained, runnable proof-of-concept is attached (the `disclosure_pocs` bundle: `pocs/<file>.t.sol` plus a minimal harness, `foundry.toml`, `src/`, `test/`, `lib/` and a README). No external repository is required. To run: set the RPC env var, then `forge test --match-path "pocs/<file>.t.sol" -vv`. Each PoC forks the chain at the pinned block below, executes the strategy, and logs the realised result. **Not executed on mainnet; no funds moved on-chain; no real party incurred any loss.**
- **Attached PoCs & pinned block:** `WombatAnkrBnbSkewArb`, `WombatLisUsdSkewArb` @ 45_500_000. BNB Smart Chain fork, `BSC_RPC_URL` = archive endpoint; run with `--threads 1`.
- **Steps:** (1) fork; (2) `quotePotentialSwap` the bonus direction; (3) if the quote exceeds rate-fair beyond fees, `swap()`; (4) measure the surplus.

## 4. Impact assessment
- **Worst case:** bounded by the coverage-ratio gap and the per-swap cap; capturing the bonus *reduces* the skew (the intended effect).
- **Who bears it:** LPs on the over-weighted side — but this is the rebalancing transfer the mechanism is designed to make; not an unexpected loss in the way an exploit would be.
- **Repeatability:** only while a pool is skewed; self-extinguishing as the swap rebalances the pool.

## 5. Remediation suggestions
- We do **not** recommend a code change: the behaviour is the intended rebalancing incentive. If the team nonetheless wishes to reduce third-party capture of the rebalancing reward, options are: lower the coverage-ratio slippage curve's convexity (smaller bonus per unit of imbalance), tighten the per-swap coverage cap, or direct part of the rebalancing reward to LPs rather than the swapper. Included only for completeness of the cross-protocol catalogue.

## 6. Disclosure timeline & publication plan
- We intend to publish an academic paper. We propose a **90-day embargo** from acknowledgement before public release and will include any context you provide.
- Please confirm receipt. Contact: luofeng7777@gmail.com.
