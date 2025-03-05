// // SPDX-License-Identifier: AGPL-3.0-only
// pragma solidity 0.8.26;

// import "forge-std/Script.sol";



// // Import core contracts
// import {PoolManager} from "../contracts/Zybra/PoolManager.sol";
// import {InvestmentManager} from "../contracts/Zybra/InvestmentManager.sol";
// import {CentrifugeRouter} from "../contracts/Zybra/CentrifugeRouter.sol";
// import {ZybraConfigurator} from "../contracts/Zybra/configuration/ZybraConfigurator.sol";
// import {Root} from "../contracts/Zybra/Root.sol";
// import {Lzybra} from "../contracts/Zybra/token/Lzybra.sol";
// import {Escrow} from "../contracts/Zybra/Escrow.sol";

// // Import mock and dependency setup scripts
// import "../src/ERC20Setup.sol";
// import "../src/MockChainlinkSetup.sol";


// // Import individual deployers
// import {RootEscrowDeployer} from "./RootEscrowDeployer.sol";
// import {FactoryDeployer} from "./FactoryDeployer.sol";
// import {GatewayDeployer} from "./GatewayDeployer.sol";
// import {LzybraDeployer} from "./LzybraDeployer.sol";


// contract FullSystemDeployer is Script {
//     function run() external {
//         uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
//         vm.startBroadcast(deployerPrivateKey);

//         address deployer = msg.sender;
//         console.log("Deployer address:", deployer);
//         // Step 1: Deploy Root and Escrow
//         RootEscrowDeployer rootEscrowDeployer = new RootEscrowDeployer();
//         (address escrow, address root) = rootEscrowDeployer.deploy(deployer);

//         // Step 2: Deploy Factories
//         FactoryDeployer factoryDeployer = new FactoryDeployer();
//         (
//             address vaultFactory,
//             address restrictionManager,
//             address trancheFactory
//         ) = factoryDeployer.call(root, deployer);

//         // Step 3: Deploy PoolManager and InvestmentManager
//         PoolManager poolManager = new PoolManager(escrow, vaultFactory, trancheFactory);
//         InvestmentManager investmentManager = new InvestmentManager(root, escrow);

//         console.log("PoolManager deployed at:", address(poolManager));
//         console.log("InvestmentManager deployed at:", address(investmentManager));

//         // Step 4: Deploy Gateway and GasService
//         GatewayDeployer gatewayDeployer = new GatewayDeployer();
//         (address gasService, address gateway) = gatewayDeployer.call(
//             root,
//             address(poolManager),
//             address(investmentManager)
//         );

//         // Step 5: Deploy Mock ERC20 and Chainlink Mock
//         ERC20Setup erc20Setup = new ERC20Setup();
//         address erc20 = erc20Setup.setupERC20();

//         MockChainlinkSetup mockChainlinkSetup = new MockChainlinkSetup();
//         address chainlinkMock = mockChainlinkSetup.setupMockChainlink();

//         // Deploy Zybra Configurator

//         // Step 6: Deploy Lzybra and LzybraVault
//         LzybraDeployer lzybraDeployer = new LzybraDeployer();
//         (address lzybra, address lzybraVault, address configurator) = lzybraDeployer.deploy(
//             erc20,
//             chainlinkMock,
//             address(poolManager)
//         );

//         // Step 7: Deploy Router
//         CentrifugeRouter router = new CentrifugeRouter(
//             escrow,
//             gateway,
//             address(poolManager)
//         );
//         console.log("USDC deployed at:", address(erc20));
//         console.log("Configurator deployed at:", address(configurator));
//         console.log("Chainlink Mock deployed at:", address(chainlinkMock));
//         console.log("CentrifugeRouter deployed at:", address(router));
//         console.log("Lzybra owner at:", Lzybra(lzybra).owner());

//         // Final Step: System Connection

//            Root(root).rely(address(this)); // Ensure the Deployer is authorized to make changes
//         Root(root).rely(address(gateway));
//         Root(root).rely(address(investmentManager));
//         Root(root).rely(address(poolManager));
//         Root(root).rely(address(router));
//         Root(root).rely(address(lzybraVault));
//         Root(root).endorse(address(router)); // Call after rely to ensure authorization
//         Root(root).endorse(address(escrow));

//         investmentManager.rely(address(gateway));
//         poolManager.rely(address(gateway));

//         Escrow(escrow).rely(address(root));

//         console.log("System successfully deployed and connected!");

//         vm.stopBroadcast();
//     }
// }
