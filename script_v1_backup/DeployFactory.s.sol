// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/ZybraGroupFactory.sol";
import "../src/mocks/MockERC4626Vault.sol";

/**
 * @title DeployFactory
 * @dev Deployment script for ZybraGroupFactory
 *
 * To deploy:
 * forge script script/DeployFactory.s.sol:DeployFactory --rpc-url $SEPOLIA_RPC_URL --broadcast --legacy
 */
contract DeployFactory is Script {
    // Existing USDC contract address on Sepolia
    address constant USDC = 0x9d60E70d6d164708397E7F0aBa139589c7447255;

    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== ZybraGroupFactory Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Network: Sepolia Testnet");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy ZybraGroupFactory
        console.log("1. Deploying ZybraGroupFactory...");
        ZybraGroupFactory factory = new ZybraGroupFactory();
        console.log("ZybraGroupFactory deployed at:", address(factory));
        console.log("");

        // Step 2: Deploy a Mock Vault for testing
        console.log("2. Deploying Mock ERC4626 Vault for testing...");
        MockERC4626Vault vault = new MockERC4626Vault(
            IERC20(USDC),
            "Zybra Vault USDC",
            "zvUSDC"
        );
        console.log("Mock Vault deployed at:", address(vault));
        console.log("");

        // Step 3: Display deployment summary
        console.log("=== Deployment Summary ===");
        console.log("Factory Owner:", factory.owner());
        console.log("Factory Address:", address(factory));
        console.log("Mock Vault Address:", address(vault));
        console.log("USDC Address:", USDC);
        console.log("");

        console.log("=== Next Steps ===");
        console.log("Use the factory to deploy ZybraGroup contracts:");
        console.log("");
        console.log("Example: Deploy a group with factory");
        console.log("factory.deployGroup(");
        console.log("    USDC,                    // asset");
        console.log("    100e6,                   // contribution amount (100 USDC)");
        console.log("    1 weeks,                 // cycle duration");
        console.log("    4,                       // total cycles");
        console.log("    YOUR_ADDRESS,            // admin");
        console.log("    VAULT_ADDRESS,           // vault");
        console.log("    block.timestamp + 1 hour // pool start time");
        console.log(");");
        console.log("");

        vm.stopBroadcast();
    }
}
