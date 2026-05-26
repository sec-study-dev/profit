# F11-08: Euler v2 cross-vault USDC supply-rate sniffer

## Mechanism
Euler v2 is a *factory* for permissionless lending vaults (EVaults) sharing
the same EVC (Ethereum Vault Connector). At any moment several USDC-base
EVaults coexist with different curator strategies, collateral whitelists,
IRM parameters and reserve fees:

- **Euler Prime USDC** — Euler Labs conservative cluster (DAO-curated).
- **Euler Yield USDC** — higher-yield cluster with broader collateral whitelist.
- **Re7 USDC** — Re7 Labs curator cluster, tuned for yield-bearing collateral.

Because each vault has its own utilization curve and its own collateral set,
the **supply-side APR diverges** across vaults at any block. The strategy is
trivial: read the three rates, pick the highest, deposit. Re-survey after a
horizon to ensure the spread persisted; if a competitor vault's rate has
overtaken, an atomic EVC batch can migrate (withdraw shares from vault A,
deposit assets to vault B, all under deferred health checks).

The novel piece is the *vault sniffer* itself: a single staticcall per
vault yields its borrow rate (per-sec, 1e27 scale). Supply rate is
approximately `borrowRate × util × (1 - reserveFee)`. For ranking
purposes the borrow rate is a faithful proxy because all EVaults share the
same IRM family.

## Why it composes
This is a *pure Euler v2 primitive* strategy: the mechanism is the
EVC + EVault factory itself. The composition is *cross-vault* — the EVC
provides the deferred-health-check semantics that let migration happen
atomically when two vaults of the same base asset diverge in rates.

EVC.batch is the underlying primitive: it sequences multiple `EVault.call`
operations under a single account-status check. For a same-base migration,
the batch is:

```
items[0] = EVault_A.withdraw(amount, this, this)
items[1] = EVault_B.deposit(amount, this)
```

Both vaults read USDC; the account-status check runs **at the end** of
the batch, so a transient zero-collateral state mid-batch does not revert.

## Preconditions
- Mainnet at block ≥ Euler v2 deployment (Aug 2024).
- At least two USDC-base EVaults live and not paused.
- At the pinned block (Nov 2024), Prime/Yield/Re7 are all active.

## Strategy steps
1. Staticcall `interestRate()` on each candidate USDC EVault. Read the
   per-second borrow rate (1e27 scale).
2. Rank vaults by rate; pick the highest.
3. Approve USDC to the winning vault.
4. Inside an `EVC.batch`, deposit bootstrap USDC into the winning vault.
   (Single-item batches are useful for future composition: the same
   transaction can later withdraw from a stale vault and deposit to a
   fresh one.)
5. Hold horizon. Re-survey. Verify rate ordering preserved.
6. (Optional, future) If ordering flipped, run a migration batch.

## PnL math
Let the supply rate of vault A be 4.0 % APR and vault B be 5.5 % APR at
the pinned block. Capital of $500 k for 30 days:
- Supply on A: 500 k × 0.040 × 30/365 = +$1,644
- Supply on B: 500 k × 0.055 × 30/365 = +$2,260
- **Capture**: $616 (12 bps of principal) by routing to the best vault.

The strategy's edge is `Δrate × time`. For a stable spread of 150 bps,
30-day capture is **12 bps of principal**, plus the cumulative compounding
of the higher base.

## Block pinned
**21_200_000** (Nov 2024) — three Euler USDC vaults live with observable
rate divergence between curators.

## Addresses used (verified)
- `0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383` — Euler v2 EVC mainnet,
  verified at https://etherscan.io/address/0x0c9a3dd6b8f28529d72d7f9ce918d493519ee383
- `0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9` — Euler Prime USDC EVault,
  verified at https://etherscan.io/address/0x797dd80692c3b2dadabce8e30c07fde5307d48a9
- `0xcBC9B61177444A793B85442D3a953B90f6170b7D` — Euler Yield USDC EVault,
  verified at https://etherscan.io/address/0xcbc9b61177444a793b85442d3a953b90f6170b7d
- `0x3A8992754E2EF51D8F90620d2766278af5C59b90` — Re7 USDC EVault,
  verified at https://etherscan.io/address/0x3a8992754e2ef51d8f90620d2766278af5c59b90
- `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` — USDC

## Risks
- **Rate mean-reversion**: large deposit can compress the rate spread by
  the supply itself. Capacity is bounded by the rate's elasticity to
  liquidity changes.
- **Curator action**: a vault curator can change parameters (reserve fee,
  IRM kink) — supply rate can drop mid-horizon.
- **Vault pause**: any EVault can be paused by its governor. Migration is
  needed in that scenario.
- **Smart contract risk**: Euler v2 has been audited (Spearbit/OpenZeppelin)
  but is younger than Aave/Compound.

## Result
Status: theoretical (forge build not run; addresses verified on Etherscan).
PoC reads pre + post rates on all three vaults, deposits into the best one
via an EVC batch, asserts shares minted. Expected PnL: **+0.05-0.12 %
over 30 days** depending on spread persistence.
