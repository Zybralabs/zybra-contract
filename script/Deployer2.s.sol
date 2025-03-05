// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Root} from "../contracts/Zybra/Root.sol";
import {Gateway} from "../contracts/Zybra/gateway/Gateway.sol";
import {GasService} from "../contracts/Zybra/gateway/GasService.sol";
import {InvestmentManager} from "../contracts/Zybra/InvestmentManager.sol";
import {TrancheFactory} from "../contracts/Zybra/factories/TrancheFactory.sol";
import {ERC7540VaultFactory} from "../contracts/Zybra/factories/ERC7540VaultFactory.sol";
import {RestrictionManager} from "../contracts/Zybra/token/RestrictionManager.sol";
import {TransferProxyFactory} from "../contracts/Zybra/factories/TransferProxyFactory.sol";
import {PoolManager} from "../contracts/Zybra/PoolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Escrow} from "../contracts/Zybra/Escrow.sol";
import {CentrifugeRouter} from "../contracts/Zybra/CentrifugeRouter.sol";
import {Guardian} from "../contracts/Zybra/admin/Guardian.sol";
import {LzybraVault} from "../contracts/Zybra/pools/LzybraVault.sol";
import {IAuth} from "../contracts/Zybra/interfaces/IAuth.sol";
import "forge-std/Script.sol";
import {ERC7540Vault} from "../contracts/Zybra/ERC7540Vault.sol";

import {Lzybra} from "../contracts/Zybra/token/LZYBRA.sol";

import {MockCentrifugeChain} from "../test/mocks/MockCentrifugeChain.sol";
import {mockChainlink} from "../contracts/mocks/chainLinkMock.sol";
import {MockGasService} from "test/mocks/MockGasService.sol";
import {MockSafe} from "test/mocks/MockSafe.sol";

import {MockAdapter} from "test/mocks/MockAdapter.sol";
import {ERC20} from "../contracts/Zybra/token/ERC20.sol";
import {ZybraConfigurator} from "../contracts/Zybra/configuration/ZybraConfigurator.sol";

