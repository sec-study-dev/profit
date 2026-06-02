# B13-05: USD1 (WLF) BSC <-> ETH bridge spread

## Family
B13 — Cross-chain bridge LST/stable discount arbs.

## Thesis
World Liberty Financial's **USD1** launched in March 2025 on both BSC and
Ethereum with a LayerZero V2 OFT bridge as the canonical cross-chain path.
Because WLF's distribution mechanics push USD1 onto BSC ahead of liquidity
deepening on PCS (the USD1/USDT pool fee tier 0.05% is still TODO-confirm
but observed shallow at launch), USD1 on BSC has cleared at **15-40 bp**
discounts to peg during inflow spikes, while the OFT bridge mints/burns 1:1.

## Bridge primitive
- **LayerZero V2 OFT** (WLF official bridge).
  - `send(SendParam{dstEid:30101})` atomically burns BSC USD1, delivers ETH
    USD1 once the LZ executor runs (~LZ DVN attestation window).
- **PCS v3 single-pool flash** on `USDT/USDC` (1 bp loan).

## Mechanism count: **2-mechanism** (PCS flash + OFT burn)

## Atomic vs positional
**Positional.** The BSC-side burn is atomic but the ETH-side credit lands
within the LZ window (seconds to minutes). PnL is booked when the burn
lands; the eventual USDT round-trip back to BSC is modelled as a buffer.

## Block pinned
- `FORK_BLOCK = 45_500_000` — placeholder. Re-pin to a USD1 inflow window
  (e.g. post-WLF treasury op, governance unlock). TODO scan DexScreener
  USD1/USDT slot0 history for `< 0.998`.

## PnL math
Let `D` = USD1 discount vs USDT (bp). Flash notional `N` USDT.
- USD1 received from swap: `N * (1 + D/10000)` minus 5 bp PCS fee.
- USD1 burned via OFT.send -> same amount delivered on ETH.
- Flash fee (1 bp): `N * 1 / 10000`.
- LayerZero native gas: ~$0.10.
- WLF bridge tax: estimated 3 bp.
- Net per $500k cycle at 25 bp: ≈ `$1,250 - $50 (flash) - $150 (bridge tax)`
  ≈ **$1,050**.

## Preconditions
- `USD1_OFT_ADAPTER` deployed and exposing OFT V2 `send`/`quoteSend`. TODO
  verify mainnet address.
- USD1/USDT PCS v3 pool exists at 0.05% tier with > 25 bp slot0 discount.
- LZ peer for ETH endpoint id `30101` configured.

## Risks
- **Adapter address unset** in BSC.sol — PoC runs offline-first.
- **Discount snapback** during the swap can erode > 50% of expected PnL;
  mitigate by sizing N ≤ pool TVL / 20.
- **Bridge delivery failure on ETH** leaves the strat short USDT on BSC.
  Mitigated by N <= REPAY_BUFFER.
- **WLF regulatory / freeze risk** on USD1 contract.

## TODO
- Verify USD1 address checksum on BSC.sol.
- Resolve `USD1_OFT_ADAPTER` (post-launch).
- Locate live USD1/USDT pool (verify fee tier).
- Re-pin `FORK_BLOCK` to an observed 25 bp+ discount window.
