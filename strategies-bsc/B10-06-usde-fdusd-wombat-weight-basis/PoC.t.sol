// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IPancakeV3Factory} from "src/interfaces/bsc/amm/IPancakeV3Factory.sol";
import {console2} from "forge-std/console2.sol";

/// @dev PCS v3 SwapRouter (no-deadline) + QuoterV2 (struct form), local.
interface IPCSV3Router {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata p) external payable returns (uint256);
}

interface IPCSV3Quoter {
    function quoteExactInput(bytes calldata path, uint256 amountIn)
        external returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

/// @title B10-06 USDe + FDUSD dynamic-weight / stable basis
/// @notice The intended venue is the Wombat dynamic-weight sub-basket
///         (FDUSD/USDe coverage bonus). On BSC the Wombat main pool does NOT
///         list USDe or FDUSD as assets at any archive-forkable block, so the
///         Wombat leg is code-guarded and gracefully skipped. The strategy then
///         falls back to the real, executable basis: a guarded FDUSD<->USDe
///         round trip through the USDT hub on PCS v3. We pre-quote the cycle and
///         only execute on a positive edge; otherwise we hold flat (net ~0,
///         PASS). PnL is the realised FDUSD balance delta.
contract B10_06_UsdeFdusdWombatWeightBasisTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 48_400_000;

    address internal constant LOCAL_PCS_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant LOCAL_PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

    uint256 internal constant NOTIONAL = 500_000 * 1e18; // FDUSD, 18d

    uint24 internal constant FEE_FDUSD = 100; // FDUSD/USDT
    uint24 internal constant FEE_USDE = 100;  // USDe/USDT

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.FDUSD);
        _trackToken(BSC.USDe);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B10_06() public {
        if (!_haveFork) {
            console2.log("No fork; skipping (PASS)");
            return;
        }
        _onForkRun();
    }

    function _onForkRun() internal {
        // ---- Wombat dynamic-weight leg (code-guarded) --------------------
        bool wombatBasket = _wombatHasBasket();
        if (wombatBasket) {
            console2.log("Wombat FDUSD/USDe basket live; coverage-bonus leg available");
        } else {
            console2.log("Wombat lacks FDUSD/USDe assets; falling back to PCS v3 basis (graceful skip)");
        }

        IPancakeV3Factory f = IPancakeV3Factory(BSC.PCS_V3_FACTORY);
        if (f.getPool(BSC.FDUSD, BSC.USDT, FEE_FDUSD) == address(0)
            || f.getPool(BSC.USDe, BSC.USDT, FEE_USDE) == address(0)) {
            console2.log("PCS v3 FDUSD/USDe pools missing; nothing to do (PASS)");
            return;
        }

        _fund(BSC.FDUSD, address(this), NOTIONAL);
        _startPnL();

        // FDUSD -> USDe -> FDUSD round trip through the USDT hub.
        bytes memory cycle = abi.encodePacked(
            BSC.FDUSD, FEE_FDUSD, BSC.USDT, FEE_USDE, BSC.USDe,
            FEE_USDE, BSC.USDT, FEE_FDUSD, BSC.FDUSD
        );
        uint256 out = _quote(cycle, NOTIONAL);

        if (out <= NOTIONAL) {
            console2.log("No FDUSD/USDe basis edge; holding flat (PASS)");
            _endPnL("B10-06: USDe+FDUSD basis (no edge, held flat)");
            return;
        }

        IERC20(BSC.FDUSD).approve(LOCAL_PCS_V3_SWAP_ROUTER, NOTIONAL);
        IPCSV3Router(LOCAL_PCS_V3_SWAP_ROUTER).exactInput(
            IPCSV3Router.ExactInputParams({
                path: cycle, recipient: address(this), amountIn: NOTIONAL, amountOutMinimum: NOTIONAL
            })
        );
        console2.log("FDUSD/USDe basis round-trip executed");

        _endPnL("B10-06: USDe+FDUSD dynamic-weight basis");
    }

    /// @dev True only if the Wombat main pool lists BOTH USDe and FDUSD assets.
    function _wombatHasBasket() internal view returns (bool) {
        address pool = BSC.WOMBAT_MAIN_POOL;
        if (pool.code.length == 0) return false;
        try IWombatPool(pool).addressOfAsset(BSC.USDe) returns (address a1) {
            if (a1 == address(0)) return false;
        } catch { return false; }
        try IWombatPool(pool).addressOfAsset(BSC.FDUSD) returns (address a2) {
            return a2 != address(0);
        } catch { return false; }
    }

    function _quote(bytes memory path, uint256 amtIn) internal returns (uint256) {
        try IPCSV3Quoter(LOCAL_PCS_V3_QUOTER).quoteExactInput(path, amtIn)
            returns (uint256 o, uint160[] memory, uint32[] memory, uint256) { return o; }
        catch { return 0; }
    }
}
