// // SPDX-License-Identifier: AGPL-3.0-only
// pragma solidity 0.8.26;

// import "forge-std/Script.sol";
// import "../contracts/Zybra/token/LZYBRA.sol";
// import "../contracts/Zybra/pools/LzybraVault.sol";
// import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// import {ZybraConfigurator} from "../contracts/Zybra/configuration/ZybraConfigurator.sol";
// contract LzybraDeployer is Script {

    
//     function deploy(
//         address usdc,
//         address chainlinkMock,
//         address poolManager
//     ) external returns (address,address,address) {
//         console.log("depoloy",msg.sender);
        
//         Lzybra lzybra = new Lzybra("Lzybra", "LZY");

//          ZybraConfigurator configuratorImplementation = new ZybraConfigurator();
//         console.log(
//             "ZybraConfigurator Implementation deployed at:",
//             address(configuratorImplementation)
//         );

//         // Step 6: Deploy ZybraConfigurator Proxy
//         ERC1967Proxy configuratorProxy = new ERC1967Proxy(
//             address(configuratorImplementation),
//             abi.encodeWithSelector(
//                 ZybraConfigurator.initialize.selector,
//                 address(lzybra),
//                 address(usdc)
//             )
//         );
// ZybraConfigurator configurator = ZybraConfigurator(address(configuratorProxy));
//         LzybraVault lzybraVault = new LzybraVault(
//             chainlinkMock,
//             usdc,
//             address(lzybra),
//             poolManager,
//             address(configurator)
//         );

//         console.log("Lzybra deployed at:", address(lzybra));
//         console.log("LzybraVault deployed at:", address(lzybraVault));
//         console.log("ZybraConfigurator deployed at:", address(configurator));
//         Lzybra(lzybra).grantMintRole(address(lzybraVault));

//         return (address(lzybra), address(lzybraVault),address(configurator));
//     }
// }

