# DeFi Corpus Builder

Reproducible source-code corpus for the 84 Ethereum + 57 BSC DeFi protocols
referenced by this project's strategy PoCs.

## What this directory contains

| file                       | purpose                                                                    |
|----------------------------|----------------------------------------------------------------------------|
| `eth_protocols.json`       | 84 Ethereum protocols: slug, name, category, mainnet address               |
| `bsc_protocols.json`       | 57 BSC protocols                                                           |
| `fetch_sources.py`         | first pass: Etherscan V2 `getsourcecode` per address                       |
| `retry_unverified.py`      | proxy pass: for `Proxy==1`, refetch at `Implementation`                    |
| `apply_substitutions.py`   | fallback pass: swap in a same-category verified alternative                |
| `MANIFEST_ALL.csv`         | combined per-address status (verified / verified_substituted / unverified) |
| `ETH_MANIFEST.csv`         | Ethereum-only slice                                                        |
| `BSC_MANIFEST.csv`         | BSC-only slice                                                             |

## How to reproduce the corpus

1. Get an Etherscan V2 API key (`https://etherscan.io/myapikey`).
   The same key works for BSC via `chainid=56`.
2. `echo <API_KEY> > .apikey` in this directory.
3. `python3 fetch_sources.py` — pulls `getsourcecode` for every address,
   writing `ethereum-defi-corpus/<slug>/` and `bsc-defi-corpus/<slug>/`.
4. `python3 apply_substitutions.py` — for the 11 addresses whose source
   comes back unverified, swap in the documented same-category alternative
   (list is hard-coded in the script).

## Selection procedure

Protocols were drawn from **DefiLlama** (`api.llama.fi/protocols`), filtered
to protocols with **TVL ≥ 10M USD** on the relevant chain, then narrowed
to the DeFi categories our strategy PoCs exercise:

- Liquid Staking, Liquid Restaking, Restaking
- CDP / Stablecoin
- Yield-Bearing Stable
- Pendle-style yield tokens
- Money Market
- AMM (Uniswap-style, StableSwap, ve(3,3))
- ve/Bribe (Convex, Aura, Votium, Hidden Hand)
- Derivatives (Synthetix, GMX)
- BTC-LSD (BSC-specific)
- Cross-chain bridge / OFT

Each surviving protocol was cross-checked for (a) a distinctive,
atomically-composable on-chain mechanism, and (b) verified source on
the chain's explorer.

## What ends up in the zips

For each protocol:
- `sources/*.sol` — verbatim files as verified on Etherscan / BscScan
- `metadata.json` — slug/name/category/chain/address/compiler/verified/etc
- `compiler.json` — CompilerVersion, OptimizationUsed, Runs, EVMVersion, LicenseType
- `abi.json` — verified ABI

Nothing is model-generated or hand-written.
