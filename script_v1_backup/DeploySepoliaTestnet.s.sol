// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/ZybraGroup.sol";
import "../src/ZybraGroupFactory.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockERC4626Vault.sol";

/**
 * @title DeploySepoliaTestnet
 * @dev Comprehensive deployment script for Sepolia testnet
 * @notice Deploys Mock ERC4626 vault, MockERC20 (USDC), ZybraGroupFactory, and a test ZybraGroup
 */
contract DeploySepoliaTestnet is Script {
    // Deployment addresses (will be set during deployment)
    MockERC20 public mockUSDC;
    MockERC4626Vault public mockVault;
    ZybraGroupFactory public factory;
    ZybraGroup public testGroup;

    // Test parameters
    uint256 public constant CONTRIBUTION_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CYCLE_LENGTH = 4; // 4 weeks for testing

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

        console.log("=== Sepolia Testnet Deployment ===");
        console.log("Deployer address:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Mock USDC (6 decimals like real USDC)
        console.log("1. Deploying Mock USDC...");
        mockUSDC = new MockERC20("USD Coin", "USDC", 6);
        require(address(mockUSDC) != address(0), "Mock USDC deployment failed");
        console.log("   Mock USDC deployed at:", address(mockUSDC));

        // Step 2: Deploy Mock ERC4626 Vault
        console.log("2. Deploying Mock ERC4626 Vault...");
        mockVault = new MockERC4626Vault(mockUSDC, "Mock USDC Vault", "mUSDC-Vault");
        require(address(mockVault) != address(0), "Mock Vault deployment failed");
        console.log("   Mock Vault deployed at:", address(mockVault));

        // Step 3: Deploy ZybraGroupFactory
        console.log("3. Deploying ZybraGroupFactory...");
        factory = new ZybraGroupFactory();
        require(address(factory) != address(0), "Factory deployment failed");
        console.log("   Factory deployed at:", address(factory));

        // Step 4: Deploy a test ZybraGroup via factory
        console.log("4. Deploying test ZybraGroup...");
        uint256 poolStartTime = block.timestamp + 1 hours; // Start in 1 hour
        address testGroupAddress = factory.deployGroup(
            address(mockUSDC),
            CONTRIBUTION_AMOUNT,
            1 weeks, // cycleDuration - 1 week
            CYCLE_LENGTH, // totalCycles - 4 cycles
            deployer,
            address(mockVault)
        );
        require(testGroupAddress != address(0), "ZybraGroup deployment failed");
        testGroup = ZybraGroup(testGroupAddress);
        console.log("   Test ZybraGroup deployed at:", testGroupAddress);

        // Step 5: Mint test USDC to deployer
        console.log("5. Minting test USDC to deployer...");
        uint256 mintAmount = 10000e6; // 10,000 USDC
        mockUSDC.mint(deployer, mintAmount);
        console.log("   Minted", mintAmount / 1e6, "USDC to deployer");

        vm.stopBroadcast();

        // Print summary
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Mock USDC:", address(mockUSDC));
        console.log("Mock Vault:", address(mockVault));
        console.log("ZybraGroupFactory:", address(factory));
        console.log("Test ZybraGroup:", address(testGroup));
        console.log("");
        console.log("=== Test Group Info ===");
        console.log("Admin:", deployer);
        console.log("Asset:", address(mockUSDC));
        console.log("Contribution Amount:", CONTRIBUTION_AMOUNT / 1e6, "USDC");
        console.log("Cycle Length:", CYCLE_LENGTH, "weeks");
        console.log("Group Start Time:", poolStartTime);
        console.log("Current Members:", testGroup.membersCount());
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Add members: testGroup.joinGroup(memberAddress)");
        console.log("2. Set payout order (optional): testGroup.setPayoutOrder(merkleRoot)");
        console.log("3. Start pool: testGroup.startGroup()");
        console.log("4. Members contribute: testGroup.contribute(amount)");
        console.log("5. Deposit to Vault: testGroup.depositToMorpho(amount)");
        console.log("");

        // Save deployment addresses to file
        _saveDeploymentInfo();
    }

    function _saveDeploymentInfo() internal view {
        // Deployment info for logging
        string memory deploymentInfo = string.concat(
            "# Sepolia Testnet Deployment\n\n",
            "## Contract Addresses\n",
            "- Mock USDC: ", vm.toString(address(mockUSDC)), "\n",
            "- Mock Vault: ", vm.toString(address(mockVault)), "\n",
            "- ZybraGroupFactory: ", vm.toString(address(factory)), "\n",
            "- Test ZybraGroup: ", vm.toString(address(testGroup)), "\n\n",
            "## Configuration\n",
            "- Contribution Amount: 100 USDC\n",
            "- Cycle Length: 4 weeks\n",
            "- Vault Type: ERC4626\n\n",
            "## Deployed At\n",
            "- Block Number: ", vm.toString(block.number), "\n",
            "- Timestamp: ", vm.toString(block.timestamp), "\n"
        );
        
        // Log the deployment info (variable is used)
        console.log(deploymentInfo);

        // Uncomment to save deployment info to file
        // vm.writeFile("./deployments/sepolia-latest.md", deploymentInfo);

        console.log("Deployment info ready to be saved.");
        console.log("Uncomment vm.writeFile() in _saveDeploymentInfo() to save to file.");
    }
}