contract Deployer is Script {
    uint256 internal constant delay = 48 hours;
    address adminSafe;
    address[] adapters;

    Root public root;
    InvestmentManager public investmentManager;
    PoolManager public poolManager;
    Escrow public escrow;
    Escrow public routerEscrow;
    Guardian public guardian;
    Gateway public gateway;
    GasService public gasService;
    CentrifugeRouter public router;
    TransferProxyFactory public transferProxyFactory;
    address public vaultFactory;
    address public restrictionManager;
    address public trancheFactory;
    MockCentrifugeChain centrifugeChain;
    MockGasService mockedGasService;
    address[] testAdapters;
    ERC20 public erc20;
    LzybraVault public Lzybravault;
    mockChainlink public ChainLinkMock;
    Lzybra public lzybra;
    ZybraConfigurator public configurator;
    address self = address(this);
    uint128 constant MAX_UINT128 = type(uint128).max;
    uint256 constant GATEWAY_INITIAL_BALACE = 10 ether;
    MockAdapter adapter1;
    MockAdapter adapter2;
    MockAdapter adapter3;
    // default values
    uint128 public defaultAssetId = 1;
    uint128 public defaultPrice = 1 * 10 ** 18;
    uint8 public defaultDecimals = 8;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        address deployer = vm.addr(deployerPrivateKey);
        // make yourself owner of the adminSafe
        address[] memory pausers = new address[](1);
        pausers[0] = deployer;
        adminSafe = address(new MockSafe(pausers, 1));
        console.log("ddddddddddddddddd", deployer);

        // deploy core contracts/Zybra
        deploy(deployer);

        // deploy mock adapters

        adapter1 = new MockAdapter(address(gateway));
        adapter2 = new MockAdapter(address(gateway));
        adapter3 = new MockAdapter(address(gateway));

        adapter1.setReturn("estimate", uint256(1 gwei));
        adapter2.setReturn("estimate", uint256(1.25 gwei));
        adapter3.setReturn("estimate", uint256(1.75 gwei));

        testAdapters.push(address(adapter1));
        testAdapters.push(address(adapter2));
        testAdapters.push(address(adapter3));

        // wire contracts/Zybra
        // remove deployer access
        // removeDeployerAccess(address(adapter)); // need auth permissions in tests

        centrifugeChain = new MockCentrifugeChain(testAdapters);
        mockedGasService = new MockGasService();
        erc20 = ERC20(0x15C46bEc4B862BABb386437CECEc9e53e8F4694A);
        lzybra = new Lzybra("Lzybra", "LZYB");

        gateway.file("adapters", testAdapters);

        ChainLinkMock = new mockChainlink();
        // configurator.initGTialize(address(this), address(erc20));
        ZybraConfigurator configuratorImpl = new ZybraConfigurator();
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
        console.log(
            "ZybraConfigurator Proxy deployed at:",
            address(configuratorProxy)
        );

        // Deploy LzybraVault
        LzybraVault lzybraVaultImpl = new LzybraVault();
        console.log(
            "LzybraVault Implementation deployed at:",
            address(lzybraVaultImpl)
        );

        bytes memory vaultInitData = abi.encodeWithSelector(
            LzybraVault.initialize.selector,
            address(ChainLinkMock),
            address(erc20),
            address(lzybra),
            address(poolManager),
            address(configurator)
        );

        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(lzybraVaultImpl),
            vaultInitData
        );
        Lzybravault = LzybraVault(address(vaultProxy));
        configurator.setMintVaultMaxSupply(
            address(Lzybravault),
            200000000 * 10 ** 18
        );

        lzybra.grantMintRole(address(Lzybravault));
        gateway.file("gasService", address(mockedGasService));
        vm.deal(address(gateway), GATEWAY_INITIAL_BALACE);

        mockedGasService.setReturn("estimate", uint256(0.5 gwei));
        mockedGasService.setReturn("shouldRefuel", true);

        uint256 amount = 1000 * 10 ** 18;
        uint256 lzybra_amount = 200 * 10 ** 18;
        uint128 price = 2 * 10 ** 18;

        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);

        Lzybravault.addVault(address(vault));

        // Setup permissions

        // Update members
        centrifugeChain.updateMember(
            vault.poolId(),
            vault.trancheId(),
            address(Lzybravault),
            type(uint64).max
        );

        centrifugeChain.updateMember(
            vault.poolId(),
            vault.trancheId(),
            deployer,
            type(uint64).max
        );
        root.endorse(address(Lzybravault));
        root.endorse(deployer);
        // Allow asset
        centrifugeChain.allowAsset(vault.poolId(), defaultAssetId);

        // Set operator
        vault.setOperator(address(Lzybravault), true);

        // Update price
        centrifugeChain.updateTranchePrice(
            vault.poolId(),
            vault.trancheId(),
            defaultAssetId,
            price,
            uint64(block.timestamp)
        );

        // Now you can proceed with deposit
        erc20.approve(address(Lzybravault), amount);
        Lzybravault.requestDeposit(amount, vault_);
        // trigger executed collectInvest
        console.log("+>>>>>>>>>>>>>>depositrequest");

        uint128 assetId = poolManager.assetToId(address(erc20)); // retrieve assetId
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(),
            vault.trancheId(),
            bytes32(bytes20(deployer)),
            assetId,
            uint128(amount),
            uint128(amount)
        );

        uint256 shares = vault.maxMint(address(this));
        uint256 numerator = 75;
        uint256 denominator = 100;
        uint256 multiplier = (numerator * 1e18) / denominator; // Using a large number to avoid fractional division
        console.log(vault.maxMint(deployer), shares);
        console.log(vault.maxDeposit(deployer), amount, 1);
        console.log(vault.pendingDepositRequest(0, deployer), 0);
        console.log(vault.claimableDepositRequest(0, deployer), amount);
        Lzybravault.deposit(address(vault), lzybra_amount); // claim the tranches
        // Label contracts/Zybra
        console.log(address(root), "Root");
        console.log(address(investmentManager), "InvestmentManager");
        console.log(address(poolManager), "PoolManager");
        console.log(address(gateway), "Gateway");
        console.log(address(erc20), "ERC20");
        console.log(address(Lzybravault), "Lzybravault");
        console.log(address(configurator), "configurator");
        console.log(address(centrifugeChain), "CentrifugeChain");
        console.log(address(router), "CentrifugeRouter");
        console.log(address(gasService), "GasService");
        console.log(address(mockedGasService), "MockGasService");
        console.log(address(escrow), "Escrow");
        console.log(address(routerEscrow), "RouterEscrow");
        console.log(address(guardian), "Guardian");
        console.log(address(poolManager.trancheFactory()), "TrancheFactory");
        console.log(address(poolManager.vaultFactory()), "ERC7540VaultFactory");

        // Exclude predeployed contracts/Zybra from invariant tests by default
    }

    // helpers
    function deployVault(
        uint64 poolId,
        uint8 trancheDecimals,
        address hook,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId,
        uint128 assetId,
        address asset
    ) public returns (address) {
        if (poolManager.idToAsset(assetId) == address(0)) {
            centrifugeChain.addAsset(assetId, asset);
        }

        if (poolManager.getTranche(poolId, trancheId) == address(0)) {
            centrifugeChain.batchAddPoolAllowAsset(poolId, assetId);
            centrifugeChain.addTranche(
                poolId,
                trancheId,
                tokenName,
                tokenSymbol,
                trancheDecimals,
                hook
            );

            poolManager.deployTranche(poolId, trancheId);
        }

        if (!poolManager.isAllowedAsset(poolId, asset)) {
            centrifugeChain.allowAsset(poolId, assetId);
        }

        address vaultAddress = poolManager.deployVault(
            poolId,
            trancheId,
            asset
        );

        return vaultAddress;
    }

    function deployVault(
        uint64 poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId,
        uint128 asset
    ) public returns (address) {
        return
            deployVault(
                poolId,
                decimals,
                restrictionManager,
                tokenName,
                tokenSymbol,
                trancheId,
                asset,
                address(erc20)
            );
    }

    function deploySimpleVault() public returns (address) {
        return
            deployVault(
                8,
                7,
                restrictionManager,
                "TestVaultZybra",
                "TestZybra",
                bytes16(bytes("1")),
                defaultAssetId,
                address(erc20)
            );
    }

    function deploy(address deployer) public {
        // If no salt is provided, a pseudo-random salt is generated,
        // thus effectively making the deployment non-deterministic
        bytes32 salt = vm.envOr(
            "DEPLOYMENT_SALT",
            keccak256(
                abi.encodePacked(
                    string(abi.encodePacked(blockhash(block.number - 1)))
                )
            )
        );

        uint64 messageCost = uint64(
            vm.envOr("MESSAGE_COST", uint256(20000000000000000))
        ); // in Weight
        uint64 proofCost = uint64(
            vm.envOr("PROOF_COST", uint256(20000000000000000))
        ); // in Weigth
        uint128 gasPrice = uint128(
            vm.envOr("GAS_PRICE", uint256(2500000000000000000))
        ); // Centrifuge Chain
        uint256 tokenPrice = vm.envOr("TOKEN_PRICE", uint256(178947400000000)); // CFG/ETH

        escrow = new Escrow{salt: salt}(deployer);
        routerEscrow = new Escrow{
            salt: keccak256(abi.encodePacked(salt, "escrow2"))
        }(deployer);
        root = new Root{salt: salt}(address(escrow), delay, deployer);
        vaultFactory = address(new ERC7540VaultFactory(address(root)));
        restrictionManager = address(
            new RestrictionManager{salt: salt}(address(root), deployer)
        );
        trancheFactory = address(
            new TrancheFactory{salt: salt}(address(root), deployer)
        );
        investmentManager = new InvestmentManager(
            address(root),
            address(escrow)
        );
        poolManager = new PoolManager(
            address(escrow),
            vaultFactory,
            trancheFactory
        );
        transferProxyFactory = new TransferProxyFactory{salt: salt}(
            address(root),
            deployer
        );
        gasService = new GasService(
            messageCost,
            proofCost,
            gasPrice,
            tokenPrice
        );
        gateway = new Gateway(
            address(root),
            address(poolManager),
            address(investmentManager),
            address(gasService)
        );
        router = new CentrifugeRouter(
            address(routerEscrow),
            address(gateway),
            address(poolManager)
        );
        guardian = new Guardian(adminSafe, address(root), address(gateway));

        _endorse();
        _rely();
        _file();
    }

    function _endorse() internal {
        root.endorse(address(router));
        root.endorse(address(escrow));
    }

    function _rely() internal {
        // Rely on PoolManager
        escrow.rely(address(poolManager));
        IAuth(vaultFactory).rely(address(poolManager));
        IAuth(trancheFactory).rely(address(poolManager));
        IAuth(restrictionManager).rely(address(poolManager));

        // Rely on Root
        router.rely(address(root));
        poolManager.rely(address(root));
        investmentManager.rely(address(root));
        gateway.rely(address(root));
        gasService.rely(address(root));
        escrow.rely(address(root));
        routerEscrow.rely(address(root));
        transferProxyFactory.rely(address(root));
        IAuth(vaultFactory).rely(address(root));
        IAuth(trancheFactory).rely(address(root));
        IAuth(restrictionManager).rely(address(root));

        // Rely on guardian
        root.rely(address(guardian));
        gateway.rely(address(guardian));

        // Rely on gateway
        root.rely(address(gateway));
        investmentManager.rely(address(gateway));
        poolManager.rely(address(gateway));
        gasService.rely(address(gateway));

        // Rely on others
        routerEscrow.rely(address(router));
        investmentManager.rely(address(vaultFactory));
    }

    function _file() public {
        poolManager.file("investmentManager", address(investmentManager));
        poolManager.file("gasService", address(gasService));
        poolManager.file("gateway", address(gateway));

        investmentManager.file("poolManager", address(poolManager));
        investmentManager.file("gateway", address(gateway));

        gateway.file("payers", address(router), true);

        transferProxyFactory.file("poolManager", address(poolManager));
    }

    function wire(address adapter) public {
        adapters.push(adapter);
        gateway.file("adapters", adapters);
        IAuth(adapter).rely(address(root));
    }

    function removeDeployerAccess(address adapter, address deployer) public {
        IAuth(adapter).deny(deployer);
        IAuth(vaultFactory).deny(deployer);
        IAuth(trancheFactory).deny(deployer);
        IAuth(restrictionManager).deny(deployer);
        transferProxyFactory.deny(deployer);
        root.deny(deployer);
        investmentManager.deny(deployer);
        poolManager.deny(deployer);
        escrow.deny(deployer);
        routerEscrow.deny(deployer);
        gateway.deny(deployer);
        router.deny(deployer);
        gasService.deny(deployer);
    }
}
