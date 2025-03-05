// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Root} from "../contracts/Zybra/Root.sol";
import {Gateway} from "../contracts/Zybra/gateway/Gateway.sol";
import {GasService} from "../contracts/Zybra/gateway/GasService.sol";
import {InvestmentManager} from "../contracts/Zybra/InvestmentManager.sol";
import {PoolManager} from "../contracts/Zybra/PoolManager.sol";
import {Escrow} from "../contracts/Zybra/Escrow.sol";
import {CentrifugeRouter} from "../contracts/Zybra/CentrifugeRouter.sol";
import {ZybraConfigurator} from "../contracts/Zybra/configuration/ZybraConfigurator.sol";
import {LzybraVault} from "../contracts/Zybra/pools/LzybraVault.sol";
import {Lzybra} from "../contracts/Zybra/token/LZYBRA.sol";
import {mockChainlink} from "../contracts/mocks/chainLinkMock.sol";
import {ERC20} from "../contracts/Zybra/token/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "forge-std/Script.sol";

contract StakingDeployer is Script {
    Root public root;
    InvestmentManager public investmentManager;
    PoolManager public poolManager;
    Escrow public escrow;
    Escrow public routerEscrow;
    Gateway public gateway;
    GasService public gasService;
    CentrifugeRouter public router;
    LzybraVault public lzybraVault;
    Lzybra public lzybra;
    mockChainlink public chainlinkMock;
    ZybraConfigurator public configurator;
    ERC20 public erc20;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Connect to existing contracts
        root = Root(0x86aFA8451FB7bDAa6eCE9eD9980a603Ab3705c6f);
        investmentManager = InvestmentManager(payable(0x8503b4452Bf6238cC76CdbEE223b46d7196b1c93));
        poolManager = PoolManager(payable(0xfFFAFb8d12d130414FD423A1dEb35130ac302D10));
        escrow = Escrow(payable(0x1C535265A20Cfb5FE20baab086642C245117D6c9));
        routerEscrow = Escrow(payable(0x425af5C6A68f535A47Cb811f5eB9dad3F6235432));
        gateway = Gateway(payable(0xeda53c42fCaa2a36473AE95c7EB8CE271D4979CD));
        gasService = GasService(payable(0x314fc3bf9984ca64DBB0d6b5A513F1cAAb812A4c));
        router = CentrifugeRouter(payable(0x1e67906F3F990F7d1B53bfcAB97346d4B16310E3));

        // Deploy only new required contracts
        chainlinkMock = new mockChainlink();
        console.log("Chainlink Mock deployed at:", address(chainlinkMock));

        erc20 =  ERC20(0xf703620970dCB2f6C5a8eAc1c446Ec1AbDdb8191);
        console.log("USDC deployed at:", address(erc20));

        lzybra = new Lzybra("Lzybra", "LZY");
        console.log("Lzybra deployed at:", address(lzybra));

        // Deploy and initialize configurator
        ZybraConfigurator configuratorImpl = new ZybraConfigurator();
        console.log("ZybraConfigurator Implementation deployed at:", address(configuratorImpl));

        bytes memory initData = abi.encodeWithSelector(
            ZybraConfigurator.initialize.selector,
            address(lzybra),
            address(erc20)
        );
        
        ERC1967Proxy configuratorProxy = new ERC1967Proxy(
            address(configuratorImpl),
            initData
        );
        configurator = ZybraConfigurator(address(configuratorProxy));
        console.log("ZybraConfigurator Proxy deployed at:", address(configuratorProxy));

        // Deploy LzybraVault
        LzybraVault lzybraVaultImpl = new LzybraVault();
        console.log("LzybraVault Implementation deployed at:", address(lzybraVaultImpl));

        bytes memory vaultInitData = abi.encodeWithSelector(
            LzybraVault.initialize.selector,
            address(chainlinkMock),
            address(erc20),
            address(lzybra),
            address(poolManager),
            address(configurator)
        );

        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(lzybraVaultImpl),
            vaultInitData
        );
        lzybraVault = LzybraVault(address(vaultProxy));
        console.log("LzybraVault Proxy deployed at:", address(vaultProxy));

        // Setup permissions
        lzybra.grantMintRole(address(lzybraVault));
        configurator.setMintVaultMaxSupply(address(lzybraVault), 200000000 * 10**18);
        
        // Add vault
        lzybraVault.addVault(0x0a7210FCFdd69f450FE8Cc1ed073b42180d23F37);

        vm.stopBroadcast();
    }
}