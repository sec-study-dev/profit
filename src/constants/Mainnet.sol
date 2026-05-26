// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Mainnet address book
/// @notice Centralized constant addresses for every protocol used by the
///         strategy PoCs. Grouped by category. Verify and update if a
///         protocol upgrades.
library Mainnet {
    // ---- WETH / ETH ----
    address constant WETH = 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2;
    // ETH sentinel (used by some AMMs / lending markets to denote native ETH)
    address constant ETH = 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee;

    // ---- LST ----
    address constant STETH = 0xae7ab96520de3a18e5e111b5eaab095312d7fe84;
    address constant WSTETH = 0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0;
    address constant LIDO_WITHDRAWAL_QUEUE = 0x889edc2edab5f40e902b864ad4d7ade8e412f9b1;
    address constant RETH = 0xae78736cd615f374d3085123a210448e74fc6393;
    address constant ROCKET_DEPOSIT_POOL = 0xdd3f50f8a6cafbe9b31a427582963f465e745af8;
    address constant SFRXETH = 0xac3e018457b222d93114458476f3e3416abbe38f;
    address constant FRXETH = 0x5e8422345238f34275888049021821e8e08caa1f;
    address constant FRXETH_MINTER = 0xbafa44efe7901e04e39dad13167d089c559c1138;
    address constant CBETH = 0xbe9895146f7af43049ca1c1ae358b0541ea49704;
    address constant METH = 0xd5f7838f5c461feff7fe49ea5ebaf7728bb0adfa;
    address constant METH_STAKING = 0xe3cbd06d7dadb3f4e6557bab7edd924cd1489e8f;
    address constant SWETH = 0xf951e335afb289353dc249e82926178eac7ded78;

    // ---- LRT ----
    address constant WEETH = 0xcd5fe23c85820f7b72d0926fc9b05b43e359b7ee;
    address constant EETH = 0x35fa164735182de50811e8e2e824cfb9b6118ac2;
    address constant ETHERFI_LIQUIDITY_POOL = 0x308861a430be4cce5502d0a12724771fc6daf216;
    // TODO verify: Renzo ezETH token address (check on ezETH protocol docs)
    address constant EZETH = 0xbf5495efe5db9ce00f80364c8b423567e58d2110;
    address constant RENZO_RESTAKE_MANAGER = 0x74a09653a083691711cf8215a6ab074bb4e99ef5;
    address constant RSETH = 0xa1290d69c65a6fe4df752f95823fae25cb99e5a7;
    address constant PUFETH = 0xd9a442856c234a39a81a089c06451ebaa4306a72;
    address constant RSWETH = 0xfae103dc9cf190ed75350761e95403b7b8afa6c0;

    // ---- CDP / Stable ----
    address constant DAI = 0x6b175474e89094c44da98b954eedeac495271d0f;
    address constant USDS = 0xdc035d45d973e3ec169d2276ddab16f1e407384f;
    address constant USDC = 0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48;
    address constant USDT = 0xdac17f958d2ee523a2206206994597c13d831ec7;
    address constant DSS_PSM_USDC = 0x89b78cfa322f6c5de0abceecab66aee45393cc5a;
    address constant DSS_FLASH = 0x60744434d6339a6b27d73d9eda62b6f66a0a04fa;
    address constant POT = 0x197e90f9fad81970ba7976f33cbd77088e5d7cf7;
    address constant DSR_MANAGER = 0x373238337bfe1146fb49989fc222523f83081ddb;
    address constant SDAI = 0x83f20f44975d03b1b09e64809b757c47f942beea;
    address constant SUSDS = 0xa3931d71877c0e7a3148cb7eb4463524fec27fbd;
    address constant CRVUSD = 0xf939e0a03fb07f59a73314e73794be0e57ac1b4e;
    address constant LUSD = 0x5f98805a4e8be255a32880fdec7f6728c6568ba0;
    // Liquity v2 BOLD token (post-2025-05-19 redeployment).
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json
    address constant BOLD = 0x6440f144b7e50d6a8439336510312d2f54beb01d;
    address constant RAI = 0x03ab458634910aad20ef5f1c8ee96f1d6ac54919;
    address constant DOLA = 0x865377367054516e17014ccded1e7d814edc9ce4;
    address constant GHO = 0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f;

    // ---- Yield-bearing stable ----
    address constant USDE = 0x4c9edd5852cd905f086c759e8383e09bff1e68b3;
    address constant SUSDE = 0x9d39a5de30e57443bff2a8307a4256c8797a3497;
    // TODO verify: canonical EthenaMinting contract
    address constant ETHENA_MINTING = 0x9d39a5de30e57443bff2a8307a4256c8797a3497; // placeholder, override before use
    address constant USDM = 0x59d9356e565ab3a36dd77763fc0d87feaf85508c;
    // TODO verify: USDY (Ondo) mainnet token
    address constant USDY = address(0);
    // TODO verify: syrupUSDC (Maple) mainnet token
    address constant SYRUPUSDC = address(0);
    address constant OUSD = 0x2a8e1e676ec238d8a992307b495b45b3feaa5e86;
    address constant OETH = 0x856c4efb76c1d1ae02e20ceb03a2a6a08b0b8dc3;

    // ---- Pendle ----
    // TODO verify: Pendle Router V4 (check Pendle docs for latest)
    address constant PENDLE_ROUTER_V4 = 0x888888888889758f76e7103c6cbf23abbf58f946;
    address constant PENDLE_TOKEN = 0x808507121b80c02388fad14726482e061b8da827;
    // TODO verify: vePENDLE contract
    address constant VEPENDLE = address(0);

    // ---- Money Markets ----
    address constant MORPHO = 0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb;
    address constant AAVE_V3_POOL = 0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2;
    address constant COMPOUND_V3_USDC_COMET = 0xc3d688b66703497daa19211eedff47f25384cdc3;
    // TODO verify: Euler V2 EVC (Ethereum Vault Connector) mainnet
    address constant EULER_EVC = address(0);
    // TODO verify: Fluid Vault Factory mainnet
    address constant FLUID_VAULT_FACTORY = address(0);
    address constant SPARK_POOL = 0xc13e21b648a5ee794902342038ff3adab66be987;

    // ---- AMM ----
    address constant CURVE_3POOL = 0xbebc44782c7db0a1a60cb6fe97d0b483032ff1c7;
    address constant CURVE_STETH_POOL = 0xdc24316b9ae028f1497c275eb9192a3ea0f67022;
    address constant CURVE_TRICRYPTO_2 = 0xd51a44d3fae010294c616388b506acda1bfaae46;
    address constant BAL_VAULT = 0xba12222222228d8ba445958a75a0704d566bf2c8;
    address constant UNI_V3_FACTORY = 0x1f98431c8ad98523631ae4a59f267346ea31f984;
    address constant UNI_V3_ROUTER = 0xe592427a0aece92de3edee1f18e0157c05861564;
    address constant UNI_V2_ROUTER = 0x7a250d5630b4cf539739df2c5dacb4c659f2488d;

    // ---- Bribe / Vote ----
    address constant CONVEX_BOOSTER = 0xf403c135812408bfbe8713b5a23a04b3d48aae31;
    address constant VLCVX = 0x72a19342e8f1838460ebfccef09f6585e32db86e;
    address constant CVX = 0x4e3fbd56cd56c3e72c1403e103b45db9da5b9d2b;
    address constant VOTIUM_MULTI_MERKLE_STASH = 0x378ba9b73309be80bf4c2c027aad799766a7ed5a;
    // TODO verify: Hidden Hand rewards distributor (Bribe Vault)
    address constant HIDDEN_HAND_REWARDS = address(0);
    // Curve gauge controller (well-known)
    address constant CURVE_GAUGE_CONTROLLER = 0x2f50d538606fa9edd2b11e2446beb18c9d5846bb;

    // ---- Synth / Derivative ----
    // TODO verify: Synthetix AtomicSynthExchange / direct integration proxy
    address constant SNX_ATOMIC_EXCHANGER = address(0);
    address constant SUSD = 0x57ab1ec28d129707052df4df418d58a2d46d5f51;
    address constant SETH = 0x5e74c9036fb86bd7ecdcb084a0673efc32ea31cb;

    // ---- Restake ----
    address constant EIGEN_STRATEGY_MANAGER = 0x858646372cc42e1a627fce94aa7a7033e7cf075a;
    address constant EIGEN_DELEGATION_MANAGER = 0x39053d51b77dc0d36036fc1fcc8cb819df8ef37a;
}
