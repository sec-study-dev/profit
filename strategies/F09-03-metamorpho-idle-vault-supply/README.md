# F09-03: MetaMorpho idle-liquidity capture — supply to a vault before reallocation

## Mechanism

MetaMorpho is a thin ERC-4626 wrapper that sits on top of Morpho Blue and
routes depositor capital across a curator-defined set of Morpho markets,
each with its own supply cap. A new MetaMorpho vault (or one that just
received a large redemption) holds a portion of total assets as **idle**
WETH/USDC inside the vault contract itself — *not yet* allocated to any
Morpho market.

When idle, the vault's shareholder-side APY = `0` (or whatever Morpho's
default-idle-market pays, typically near zero). But the *next* allocation
(triggered by the **allocator** role or by the public
`reallocate()` keeper) pushes that idle capital into markets at the
current spot supply rate — usually 3-8% on stablecoins. Depositors who
**arrive in the idle window** and exit just before the next big inflow get
to harvest the post-allocation rate without diluting it.

Concretely, this PoC focuses on **Steakhouse USDC** (a flagship MetaMorpho
vault by Steakhouse Financial, used widely as the canonical "blue-chip USDC
vault"):

| field           | value                                                        |
| --------------- | ------------------------------------------------------------ |
| vault           | `0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB` (Steakhouse USDC) |
| asset           | `USDC`                                                       |
| curator         | Steakhouse Financial                                         |
| total supply    | $50M-200M (varies)                                           |
| markets         | wstETH/USDC, WBTC/USDC, sUSDe/USDC, PT-sUSDe/USDC, idle      |

The position is positional / opportunistic, not atomic: the depositor
must identify *via off-chain signal* (e.g. Morpho's API or by watching
`Idle()` events) a window where idle ratio is > some threshold (e.g.
> 5%) AND the curator is known to reallocate within hours.

## Why it composes — unique to Morpho

- **MetaMorpho routing is on-chain transparent** unlike Aave/Compound's
  single-pool design. We can read `vault.idle()`, `vault.totalAssets()`,
  and the `supplyQueue` market caps to forecast where the next allocation
  goes.
- **Free flashloan as exit accelerator**: if the curator's next allocation
  pushes the underlying market to a high utilisation that we want to
  vacate (i.e. supply rate spikes but liquidity dries), we can
  `vault.redeem()` partial, flash-borrow the rest from Morpho singleton,
  then re-balance — Morpho's flashLoan callback lets us do this in a
  single tx without exit fees.
- **No protocol fee**: most MetaMorpho vaults charge 0% performance fee
  (Steakhouse charges 5%). Net APY ≈ underlying market APY × (1 - fee).

The deeper composition: a single MetaMorpho vault is an **aggregator over
isolated markets** — the depositor outsources market selection to the
curator, but keeps the option to read the vault's internal allocation and
side-bet (e.g. supply directly to the same underlying market and skip the
curator fee, or sandwich a known incoming allocation).

## Preconditions

- Off-chain signal that a MetaMorpho vault is currently > 5% idle. PoC
  reads `IMetaMorpho.totalAssets()` and the underlying USDC balance held
  directly by the vault contract; the difference is the "allocated"
  amount, and the residue is idle.
- The vault is currently accepting deposits (not paused, and total supply
  cap not hit).
- A reasonable expectation that allocation will happen within the holding
  window (1-3 days is typical for active curators).

## Strategy steps (PoC)

1. Snapshot pre-deposit: vault's idle USDC ratio and share-price.
2. `_fund(USDC, this, 1_000_000e6)` (1M USDC equity).
3. `IERC20(USDC).approve(vault, ...)` and `vault.deposit(1_000_000e6, this)`.
4. Record share balance and `convertToAssets(shares)`.
5. **(Off-PoC, off-chain)**: wait for the curator to reallocate — at that
   point the per-share NAV ticks up at the spot supply APY.
6. (Exit, not in PoC) `vault.redeem(shares, this, this)` for USDC out.

The PoC asserts only that:
- The vault accepts our deposit (no role-gated check).
- `previewRedeem(shares)` shortly after deposit is `>= equity * 0.9999`
  (no instantaneous loss).
- The vault's `idle()` ratio is non-trivial at the fork block (we want
  to demonstrate the opportunity exists; the PoC doesn't simulate
  allocation).

## PnL math

```
idle_ratio      = idle_assets / total_assets  (read at fork)
spot_underlying_apy = current weighted avg of allocated-market supply APYs
post_alloc_apy ≈ spot_underlying_apy           (after next reallocation)

excess_apy_during_idle = 0  (idle USDC earns 0)
APY_after_alloc        = post_alloc_apy * (1 - perf_fee)
```

So the opportunity is: enter at NAV = $1 per share, hold through the next
allocation event, earn the post-allocation APY proportionally. Over 30
days at 6% net APY on $1M: `$1M * 0.06 * 30/365 = $4,932`.

The **upside vs. depositing directly to a single Morpho market** is
diversification (curator-managed risk) and no need to monitor caps.

The **downside vs. direct supply** is the perf fee (5% of yield in this
vault's case) and the fact that the curator could allocate to a lower-rate
market than the one you'd pick yourself.

## Block pinned

**21,400,000** (Dec 2024). At this block the Steakhouse USDC MetaMorpho
vault was a known major player ($150M+ TVL). Idle ratio at this exact
block is read live in the PoC.

## Risks

- **Curator misallocation**: curator might allocate to a market that
  later underperforms or gets paused.
- **Idle bleed**: if the vault sits idle for weeks (the curator is
  inactive), you earn 0; opportunity cost vs. direct supply.
- **Withdrawal-queue gating**: redemption from a MetaMorpho vault is
  limited by the redeemable liquidity (idle + market-supply liquidity).
  In a stress scenario you may queue or partially redeem.
- **Vault-level emergency pause**: each MetaMorpho has a `guardian` who
  can stop deposits or change the supply queue.
- **No flashloan-bootstrap available**: MetaMorpho deposits cannot be
  done atomically with a borrow because the receiver is a vault, not a
  flashloan callback. The opportunity is positional.

## Result

Status: **theoretical / on-chain mechanically-tested** (deposit path
fully exercised in PoC). The post-allocation yield is forward-looking
and depends on curator action.

Expected PnL on $1M equity over 30 days assuming allocation happens in
day 1-2: **+$4,000 to +$5,500** (≈ 5-7% net APY × 30 days × $1M).

## Uncertainties

- The vault address `0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB` is the
  publicly-cited Steakhouse USDC vault; verify with Morpho's
  MetaMorphoFactory event log if a fork-block check fails.
- Idle ratio at the exact fork block must be ≥ 5% for the opportunity to
  be meaningful; PoC `console2.log`s the actual ratio for inspection.
