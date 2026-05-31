// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BSC mainnet address book
/// @notice Centralized constant addresses for every protocol used by the BSC
///         strategy PoCs. BSC mainnet chain id = 56; addresses verified from
///         BscScan unless marked `TODO verify`. Grouped by category.
/// @dev    This is the BSC analogue of `src/constants/Mainnet.sol`. The two
///         files are intentionally disjoint so Wave 2 BSC agents and the
///         existing Ethereum agents do not collide.
library BSC {
    // ---- Native / Wrapped ----
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @notice BNB sentinel (mirrors the EeEe... ETH sentinel pattern)
    address constant BNB = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @notice Same sentinel reused for native ETH abstraction on BSC tooling.
    address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @notice Binance-Peg BTCB (1:1 BTC).
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    /// @notice Binance-Peg ETH (bridged ETH on BSC).
    address constant WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    // ---- LST / LRT (BNB) ----
    /// @notice Stader BNBx (non-rebasing LST). Exchange rate via StaderStakeManager.
    address constant BNBx = 0x1bdd3Cf7F79cfB8EdbB955f20ad99211044F6aE4;
    /// @notice Ankr aBNBc (legacy bond token). // TODO verify: aBNBc still active or replaced by ankrBNB.
    address constant aBNBc = 0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827;
    /// @notice Ankr ankrBNB (wrapped non-rebasing). Same address as aBNBc on most explorers.
    address constant ankrBNB = 0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827;
    /// @notice Lista DAO slisBNB (non-rebasing LST).
    address constant slisBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    /// @notice pSTAKE stkBNB.
    address constant stkBNB = 0xc2E9d07F66A89c44062459A47a0D2Dc038E4fb16;
    /// @notice Binance wrapped Beacon ETH (WBETH) — bridged from ETH mainnet.
    address constant WBETH = 0xa2E3356610840701BDf5611a53974510Ae27E2e1;
    /// @notice Astherus asBNB (restaked BNB). // TODO verify
    address constant asBNB = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;

    // ---- Stable / CDP ----
    /// @notice Binance-Peg USDT (18 decimals on BSC, NOT 6).
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    /// @notice Binance-Peg USDC.
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    /// @notice BUSD (legacy, frozen issuance).
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    /// @notice First Digital USD.
    address constant FDUSD = 0xc5f0F7b66764F6ec8C8Dff7BA683102295E16409;
    /// @notice World Liberty Financial USD1. // TODO verify
    address constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    /// @notice Lista DAO lisUSD (CDP-issued stable).
    address constant lisUSD = 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5;
    /// @notice Ethena USDe on BSC (bridged via LayerZero OFT).
    address constant USDe = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
    /// @notice Ethena staked USDe (sUSDe) on BSC.
    address constant sUSDe = 0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2;

    // ---- Pendle (on BSC) ----
    /// @notice Pendle Router V4 on BSC. // TODO verify (mainnet address reused; confirm chain-specific deployment).
    address constant PENDLE_ROUTER_V4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    // ---- Venus (Core pool + selected vTokens) ----
    /// @notice Venus Core Comptroller (Unitroller proxy).
    address constant VENUS_COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    /// @notice vBNB (native BNB collateral market).
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
    /// @notice vBNBx (isolated pool listing). // TODO verify: confirm canonical vBNBx vToken address (currently placeholder = Comptroller).
    address constant vBNBx = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    /// @notice vUSDT.
    address constant vUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    /// @notice vUSDC.
    address constant vUSDC = 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8;
    /// @notice vBUSD (legacy, may be deprecated for new borrows).
    address constant vBUSD = 0x95c78222B3D6e262426483D42CfA53685A67Ab9D;
    /// @notice vBTCB.
    address constant vBTCB = 0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B;
    /// @notice VAI (Venus native overcollateralized stable).
    address constant VAI = 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;

    // ---- Lista DAO ----
    /// @notice Lista Interaction (CDP open/close, lisUSD mint/burn). // TODO verify
    address constant LISTA_INTERACTION = 0x1A0D55a5fC2dA0C71eE0aD63D43308F45a16cBE0;
    /// @notice Lista Lending (slisBNB market). // TODO verify (placeholder).
    address constant LISTA_LENDING = 0xaA0F8c41E3DC22a8C4d4Da6da1A1cAF048D7e4b5;
    /// @notice Lista slisBNB StakeManager (BNB <-> slisBNB exchange-rate source).
    address constant LISTA_STAKE_MANAGER = 0x1adB950d8bB3dA4bE104211D5AB038628e477fE6;

    // ---- PancakeSwap ----
    /// @notice PancakeSwap V2 Router.
    address constant PCS_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    /// @notice PancakeSwap V2 Factory.
    address constant PCS_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    /// @notice PancakeSwap V3 SwapRouter.
    address constant PCS_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    /// @notice PancakeSwap V3 Factory.
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    /// @notice PancakeSwap StableSwap Router. // TODO verify
    address constant PCS_STABLE_ROUTER = 0xeC2D6Da16e9aDe97c6da8ad6E8C5e6dD7e9d4e8e;
    /// @notice CAKE governance / reward token.
    address constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    // ---- Thena (ve(3,3) on BSC) ----
    /// @notice Thena Router. // TODO verify
    address constant THENA_ROUTER = 0x20a304a7d126758dfe6B243D0fc515F83bCA8431;
    /// @notice Thena PairFactory. // TODO verify
    address constant THENA_PAIR_FACTORY = 0xAFD89d21BdB66d00817d4153E055830B1c2B3970;
    /// @notice veTHE (Thena voting escrow). // TODO verify
    address constant veTHE = 0xfBBF371C9B0B994EebFcC977CEf603F7f31c070D;
    /// @notice THE governance token.
    address constant THE = 0xF4C8E32EaDEC4BFe97E0F595AdD0f4450a863a11;

    // ---- Wombat ----
    /// @notice Wombat Main Pool (BNB / stables). // TODO verify
    address constant WOMBAT_MAIN_POOL = 0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0;
    /// @notice Wombat Router. // TODO verify
    address constant WOMBAT_ROUTER = 0x19609B03C976CCA288fbDae5c21d4290e9a4aDD7;
    /// @notice WOM governance token.
    address constant WOM = 0xAD6742A35fB341A9Cc6ad674738Dd8da98b94Fb1;

    // ---- Avalon / BTC-LSD ----
    /// @notice Avalon Lending Pool (BTC-LSD collateral markets). // TODO verify
    address constant AVALON_LENDING_POOL = 0xf9278C7c4aEfaC4dDfd0d496f7a1c39Ca6BcA6d4;
    /// @notice Solv solvBTC.
    address constant solvBTC = 0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7;
    /// @notice Solv solvBTC.BBN (Babylon-restaked).
    address constant solvBTC_BBN = 0x1346b81C8E3FE38d6cFc7e1B1cdF92C6b0050BFE;

    // ---- Astherus ----
    /// @notice Astherus StakeManager (asBNB mint/burn). // TODO verify
    address constant ASTHERUS_STAKE_MANAGER = 0xb0fd0bf41fbDd5C56db8FFa2Ad5D9F0b27c2B0a1;

    // ---- Bridges (LayerZero OFT) ----
    /// @notice USDT OFT Adapter (LayerZero V2). // TODO verify
    address constant USDT_OFT_ADAPTER = address(0);
    /// @notice USDC OFT Adapter (LayerZero V2). // TODO verify
    address constant USDC_OFT_ADAPTER = address(0);
}
