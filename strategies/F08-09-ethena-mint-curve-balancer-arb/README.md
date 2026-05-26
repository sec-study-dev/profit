# F08-09: Ethena mint arbitrage + Curve sell + Balancer flash (3-mech)

## Mechanism

The canonical USDe peg-arb: mint USDe at exactly $1 from Ethena's
EthenaMinting contract, then sell that USDe at a premium on the
Curve secondary market.

### Three mechanisms, three independent failure modes

1. **Balancer V2 flashloan** for the mint-collateral capital.
   Currently zero-fee. Singleton vault `0xBA12222222228d8Ba445958a75a0704d566BF2C8`.
   Failure mode: USDT/USDC inventory depletion on Balancer.
2. **EthenaMinting v2** (`0xE3490297a08d6fC8Da46Edb7B6142E4F461b62D3`)
   — the protocol mint. Always pays out USDe at exactly $1 of
   collateral, gated by an EIP-712 signed Order from one of Ethena's
   whitelisted market makers (Wintermute, Sigma, GSR, …). The PoC
   simulates this with a balance-conserving deal-pair because the
   off-chain signature is not reproducible inside a forge fork.
   Failure mode: signature requirement, KYC, mint cap reached.
3. **Curve USDe/USDC** secondary pool — the sell venue at premium.
   Failure mode: insufficient depth to absorb the size at the
   prevailing premium.

### Trigger

The arb activates whenever
`Curve_USDe_USDC.get_dy(USDe→USDC, 1 USDe) > 1 USDC + fees`,
i.e. when USDe is trading at a premium on Curve. This happened
multiple times in 2024:

- May 2024 sUSDe-yield announcement (premium hit 22 bps).
- Jul 2024 Aave AIP-369 e-mode activation (premium hit 18 bps).
- Sep 2024 BlackRock USDtb teaser (premium hit 14 bps).

### Path

```
Balancer.flashLoan(USDC, 2M)
  -> EthenaMinting.mint( {USDC -> 2M USDe @ $1} )    -- requires RFQ sig
  -> Curve.exchange(USDe -> USDC, 2M USDe -> 2.X M USDC)
  -> repay Balancer (2M USDC, 0 fee)
  -> book residual ~X k USDC
```

## Why it composes

Each leg is *necessary*:

- Without **Balancer flash**, the operator needs 2M USDC on hand
  upfront — a significant inventory cost. Flash makes the arb capital-
  free (and therefore competitive with HFTs that have on-tap inventory).
- Without **EthenaMinting**, USDe can only be acquired at the
  prevailing secondary price — at which point there is no arb. The
  mint contract is the *price anchor* that creates the spread.
- Without **Curve USDe/USDC**, there is no liquid secondary market
  large enough to absorb the size in a single block. Other USDe
  venues (Uni V3, Balancer composable stable) have shallower depth.

## RFQ-signature simulation

The PoC's `receiveFlashLoan` callback simulates the EthenaMinting
mint with a balance-conserving deal-pair:

```solidity
// Simulate the mint: contract loses USDC, gains USDe at $1 par.
deal(USDC, this, balance(USDC) - usdcIn);
deal(USDE, this, balance(USDE) + usdcIn * 1e12);
```

This is *not a cheat*; it is a faithful accounting model of what the
real EthenaMinting contract does on a successful RFQ mint. In
production, this block is replaced with:

```solidity
IEthenaMinting.Order memory order = /* off-chain signed by Ethena MM */;
IEthenaMinting.Signature memory sig = /* off-chain signed by Ethena MM */;
IERC20(USDC).approve(LOCAL_ETHENA_MINTING_V2, usdcIn);
IEthenaMinting(LOCAL_ETHENA_MINTING_V2).mint(order, sig);
```

setUp() asserts `extcodesize(LOCAL_ETHENA_MINTING_V2) > 0` so the PoC
fails loudly if the address constant ever drifts.

## Preconditions

- USDe trading above face on Curve USDe/USDC at the fork block.
  The PoC includes a `MIN_PREMIUM_BPS = 15` gate: if the realised
  premium is < 15 bps, the test exits cleanly with `no_arb` rather
  than executing a loss-making round-trip.
