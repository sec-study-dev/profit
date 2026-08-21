# Coordinated pre-publication research notice — PancakeSwap

> **This is NOT a smart-contract vulnerability report.** The strategy uses
> PancakeSwap v3 exactly as designed; no invariant is violated and no code bug
> is exploited. Shared ahead of an academic publication.

## 1. Summary
- **Protocol:** PancakeSwap v3, BNB Smart Chain.
- **Affected contracts (BSC):** PCS v3 factory `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865`, SwapRouter `0x1b81D678ffb9C0263b24A97847620C99d213eB14`; affected market is the **WBETH/ETH** v3 pool (WBETH `0xa2E3356610840701BDf5611a53974510Ae27E2e1`, Binance-Peg ETH `0x2170Ed0880ac9A755fd29B2688956BD959F933F8`), resolved via the factory.
- **Profit method (one line):** buy WBETH on the PCS v3 pool while its price lags WBETH's rising on-chain `exchangeRate()` (NAV) — standard adverse selection against the LP that has not repriced.
- **Severity:** **Informational / Low** — loss-versus-rebalancing on a rate-bearing pair; well-documented, inherent to AMMs.
- **Realistic value captured (fork-measured):** `WbethRateLagArb` ~$4.44 on the tested size at block 46_000_000; scales with the accumulated rate-vs-price gap and LP depth at the stale price.

## 2. Technical details
- **Finding P-1** (`WbethRateLagArb`): WBETH is a rate-bearing LST whose `exchangeRate()` rises as staking rewards accrue. The PCS v3 WBETH/ETH pool price only moves on trades; between trades it underprices WBETH vs its NAV. An arbitrageur calls `SwapRouter.exactInputSingle(WETH->WBETH)` to buy WBETH below NAV; the WBETH is worth its on-chain `exchangeRate`.
- **Root cause (in-spec composition, not a bug):** the pool is a constant-function AMM with no rate awareness; the loss is the standard LVR an LP accepts when providing liquidity for a monotonically appreciating asset. No PancakeSwap code misbehaves.
- **Preconditions:** an accumulated WBETH rate-vs-pool-price gap exceeding fees; capital to swap. No permissions. In an already-arbitraged pool the flow nets ~0.

## 3. Reproduction / PoC
- **Environment:** Foundry (`forge`) + an archive RPC for the chain. A self-contained, runnable proof-of-concept is attached (the `disclosure_pocs` bundle: `pocs/<file>.t.sol` plus a minimal harness, `foundry.toml`, `src/`, `test/`, `lib/` and a README). No external repository is required. To run: set the RPC env var, then `forge test --match-path "pocs/<file>.t.sol" -vv`. Each PoC forks the chain at the pinned block below, executes the strategy, and logs the realised result. **Not executed on mainnet; no funds moved on-chain; no real party incurred any loss.**
- **Attached PoC & pinned block:** `WbethRateLagArb` @ 46_000_000. BNB Smart Chain fork, `BSC_RPC_URL` = archive endpoint; run with `--threads 1`.
- **Steps:** (1) fork; (2) read `WBETH.exchangeRate()` (NAV) and the pool price; (3) if WBETH trades below NAV beyond fees, swap WETH->WBETH via the SwapRouter; (4) value WBETH at NAV and measure the captured discount.

## 4. Impact assessment
- **Worst case:** bounded by (rate-vs-price gap) x (LP liquidity at the stale price); a one-shot correction, not a drain.
- **Who bears it:** the WBETH/ETH pool LPs (LVR).
- **Repeatability:** whenever the pool price drifts below WBETH NAV; each execution costs gas + swap fee, so it self-limits.

## 5. Remediation suggestions (concrete)
- Price the WBETH/ETH pool with rate-awareness: reference `WBETH.exchangeRate()` (or a rate oracle) so quotes track NAV — e.g. deploy the pair as a StableSwap/rate-adjusted pool rather than a vanilla constant-product pool — and/or apply a dynamic fee that widens with realised WBETH appreciation between trades. This removes the specific rate-lag adverse-selection window (not generic LVR).

## 6. Disclosure timeline & publication plan
- We intend to publish an academic paper. We propose a **90-day embargo** from your acknowledgement before public release and will include any context you provide.
- Please confirm receipt and whether 90 days is acceptable. Contact: <your email>.
