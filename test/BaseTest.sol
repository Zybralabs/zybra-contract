pragma solidity 0.8.26;
// SPDX-License-Identifier: AGPL-3.0-only
pragma abicoder v2;

// core contracts/Zybra
import {Root} from "../contracts/Zybra/Root.sol";
import {InvestmentManager} from "../contracts/Zybra/InvestmentManager.sol";
import {PoolManager} from "../contracts/Zybra/PoolManager.sol";
import {Escrow} from "../contracts/Zybra/Escrow.sol";
import {ERC7540VaultFactory} from "../contracts/Zybra/factories/ERC7540VaultFactory.sol";
import {TrancheFactory} from "../contracts/Zybra/factories/TrancheFactory.sol";
import {ERC7540Vault} from "../contracts/Zybra/ERC7540Vault.sol";
import {Tranche} from "../contracts/Zybra/token/Tranche.sol";
import {ITranche} from "../contracts/Zybra/interfaces/token/ITranche.sol";
import {ERC20} from "../contracts/Zybra/token/ERC20.sol";
import {Gateway} from "../contracts/Zybra/gateway/Gateway.sol";
import {RestrictionManager} from "../contracts/Zybra/token/RestrictionManager.sol";
import {MessagesLib} from "../contracts/Zybra/libraries/MessagesLib.sol";
import {MockSafe} from "test/mocks/MockSafe.sol";
import "contracts/Zybra/interfaces/IERC20.sol";
import {LzybraVault} from "../contracts/Zybra/pools/LzybraVault.sol";
import {ZybraConfigurator} from "../contracts/Zybra/configuration/ZybraConfigurator.sol";
import {PoolManager} from "../contracts/Zybra/PoolManager.sol";
import {Lzybra} from "../contracts/Zybra/token/LZYBRA.sol";
import {MessagesLib} from "../../../contracts/Zybra/libraries/MessagesLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// mocks
import {MockCentrifugeChain} from "../test/mocks/MockCentrifugeChain.sol";
import {mockChainlink} from "../contracts/mocks/chainLinkMock.sol";
import {MockGasService} from "../../test/mocks/MockGasService.sol";
import {MockAdapter} from "test/mocks/MockAdapter.sol";
import {Deployer} from "../script/Deployer2.s.sol";

// test env
import "forge-std/Test.sol";

