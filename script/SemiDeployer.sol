// // SPDX-License-Identifier: AGPL-3.0-only
// pragma solidity <=0.8.26;

// import "forge-std/Script.sol";

// // Import core contracts
// import {PoolManager} from "../contracts/Zybra/PoolManager.sol";
// import {InvestmentManager} from "../contracts/Zybra/InvestmentManager.sol";
// import {CentrifugeRouter} from "../contracts/Zybra/CentrifugeRouter.sol";

// import {Root} from "../contracts/Zybra/Root.sol";
// import {Lzybra} from "../contracts/Zybra/token/Lzybra.sol";
// import {Escrow} from "../contracts/Zybra/Escrow.sol";

// // Import mock and dependency setup scripts
// import "../src/ERC20Setup.sol";
// import "../src/MockChainlinkSetup.sol";

// // Import individual deployers
// import {LzybraDeployer} from "./LzybraDeployer.sol";

// contract SemiSystemDeployer is Script {
//     function run() external {
//         uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
//         vm.startBroadcast(deployerPrivateKey);

//         address deployer = msg.sender;
//         console.log("Deployer address:", deployer);

//         // Use provided contract addresses
//         address root = 0x86aFA8451FB7bDAa6eCE9eD9980a603Ab3705c6f;
//         address guardian = 0x0E371D2F84Bbf2D7773F7f51Fa434B192550240d;
//         address restrictionManager = 0x318228Ca44F96fe7d2DA84Ab38cd3E9775d1170a;
//         address vaultFactory = 0x934eA3cAF6A798Cdf441408bF8C4D4F4E698cef0;
//         address trancheFactory = 0xcE4D15c9d35995e5F46FE406c3E6aa3Fb97ad978;
//         address escrow = 0x1C535265A20Cfb5FE20baab086642C245117D6c9;
//         address poolManager = 0xfFFAFb8d12d130414FD423A1dEb35130ac302D10;
//         address investmentManager = 0x8503b4452Bf6238cC76CdbEE223b46d7196b1c93;
//         address gateway = 0xeda53c42fCaa2a36473AE95c7EB8CE271D4979CD;
//         address gasService = 0x314fc3bf9984ca64DBB0d6b5A513F1cAAb812A4c;
//         address router = 0x1e67906F3F990F7d1B53bfcAB97346d4B16310E3;

//         // Step 5: Deploy Mock ERC20 and Chainlink Mock
//         ERC20Setup erc20Setup = new ERC20Setup();
//         address usdc = erc20Setup.setupERC20();

//         MockChainlinkSetup mockChainlinkSetup = new MockChainlinkSetup();
//         address chainlinkMock = mockChainlinkSetup.setupMockChainlink();

//         // Deploy Zybra Configurator
       
    
//         // Step 6: Deploy Lzybra and LzybraVault
//         LzybraDeployer lzybraDeployer = new LzybraDeployer();
//         (address lzybra, address lzybraVault, address configurator) = lzybraDeployer.deploy(
//             usdc,
//             chainlinkMock,
//             poolManager

//         );
  

//         console.log("USDC deployed at:", address(usdc));
//         console.log("Chainlink Mock deployed at:", address(chainlinkMock));
//         console.log("Lzybra deployed at:", lzybra);
//         console.log("LzybraVault deployed at:", lzybraVault);

      

//         console.log("System successfully deployed and connected!");

//         vm.stopBroadcast();
//     }
// }
