# F14-01: sETH -> sUSD atomic vs ETH -> USDC Uniswap triangular arbitrage

> Status: **theoretical-historical-replay**. Requires the Synthetix Atomic
> Exchange to still be wired on mainnet at the pinned block. As of late-2024
> Synthetix governance has migrated most synth liquidity / atomic capacity to
> Optimism / Synthetix V3; the mainnet `Exchanger` contract still exists but its
> `exchangeAtomically` path has been progressively tightened (volume caps, fee
> bumps via SCCP). The PoC therefore pins an older block where the atomic
> mechanism is known to have routed real flow.

## Mechanism

Synthetix V2x ("Atomic Synth Exchange", introduced by SIP-120 and refined in
SIP-198 / SIP-258) lets a single caller swap between synths *at the Chainlink
oracle price floored by a Curve TWAP* in a single transaction with **no 5-min
fee-reclamation window** (the original Synthetix exchange forced a 5-minute
wait). The pricing rule, paraphrased from the published Exchanger code:

```
priceUsed = min(chainlinkPrice, curveTwapPrice)        // when selling source
priceUsed = max(chainlinkPrice, curveTwapPrice)        // when buying dest
priceUsed *= (1 - atomicExchangeFee)                   // e.g. 30 bps
```

This means the *effective* sETH -> sUSD rate is bounded by *both*:

1. The Chainlink ETH/USD aggregator (currently `0x5f4e...`).
2. A Curve TWAP — historically the `sETH/ETH` Curve pool combined with
   `ETH/USDC` Uniswap v3 TWAP. The Synthetix system reads these and clamps to
   the worse side from the trader's perspective.

When the **secondary venue (Uniswap)** runs *ahead* of Chainlink — i.e. Uniswap
prices ETH below the Chainlink mid because of a fresh sell-off that hasn't
propagated to the on-chain feed yet — a tradeable wedge opens: atomic
`sETH -> sUSD` settles at the *higher* (Chainlink-anchored) price, while
buying sETH from the open market (WETH -> sETH on Curve sETH/ETH) costs the
*lower* (spot) price. The PoC harvests this delta.

## Why it composes

This is the canonical Synthetix mechanism arb: the atomic exchanger is a
captive on-chain market maker that *always* quotes off Chainlink (subject to
a Curve clamp). Whenever real-world price moves faster than Chainlink updates,
the atomic exchanger is stale and pays out at the wrong price. Five primitives
chain in one tx:

1. **Balancer Vault flashloan** (0 fee on WETH at current gov parameters) —
   provides the WETH inventory.
2. **Curve sETH/ETH pool** (`0xc5424B857f758E906013F3555Dad202e4bdB4567`) —
   converts WETH to sETH on the open market.
3. **Synthetix Atomic Exchange** (Exchanger looked up via
   `AddressResolver.getAddress("Exchanger")` on the canonical resolver at
   `0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83`) — converts sETH to sUSD at
   the dual-oracle clamped price.
4. **Curve sUSD/3pool** (`0xA5407eAE9Ba41422680e2e00537571bcC53efBfD`) —
   converts sUSD to USDC.
5. **Uniswap v3 USDC/WETH 0.05% pool** — converts USDC back to WETH to repay
   the flashloan.

Profit is `(Chainlink_ETH_USD * (1 - atomicFee))` against the cumulative cost
of the three open-market legs (Curve sETH/ETH + Curve sUSD/3pool + Uni v3 USDC
/WETH), all bounded by the Balancer flashloan zero fee.

## Preconditions

- Mainnet fork at a block where Synthetix `exchangeAtomically` still routes
  for the sETH <-> sUSD pair. We pin `17_500_000` (June 2023) where this is
  documented to have been live.
- `AddressResolver.getAddress("Exchanger")` returns a non-zero address.
- The atomic exchange fee rate (`SystemSettings.atomicExchangeFeeRate(sETH)`)
  is < 100 bps.
- `atomicMaxVolumePerBlock()` >= `notional / spotPriceUsd` (otherwise the call
  reverts with `ATOMIC_MAX_VOLUME_EXCEEDED`).

## Strategy steps

1. Fork at `FORK_BLOCK = 17_500_000`.
2. Look up the Exchanger and the Synthetix proxy from the AddressResolver.
3. Balancer flashloan `FLASH_WETH = 100 WETH`.
4. `WETH -> sETH` via Curve sETH/ETH pool (index 0 = ETH sentinel, 1 = sETH).
   - Unwrap WETH to ETH first.
