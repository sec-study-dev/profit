# BSC Pendle interfaces

Pendle uses the same router ABI across chains. BSC PoCs should reuse the
mainnet interfaces directly:

```solidity
import {IPendleRouterV4} from "src/interfaces/pendle/IPendleRouterV4.sol";
```

Only add files under this directory if the BSC deployment exposes selectors
not present on the mainnet router (e.g., chain-specific yield-source adapters).
