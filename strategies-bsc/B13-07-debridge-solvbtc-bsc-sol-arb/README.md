# B13-07: deBridge solvBTC BSC <-> Solana arb (3-mechanism)

## Family
B13 — Cross-chain bridge LST/stable discount arbs.

## Thesis
solvBTC exists on both BSC (`0x4aae...BCf7`) and Solana (as
`solvBTC.BBN` — the Babylon-restaked variant). During BBN points campaign
ramps, Solana-side solvBTC.BBN trades at a **30-80 bp premium** to the
BSC solvBTC because BSC supply gets drained westward, leaving BSC's PCS
`BTCB / solvBTC` pool with solvBTC at a **20-50 bp discount** to BTCB.

deBridge's DLN (Decentralised Limit-Order Network) lets any market maker
fulfil a BSC -> Solana token transfer atomically on the receive side; the
sender locks tokens on BSC and the order is filled within minutes by a
taker on Solana.

## Bridge primitive
- **deBridge DLN `DlnSource.createOrder`** — taker-fulfilled cross-chain
  limit order. BSC-side lock is atomic; Solana fill latency ~1-3 min.
- **PCS v3 flash** on BTCB/USDT for the BTC notional.
- **Wombat router** as a third venue for residual solvBTC -> BTCB on BSC.

## Mechanism count: **3-mechanism**
1. PCS v3 BTCB flash (cheap BTC loan).
2. PCS v3 BTCB -> solvBTC swap (captures BSC-side discount).
3. deBridge DLN `createOrder` BSC -> Solana (captures cross-chain premium).
4. Wombat router solvBTC -> BTCB for residual (third venue; squares the
   on-chain leg).

## Atomic vs positional
**Positional.** BSC leg + DLN lock are atomic within one block (the
`createOrder` is a state-only escrow); the Solana fill is out-of-band.
PnL on the BSC leg is booked at swap+lock time; the SOL leg pays via the
buffer model used by other B13 PoCs.

## Block pinned
- `FORK_BLOCK = 45_500_000` — placeholder. Re-pin to a BBN points campaign
  inflow window when solvBTC/BTCB slot0 < 0.997. TODO.

## PnL math
At 35 bp BSC discount + 50 bp Solana premium, 5 BTC notional ($325k):
- BSC swap capture: `5 * 0.0035 = 0.0175 BTC` ≈ $1,140.
- SOL premium on 80% bridged: `4 * 0.0050 - 0.0020 taker_bid = 0.0120 BTC`
  ≈ $780.
- Flash fee (5 bp on 0.05% tier): `5 * 0.0005 = 0.0025 BTC` ≈ $165.
- deBridge native fee: ~$0.50.
- Wombat fee on residual 1 BTC: 5 bp ≈ $33.
- Net: **~$1,720 per cycle**.

## Preconditions
- `DLN_SOURCE` deployed and active on BSC. TODO verify.
- Active DLN taker liquidity on Solana for solvBTC.BBN.
- PCS v3 BTCB/solvBTC pool exists (TODO verify fee tier).
- Wombat solvBTC/BTCB pool exists (TODO populate `poolPath[0]`).

## Risks
- **DLN taker timeout** — order may not be filled if no taker bids,
  forcing manual cancel and a lost spread.
- **Cross-chain price reversal** during the unfilled window.
- **Babylon slashing** on solvBTC.BBN reduces redemption value.
- **Pool fee tier mismatch** — solvBTC/BTCB may only exist at 1% tier in
  early markets, halving the capturable spread.

## TODO
- Resolve `DLN_SOURCE` address on BSC.
- Resolve Solana `solvBTC.BBN` mint and DLN `takeChainId` semantics.
- Populate Wombat `poolPath[0]` for solvBTC/BTCB.
- Re-pin `FORK_BLOCK` to an observed discount/premium window.
