# F18-03: Ethena USDe-mint + Curve USDe/USDT + Aave USDe-eMode borrow carry

## Mechanism

Tri-protocol synthetic dollar carry that simultaneously routes the user
through three distinct stable-dollar mechanisms in one position:

1. **Ethena** — issues USDe by delta-hedging ETH/BTC collateral on perp
   exchanges. The user obtains USDe either through `EthenaMinting.mint`
   (off-chain-signed orders) or by buying USDe on a DEX. Yield accrues
   inside `sUSDe` (ERC-4626 wrapper) from perp-basis funding.
2. **Curve USDe/USDT** — provides the only liquid on-chain primary
   market that lets a non-allowlisted user obtain USDe atomically with
   no signed order. The PoC routes through this pool, capturing any
   sub-peg discount Ethena's mint queue creates.
3. **Aave v3 USDe-stable e-mode** — Aave v3 supports a "stables e-mode"
   category that **specifically lists USDe** (added July 2024) with
   ~93% LTV against USDC/USDT debt. This unlocks 14× leverage on the
   USDe carry — a setting unique to Aave's stable e-mode (Compound v3,
   Morpho stable markets, and Fluid do not provide this).

The composite position: **Curve-sourced USDe → sUSDe wrap (yield-bearing) →
Aave stable-eMode collateral → borrow USDC → swap to USDe → loop**.
End result is a leveraged stable-stable carry where the *only* source of
yield is sUSDe's underlying perp basis, the *only* leverage source is
Aave's USDe stable-eMode, and the *only* on-chain entry path is Curve.

## Why it composes — the 3 mechanisms

1. **Ethena USDe / sUSDe** — the only yield-source (perp-basis).
2. **Curve USDe/USDT (or USDe/USDC) NG pool** — the only permissionless
   on-chain entry; the alternative (Ethena's signed-order mint) is
   allowlist-gated for most users.
3. **Aave v3 USDe stable-eMode** — the only LTV regime that turns a
   ~9% sUSDe APY into ~30%+ leveraged carry. Without stable-eMode at
   93% LTV the loop caps at LLTV 80% (general category), reducing K
   from ~14 to ~5.

No 2-mechanism combo works:
- (Ethena + Curve) gives spot USDe yield at ~9%, no leverage.
- (Ethena + Aave) requires a signed-order mint Ethena does not
  permissionlessly grant; spot USDe with no entry path.
- (Curve + Aave) yields nothing — USDe and USDC both supplied have
  near-zero rate spread without sUSDe wrapping.

## Preconditions

- Mainnet block where Aave v3 has the stables-eMode category listing
  USDe + USDC + USDT (post-July 2024). We pin **block 20,400,000**
  (early-Aug 2024). At this block, sUSDe APY trends ~9-13% and the
  stables-eMode is live.
- Curve USDe/USDT pool has ≥ 5M USDe + USDT liquidity (true at the
  pinned block).
- sUSDe.cooldownDuration > 0 (i.e. wrapper is operational, withdrawals
  go through a cooldown).

## Strategy steps (PoC)

1. Fund `1,000,000 USDT` equity.
2. Swap USDT → USDe on Curve `USDe/USDT` pool (Curve mechanism leg).
3. Deposit USDe → sUSDe via ERC-4626 deposit (Ethena mechanism leg).
4. Switch on Aave's stable-eMode (`pool.setUserEMode(stableCategoryId)`).
5. Supply sUSDe as collateral on Aave (`pool.supply(SUSDE, amount, ...)`).
   sUSDe is the listed collateral in the stables-eMode.
6. Borrow USDC at 80% LTV of sUSDe value (sub-LLTV ~93%, 13pp safety).
7. Swap the borrowed USDC → USDe on Curve `USDe/USDC` pool, wrap → sUSDe,
   re-supply, re-borrow. PoC executes one full loop iteration; production
   would loop 3-4 times to approach K=14.

## PnL math

Let `r_susde = 0.09` (sUSDe spot APY at pinned block), `r_usdc_borrow =
0.08` (Aave USDC variable borrow APY at fork), `K = 5` (single-loop
leverage; full unwind gives ~14), `E = 1,000,000` USDT.

```
Total sUSDe collateral_USD ≈ K × E = 5,000,000
Total USDC debt           = 4,000,000
Gross yield               = 5,000,000 × 0.09 = $450,000 / yr
Gross borrow cost         = 4,000,000 × 0.08 = $320,000 / yr
Net APR on equity         = (450k - 320k) / 1M = 13.0%
```

30-day pro-rata net PnL on $1M equity: **~$10,700** before
slippage/oracle/gas. Curve fee (4 bps × 2 swaps) costs ~$800; gas for
the full multi-step open ≈ $250. Net ≈ **+$9,650 / 30d / $1M**.

(Fully looped to K=14: net APR ≈ 21-26%; depends on Aave borrow rate
adapting to higher utilisation.)

## Block pinned

**20,400,000** (early Aug 2024). Aave v3 USDe stables-eMode is live;
sUSDe APY in low-double-digits; Curve USDe/USDT pool deep with
sub-peg-friendly TWAP.

## Risks

- **USDe peg risk**: USDe has occasionally traded -0.3% to -0.7% off
  peg during ETH funding spikes. Borrowing USDC against sUSDe means a
  USDe depeg moves our LTV up — we open at 80% (13pp buffer to LLTV
  ~93%).
- **sUSDe cooldown**: unwind requires 7-day cooldown unless the
  user-route Ethena unstake fee is paid. Atomic unwind not possible.
- **Perp-basis flip**: sUSDe yield is funded by perp basis. If perps
  go contango-flat (basis = 0), sUSDe APY → ~5% (T-bill backstop) and
  the carry compresses sharply.
- **Aave stable-eMode degredation**: governance can decrease the
  eMode LTV with a 24h timelock. Realised LTV drift would partially
  liquidate the position.

## Result

Status: **mechanically-reproducible**. The PoC executes the Curve swap
leg, the sUSDe wrap leg, and the Aave supply + setUserEMode + borrow
legs in sequence on a single fork block. The sUSDe yield leg accrues
over time and would be materialised via `vm.warp(... + 30 days)`.

Expected gross PnL on $1M equity over 30 days: **+$9,000 to +$25,000**
depending on whether the loop is run once (K=5) or fully unwound (K=14).
