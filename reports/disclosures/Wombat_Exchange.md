# Coordinated pre-publication research notice — Wombat Exchange

> **This is NOT a smart-contract vulnerability report — and, on our reading,
> not even an unintended behaviour.** The strategy uses Wombat's dynamic-weight
> rebalancing incentive exactly as designed. We are sharing it for completeness
> ahead of an academic publication; you may reasonably classify it "working as
> intended."

## 1. Summary
- **Protocol:** Wombat Exchange, BNB Smart Chain.
- **Affected contracts (BSC):** BNB-LST side pool `0x6F1c689235580341562cdc3304E923cC8fad5bFa` (ankrBNB `0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827`; case B09-04); lisUSD "smartHAY" side pool `0x0520451B19AD0bb00eD35ef391086A692CFC74B2` (case B09-05). Via `swap()` / `quotePotentialSwap()`.
- **Profit method (one line):** swap **into** an under-weighted asset in a Wombat pool to collect the coverage-ratio restoration bonus the pool is designed to pay for improving its balance.
- **Severity:** **Informational** — this is Wombat's intended rebalancing incentive; there is no victim beyond the ordinary asymmetry the mechanism deliberately creates.
- **Realistic value captured (fork-measured):** B09-05 ≈ **$58**, B09-04 ≈ **$12**, at the tested sizes/blocks; bounded by how far the pool's coverage ratios are from balance.

## 2. Technical details
- **Findings W-1 (B09-04, WBNB→ankrBNB) and W-2 (B09-05, USDC→lisUSD):** Wombat prices swaps by coverage ratio; a swap that moves an under-weighted asset toward its target receives a better-than-rate-fair execution (a bonus). The strategy simply performs that bonus-earning direction when a pool is skewed.
- **Root cause (by design):** the coverage-ratio-dependent price *is* Wombat's core rebalancing mechanism — it deliberately pays traders to restore balance. No contract misbehaves; there is no stale price and no bug. The only "cost" is borne by LPs on the over-weighted side, which is exactly the rebalancing transfer the design intends.
- **Preconditions:** the pool must be skewed (a coverage-ratio gap); capital sized under the per-swap coverage cap (`WOMBAT_COV_RATIO_LIMIT_EXCEEDED` bounds it). No permissions. A balanced pool yields ≈ 0.

## 3. Reproduction / PoC
- **Environment:** Foundry fork of BSC mainnet (archive RPC via `$BSC_RPC_URL`). Not executed on mainnet; no real loss.
- **PoCs (in repo):** `strategies-bsc/B09-04-*/PoC.t.sol`, `strategies-bsc/B09-05-*/PoC.t.sol`, block 45_500_000.
- **Run:** `FOUNDRY_TEST=strategies-bsc forge test --match-path "strategies-bsc/B09-0[45]-*/PoC.t.sol" --threads 1 -vv`.
- **Steps:** (1) fork; (2) `quotePotentialSwap` the bonus direction; (3) if the quote exceeds rate-fair beyond fees, `swap()`; (4) measure the surplus.

## 4. Impact assessment
- **Worst case:** bounded by the coverage-ratio gap and the per-swap cap; capturing the bonus *reduces* the skew (the intended effect).
- **Who bears it:** LPs on the over-weighted side — but this is the rebalancing transfer the mechanism is designed to make; it is not an unexpected loss in the way an exploit would be.
- **Repeatability:** only while a pool is skewed; self-extinguishing as the swap rebalances the pool.

## 5. Remediation suggestions
- We do **not** recommend a code change: the behaviour is the intended rebalancing incentive. If the team nonetheless wishes to reduce third-party capture of the rebalancing reward, options are: lower the coverage-ratio slippage curve's convexity (smaller bonus per unit of imbalance), tighten the per-swap coverage cap, or direct part of the rebalancing reward to LPs rather than the swapper. We include this finding only for completeness of the cross-protocol catalogue.

## 6. Disclosure timeline & publication plan
- We intend to publish an academic paper. We propose a **90-day embargo** from acknowledgement before public release and will include any context you provide.
- Please confirm receipt. Contact: <your email>.
