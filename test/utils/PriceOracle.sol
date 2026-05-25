// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {Chainlink} from "src/constants/Chainlink.sol";
import {IStETH} from "src/interfaces/lst/IStETH.sol";
import {IWstETH} from "src/interfaces/lst/IWstETH.sol";
import {IRETH} from "src/interfaces/lst/IRETH.sol";
import {ICbETH} from "src/interfaces/lst/ICbETH.sol";
import {IsfrxETH} from "src/interfaces/lst/IsfrxETH.sol";
import {IWeETH} from "src/interfaces/lrt/IWeETH.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

interface IChainlinkAggregator {
    function latestAnswer() external view returns (int256);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @notice Per-token USD price routing used by StrategyBase.
/// @dev    Returns 1e8-scaled prices. Stables fall back to 1e8. Unknown tokens
///         return 0 and emit a console warning.
library PriceOracle {
    uint256 internal constant ONE_E8 = 1e8;
    uint256 internal constant WAD = 1e18;

    /// @notice Read ETH/USD from Chainlink. Caller may also override via StrategyBase fallback.
    function ethUsdE8() internal view returns (uint256) {
        try IChainlinkAggregator(Chainlink.ETH_USD).latestAnswer() returns (int256 ans) {
            if (ans > 0) return uint256(ans);
        } catch {}
        return 0;
    }

    /// @notice USD price of `token` with 8 decimals.
    /// @dev    Routes:
    ///         - ETH/WETH: ETH/USD direct
    ///         - stETH: ETH/USD (assume peg)
    ///         - wstETH: ETH/USD * stEthPerToken
    ///         - rETH: ETH/USD * getExchangeRate
    ///         - cbETH: ETH/USD * exchangeRate
    ///         - sfrxETH: ETH/USD * pricePerShare
    ///         - weETH: ETH/USD * getRate
    ///         - ezETH / rsETH / pufETH: ETH/USD * 1 (fallback - extend if a rate getter is added)
    ///         - DAI/USDC/USDT/USDS/sUSDe/USDe/USDM/GHO/LUSD/crvUSD/BOLD/DOLA: 1e8
    ///         - sDAI/sUSDS: ERC-4626 convertToAssets * underlying USD price (assume 1)
    ///         - unknown: 0
    function priceUSD(address token) internal view returns (uint256) {
        if (token == address(0)) return 0;

        // ETH-denominated assets
        if (token == Mainnet.ETH || token == Mainnet.WETH) {
            return ethUsdE8();
        }
        if (token == Mainnet.STETH) {
            return ethUsdE8();
        }
        if (token == Mainnet.WSTETH) {
            uint256 rate = IWstETH(Mainnet.WSTETH).stEthPerToken(); // 1e18
            return (ethUsdE8() * rate) / WAD;
        }
        if (token == Mainnet.RETH) {
            uint256 rate = IRETH(Mainnet.RETH).getExchangeRate(); // 1e18
            return (ethUsdE8() * rate) / WAD;
        }
        if (token == Mainnet.CBETH) {
            uint256 rate = ICbETH(Mainnet.CBETH).exchangeRate(); // 1e18
            return (ethUsdE8() * rate) / WAD;
        }
        if (token == Mainnet.SFRXETH) {
            try IsfrxETH(Mainnet.SFRXETH).pricePerShare() returns (uint256 rate) {
                return (ethUsdE8() * rate) / WAD;
            } catch {
                return ethUsdE8();
            }
        }
        if (token == Mainnet.FRXETH) {
            return ethUsdE8();
        }
        if (token == Mainnet.WEETH) {
            try IWeETH(Mainnet.WEETH).getRate() returns (uint256 rate) {
                return (ethUsdE8() * rate) / WAD;
            } catch {
                return ethUsdE8();
            }
        }
        if (token == Mainnet.EETH) {
            return ethUsdE8();
        }
        if (token == Mainnet.EZETH || token == Mainnet.RSETH || token == Mainnet.PUFETH || token == Mainnet.METH ||
            token == Mainnet.SWETH || token == Mainnet.OETH || token == Mainnet.RSWETH)
        {
            // Conservative fallback: assume peg to ETH. Strategies that need
            // finer accuracy should set a manual fallback via StrategyBase.
            return ethUsdE8();
        }

        // USD stables (assume 1.00)
        if (
            token == Mainnet.DAI || token == Mainnet.USDC || token == Mainnet.USDT ||
            token == Mainnet.USDS || token == Mainnet.SUSDS || token == Mainnet.SDAI ||
            token == Mainnet.USDE || token == Mainnet.SUSDE || token == Mainnet.USDM ||
            token == Mainnet.GHO || token == Mainnet.LUSD || token == Mainnet.CRVUSD ||
            token == Mainnet.DOLA || token == Mainnet.SUSD || token == Mainnet.OUSD ||
            token == Mainnet.RAI
        ) {
            // sDAI/sUSDS/sUSDe are price-appreciating; we still treat as $1 per share
            // for PoC purposes. Strategies that need NAV precision should compute
            // convertToAssets directly and re-track the underlying.
            return ONE_E8;
        }

        console2.log("PriceOracle: unknown token, returning 0:", token);
        return 0;
    }
}
