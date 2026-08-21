# Coordinated pre-publication research notice — PancakeSwap

> **This is NOT a smart-contract vulnerability report.** The described strategy
> uses PancakeSwap v3 exactly as designed; no invariant is violated and no code
> bug is exploited. We are sharing this ahead of an academic publication.

## 1. Summary
- **Protocol:** PancakeSwap v3, BNB Smart Chain.
- **Affected contracts (BSC):** PCS v3 factory `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865`, SwapRouter `0x1b81D678ffb9C0263b24A97847620C99d213eB14`; the affected market is the **WBETH/ETH** v3 pool (WBETH `0xa2E3356610840701BDf5611a53974510Ae27E2e1`, Binance-Peg ETH `0x2170Ed0880ac9A755fd29B2688956BD959F933F8`), resolved via the factory.
- **Profit method (one line):** buy WBETH on the PCS v3 pool while its price lags WBETH's rising on-chain `exchangeRate()` (NAV), i.e. standard adverse selection against the LP that has not repriced to the new rate.
- **Severity:** **Informational / Low** — loss-versus-rebalancing on a rate-bearing pair; well-documented, inherent to AMMs.
- **Realistic value captured (fork-measured):** F13-02 ≈ **$4.44** on the tested size at block 46_000_000; scales with the accumulated rate-vs-price gap and the LP depth at the stale price.

## 2. Technical details
- **Finding P-1 (B13-02):** WBETH is a rate-bearing LST whose `exchangeRate()` rises as staking rewards accrue. The PCS v3 WBETH/ETH pool price only moves when someone trades; between trades the pool underprices WBETH relative to its NAV. An arbitrageur calls `SwapRouter.exactInputSingle(WETH→WBETH)` to buy WBETH below NAV; the WBETH is worth its on-chain `exchangeRate` (redeemable/valuable at NAV).
- **Root cause (in-spec composition, not a bug):** the pool is a constant-function AMM with no rate awareness; the "loss" is the standard LVR an LP accepts when providing liquidity for a monotonically appreciating asset. No PancakeSwap code misbehaves.
- **Preconditions:** an accumulated WBETH rate-vs-pool-price gap exceeding fees; capital to swap. No permissions required. In an already-arbitraged pool the flow nets ≈ 0.

## 3. Reproduction / PoC
- **Environment:** Foundry fork of BSC mainnet (archive RPC via `$BSC_RPC_URL`). Not executed on mainnet; no real loss.
- **PoC (in repo):** `strategies-bsc/B13-02-*/PoC.t.sol`, block 46_000_000.
- **Run:** `FOUNDRY_TEST=strategies-bsc forge test --match-path "strategies-bsc/B13-02-*/PoC.t.sol" --threads 1 -vv`.
- **Steps:** (1) fork; (2) read `WBETH.exchangeRate()` (NAV) and the pool price; (3) if WBETH trades below NAV beyond fees, swap WETH→WBETH via the SwapRouter; (4) value WBETH at NAV and measure the captured discount.

## 4. Impact assessment
- **Worst case:** bounded by (rate-vs-price gap) × (LP liquidity available at the stale price); a one-shot correction, not a drain.
- **Who bears it:** the WBETH/ETH pool LPs (LVR).
- **Repeatability:** whenever the pool price drifts below WBETH NAV; each execution costs gas + swap fee, so it self-limits.

## 5. Remediation suggestions (concrete)
- Price the WBETH/ETH pool with rate-awareness: reference `WBETH.exchangeRate()` (or a rate oracle) so quotes track NAV, e.g. deploy the pair as a StableSwap/rate-adjusted pool rather than a vanilla constant-product pool; and/or apply a dynamic fee that widens with realised WBETH appreciation between trades. This removes the specific rate-lag adverse-selection window (it does not remove generic LVR).

## 6. Disclosure timeline & publication plan
- We intend to publish an academic paper. We propose a **90-day embargo** from your acknowledgement before public release and will include any context you provide.
- Please confirm receipt and whether 90 days is acceptable. Contact: <your email>.
