# B15-08 — veTHE bribe vote · Pendle YT-asBNB · Venus credit stack

## Family

B15 · 三协议机制堆叠. ve(3,3) + tokenized-yield + lending — three
*structurally different* mechanism classes on one position.

## Thesis

Thena is the largest ve(3,3) DEX on BSC. Locking THE for veTHE and
voting on the asBNB/WBNB gauge directs THE emissions there *and*
captures a bribe basket (historical mix: USDT + lisUSD + asBNB,
seeded by Lista/Astherus to bootstrap their LST liquidity). The
bribe stream is recycled into Pendle YT-asBNB for **leveraged
points-class exposure** (5% YT entry ≈ 20× face), while a parallel
asBNB seed sits as Venus collateral to borrow the working USDT for
the YT-buy loop.

## The 3 mechanisms

1. **veTHE vote + bribe claim** — `veTHE.createLock(amount, 4y)` +
   `IThenaVoter.vote(...)` on the asBNB/WBNB pool.
2. **Pendle YT-asBNB** — `IPendleRouter.swapExactTokenForYt(USDT)`
   converts borrowed USDT into YT face exposure.
3. **Venus collateral + USDT borrow** — supply asBNB seed (vBNB proxy),
   borrow USDT at ~5% APR to keep feeding the YT loop.

## Why distinct from B15-01..06

- B15-02 *stakes LP into a Thena gauge*; it never locks THE for veTHE
  nor votes nor claims bribes. The mechanism class is different (gauge
  staking vs vote-bribe extraction).
- B15-04 buys YT-asBNB with a single static Venus borrow, no veTHE
  loop refreshing the USDT side.
- The combined `ve(3,3) + YT + lending` triplet is not present
  anywhere in B15-01..06.

## TODO

- Verify `LOCAL_ASBNB_WBNB_POOL` exists at the pinned block (currently
  a placeholder; Thena pair factory query needed).
- Confirm veTHE NFT ID for `IThenaVoter.vote(tokenId, ...)`; the PoC
  passes `0` and relies on the try/catch fallback.
- Replace `LOCAL_YT_ASBNB_MARKET` with the verified Pendle BSC market
  address (same placeholder as B15-04).
