// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../contracts/Zybra/gateway/Gateway.sol";
import "../contracts/Zybra/gateway/GasService.sol";

contract GatewayDeployer is Script {
    
    function call(address root, address poolManager, address investmentManager) external returns (address, address) {
        
        
        GasService gasService = new GasService(2e16, 2e16, 2.5e18, 1.789474e17);
        Gateway gateway = new Gateway(root, poolManager, investmentManager, address(gasService));

        console.log("GasService deployed at:", address(gasService));
        console.log("Gateway deployed at:", address(gateway));

        return (address(gasService), address(gateway));
    }
}

