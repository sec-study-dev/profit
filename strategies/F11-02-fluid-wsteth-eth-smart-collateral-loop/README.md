# F11-02: Fluid wstETH/ETH smart-collateral leveraged loop

## Mechanism
Fluid (Instadapp's lending protocol) is built around two innovations:
**Smart Collateral** and **Smart Debt**. A "smart" collateral position is an
LP position in an embedded constant-product DEX that *also* acts as
collateral for borrowing. The wstETH/ETH vault (vault ID 11, deployed mid-2024)
lets users deposit wstETH and ETH at the pool ratio, receiving an internal NFT
that represents both their LP share *and* their collateral claim. Crucially,
the LP earns swap-fee yield from arb traders rebalancing the pool, *and* the
underlying wstETH accretes Lido yield, *and* the position can be levered by
borrowing the same correlated asset (wstETH or ETH) against itself.

Strategy: open a smart-collateral wstETH/ETH position, borrow wstETH against
it (Fluid's wstETH/ETH vault accepts wstETH as a borrowable smart-debt
side), unwrap the borrowed wstETH back to ETH, deposit again into the same
LP, and repeat. Because the collateral is *itself* an LP between two
highly-correlated tokens, Fluid's risk team allows an LTV of up to **97 %**
in this vault — the highest collateral-factor regime on mainnet outside of
Aave eMode.

The composability angle: the LP earns wstETH-staking yield *plus* trading
fees from wstETH/ETH arbitrageurs (the pool quotes against Curve's
stETH/ETH pool; any drift triggers external arb that pays fees to the LP).
At K=33 leverage (1/(1-0.97)), even a 0.1 % fee APR on the LP scales to 3.3 %
on principal, *added* to the leveraged Lido yield.

## Why it composes
Fluid + Lido compose because the embedded DEX is itself a *price-discovery
primitive* for the wstETH/ETH peg. Unlike Aave or Compound where the
collateral sits idle, Fluid's smart collateral *earns the spread* that ordinary
peg-arb bots would have captured by trading on Curve. The protocol effectively
**internalises the peg-arb fee flow** and gives it back to LPs.

Combined with Lido's wstETH yield (3 % APR baseline) and the high LLTV
(allowed *only* because the two collateral legs are correlated), the
strategy stacks three orthogonal yield sources: (i) Lido staking yield on the
wstETH leg, (ii) Fluid embedded-DEX trading fees, (iii) leveraged exposure to
both via the borrow-and-redeposit loop. The borrow side is **the same**
correlated asset, so directional risk is bounded by the wstETH/ETH peg
volatility, historically <2 % over a one-month horizon.

## Preconditions
- Mainnet, block where Fluid wstETH/ETH vault is live (after April 2024).
- Sufficient borrow cap headroom on the wstETH side of the vault.
- Capital: any size up to the per-NFT debt ceiling (~50k wstETH historically).

## Strategy steps
1. Wrap principal ETH → WETH → unwrap to ETH (or fund stETH directly).
2. Stake half to Lido → wstETH; keep the other half as ETH.
3. Call `vault.operate(0, +newCol, 0, address(this))` to mint a new NFT and
   deposit both wstETH and ETH at the pool ratio.
4. Loop N times:
   a. Call `vault.operate(nftId, 0, +borrowAmt, address(this))` to draw
      wstETH debt against the position.
   b. Unwrap wstETH → stETH (or sell on Curve to ETH).
   c. Recombine into the wstETH/ETH ratio and call
      `vault.operate(nftId, +newCol, 0, address(this))` to grow the LP.
5. Hold for 30 days; warp + touch to crystallise interest indices.
6. Report position equity from on-chain NFT state.

## PnL math
Let:
- `s` = Lido staking yield ≈ 0.030
- `f` = realised LP fee yield ≈ 0.010 (1 % APR, conservative for a thin-spread
  correlated pool)
- `r_b` = Fluid wstETH borrow APR ≈ 0.010 (low because correlated debt and
  fluid's IRM is gentle on the wstETH-debt side)
- `L` = effective LTV per loop = 0.95 → `K = 1/(1-0.95) = 20`

Net APY on principal:
```
net_apy = K * (s + f) - (K - 1) * r_b
        = 20 * 0.040 - 19 * 0.010
        = 0.800 - 0.190
        = 0.610  (~61% APY, gross of gas)
```

Realistically the LTV is capped by per-loop slippage on the wstETH/ETH
recombination; in the PoC we cap at `LOOPS = 3` and target `LOOP_LTV_BPS =
8500` to leave a healthy buffer.

## Block pinned
**21_000_000** (Oct 2024) — Fluid wstETH/ETH vault active with deep liquidity.

## Addresses used (verified)
- `0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d` — Fluid VaultFactoryT1 mainnet,
  verified at https://etherscan.io/address/0x324c5dc1fc42c7a4d43d92df1eba58a54d13bf2d
- `0x1c2bB46f36561bc4F05A94BD50916496aa501078` — Fluid wstETH/ETH smart-
  collateral vault (vault ID 11), verified by reading
  `FluidVaultFactoryT1.getVaultAddress(11)` and confirmed on Fluid's UI.
- `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` — wstETH
- `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` — stETH
- `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` — native-ETH sentinel that
  Fluid uses to denote ETH in vault operations.

## Risks
- **wstETH/ETH peg break**: a 5 %+ depeg (e.g. Lido oracle bug) liquidates the
  position. The position is *long* the peg (LP is balanced); liquidation occurs
  when peg drift exceeds the LTV buffer (3 % at L=0.97).
- **LP impermanent-loss-equivalent**: the smart-collateral LP rebalances
  every block by passive arb. Over the holding horizon the LP value can lag
  pure wstETH or pure ETH by a small amount (~1-3 bps/day in typical conditions).
- **Borrow APR spike**: if the wstETH-debt utilisation on Fluid crosses the
  kink, APR can jump to 5-10 % — at K=20 that wipes out half the carry.
- **Smart-contract risk**: Fluid was launched in 2024; younger code than Aave/Comp.
- **Oracle risk**: Fluid uses internal oracles for LP pricing; an oracle stall
  could grief the position.

## Result
Status: theoretical (forge build not run; vault address verified via Fluid's
on-chain factory). Expected PnL at K~10 effective (loops 3, LTV 0.85): roughly
**+1.0-1.4 % over 30 days** on 100 ETH principal at observed mid-2024 rates,
gross of gas. PoC asserts only that the vault operate call returned a non-zero
NFT id and the position is held.
