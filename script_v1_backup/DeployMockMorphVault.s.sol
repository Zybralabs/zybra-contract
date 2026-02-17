// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockMorphVault} from "src/mocks/MockMorphVault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

/**
 * @title DeployMockMorphVault
 * @notice Deployment script for MockMorphVault on testnet/mainnet
 * @dev Usage:
 *      forge script script/DeployMockMorphVault.s.sol --rpc-url <RPC_URL> --broadcast --verify
 */
contract DeployMockMorphVault is Script {
    // Configuration
    string public constant VAULT_NAME = "Zybra Morph Vault Shares";
    string public constant VAULT_SYMBOL = "zmvUSDC";
    uint256 public constant INITIAL_REWARD_FUNDING = 100e6; // 100 USDC (6 decimals)

    function run() external {
        // Get deployment parameters from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address assetToken = vm.envAddress("ASSET_TOKEN"); // Should be USDC or similar

        address deployer = vm.addr(deployerPrivateKey);

        console.log("==========================================");
        console.log("Deploying MockMorphVault");
        console.log("==========================================");
        console.log("Deployer:", deployer);
        console.log("Asset Token:", assetToken);
        console.log("Network:", block.chainid);
        console.log("==========================================");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockMorphVault
        MockMorphVault vault = new MockMorphVault(
            assetToken,
            VAULT_NAME,
            VAULT_SYMBOL,
            deployer // Owner
        );

        console.log("MockMorphVault deployed at:", address(vault));
        console.log("==========================================");
        console.log("Configuration:");
        console.log("- Vault Name:", vault.name());
        console.log("- Vault Symbol:", vault.symbol());
        console.log("- Asset:", vault.asset());
        console.log("- Owner:", vault.owner());
        console.log("- Initial APY: 10%");
        console.log("==========================================");

        vm.stopBroadcast();

        // Log deployment info
        _logDeploymentInfo(address(vault), assetToken, deployer);
    }

    function _logDeploymentInfo(
        address vaultAddress,
        address assetToken,
        address owner
    ) internal view {
        console.log("");
        console.log("==========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("==========================================");
        console.log("Vault Address:", vaultAddress);
        console.log("Asset Token:", assetToken);
        console.log("Owner:", owner);
        console.log("==========================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Fund vault with reward tokens:");
        console.log("   vault.fundRewards(amount)");
        console.log("");
        console.log("2. (Optional) Adjust reward rate:");
        console.log("   vault.setRewardRate(newRate) // in WAD, e.g., 0.15e18 = 15%");
        console.log("");
        console.log("3. Users can now:");
        console.log("   - deposit(assets, receiver)");
        console.log("   - withdraw(assets, receiver, owner)");
        console.log("   - claimRewards()");
        console.log("   - pendingRewards(user)");
        console.log("==========================================");
    }
}

/**
 * @title DeployMockMorphVaultWithMockAsset
 * @notice Deploy both mock asset and vault (for testing)
 */
contract DeployMockMorphVaultWithMockAsset is Script {
    string public constant ASSET_NAME = "Mock USDC";
    string public constant ASSET_SYMBOL = "mUSDC";
    uint8 public constant ASSET_DECIMALS = 6; // USDC has 6 decimals

    string public constant VAULT_NAME = "Zybra Morph Vault Shares";
    string public constant VAULT_SYMBOL = "zmvUSDC";

    uint256 public constant INITIAL_REWARD_FUNDING = 100e6; // 100 USDC

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("==========================================");
        console.log("Deploying MockMorphVault WITH Mock Asset");
        console.log("==========================================");
        console.log("Deployer:", deployer);
        console.log("Network:", block.chainid);
        console.log("==========================================");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Mock Asset Token
        MockERC20 asset = new MockERC20(ASSET_NAME, ASSET_SYMBOL, ASSET_DECIMALS);
        console.log("Mock Asset deployed at:", address(asset));

        // Mint initial supply to deployer for reward funding
        asset.mint(deployer, INITIAL_REWARD_FUNDING * 100); // 100x for testing
        console.log("Minted", INITIAL_REWARD_FUNDING * 100, "mock tokens to deployer");

        // Deploy MockMorphVault
        MockMorphVault vault = new MockMorphVault(
            address(asset),
            VAULT_NAME,
            VAULT_SYMBOL,
            deployer
        );
        console.log("MockMorphVault deployed at:", address(vault));

        // Approve and fund vault with rewards
        asset.approve(address(vault), INITIAL_REWARD_FUNDING);
        vault.fundRewards(INITIAL_REWARD_FUNDING);
        console.log("Funded vault with", INITIAL_REWARD_FUNDING, "reward tokens");

        vm.stopBroadcast();

        // Log deployment info
        _logDeploymentInfo(address(vault), address(asset), deployer);
    }

    function _logDeploymentInfo(
        address vaultAddress,
        address assetAddress,
        address owner
    ) internal view {
        console.log("");
        console.log("==========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("==========================================");
        console.log("Mock Asset Address:", assetAddress);
        console.log("Vault Address:", vaultAddress);
        console.log("Owner:", owner);
        console.log("==========================================");
        console.log("");
        console.log("TEST INSTRUCTIONS:");
        console.log("1. Mint tokens to test users:");
        console.log("   asset.mint(user, amount)");
        console.log("");
        console.log("2. Users approve vault:");
        console.log("   asset.approve(vault, type(uint256).max)");
        console.log("");
        console.log("3. Users deposit:");
        console.log("   vault.deposit(amount, user)");
        console.log("");
        console.log("4. Wait and claim rewards:");
        console.log("   vault.pendingRewards(user)");
        console.log("   vault.claimRewards()");
        console.log("==========================================");
    }
}

/**
 * @title DeployMockMorphVaultSepolia
 * @notice Specific deployment for Sepolia testnet
 */
contract DeployMockMorphVaultSepolia is Script {
    // Sepolia USDC address (if available, otherwise deploy mock)
    address public constant SEPOLIA_USDC = address(0); // Update if real USDC exists on Sepolia

    string public constant VAULT_NAME = "Zybra Morph Vault Shares";
    string public constant VAULT_SYMBOL = "zmvUSDC";

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("==========================================");
        console.log("Deploying MockMorphVault on Sepolia");
        console.log("==========================================");

        vm.startBroadcast(deployerPrivateKey);

        address assetToken;

        // If no USDC on Sepolia, deploy mock
        if (SEPOLIA_USDC == address(0)) {
            console.log("No USDC found on Sepolia, deploying mock...");
            MockERC20 mockUSDC = new MockERC20("Mock USDC", "mUSDC", 6);
            assetToken = address(mockUSDC);

            // Mint initial tokens for testing
            mockUSDC.mint(deployer, 10_000e6); // 10k USDC
            console.log("Mock USDC deployed at:", assetToken);
            console.log("Minted 10,000 mUSDC to deployer");
        } else {
            assetToken = SEPOLIA_USDC;
            console.log("Using existing USDC at:", assetToken);
        }

        // Deploy vault
        MockMorphVault vault = new MockMorphVault(
            assetToken,
            VAULT_NAME,
            VAULT_SYMBOL,
            deployer
        );

        console.log("MockMorphVault deployed at:", address(vault));

        // Fund with rewards if we deployed mock token
        if (SEPOLIA_USDC == address(0)) {
            MockERC20(assetToken).approve(address(vault), 100e6);
            vault.fundRewards(100e6);
            console.log("Funded vault with 100 mUSDC rewards");
        }

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("SEPOLIA DEPLOYMENT COMPLETE");
        console.log("Vault:", address(vault));
        console.log("Asset:", assetToken);
        console.log("==========================================");
    }
}
