# Coordinated Pre-Publication Research Disclosures — index & how to send

These are **research notices, not vulnerability reports.** Each documents a
*profit strategy built by composing several protocols' in-spec mechanisms*.
None exploits a smart-contract bug; every call is a documented, permissionless
protocol function used exactly as designed. We are sending them ahead of an
academic publication as a courtesy and to invite comment.

## Reports
| File | Protocol | Findings covered | Channel |
|---|---|---|---|
| `Curve_Finance.md` | Curve Finance | LLAMMA soft-liquidation band capture; crvUSD PegKeeper peg-arb; stableswap adverse-selection (depeg / cooldown / stable-basis / rate-lag) | email **security@curve.finance** |
| `Uniswap.md` | Uniswap Labs | Just-in-time (JIT) v3 liquidity fee capture; cbETH rate-update adverse selection | email **security@uniswap.org** (or Cantina) |
| `PancakeSwap.md` | PancakeSwap | WBETH exchange-rate-lag adverse selection on PCS v3 | Immunefi program page / team Discord |
| `Wombat_Exchange.md` | Wombat Exchange | Coverage-ratio (dynamic-weight) rebalancing-reward capture | Immunefi program page / team Discord |
| `Convex_Finance.md` | Convex Finance | (peripheral) Convex-wrapped crvUSD LP leg of the LLAMMA basis trade | docs bug-bounty contact |

## How to send (important)
- These are **economic / market-structure findings**. Every one of the above
  bug-bounty programs is scoped to *smart-contract vulnerabilities / loss of
  user funds by draining or social engineering*, and explicitly does **not**
  cover economic, market, or MEV issues. If submitted through a bounty intake
  they will (correctly) be closed as *out-of-scope / known / by-design*.
- Therefore: **do not file these on Immunefi as bounty claims.** Send them as
  plain e-mail to the security address (Curve, Uniswap, Convex), or, for
  PancakeSwap / Wombat which route through Immunefi, use the program's
  "contact team / non-bounty message" option or the project's official
  security Discord to reach the team directly.
- Subject line suggestion: `Pre-publication research notice (non-vulnerability) — coordinated disclosure`.
- First line of every message should state: *"This is NOT a smart-contract
  vulnerability report. The described strategy uses your contracts exactly as
  designed; we are notifying you before publishing academic research."*

## A note on severity (please read before sending)
Each finding is rated **Informational / Low**. The constituent mechanisms
(loss-versus-rebalancing, JIT liquidity, soft-liquidation arbitrage, peg-keeper
arbitrage) are **well-documented, in some cases intended, prior art**. The
research contribution is the *systematic multi-protocol composition and
reproducible quantification*, not the discovery of any single new exploit.
Framing these as high-severity vulnerabilities would be inaccurate and would
harm credibility with these teams.
