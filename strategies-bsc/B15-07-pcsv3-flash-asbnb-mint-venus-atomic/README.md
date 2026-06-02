# B15-07 — PCS v3 flash · Astherus asBNB mint · Venus collateral atomic

## Family

B15 · 三协议机制堆叠. Atomic three-mechanism levered restake-LST mint
inside a single block.

## Thesis

Astherus asBNB is the highest-APR BNB-side LST on BSC (Babylon points
+ restake premium ≈ 9.5%). Holding it un-levered (B15-04) leaves the
restake basis on the table. PCS v3 has a 1 bp WBNB/USDT pool with deep
liquidity that supports flash loans; routing the borrowed USDT through
Wombat (USDT→WBNB), unwrapping to BNB, and minting asBNB inside a
single tx lets the position sit at the *maximum* sustainable Venus
LTV with zero pre-funded equity beyond a thin seed.

## The 3 mechanisms

1. **PCS v3 flash** — `IPancakeV3Pool.flash` on the USDT/WBNB 1 bp pool.
2. **Astherus stake** — `ASTHERUS_STAKE_MANAGER.deposit{value}()` mints
   asBNB at the canonical share rate.
3. **Venus collateral + USDT borrow** — supply asBNB-equivalent (vBNB
   proxy until vAsBNB lists), borrow USDT to repay the flash atomically.

## Why distinct from B15-01..06

- B15-03 uses the same PCS-flash primitive but routes into **Pendle
  PT-sUSDe**, not Astherus mint.
- B15-04 holds asBNB *un-levered* at a single LTV with no flash hop.
- B15-07 is the first to combine *atomic flash + LST mint + lending*
  into one tx — closer in spirit to mainnet F18 mint-on-flash patterns.

## TODO

- Verify vAsBNB Venus listing (currently proxied via vBNB).
- Confirm Wombat USDT→WBNB swap is the cheapest hop on BSC at
  block 42_900_000 (vs PCS v3 USDT/WBNB 5 bp pool).
- Replace `ASTHERUS_STAKE_MANAGER` ABI with the verified asBNB minter
  if the interface drifts from `IListaStakeManager.deposit()`.
