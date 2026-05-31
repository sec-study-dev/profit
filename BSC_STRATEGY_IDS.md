# BSC Strategy Family Ownership Table

This file is the **collision-prevention contract** for the BSC Wave 2. Each
Wave 2 BSC agent owns exactly one family ID `BXX` and may only write to paths
matching `strategies-bsc/BXX-*`. Do not edit another family's row or create
files outside your assigned family. This file is the BSC analogue of
`STRATEGY_IDS.md`; the two subtrees (Ethereum `strategies/Fxx-*` and BSC
`strategies-bsc/Bxx-*`) are intentionally disjoint.

| ID  | Family name                  | Description                                                                | Owner             | Status   |
| --- | ---------------------------- | -------------------------------------------------------------------------- | ----------------- | -------- |
| B01 | BNB LST 杠杆循环              | slisBNB/BNBx/stkBNB/asBNB 在 Venus/Lista lending 上的递归借贷             | wave2-B01-agent   | pending  |
| B02 | BNB LST peg & basis 套利      | LST 内部 exchangeRate vs PCS/Thena/Wombat 现价的原子套利                  | wave2-B02-agent   | pending  |
| B03 | Lista lisUSD CDP 机制套利     | lisUSD 软清算、redemption arb、cross-CDP basis on BSC                     | wave2-B03-agent   | pending  |
| B04 | Pendle PT/YT on BSC          | BSC 上 PT-USDe/PT-slisBNB/PT-asBNB cash-and-carry + YT 投机              | wave2-B04-agent   | pending  |
| B05 | Ethena USDe/sUSDe BSC carry  | USDe BSC 上的 funding 套利、sUSDe + Venus/Lista loop                     | wave2-B05-agent   | pending  |
| B06 | Venus isolated pool 套利     | Venus V4 isolated pools 之间的 IRM 差异 + 跨池套利                       | wave2-B06-agent   | pending  |
| B07 | PCS v3 flash + cross-DEX     | PCS v3 单池 flash + Thena/Biswap/Wombat 跨 DEX peg arb                    | wave2-B07-agent   | pending  |
| B08 | Thena/PCS ve(3,3) gauge      | veTHE/cake gauge vote、HiddenHand BSC、cross-protocol bribe basket        | wave2-B08-agent   | pending  |
| B09 | Wombat StableSwap dynamic    | Wombat dynamic asset weight 与 PCS StableSwap/Curve 的价差                | wave2-B09-agent   | pending  |
| B10 | 跨稳定币 CDP basis            | lisUSD × FDUSD × USDe × USD1 跨稳定币 CDP/borrow/peg basis                | wave2-B10-agent   | pending  |
| B11 | Astherus asBNB restake stack | asBNB 在 Venus/Lista 抵押 + 底层 restake 的 stacked alpha                | wave2-B11-agent   | pending  |
| B12 | Avalon BTC-LSD 借贷          | solvBTC/pumpBTC 等 BTC-LSD 在 Avalon 上的循环借贷                        | wave2-B12-agent   | pending  |
| B13 | 跨链桥 LST/stable 折价        | LayerZero OFT / CCIP 在 BSC ↔ ETH/Sol 桥接资产的折溢价                    | wave2-B13-agent   | pending  |
| B14 | 收益型稳定币循环              | USDe / sUSDe / sUSDX / Lista sUSDX 在 BSC 上的递归 farm                   | wave2-B14-agent   | pending  |
| B15 | 三协议机制堆叠                | 必须组合 ≥3 个 BSC 协议机制的 atomic 或 positional 策略                   | wave2-B15-agent   | pending  |

## Rules

1. **One family, one agent.** Do not write `strategies-bsc/BYY-*` if you are
   not the owner of `BYY`.
2. **Status transitions.** When you start, change your row's status from
   `pending` to `in-progress`. When you finish, set it to `done`. Do not
   edit other rows.
3. **Numbering.** Within a family, number PoCs `01`, `02`, ... and keep them
   under ~5 per family unless the family is genuinely rich.
4. **No cross-family edits.** If a strategy genuinely spans families, file it
   under the family that *initiates* the position.
5. **No cross-chain edits.** BSC families (`Bxx`) must not touch Ethereum
   files under `strategies/`, `src/constants/Mainnet.sol`, or the existing
   `src/interfaces/` (non-`bsc/`) subdirectories. Ethereum families
   (`Fxx`) likewise must not touch BSC files.
