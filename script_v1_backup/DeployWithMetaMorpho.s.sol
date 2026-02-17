// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/ZybraGroup.sol";
import "../src/ZybraGroupFactory.sol";
import "../src/MetaMorphoFactory.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockMorpho.sol";
import "../src/mocks/MockMetaMorpho.sol";
import {MarketParams, Id} from "../src/interfaces/IMorpho.sol";

/**
 * @title DeployWithMetaMorpho
 * @dev Comprehensive deployment script for testnet with MockMorpho and MockMetaMorpho
 * @notice Deploys complete ecosystem:
 *   1. MockERC20 (USDC)
 *   2. MockMorpho protocol
 *   3. MockMetaMorpho vault (via factory)
 *   4. ZybraGroupFactory
 *   5. Test ZybraGroup
 */
contract DeployWithMetaMorpho is Script {
    /* DEPLOYED CONTRACTS */
    MockERC20 public mockUSDC;
    MockMorpho public mockMorpho;
    MetaMorphoFactory public metaMorphoFactory;
    MockMetaMorpho public mockMetaMorphoVault;
    ZybraGroupFactory public zybraFactory;
    ZybraGroup public testGroup;

    /* DEPLOYMENT PARAMETERS */
    uint256 public constant CONTRIBUTION_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CYCLE_LENGTH = 4; // 4 weeks for testing
    uint256 public constant INITIAL_SUPPLY_CAP = 1_000_000e6; // 1M USDC cap per market

    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey;

        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            revert("PRIVATE_KEY not found in .env file. Please set it.");
        }

        require(deployerPrivateKey != 0, "Invalid PRIVATE_KEY: cannot be 0");

        address deployer = vm.addr(deployerPrivateKey);
        require(deployer != address(0), "Invalid deployer address");

        console.log("=== MetaMorpho + Zybra Testnet Deployment ===");
        console.log("Deployer address:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        /* STEP 1: Deploy Mock USDC */
        console.log("1. Deploying Mock USDC...");
        mockUSDC = new MockERC20("USD Coin", "USDC", 6);
        require(address(mockUSDC) != address(0), "Mock USDC deployment failed");
        console.log("   Mock USDC deployed at:", address(mockUSDC));

        /* STEP 2: Deploy MockMorpho */
        console.log("2. Deploying MockMorpho...");
        mockMorpho = new MockMorpho();
        require(address(mockMorpho) != address(0), "MockMorpho deployment failed");
        console.log("   MockMorpho deployed at:", address(mockMorpho));

        /* STEP 3: Create a Morpho Market */
        console.log("3. Creating Morpho market for USDC...");
        MarketParams memory marketParams = MarketParams({
            loanToken: address(mockUSDC),
            collateralToken: address(0), // No collateral for supply-only vault
            oracle: address(0),
            irm: address(1), // Mock IRM address
            lltv: 0 // No LLTV for supply-only
        });
        mockMorpho.createMarket(marketParams);
        Id marketId = Id.wrap(keccak256(abi.encode(marketParams)));
        console.log("   Market ID:", uint256(Id.unwrap(marketId)));

        /* STEP 4: Deploy MetaMorphoFactory */
        console.log("4. Deploying MetaMorphoFactory...");
        metaMorphoFactory = new MetaMorphoFactory(address(mockMorpho));
        require(address(metaMorphoFactory) != address(0), "MetaMorphoFactory deployment failed");
        console.log("   MetaMorphoFactory deployed at:", address(metaMorphoFactory));

        /* STEP 5: Deploy MockMetaMorpho Vault via Factory */
        console.log("5. Deploying MockMetaMorpho vault via factory...");
        address vaultAddress = metaMorphoFactory.deployVaultWithDefaultMorpho(
            address(mockUSDC),
            "MetaMorpho USDC Vault",
            "mmUSDC",
            deployer
        );
        require(vaultAddress != address(0), "MockMetaMorpho deployment failed");
        mockMetaMorphoVault = MockMetaMorpho(vaultAddress);
        console.log("   MockMetaMorpho vault deployed at:", vaultAddress);

        /* STEP 6: Configure the MetaMorpho Vault */
        console.log("6. Configuring MetaMorpho vault...");

        // Set supply cap for the market
        mockMetaMorphoVault.submitCap(marketParams, INITIAL_SUPPLY_CAP);
        console.log("   Set supply cap:", INITIAL_SUPPLY_CAP / 1e6, "USDC");

        // Set performance fee (5%)
        mockMetaMorphoVault.setFee(0.05e18); // 5% fee in WAD
        console.log("   Set performance fee: 5%");

        /* STEP 7: Fund the vault with initial USDC */
        console.log("7. Funding vault with initial liquidity...");
        uint256 initialVaultFunding = 10_000e6; // 10,000 USDC
        mockUSDC.mint(deployer, initialVaultFunding);
        mockUSDC.approve(address(mockMetaMorphoVault), initialVaultFunding);
        mockMetaMorphoVault.deposit(initialVaultFunding, deployer);
        console.log("   Deposited", initialVaultFunding / 1e6, "USDC to vault");

        // Supply to Morpho market
        mockMetaMorphoVault.supplyToMarket(marketParams, initialVaultFunding);
        console.log("   Supplied to Morpho market");

        /* STEP 8: Deploy ZybraGroupFactory */
        console.log("8. Deploying ZybraGroupFactory...");
        zybraFactory = new ZybraGroupFactory();
        require(address(zybraFactory) != address(0), "ZybraGroupFactory deployment failed");
        console.log("   ZybraGroupFactory deployed at:", address(zybraFactory));

        /* STEP 9: Deploy test ZybraGroup via factory */
        console.log("9. Deploying test ZybraGroup...");
        uint256 poolStartTime = block.timestamp + 1 hours; // Start in 1 hour
        address testGroupAddress = zybraFactory.deployGroup(
            address(mockUSDC),
            CONTRIBUTION_AMOUNT,
            1 weeks, // cycleDuration - 1 week
            CYCLE_LENGTH, // totalCycles - 4 cycles
            deployer,
            address(mockMetaMorphoVault) // Use MockMetaMorpho vault
        );
        require(testGroupAddress != address(0), "ZybraGroup deployment failed");
        testGroup = ZybraGroup(testGroupAddress);
        console.log("   Test ZybraGroup deployed at:", testGroupAddress);

        /* STEP 10: Mint test USDC to deployer for testing */
        console.log("10. Minting test USDC to deployer...");
        uint256 testMintAmount = 50_000e6; // 50,000 USDC for testing
        mockUSDC.mint(deployer, testMintAmount);
        console.log("   Minted", testMintAmount / 1e6, "USDC to deployer");

        vm.stopBroadcast();

        /* PRINT DEPLOYMENT SUMMARY */
        _printDeploymentSummary(deployer, poolStartTime, marketId);

        /* SAVE DEPLOYMENT INFO */
        _saveDeploymentInfo(deployer, poolStartTime, marketId);
    }

    function _printDeploymentSummary(address deployer, uint256 poolStartTime, Id marketId) internal view {
        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("");
        console.log("Core Contracts:");
        console.log("  Mock USDC:", address(mockUSDC));
        console.log("  MockMorpho:", address(mockMorpho));
        console.log("  MetaMorphoFactory:", address(metaMorphoFactory));
        console.log("  MockMetaMorpho Vault:", address(mockMetaMorphoVault));
        console.log("  ZybraGroupFactory:", address(zybraFactory));
        console.log("  Test ZybraGroup:", address(testGroup));
        console.log("");
        console.log("Morpho Market:");
        console.log("  Market ID:", uint256(Id.unwrap(marketId)));
        console.log("  Loan Token:", address(mockUSDC));
        console.log("  Supply Cap:", INITIAL_SUPPLY_CAP / 1e6, "USDC");
        console.log("");
        console.log("MetaMorpho Vault Info:");
        console.log("  Name:", mockMetaMorphoVault.name());
        console.log("  Symbol:", mockMetaMorphoVault.symbol());
        console.log("  Total Assets:", mockMetaMorphoVault.totalAssets() / 1e6, "USDC");
        console.log("  Total Supply (shares):", mockMetaMorphoVault.totalSupply() / 1e6);
        console.log("  Performance Fee: 5%");
        console.log("  Owner:", mockMetaMorphoVault.owner());
        console.log("");
        console.log("ZybraGroup Info:");
        console.log("  Admin:", deployer);
        console.log("  Asset:", address(mockUSDC));
        console.log("  Vault:", address(mockMetaMorphoVault));
        console.log("  Contribution Amount:", CONTRIBUTION_AMOUNT / 1e6, "USDC");
        console.log("  Cycle Length:", CYCLE_LENGTH, "weeks");
        console.log("  Group Start Time:", poolStartTime);
        console.log("  Current Members:", testGroup.membersCount());
        console.log("");
        console.log("=== TESTING GUIDE ===");
        console.log("");
        console.log("1. Add members to ZybraGroup:");
        console.log("   testGroup.joinGroup(memberAddress)");
        console.log("");
        console.log("2. Set payout order (optional):");
        console.log("   testGroup.setPayoutOrder(merkleRoot)");
        console.log("");
        console.log("3. Start the pool:");
        console.log("   testGroup.startGroup()");
        console.log("");
        console.log("4. Members contribute USDC:");
        console.log("   mockUSDC.approve(address(testGroup), amount)");
        console.log("   testGroup.contribute(amount)");
        console.log("");
        console.log("5. Deposit to MetaMorpho vault:");
        console.log("   testGroup.depositToMorpho(amount)");
        console.log("");
        console.log("6. Monitor vault performance:");
        console.log("   mockMetaMorphoVault.totalAssets()");
        console.log("   mockMetaMorphoVault.totalSupply()");
        console.log("");
    }

    function _saveDeploymentInfo(address deployer, uint256 poolStartTime, Id marketId) internal view {
        string memory deploymentInfo = string.concat(
            "# MetaMorpho + Zybra Testnet Deployment\n\n",
            "## Contract Addresses\n",
            "- Mock USDC: `", vm.toString(address(mockUSDC)), "`\n",
            "- MockMorpho: `", vm.toString(address(mockMorpho)), "`\n",
            "- MetaMorphoFactory: `", vm.toString(address(metaMorphoFactory)), "`\n",
            "- MockMetaMorpho Vault: `", vm.toString(address(mockMetaMorphoVault)), "`\n",
            "- ZybraGroupFactory: `", vm.toString(address(zybraFactory)), "`\n",
            "- Test ZybraGroup: `", vm.toString(address(testGroup)), "`\n\n",
            "## Morpho Market\n",
            "- Market ID: `", vm.toString(uint256(Id.unwrap(marketId))), "`\n",
            "- Loan Token: `", vm.toString(address(mockUSDC)), "`\n",
            "- Supply Cap: 1,000,000 USDC\n\n",
            "## Configuration\n",
            "- Contribution Amount: 100 USDC\n",
            "- Cycle Length: 4 weeks\n",
            "- Performance Fee: 5%\n",
            "- Deployer: `", vm.toString(deployer), "`\n\n",
            "## Deployed At\n",
            "- Block Number: ", vm.toString(block.number), "\n",
            "- Timestamp: ", vm.toString(block.timestamp), "\n",
            "- Group Start Time: ", vm.toString(poolStartTime), "\n"
        );

        console.log("");
        console.log("=== DEPLOYMENT INFO ===");
        console.log(deploymentInfo);
        console.log("");
        console.log("To save deployment info to file:");
        console.log("Uncomment vm.writeFile() in _saveDeploymentInfo()");

        // Uncomment to save to file
        // vm.writeFile("./deployments/metamorpho-testnet-latest.md", deploymentInfo);
    }
}
