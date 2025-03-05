// // // SPDX-License-Identifier: AGPL-3.0-only
// // pragma solidity 0.8.26;

// // import "forge-std/Script.sol";
// // import "../src/MockSetup.sol";
// // import "../src/ComponentSetup.sol";

// // contract DeployerScript is Script {
// //     function run() external {
// //         uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
// //         vm.startBroadcast(deployerPrivateKey);

// //         // Step 1: Deploy and set up mocks
// //         MockSetup mockSetup = new MockSetup();
// //         (address[] memory testAdapters, address erc20, address chainlinkMock) = mockSetup.setupMocks(msg.sender);
// //         console.log("Mocks deployed. ERC20 deployed at:", erc20);

// //         // Step 2: Deploy Zybra components
// //         ComponentSetup componentSetup = new ComponentSetup();
// //         (Root root, LzybraVault lzybraVault) = componentSetup.setupComponents(msg.sender, erc20, chainlinkMock);

// //         console.log("Zybra components deployed. Root deployed at:", address(root));
// //         console.log("LzybraVault deployed at:", address(lzybraVault));

// //         vm.stopBroadcast();
// //     }
// // }


// pragma solidity 0.8.26;

// import "forge-std/Script.sol";
// import "../src/MockAdapterSetup.sol";
// import "../src/ERC20Setup.sol";
// import "../src/MockChainlinkSetup.sol";
// import "../src/MockCentrifugeChainSetup.sol";

// contract MockSetupDeployer is Script {
//     function run() external {
//         uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
//         vm.startBroadcast(deployerPrivateKey);

//         // Step 1: Deploy MockAdapterSetup
//         MockAdapterSetup adapterSetup = new MockAdapterSetup();
//         address[] memory testAdapters = adapterSetup.setupMockAdapters();

    
//         // Step 4: Deploy MockCentrifugeChainSetup
//         MockCentrifugeChainSetup centrifugeSetup = new MockCentrifugeChainSetup();
//         address centrifugeChain = centrifugeSetup.setupCentrifugeChain(testAdapters);
//         console.log("MockCentrifugeChain deployed at:", centrifugeChain);
//         // console.log(testAdapters);

//         vm.stopBroadcast();
//     }
// }