5. `sETH -> sUSD` via Synthetix `exchangeAtomically`.
6. `sUSD -> USDC` via Curve sUSD/3pool (i=0 sUSD -> j=2 USDC).
7. `USDC -> WETH` via Uniswap v3 `0x88e6...5640` USDC/WETH 0.05% pool.
8. Repay `100 WETH` to Balancer. Residual is profit.

If at the pinned block the atomic exchanger reverts (e.g. the pair is gated
off, the fee exceeds the spread, the volume cap is exhausted), the PoC
**logs the failure mode and returns** rather than asserting — this preserves
the test as a research probe even on blocks where the mechanism is dormant.

## PnL math

Let:

- `P_cl`   = Chainlink ETH/USD price at block.
- `P_uni`  = Uniswap v3 ETH/USDC mid at block.
- `f_atom` = atomic exchange fee (bps).
- `f_curve_seth` = Curve sETH/ETH slippage on `WETH -> sETH`.
- `f_curve_susd` = Curve sUSD/3pool slippage on `sUSD -> USDC`.
- `f_uni`  = Uni v3 0.05% fee + slippage on `USDC -> WETH`.

Then for a `N` WETH notional:

```
sETH_out  = N * (1 - f_curve_seth)
sUSD_out  = sETH_out * P_cl * (1 - f_atom)
USDC_out  = sUSD_out * (1 - f_curve_susd)
WETH_back = USDC_out / P_uni * (1 - f_uni)
PnL_WETH  = WETH_back - N
```

Substituting:

```
PnL_WETH / N = (1 - f_curve_seth) * (P_cl / P_uni) * (1 - f_atom) *
               (1 - f_curve_susd) * (1 - f_uni) - 1
```

The trade is profitable iff `(P_cl / P_uni) > 1 / [(1 - f_atom) *
(1 - f_curve_*) * (1 - f_uni)]`. With `f_atom = 30 bp`, three 5-bp slippage
legs and 5-bp Uni fee, the break-even drift is ~`50 bp` (Chainlink trading
0.5% richer than Uniswap on ETH/USD). Such drifts happen routinely during
fast moves but the *direction* is unpredictable, so a production runner must
also implement the mirror trade (`USDC -> sUSD -> sETH -> WETH` via the
inverse path).

## Block pinned

`17_500_000` — early June 2023. Chosen because:

- Atomic exchange was live and documented as routing meaningful volume.
- Curve sETH/ETH pool had non-trivial liquidity (>10k ETH).
- Curve sUSD/3pool had >50M TVL.
- ETH price ~$1,900, so a 100 WETH probe is well within volume caps.

If the fork's Exchanger configuration has the atomic pair disabled for sETH at
this block, the PoC logs the revert reason and exits cleanly (`no_arb`).

## Risks

- **Atomic exchange capped or disabled.** SIPs frequently tighten which
  currency keys are atomic-eligible. Production must read
  `SystemSettings.atomicExchangeFeeRate(currencyKey)` and bail on `0` (means
  disabled) or fees > 100 bp.
- **Volume cap per block.** `atomicMaxVolumePerBlock()` is denominated in
  sUSD; a single sandwich tx can be reverted by a competing arber that has
  consumed the cap earlier in the same block.
- **Curve sETH/ETH pool drain.** Historical Synthetix exits depleted the pool
  on multiple occasions, making the WETH -> sETH leg expensive.
- **Settlement on the Synthetix side.** Atomic exchange skips the 5-minute
  fee-reclamation, but a `settle()` call from a malicious actor before the
  Curve sUSD swap could revert if the rate moved meaningfully (paranoid mode
  only; ordinary atomic exchanges do not require a follow-up settle).
- **Direction risk.** Chainlink trailing Uniswap by 50bp can occur in *either*
  direction; running the wrong leg loses the full spread plus fees. PoC
  computes both directions and picks the profitable one (or bails).

## Result
Status: theoretical-historical-replay
Expected PnL: ~(drift_bps - 50bp) × notional on 100 WETH per event (~$1,900 net at 100 bp drift on ETH=$1,900; condition-dependent, gated on atomic-pair live)

Atomic 5-leg sandwich monetizing Chainlink-Uniswap ETH/USD price drift through
Synthetix's atomic exchanger. PoC is gated on the atomic pair being live at
the fork block; on dormant blocks it surfaces `no_arb` instead of asserting.
On live blocks, expected gross PnL is `notional * |drift_bps - 50bp|`.
