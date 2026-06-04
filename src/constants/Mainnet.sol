// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Mainnet address book
/// @notice Centralized constant addresses for every protocol used by the
///         strategy PoCs. Grouped by category. Verify and update if a
///         protocol upgrades.
library Mainnet {
    // ---- WETH / ETH ----
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // ETH sentinel (used by some AMMs / lending markets to denote native ETH)
    address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // ---- LST ----
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant LIDO_WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
    address constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant ROCKET_DEPOSIT_POOL = 0xDD3f50F8A6CafbE9b31a427582963f465E745AF8;
    address constant SFRXETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;
    address constant FRXETH = 0x5E8422345238F34275888049021821E8E08CAa1f;
    address constant FRXETH_MINTER = 0xbAFA44EFE7901E04E39Dad13167D089C559c1138;
    address constant CBETH = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
    address constant METH = 0xd5F7838F5C461fefF7FE49ea5ebaF7728bB0ADfa;
    address constant METH_STAKING = 0xe3cBd06D7dadB3F4e6557bAb7EdD924CD1489E8f;
    address constant SWETH = 0xf951E335afb289353dc249e82926178EaC7DEd78;

    // ---- LRT ----
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant ETHERFI_LIQUIDITY_POOL = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    // TODO verify: Renzo ezETH token address (check on ezETH protocol docs)
    address constant EZETH = 0xbf5495Efe5DB9ce00f80364C8B423567e58d2110;
    address constant RENZO_RESTAKE_MANAGER = 0x74a09653A083691711cF8215a6ab074BB4e99ef5;
    address constant RSETH = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
    address constant PUFETH = 0xD9A442856C234a39a81a089C06451EBAa4306a72;
    address constant RSWETH = 0xFAe103DC9cf190eD75350761e95403b7b8aFa6c0;

    // ---- CDP / Stable ----
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DSS_PSM_USDC = 0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A;
    address constant DSS_FLASH = 0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA;
    address constant POT = 0x197E90f9FAD81970bA7976f33CbD77088E5D7cf7;
    address constant DSR_MANAGER = 0x373238337Bfe1146fb49989fc222523f83081dDb;
    address constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant LUSD = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0;
    // Liquity v2 BOLD token (post-2025-05-19 redeployment).
    // Verified at https://raw.githubusercontent.com/liquity/bold/main/contracts/addresses/1.json
    address constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address constant RAI = 0x03ab458634910AaD20eF5f1C8ee96F1D6ac54919;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;

    // ---- Yield-bearing stable ----
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    // TODO verify: canonical EthenaMinting contract
    address constant ETHENA_MINTING = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497; // placeholder, override before use
    address constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;
    // TODO verify: USDY (Ondo) mainnet token
    address constant USDY = address(0);
    // TODO verify: syrupUSDC (Maple) mainnet token
    address constant SYRUPUSDC = address(0);
    address constant OUSD = 0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86;
    address constant OETH = 0x856c4Efb76C1D1AE02e20CEB03A2A6a08b0b8dC3;

    // ---- Pendle ----
    // PENDLE_ROUTER_V4 (0x888...) handles only mint/redeem (mintPyFromToken, redeemPyToToken).
    // For AMM swaps (swapExactTokenForYt, swapExactPtForToken, etc.) use PENDLE_ROUTER_V3
    // which is the full V3 action router with 5-field TokenInput struct.
    address constant PENDLE_ROUTER_V4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    // Pendle V3 action router: has swapExactTokenForYt, swapExactPtForToken, etc.
    // V3 TokenInput: (address tokenIn, uint256 netTokenIn, address tokenMintSy,
    //                 address bulk, address pendleSwap, SwapData swapData)
    address constant PENDLE_ROUTER_V3 = 0x0000000001E4ef00d069e71d6bA041b0A16F7eA0;
    address constant PENDLE_TOKEN = 0x808507121B80c02388fAd14726482e061B8da827;
    // TODO verify: vePENDLE contract
    address constant VEPENDLE = address(0);

    // ---- Money Markets ----
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant COMPOUND_V3_USDC_COMET = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    // TODO verify: Euler V2 EVC (Ethereum Vault Connector) mainnet
    address constant EULER_EVC = address(0);
    // TODO verify: Fluid Vault Factory mainnet
    address constant FLUID_VAULT_FACTORY = address(0);
    address constant SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;

    // ---- AMM ----
    address constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address constant CURVE_TRICRYPTO_2 = 0xD51a44d3FaE010294C616388b506AcdA1bfAAE46;
    address constant BAL_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant UNI_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant UNI_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNI_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // ---- Bribe / Vote ----
    address constant CONVEX_BOOSTER = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;
    address constant VLCVX = 0x72a19342e8F1838460eBFCCEf09F6585e32db86E;
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address constant VOTIUM_MULTI_MERKLE_STASH = 0x378Ba9B73309bE80BF4C2c027aAD799766a7ED5A;
    // TODO verify: Hidden Hand rewards distributor (Bribe Vault)
    address constant HIDDEN_HAND_REWARDS = address(0);
    // Curve gauge controller (well-known)
    address constant CURVE_GAUGE_CONTROLLER = 0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB;

    // ---- Synth / Derivative ----
    // TODO verify: Synthetix AtomicSynthExchange / direct integration proxy
    address constant SNX_ATOMIC_EXCHANGER = address(0);
    address constant SUSD = 0x57Ab1ec28D129707052df4dF418D58a2D46d5f51;
    address constant SETH = 0x5e74C9036fb86BD7eCdcb084a0673EFc32eA31cb;

    // ---- Restake ----
    address constant EIGEN_STRATEGY_MANAGER = 0x858646372CC42E1A627fcE94aa7A7033e7CF075A;
    address constant EIGEN_DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
}
