# F13-05: UniV3 wstETH/WETH 0.01% JIT (just-in-time) LP backrun

## Mechanism

A **single-block** concentrated-liquidity provision pattern that
exploits the fact that UniV3 pays swap fees pro-rata to *in-range*
liquidity at the moment a swap crosses the tick:

1. **Observation step (off-chain)**: a searcher watches the mempool for
   a large pending swap on the wstETH/WETH 0.01% pool
   (`0x109830a3b59ddabe21ee0b1c34dd4a59e3f2ac81`, fee tier `100`).
2. **JIT mint**: in the same block as (or one block before) the victim
   swap, the searcher calls `pool.mint()` with a tight band straddling
   the active tick. With ~5e22 of injected liquidity vs typical
   in-range resting liquidity of ~5e21 (10-20x smaller), the JIT
   position captures roughly **>80% of the fee on the victim swap**.
3. **Victim swap executes**: the swap routes through the JIT-dominated
   tick range. Fees accrue almost entirely to the JIT position.
4. **JIT burn + collect**: in the same atomic transaction (or
   immediately after the victim's tx in the same block), burn and
   collect to pull principal + earned fees.

The PoC simulates the victim by routing a 50-WETH swap ourselves; in
production the searcher backruns the actual victim using flashbots
bundle ordering.

## Why it composes (within F13)

- Two **UniV3** mechanics on the same pool, same block: LP
  (mint/burn/collect) + swap (ExactInputSingle through Router). This
  pattern is **distinct from F13-04** (passive narrow-range LP held
  for fee accrual over many blocks) because there is no time-in-range
  exposure — the position is opened and closed in one atomic
  transaction so impermanent loss is zero except for swap-induced tick
  movement during the JIT'd swap itself.
- Distinct from F13-01 (arb between Balancer rate-lag and UniV3) — no
  rate-provider dependency.

Mechanism count: **2** (UniV3 LP + UniV3 swap).

## Preconditions

- wstETH and WETH funded on the test contract (the test funds both).
- Pending large swap (we simulate it in-test).
- Sufficient liquidity-dominance: JIT_LIQUIDITY (5e22) should be
  ≥5x the resting liquidity at the chosen tick band.

## Strategy steps

1. Fund WETH (250 ETH-equiv: 200 for the JIT mint + 50 for the
   simulated victim swap) and wstETH (200 ETH-equiv).
2. Read `slot0` for current tick. Pick `[tick-1, tick+2]` band
   (3-tick-wide, asymmetric to stay in range as the price moves
   upward with the WETH-in swap).
3. `pool.mint(this, tickLower, tickUpper, 5e22, "")`.
4. Execute the (simulated) victim's swap: `WETH → wstETH` 50 ETH via
   the SwapRouter.
5. `pool.burn(tickLower, tickUpper, 5e22)` to settle owed amounts.
6. `pool.collect(this, ..., max, max)` to pull principal + fees.
7. Report PnL.

## PnL math (per-event, not annualised)

A 50-WETH swap through a 1bp pool generates `50 * 1e-4 = 0.005 WETH`
in total LP fees ≈ **$16 @ ETH=$3,200**. If the JIT position
captures 80% of in-range liquidity, the JIT take is **~$13**.

Costs:
- Gas: ~280k gas (mint + swap-callback + burn + collect) at 25 gwei =
  0.007 ETH ≈ **$22**. At low gas (3 gwei via flashbots bundle on a
  quiet block) ≈ **$2.70**.
- Slippage on the mint (negligible since we don't trade).
- Lost opportunity cost of the JIT capital for the block: negligible
  ($16 yield on $640k capital * 1/2628000 ≈ $0).

Net per event:
- High gas: **+$13 - $22 = -$9** (negative; need bigger swap).
- Low gas: **+$13 - $3 = +$10**.

This strategy is therefore **only profitable in flashbots-private
bundles** during quiet gas regimes, and against swaps ≥30 WETH.

## Block pinned

- `FORK_BLOCK = 20_900_000` (Oct 2024). Pool has $200M TVL and the
  current tick is highly active.

## Risks

- **JIT competition**: other searchers also JIT the same big swaps.
  Liquidity-dominance shrinks; capture rate falls below 50%.
- **Victim cancels / pays priority fee**: if the victim's tx is
  reordered out of the block, the JIT mint is stuck and earns nothing
  (the burn+collect still works but the LP gets only one block of
  organic flow).
- **Mempool reveal**: backruns rely on public mempool tx; private
  order flow (CoW, flashbots private) makes the source dry.
- **Sandwich detection**: protocols / aggregators that detect JIT
  griefing may route through CoW or other dark pools.

## Result

- Status: **mechanically demonstrated**. PoC mints JIT liquidity,
  executes a 50-WETH swap through the JIT band, then burns+collects.
  Collected amounts include the captured swap fee.
- Expected per-event: **+$10 to +$13 net @ ETH=$3,200, low gas**.
