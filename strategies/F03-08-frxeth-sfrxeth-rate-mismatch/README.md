# F03-08: frxETH/sfrxETH ERC-4626 rate-provider mismatch arb

## Mechanism
Frax Ether has a **two-token** model:

- `frxETH` (`0x5E8422345238F34275888049021821E8E08CAa1f`) — non-rebasing
  1:1 with ETH (minted by `FrxETHMinter.submit{value:N}()`).
- `sfrxETH` (`0xac3E018457B222d93114458476f3E3416Abbe38F`) — ERC-4626 vault
  over frxETH; `pricePerShare()` (a.k.a. `convertToAssets(1e18)`) appreciates
  as Frax routes 100% of staking rewards into it.

Several AMMs price frxETH or sfrxETH against WETH/ETH:

- **Curve frxETH/ETH** plain pool (`0xa1F8A6807c402E4A15ef4EBa36528A3FED24E577`) —
  coins[0] = ETH (native), coins[1] = frxETH. Should quote ~1:1; sometimes
  drifts a few bps when Frax incentive flows or sfrxETH redemptions hit.
- **Curve sfrxETH/frxETH** (less common) and **Curve frxETH/sfrxETH on FraxBP**.
- **Balancer ECLP frxETH/wETH** (`pool id 0xb204...`) — concentrated stable.
- **sfrxETH ERC-4626 deposit/withdraw** is permissionless and atomic at
  the current `pricePerShare` (no queue).

The arb plays the **two independent reference rates**:

1. `Curve frxETH/ETH` market spot.
2. `sfrxETH.convertToShares(1e18)` (i.e. the ERC-4626 share rate; frxETH
   per sfrxETH = `pricePerShare / 1e18`).

When Curve's frxETH/ETH pool drifts to e.g. `0.998 frxETH per ETH` (frxETH
slightly *premium*, meaning 1 ETH < 1 frxETH on the AMM) and `pricePerShare`
is on rate, the round-trip:

```
1 ETH -> Curve -> 0.998 frxETH -> sfrxETH.deposit -> N sfrxETH
sfrxETH redeemed at sfrxETH.previewRedeem -> frxETH -> Curve -> ETH
```

contains a discoverable edge whenever any one of the four reference legs
drifts. The most common practical case: frxETH/ETH on Curve quotes at
*premium to peg* (frxETH worth more than 1 ETH on AMM) right after a
large `FrxETHMinter.submit` deposit pushes the Curve pool toward
frxETH-heavy and *no one has yet sold the freshly minted frxETH on Curve*.

The strategy steps:

```
WETH flash (Balancer V2, 0 fee)
  -> ETH via WETH.withdraw
  -> mint frxETH 1:1 via FrxETHMinter.submit{value: N}()           [Frax]
  -> deposit frxETH into sfrxETH (ERC-4626)                         [Frax]
  -> redeem sfrxETH back to frxETH (round-trip — only for the rate snapshot)
  -> sell frxETH on Curve frxETH/ETH for ETH                        [Curve]
  -> wrap, repay flash
```

If the Curve frxETH/ETH spot is *cheaper* than the FrxETHMinter mint
rate (1:1), the trade flips direction: buy frxETH cheap on Curve, mint
sfrxETH; the sfrxETH NAV (priced by `pricePerShare`) exceeds the ETH
acquisition cost.

This composes **Frax FrxETHMinter** + **sfrxETH ERC-4626 vault** + **Curve
frxETH/ETH stableswap** + **Balancer V2 flashloan** — four mechanisms across
three protocols (Frax, Curve, Balancer).

## Why it composes
- **Flashloan**: Balancer V2 Vault, 0 fee — required because the edge is
  small (typically 5-30 bps) and bonded to large notional.
- **Frax dual-asset rate**: `FrxETHMinter.submit` returns exactly 1 frxETH
  per 1 ETH at no fee. `sfrxETH.deposit` mints shares at the live PPS.
  Both are deterministic and free.
- **Curve frxETH/ETH pool**: market-driven, drifts asynchronously vs the
  protocol-internal 1:1 mint rate. Curve fee ~4 bps.
- **sfrxETH NAV**: `pricePerShare` updates on every reward sync; if Curve
  hasn't caught up to a fresh sync, there's a stale-rate edge.

## Preconditions
- `FORK_BLOCK = 21_300_000` (≈ late November 2024). Reasons:
  - sfrxETH PPS at this block ~1.084.
  - Curve frxETH/ETH pool has ~3-7k ETH side depth.
  - Frax rewards cycle near `lastSync` — fresh rate snapped in.
  - Historical observation: Curve frxETH spot drifts ±10 bps on rewards
    cycle boundaries.