contract BaseTest is Deployer, Test {
    address investor = makeAddr("investor");
    address nonMember = makeAddr("nonMember");
    address randomUser = makeAddr("randomUser");
    // default values

    // function setUp() public virtual {
    //     vm.chainId(1);

    //     // make yourself owner of the adminSafe
    //     address[] memory pausers = new address[](1);
    //     pausers[0] = self;
    //     adminSafe = address(new MockSafe(pausers, 1));

    //     // deploy core contracts/Zybra
    //     deploy(address(this));

    //     // deploy mock adapters

    //     adapter1 = new MockAdapter(address(gateway));
    //     adapter2 = new MockAdapter(address(gateway));
    //     adapter3 = new MockAdapter(address(gateway));

    //     adapter1.setReturn("estimate", uint256(1 gwei));
    //     adapter2.setReturn("estimate", uint256(1.25 gwei));
    //     adapter3.setReturn("estimate", uint256(1.75 gwei));

    //     testAdapters.push(address(adapter1));
    //     testAdapters.push(address(adapter2));
    //     testAdapters.push(address(adapter3));

    //     // wire contracts/Zybra
    //     // remove deployer access
    //     // removeDeployerAccess(address(adapter)); // need auth permissions in tests

    //     centrifugeChain = new MockCentrifugeChain(testAdapters);
    //     mockedGasService = new MockGasService();
    //     erc20 = _newErc20("X's Dollar", "USDX", 6);
    //     lzybra = new Lzybra("Lzybra", "LZYB");

    //     gateway.file("adapters", testAdapters);

    //     ChainLinkMock = new mockChainlink();
    //     // configurator.initGTialize(address(this), address(erc20));
    //     ZybraConfigurator configuratorImpl = new ZybraConfigurator();
    //     bytes memory initData = abi.encodeWithSelector(
    //         ZybraConfigurator.initialize.selector,
    //         address(lzybra),
    //         address(erc20)
    //     );

    //     ERC1967Proxy configuratorProxy = new ERC1967Proxy(
    //         address(configuratorImpl),
    //         initData
    //     );
    //     configurator = ZybraConfigurator(address(configuratorProxy));
    //     console.log(
    //         "ZybraConfigurator Proxy deployed at:",
    //         address(configuratorProxy)
    //     );

    //     // Deploy LzybraVault
    //     LzybraVault lzybraVaultImpl = new LzybraVault();
    //     console.log(
    //         "LzybraVault Implementation deployed at:",
    //         address(lzybraVaultImpl)
    //     );

    //     bytes memory vaultInitData = abi.encodeWithSelector(
    //         LzybraVault.initialize.selector,
    //         address(ChainLinkMock),
    //         address(erc20),
    //         address(lzybra),
    //         address(poolManager),
    //         address(configurator)
    //     );

    //     ERC1967Proxy vaultProxy = new ERC1967Proxy(
    //         address(lzybraVaultImpl),
    //         vaultInitData
    //     );
    //     Lzybravault = LzybraVault(address(vaultProxy));
    //     configurator.setMintVaultMaxSupply(
    //         address(Lzybravault),
    //         200000000 * 10 ** 18
    //     );

    //     assertEq(configurator.redemptionFee(), 50); // Check initial values
    //     assertEq(configurator.flashloanFee(), 500);
    //     lzybra.grantMintRole(address(Lzybravault));
    //     gateway.file("gasService", address(mockedGasService));
    //     vm.deal(address(gateway), GATEWAY_INITIAL_BALACE);

    //     mockedGasService.setReturn("estimate", uint256(0.5 gwei));
    //     mockedGasService.setReturn("shouldRefuel", true);

    //     // Label contracts/Zybra
    //     vm.label(address(root), "Root");
    //     vm.label(address(investmentManager), "InvestmentManager");
    //     vm.label(address(poolManager), "PoolManager");
    //     vm.label(address(gateway), "Gateway");
    //     vm.label(address(erc20), "ERC20");
    //     vm.label(address(Lzybravault), "Lzybravault");
    //     vm.label(address(configurator), "configurator");
    //     vm.label(address(centrifugeChain), "CentrifugeChain");
    //     vm.label(address(router), "CentrifugeRouter");
    //     vm.label(address(gasService), "GasService");
    //     vm.label(address(mockedGasService), "MockGasService");
    //     vm.label(address(escrow), "Escrow");
    //     vm.label(address(routerEscrow), "RouterEscrow");
    //     vm.label(address(guardian), "Guardian");
    //     vm.label(address(poolManager.trancheFactory()), "TrancheFactory");
    //     vm.label(address(poolManager.vaultFactory()), "ERC7540VaultFactory");

    //     // Exclude predeployed contracts/Zybra from invariant tests by default
    //     excludeContract(address(root));
    //     excludeContract(address(investmentManager));
    //     excludeContract(address(poolManager));
    //     excludeContract(address(gateway));
    //     excludeContract(address(erc20));
    //     excludeContract(address(centrifugeChain));
    //     excludeContract(address(router));
    //     excludeContract(address(escrow));
    //     excludeContract(address(routerEscrow));
    //     excludeContract(address(guardian));
    //     excludeContract(address(poolManager.trancheFactory()));
    //     excludeContract(address(poolManager.vaultFactory()));
    // }

   
    // helpers


    function deposit(
        address _vault,
        address _investor,
        uint256 amount,
        uint256 lzybra_amount
    ) public {
        deposit(_vault, _investor, amount, true, lzybra_amount);
    }

    function deposit(
        address _vault,
        address _investor,
        uint256 amount,
        bool claimDeposit,
        uint256 lzybra_amount
    ) public {
        ERC7540Vault vault = ERC7540Vault(_vault);
        erc20.mint(_investor, amount);
        centrifugeChain.updateMember(
            vault.poolId(),
            vault.trancheId(),
            _investor,
            type(uint64).max
        ); // add user as
        // member
        vm.prank(msg.sender);
        console2.log("requestDeposit====>", address(this));

        console2.log("requestDeposit====>", address(Lzybravault));

        root.endorse(address(Lzybravault));
        vm.startPrank(_investor);
        vault.setOperator(address(Lzybravault), true);
        erc20.approve(address(Lzybravault), amount); // add allowance
        console2.log("requestDeposit====>", address(this));
        Lzybravault.requestDeposit(amount, _vault);
        // trigger executed collectInvest
        uint128 assetId = poolManager.assetToId(address(erc20)); // retrieve assetId
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(),
            vault.trancheId(),
            bytes32(bytes20(_investor)),
            assetId,
            uint128(amount),
            uint128(amount)
        );
        uint256 shares = vault.maxMint(_investor);
        if (claimDeposit) {
            uint256 numerator = 75;
            uint256 denominator = 100;
            uint256 multiplier = (numerator * 1e18) / denominator; // Using a large number to avoid fractional division
            console2.log("Deposit====>", address(this));

            Lzybravault.deposit(address(vault), lzybra_amount); // claim the tranches
        }
        vm.stopPrank();
    }

    // Helpers
    function _addressToBytes32(address x) internal pure returns (bytes32) {
        return bytes32(bytes20(x));
    }

    function _newErc20(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal returns (ERC20) {
        ERC20 asset = new ERC20(decimals);
        asset.file("name", name);
        asset.file("symbol", symbol);
        return asset;
    }

    function _bytes16ToString(
        bytes16 _bytes16
    ) public pure returns (string memory) {
        uint8 i = 0;
        while (i < 16 && _bytes16[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 16 && _bytes16[i] != 0; i++) {
            bytesArray[i] = _bytes16[i];
        }
        return string(bytesArray);
    }

    function _uint256ToString(
        uint256 _i
    ) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function random(
        uint256 maxValue,
        uint256 nonce
    ) internal view returns (uint256) {
        if (maxValue == 1) {
            return maxValue;
        }
        uint256 randomnumber = uint256(
            keccak256(abi.encodePacked(block.timestamp, self, nonce))
        ) % (maxValue - 1);
        return randomnumber + 1;
    }

    // assumptions
    function amountAssumption(uint256 amount) public pure returns (bool) {
        return (amount > 1 && amount < MAX_UINT128);
    }

    function addressAssumption(address user) public view returns (bool) {
        return (user != address(0) &&
            user != address(erc20) &&
            user.code.length == 0);
    }
}
