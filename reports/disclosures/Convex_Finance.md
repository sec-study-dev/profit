# Coordinated pre-publication research notice — Convex Finance (peripheral)

> **This is NOT a smart-contract vulnerability report.** Convex appears only as
> a staking wrapper for a Curve LP; the economic transfer occurs on the Curve /
> LLAMMA side, not in Convex. Included for completeness.

## 1. Summary
- **Protocol:** Convex Finance, Ethereum mainnet.
- **Affected contracts:** Convex-wrapped crvUSD/USDC Curve LP position; Curve crvUSD/USDC pool `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E`; crvUSD wstETH LLAMMA `0x37417B2238AA52D0DD2D6252d989E728e8f706e4`.
- **Profit method (one line):** arbitrage the price basis between a Convex-staked crvUSD/USDC LP and the crvUSD LLAMMA; the basis originates in Curve/LLAMMA (see `Curve_Finance.md`, finding C-1). Convex is used only to hold/route the LP.
- **Severity:** **Informational / Low.** Realistic value captured (fork-measured): ~$3.1k (`CrvUsdLpVsLlammaBasis`), block 19_643_500.

## 2-5. Details
- **Root cause / mechanism / impact / remediation:** identical to the LLAMMA soft-liquidation-basis discussion in `Curve_Finance.md` (§2-§5, finding C-1). Convex contributes no additional loss surface; it is an in-spec LP wrapper. No Convex code misbehaves and no Convex invariant is violated. Flagged to Convex only so the team is aware its wrapped-LP position can be one leg of the cross-protocol basis trade.

## 3. Reproduction / PoC
- **Environment:** Foundry (`forge`) + an archive RPC for the chain. A self-contained, runnable proof-of-concept is attached (the `disclosure_pocs` bundle: `pocs/<file>.t.sol` plus a minimal harness, `foundry.toml`, `src/`, `test/`, `lib/` and a README). No external repository is required. To run: set the RPC env var, then `forge test --match-path "pocs/<file>.t.sol" -vv`. Each PoC forks the chain at the pinned block below, executes the strategy, and logs the realised result. **Not executed on mainnet; no funds moved on-chain; no real party incurred any loss.**
- **Attached PoC & pinned block:** `CrvUsdLpVsLlammaBasis` @ 19_643_500. Ethereum mainnet fork, `RPC_URL` = archive endpoint.

## 6. Disclosure timeline & publication plan
- Same academic publication as the Curve notice; **90-day embargo** from acknowledgement proposed. Please confirm receipt. Contact: luofeng7777@gmail.com.
- Note: send to Convex Finance's own security contact (docs.convexfinance.com bug-bounty page). Do **not** use `security@convex.dev`, which belongs to an unrelated company (Convex, the backend platform).