- FrxETHMinter accepts deposits (no cap reached in 2024).
- `sfrxETH.maxDeposit(receiver) == type(uint256).max` (uncapped ERC-4626).

## Strategy steps
1. Balancer V2 Vault `flashLoan` 1000 WETH.
2. `receiveFlashLoan`:
   a. `IWETH.withdraw(N)` -> N ETH.
   b. `FrxETHMinter.submit{value: N}()` -> N frxETH (1:1, no fee).
   c. Approve frxETH to sfrxETH vault; `sfrxETH.deposit(N, address(this))`
      -> shares (NAV-protected by ERC-4626).
   d. (Mark-to-market via `PriceOracle.priceUSD(SFRXETH)` which uses PPS;
       OR continue the round-trip):
   e. `sfrxETH.redeem(shares, this, this)` -> frxETH back (same NAV).
   f. Approve frxETH to Curve frxETH/ETH; `exchange(1, 0, frxETHAmt, minOut)`
      -> ETH out. If Curve spot is premium to peg, you receive *more* ETH
      than the original N you mints from (net gain).
   g. Wrap ETH -> WETH, repay flash.
3. The mark-to-market path (steps c -> end) plus a separate Curve sell
   captures the dual edge: (i) sfrxETH PPS appreciation between steps c
   and e and (ii) Curve frxETH/ETH spot vs 1:1 mint rate.

## PnL math
Let:
- `P_C` = Curve ETH-per-frxETH spot. If `P_C > 1`, Curve overprices frxETH
  vs the 1:1 minter rate ⇒ buy from minter, sell on Curve.
- `f_C` = Curve fee ≈ 4 bps.
- `PPS` = `sfrxETH.pricePerShare()` (≈ 1.084 at FORK_BLOCK).

Pure Curve-vs-Minter arb (skipping sfrxETH leg):
- Mint frxETH: N ETH -> N frxETH (free).
- Curve sell: N frxETH -> `N * P_C * (1 - f_C)` ETH.
- Net per ETH = `P_C * (1 - f_C) - 1`.

For `P_C = 1.0020, f_C = 0.0004`: edge = `1.002 * 0.9996 - 1 ≈ 0.00160`
⇒ **16 bps**.

For `N = 1000 WETH`:
- Gross spread = `1000 * 0.0020 = 2.0 WETH`
- Curve fee   = `1000 * 0.0004 = 0.4 WETH`
- Net pre-gas ≈ `1.6 WETH ≈ $5,120 @ $3,200/ETH`
- Gas ≈ 350k @ 25 gwei = 0.009 WETH ≈ $29
- **Net ≈ +$5,090 per 1000 WETH** at 20 bps Curve premium

If the route adds the sfrxETH deposit/redeem leg, both should net to zero
(ERC-4626 is symmetric inside one block) — the value of including it is
purely as a *NAV check* (revert if PPS moves down mid-block, which would
indicate a vault accounting bug). For yield-capture cases where the sync
*does* happen mid-block (e.g. the trade triggers `syncRewards`), there
can be a sub-bp PPS jump captured.

## Block pinned
- `FORK_BLOCK = 21_300_000` (Nov 2024). Cross-check at the fork block:
  - `Curve frxETH/ETH .get_dy(1, 0, 1e18)` should return slightly more
    than 1e18 if frxETH is at premium (the desired case for the arb).
  - `sfrxETH.pricePerShare()` should be > 1.08.
- Reference Frax community posts on frxETH peg dynamics:
  Curve forum threads on frxETH/ETH balance, late-2024 era.

## Risks
- **Curve premium reversal**: if frxETH/ETH on Curve is at *discount*
  (the more common state), the trade direction inverts: buy frxETH on
  Curve, hold or stake into sfrxETH. PoC checks `get_dy` direction and
  reverts (`MIN_SPREAD_BPS` gate) if the spread is too thin.
- **Frax minter capped**: if `FrxETHMinter` is paused or capped, the leg
  cannot fire. Mitigation: substitute with a direct Curve buy of frxETH.
- **sfrxETH reward sync front-run**: large flows can trigger
  `syncRewards()` and bump PPS upward. PoC reads PPS pre- and post-trade
  and reports the delta.
- **Self-impact on Curve**: 1000 ETH on a 5k ETH side moves the price
  ~10 bps. Net edge after impact is ~6-10 bps.

## Result
- Status: **theoretical-mechanism** (Curve frxETH premium events are
  observable historically; specific block PnL depends on RPC archive).
- PnL range: **+$500 to +$5,000 per 1000 WETH** at 5-20 bps Curve drift.
- 3+ protocols stacked: Balancer (flash) + Frax (Minter + sfrxETH 4626) +
  Curve (frxETH/ETH stableswap). **4 mechanisms across 3 protocols.**
