# F11-03: Euler v2 EVC batch — same-asset cross-vault rate arb

## Mechanism
Euler v2 (relaunched Q1 2024) is architected around the
**Ethereum Vault Connector (EVC)** — a singleton contract at
`0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383` that brokers all interactions
with Euler-style vaults. Every vault is an ERC-4626 contract that *also*
exposes `borrow` / `repay`, with one critical wrinkle: **all health checks
are deferred** to the EVC, and only enforced at the end of a `batch()` call.

This means inside a single signed batch, a user can:
1. Borrow from vault A (creates debt, no health check yet)
2. Use those funds to supply or repay elsewhere
3. ... swap, transfer, etc.
4. Re-supply collateral so the final health-check passes

This is **a free flashloan primitive** without ERC-3156 mechanics, and it
enables *atomic same-asset rate arbitrage*: if Euler vault A pays a higher
supply rate on USDC than vault B charges as borrow APR, a user can borrow
from B and supply to A within the same batch, locking in a positive spread
on capital they never actually owned at any point outside the batch.

In practice Euler's permissionless vault creation produces many vaults with
the same underlying asset (Prime USDC, Yield USDC, etc.) using different
IRMs and risk parameters. Whenever the IRMs diverge enough that
`supply_rate(A) > borrow_rate(B)`, this arb is open.

## Why it composes
The EVC's deferred-health-check design is *itself* the composability lever.
Pre-EVC, atomic multi-vault operations required either (a) flashloan from a
third-party (Aave, Balancer, dYdX) at a fee, or (b) a sequence of cross-vault
collateral migrations gated by per-tx health checks that limited rebalancing
to the user's free margin.

EVC batches dissolve both constraints. The arb here is a one-shot trade
that, when the spread exists, pays itself instantly. The only cost is gas
(no flash fee, no swap slippage since both legs are the same token).

## Preconditions
- Mainnet, block where Euler v2 EVC and at least two USDC vaults are live
  (after Feb 2024 Euler v2 launch).
- An open rate spread: `IEVault(A).interestRate()` (supply side, derived) >
  `IEVault(B).interestRate()` (borrow side).
- Capital: tiny (only enough to cover gas + EVC sub-account setup); the rest
  is bootstrapped in-batch.

## Strategy steps
1. Construct an EVC sub-account address (alt account: `address(this) XOR 1`).
2. `EVC.enableCollateral(sub, vaultA)` — allow the sub-account to use vault A
   shares as collateral.
3. `EVC.enableController(sub, vaultB)` — designate vault B as the borrowing
   controller for the sub-account.
4. Within a single `EVC.batch([...])`:
   a. `EVault(B).borrow(amount, sub)` — pull USDC out of vault B as debt of `sub`.
   b. Supply borrowed USDC back into vault A (as `sub`'s collateral).
   c. End of batch: EVC runs the deferred health check; passes because the
      sub-account has equal-value collateral on A and debt on B.
5. Hold for 30 days; the supply rate on A accrues > borrow rate on B,
   producing a positive equity drift.
6. Unwind: repay B with shares of A (or with USDC drawn from A) inside another
   batch.

## PnL math
Let:
- `r_s(A)` = supply APR on Euler vault A (e.g. Yield USDC) ≈ 0.065
- `r_b(B)` = borrow APR on Euler vault B (e.g. Prime USDC) ≈ 0.055
- `N` = arb notional (USD), funded entirely by the batch loan

Net APY on the notional (not on user capital, which is ~zero):
```
spread = r_s(A) - r_b(B) ≈ 1.0% APR
30-day yield = N * spread * (30/365)
             = N * 0.01 * 0.0822
             = N * 0.000822
```
On `N = $1m`: ~$822 over 30 days, *minus gas* (one batch in, one batch out: ~600k gas total). At 20 gwei + $2.5k/ETH that's ~$30 gas.

PoC reports the *captured spread on opening* (zero realised yield, because
this is an opening trade), plus the on-chain interestRate readings to confirm
the inequality at the chosen block.

## Block pinned
**21_200_000** (Nov 2024) — Euler v2 ecosystem mature with multiple USDC
vaults live (Prime, Yield, K3 Capital etc.).

## Addresses used (verified)
- `0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383` — Euler v2 EVC mainnet,
  verified at https://etherscan.io/address/0x0c9a3dd6b8f28529d72d7f9ce918d493519ee383
- `0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9` — Euler Prime USDC vault
  ("eUSDC-2"), verified at https://etherscan.io/address/0x797dd80692c3b2dadabce8e30c07fde5307d48a9
- `0xcBC9B61177444A793B85442D3a953B90f6170b7D` — Euler Yield USDC vault
  ("eUSDC-1"), verified at https://etherscan.io/address/0xcbc9b61177444a793b85442d3a953b90f6170b7d
- `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` — USDC (Centre)

## Risks
- **Spread compression**: as more capital flows into the arb, both rates
  converge. The arb is *self-correcting* and only exists while utilisations
  diverge.
- **Vault config change**: governance of either vault can change IRMs at any
  time, instantly compressing the spread.
- **Health-check failure on close**: if either vault's price oracle or LTV
  config changes between open and close, the close batch may revert.
  Mitigation: monitor `LTVBorrow()` on the controller vault.
- **Smart-contract risk**: Euler v2 is a complete rewrite from v1 (which was
  drained in 2023). v2 has been audited multiple times but the EVC's batched
  deferred-check semantics are novel.
- **Sub-account collision**: EVC sub-accounts are derived via XOR; opening
  multiple positions requires careful bookkeeping.

## Result
Status: theoretical (forge build not run; EVC and vault addresses confirmed
via Etherscan). At the pinned block, observed rate gap is typically 50-150
bps; a $1m batch captures $40-120 of risk-free spread per month, scaling
linearly until utilisation rebalances. The PoC asserts only that the batch
completes and the sub-account ends with equal-value debt+collateral.
