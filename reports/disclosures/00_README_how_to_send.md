# Coordinated Pre-Publication Research Disclosures — index & how to send

These are **research notices, not vulnerability reports.** Each documents a
*profit strategy built by composing several protocols' in-spec mechanisms*.
None exploits a smart-contract bug; every call is a documented, permissionless
protocol function used exactly as designed. They are sent ahead of an academic
publication as a courtesy and to invite comment.

Each notice is self-contained: the affected contracts, the mechanism, and the
reproduction are described in full in the notice itself, and a runnable
proof-of-concept is attached (`disclosure_pocs` bundle). No external repository
needs to be accessed to understand or reproduce a finding.

## Reports & attached PoCs
| Notice file | Protocol | Attached PoC file(s) | Channel |
|---|---|---|---|
| `Curve_Finance.md` | Curve Finance | LlammaBandArbWsteth, LlammaSoftLiqHarvestWbtc, LlammaSoftLiqHarvestTbtc, CrvUsdLpVsLlammaBasis, CrvUsdPegKeeperArb, StethDepegRedeemArb, SusdeCooldownArb, StableBasisGhoSusdsArb, CbethRateUpdateArb | email **security@curve.finance** |
| `Uniswap.md` | Uniswap Labs | UniV3JitLpBackrun, CbethRateUpdateArb | email **security@uniswap.org** (or Cantina) |
| `PancakeSwap.md` | PancakeSwap | WbethRateLagArb | Immunefi program page / team Discord |
| `Wombat_Exchange.md` | Wombat Exchange | WombatAnkrBnbSkewArb, WombatLisUsdSkewArb | Immunefi program page / team Discord |
| `Convex_Finance.md` | Convex Finance | CrvUsdLpVsLlammaBasis | docs bug-bounty contact |

## How to send (important)
- These are **economic / market-structure findings**. Every bug-bounty program
  above is scoped to *smart-contract vulnerabilities / loss of user funds by
  draining or social engineering*, and does **not** cover economic, market, or
  MEV issues. Submitted through a bounty intake they will (correctly) be closed
  as *out-of-scope / known / by-design*.
- Therefore: **do not file these as bounty claims.** Send them as plain e-mail
  to the security address (Curve, Uniswap, Convex), or, for PancakeSwap /
  Wombat which route through Immunefi, use the program's "contact team" option
  or the project's official security Discord to reach the team directly.
- Subject line: `Pre-publication research notice (non-vulnerability) — coordinated disclosure`.
- First line of every message: *"This is NOT a smart-contract vulnerability
  report. The described strategy uses your contracts exactly as designed; we are
  notifying you before publishing academic research."*
- Attach the relevant notice `.md` and the `disclosure_pocs` bundle (or just the
  PoC files listed for that protocol plus the bundle's `foundry.toml`, `src/`,
  `test/`, `lib/` and `README.md`).

## A note on severity
Each finding is rated **Informational / Low**. The constituent mechanisms
(loss-versus-rebalancing, JIT liquidity, soft-liquidation arbitrage, peg-keeper
arbitrage) are well-documented, in some cases intended, prior art. The research
contribution is the systematic multi-protocol composition and reproducible
quantification, not a new single-protocol exploit.
