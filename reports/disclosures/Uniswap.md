# Coordinated pre-publication research notice — Uniswap

> **This is NOT a smart-contract vulnerability report.** Every function called
> is a documented, permissionless Uniswap v3 function used exactly as designed.
> No invariant is violated. Shared ahead of an academic publication.

## 1. Summary
- **Protocol:** Uniswap v3, Ethereum mainnet.
- **Affected contracts (mainnet):** wstETH/WETH 0.01% pool `0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa` (JIT case); cbETH/WETH 0.05% pool `0x840DEEef2f115Cf50DA625F7368C24af6fE74410` (rate-lag case). Mechanism is generic to any v3 pool via `mint()`/`burn()`/`collect()` and `SwapRouter.exactInputSingle`.
- **Profit method (one line):** (a) *JIT liquidity* — mint a tight concentrated position immediately before a large pending swap, capture the bulk of that swap's fee, burn in the same block; (b) *rate-update adverse selection* — trade cbETH right after a Coinbase rate update the pool price has not yet reflected.
- **Severity:** **Informational / Low** — JIT liquidity and LVR are widely documented public MEV phenomena (studied since 2021); no new exploit.
- **Realistic value captured (fork-measured, size-specific):** JIT (`UniV3JitLpBackrun`) ~$7 against a simulated 50-WETH victim swap (scales with victim size x fee tier); cbETH rate-lag (`CbethRateUpdateArb`) ~$0.13k.

## 2. Technical details
### 2.1 Findings
- **U-1 — JIT liquidity fee capture** (`UniV3JitLpBackrun`). In one block: `pool.mint(tightRange, largeLiquidity)` straddling the active tick just before a large swap -> the swap routes through the JIT-dominated tick and pays ~its whole fee to the JIT position -> `pool.burn()` + `collect()`. With injected liquidity ~5-20x resting in-range liquidity, the JIT position captures the majority of the fee that passive in-range LPs would otherwise have earned.
- **U-2 — cbETH rate-update adverse selection** (`CbethRateUpdateArb`). Trade the cbETH/WETH pool against a Curve leg around a `cbETH` exchange-rate update, capturing the pre/post-update price gap from the LP that has not repriced.

### 2.2 Root cause — in-spec mechanism composition, not a bug
Uniswap v3 pays swap fees pro-rata to in-range liquidity at the moment of the swap, by design. JIT exploits nothing in the code — it uses `mint`/`burn` exactly as specified, combined with mempool observation and block ordering, to be in-range for exactly one swap. U-2 is standard LVR against an LP quoting a stale rate. Both are known, in-spec economic behaviours.

### 2.3 Preconditions
- U-1: a large pending swap visible in the mempool + the ability to order the mint immediately before it (bundle). Capital to mint the JIT range (returned same block).
- U-2: a cbETH rate update with the pool price not yet arbitraged.
- No admin/governance rights; no protocol permission required.

## 3. Reproduction / PoC
- **Environment:** Foundry (`forge`) + an archive RPC for the chain. A self-contained, runnable proof-of-concept is attached (the `disclosure_pocs` bundle: `pocs/<file>.t.sol` plus a minimal harness, `foundry.toml`, `src/`, `test/`, `lib/` and a README). No external repository is required. To run: set the RPC env var, then `forge test --match-path "pocs/<file>.t.sol" -vv`. Each PoC forks the chain at the pinned block below, executes the strategy, and logs the realised result. **Not executed on mainnet; no funds moved on-chain; no real party incurred any loss.**
- **Attached PoCs & pinned blocks:** `UniV3JitLpBackrun` @ 20_900_000; `CbethRateUpdateArb` @ 19_000_000. Ethereum mainnet fork, `RPC_URL` = archive endpoint. The "victim" swap in U-1 is simulated in-test.
- **Steps (U-1):** (1) fork; (2) read `slot0` tick; (3) `mint` a 1-3 tick range with liquidity ~5x resting; (4) route the (simulated) large swap through the pool; (5) `burn`+`collect`; (6) measure fee captured vs principal.

## 4. Impact assessment
- **Worst case:** bounded by the fee on the specific large swap being back-run (fee tier x swap size); per-swap, not a drain.
- **Who bears it:** passive in-range LPs, who lose the fee they would have earned on that swap (U-1); the stale-priced LP (U-2).
- **Repeatability:** per large swap / per rate update; requires mempool access and favourable ordering; not zero-cost.

## 5. Remediation suggestions (concrete)
- **U-1 (JIT):** JIT is inherent to v3's per-swap fee sharing. Practical mitigations are venue-level: in **Uniswap v4**, curate a hook that imposes a minimum liquidity dwell time or a JIT-aware fee surcharge on positions minted and burned within the same block/short window, redirecting the surcharge to longer-tenure positions; and document JIT clearly in LP-facing UIs.
- **U-2 (rate-lag):** for LST pairs, prefer pools/oracles that price from the LST rate provider; a v4 hook that adjusts the effective price by the on-chain exchange rate removes the rate-update adverse-selection window.

## 6. Disclosure timeline & publication plan
- We intend to publish an academic paper cataloguing these cross-protocol strategies. We propose a **90-day embargo** from your acknowledgement before public release and will include any context you provide.
- Please confirm receipt and whether 90 days is acceptable. Contact: <your email>.