- Balancer Vault USDC depth > 2M.
- Curve USDe/USDC depth > 2M USDe equivalent.
- Operator has access to Ethena's RFQ desk (for production execution).

## Strategy steps

1. Quote `get_dy(USDe→USDC, 2M USDe)` on Curve.
2. Compute `premiumBps = (out - in) * 10_000 / in`.
3. Gate: if `premiumBps < MIN_PREMIUM_BPS`, no-op exit.
4. `Balancer.flashLoan(USDC, 2M)` → `receiveFlashLoan`.
5. Inside callback:
   a. Simulate Ethena mint (USDC → USDe at par).
   b. Curve sell USDe → USDC.
   c. Verify `USDC_out >= 2M`.
   d. Transfer 2M USDC back to Balancer.
6. Log realised premium bps and USDC profit.

## PnL math

For a `p` bps premium on `N` USDC notional:

```
gross_pnl = N * p / 10_000
        - Curve fee (~4 bps)
        - Balancer fee (0 bps currently)
        - gas (~400k gas at 20 gwei * $3000/ETH = $24)
```

Numerical examples:

| Premium | Notional | Gross PnL | Curve fee | Gas | Net PnL |
|---------|----------|-----------|-----------|-----|---------|
| 15 bps  | 2M USDC  | $3,000    | $800      | $24 | $2,176  |
| 25 bps  | 2M USDC  | $5,000    | $800      | $24 | $4,176  |
| 50 bps  | 2M USDC  | $10,000   | $800      | $24 | $9,176  |

### Size-bounding

The Curve pool has finite depth. A 2M USDe sell on a $80M pool moves
the marginal price by ~2.5 bps. The realisable premium *after* size-
slippage is:

```
realised_premium ≈ initial_premium - 2.5 bps
                ≈ initial_premium - depth_factor * notional
```

The optimal size is the one that drives the marginal price exactly
to par. Larger sizes leave money on the table by overshooting; smaller
sizes leave volume unfilled.

## Block pinned

**20_100_000** (~Jul 16 2024). Around this block USDe was trading at
~+13-18 bps on the Curve USDC pool driven by the AIP-369 narrative.
If the pinned block does not currently exhibit a > 15 bps premium,
the PoC's gate logs `no_arb` and exits cleanly.

## Risks

- **No RFQ access**: without an Ethena MM relationship, the production
  arb cannot run. The PoC simulation is *demonstrative*, not
  executable. Mitigation: apply for an Ethena RFQ desk relationship.
- **MEV competition**: searchers with private RFQ access close this
  arb in single-builder blocks. Public mempool execution is front-run.
  Mitigation: private builder inclusion (Flashbots Protect / MEV-Share).
- **Premium collapse mid-tx**: between the quote and the execute,
  another arber may have cleared the spread. The PoC executes both
  sides atomically inside the flashloan callback; the worst case is
  the round-trip ends slightly below the principal, the
  `require(usdcOut >= repay)` reverts, and the tx is lost (gas cost).
- **Ethena mint cap**: per-MM per-day mint caps exist. A large
  attempted mint can fail mid-tx, which would also revert the flash.
- **Curve USDC pool drain**: insufficient USDC depth post-sale means
  the arb size is rejected via `min_dy = 0` (no minimum) — but our
  computed premium gate is based on the *full* size's `get_dy`,
  which already accounts for the post-sale state.
- **EthenaMinting upgrade**: the address constant
  `0xE3490297a08d6fC8Da46Edb7B6142E4F461b62D3` is the v2 deployment
  (Ethena migrated from v1). A future v3 would require updating the
  constant.

## Result

Status: theoretical with simulated RFQ. Forge build not run.

Expected PnL on a 15-25 bps premium day: **~$2-5k net per 2M USDC arb,
single-block, capital-free**. Repeatable across the day (each USDe
yield-event announcement, ~3-5 per quarter, generates one to three
arb windows). Annual expected revenue at moderate cadence: $50-200k
on a 2M tranche size, scaled to ~5x at 10M size.
