# F14-07: Synthetix V3 mainnet vault deposit — research probe

> Status: **research-probe / dormant-on-mainnet**. Two-mechanism PoC.
> Synthetix V3 launched primarily on Optimism (and later Base); the L1
> deployment exists at `0xffffffaEff0B96Ea8e4f94b2253f31abdD875847` (CoreProxy)
> but with narrow active markets through 2024. This strategy is a documented
> snapshot of that state — useful as a baseline for future re-activation.

## Mechanism count: 2

1. **Synthetix V3 Core Proxy** on mainnet — the post-V2x system's user-facing
   entrypoint (governance, collateral configuration, market registry, pool /
   vault management). The PoC reads `getMarkets()`,
   `getCollateralConfigurations(true)` to discover whether any market accepts
   collateral and provides yield at the fork block.
2. **Synthetix V2x AddressResolver** — sanity-checks the older system is
   still wired (so the "no markets" finding is not just a fork-config issue).

## Why this is a research probe (not an arbitrage)

V3's atomic-exchange equivalent on L1 has not seen broad adoption — most
liquidity-bearing markets (perpetuals, sUSDC/wrappedUSDC carry, the LegacyMarket
that bridges V2x sUSD to V3 snxUSD) live on Optimism. On mainnet at typical
2024-block forks:

- `getMarkets()` returns a small set of system markets (LegacyMarket, possibly
  a perp adapter) with TVL << $1M.
- `getCollateralConfigurations(true)` typically returns SNX and (sometimes)
  stETH; ETH-denominated collateral exists but `depositingEnabled` is often
  false on L1.
- The V3 USD token (`snxUSD`) has a sub-million-dollar L1 supply.

There is *no* high-IRR loop available on mainnet V3 at this snapshot. The
useful output of this PoC is documentary: the list of registered markets +
active collateral at the fork block is the input to a future deepening agent
that decides whether V3-on-L1 has activated.

## Strategy

1. Fork at `20_900_000` (late 2024 baseline).
2. `getAddress("Synthetix")` on the V2x resolver — record V2x is still alive.
3. `getMarkets()` on V3 CoreProxy — log returned market IDs.
4. `getCollateralConfigurations(true)` on V3 CoreProxy — log every entry
   (issuance ratio, min delegation, token address).
5. If at least one collateral entry exists, the PoC logs the parameters and
   leaves the actual deposit/mint to a future activation-validated probe.
6. If none, log dormant-state and exit cleanly.

## Why two mechanisms not three

V3 mainnet is mechanism-rich on paper (CoreProxy + USDToken + LegacyMarket +
account NFT + spot market) but at a typical fork block fewer than two of
those have non-trivial state. To stay honest in the family taxonomy we count
only:

- V3 Core Proxy reads (mechanism 1)
- V2x AddressResolver as a sanity / cross-check leg (mechanism 2)

When V3 mainnet activates a real lending vault, a future strategy can
upgrade this to 3+ mechanisms (V3 CoreProxy deposit + LegacyMarket bridge +
Curve sUSD/snxUSD pool).

## Preconditions (availability gate)

- V3 CoreProxy must have non-zero code at the fork block.
- `getCollateralConfigurations(true)` must return non-empty.

If both gates pass, the PoC logs the discovered state and stops (no
deposit). If either fails, the PoC logs dormant-state and exits with a
zero-PnL report.

## PnL math

Zero gross by design — the PoC does not deposit. Reported PnL is purely the
ETH/gas cost of the discovery calls (small).

For a future activated state:
```
PnL_apr = vault_yield_apr - opportunity_cost_apr
         (where vault_yield_apr is paid in snxUSD or LP-share appreciation)
```
A V3-on-L1 deposit becomes interesting only if `vault_yield_apr` exceeds
DSR (currently ~5%) — i.e. V3 markets are paying their LPs at least 5% APY.

## Block pinned

`20_900_000` — late 2024. Chosen because:

- V3 CoreProxy is deployed and reachable.
- We are after the main 2023 V3-on-OP push, so any mainnet activation event
  would be visible by now.
- Establishes a *baseline* dormant-state finding for the family record.

## Risks

- **Fork-only artifact**: `getCollateralConfigurations` ABI may shift on
  V3 upgrades; we use `try/catch` so a shifted selector logs the revert
  reason rather than reverting the test.
- **Activation false-positive**: even if a collateral is listed, the vault
  might still pay 0 APY. Probe doesn't assert profit, only state.

## Result
Status: theoretical
Expected PnL: ~$0 (read-only discovery on dormant L1 V3 deployment, ~$5 gas; future-activation upside dependent on V3-on-L1 markets paying > 5% APY)

Research-probe PoC. Two-mechanism reading of the Synthetix V3 mainnet state
plus a V2x cross-check. Surfaces whether mainnet V3 has activated any
depositable collateral — a *prerequisite* for any future V3-flavoured
strategy on L1. Documented dormant baseline as of late-2024 fork.
