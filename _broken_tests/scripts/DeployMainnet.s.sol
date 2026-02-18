// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/ZybraGroupFactory.sol";

/**
 * @title DeployMainnet
 * @notice Production mainnet deployment of Zybra protocol contracts.
 *
 * WHAT THIS DEPLOYS:
 *   1. ZybraGroupFactory - Factory for creating ROSCA groups
 *
 * WHAT THIS DOES NOT DEPLOY:
 *   - MockYieldVault (mainnet uses real Morpho vaults like Steakhouse USDC)
 *   - Sample groups (groups are created via the backend API)
 *   - Treasury / FeeCollector contracts (not needed — fees go directly to treasury wallet)
 *
 * FEE ARCHITECTURE:
 *   ZybraGroup.collectFees() is permissionless and sends accumulated
 *   fees directly to the group's `treasury` address (a wallet/multisig).
 *   No intermediary contract is needed. Anyone can call collectFees()
 *   and the funds always go to the configured treasury wallet.
 *
 * PREREQUISITES:
 *   - Set DEPLOYER_PRIVATE_KEY in .env (deployer address with ETH for gas)
 *   - Set TREASURY_WALLET (multisig/wallet address to receive protocol fees)
 *   - MAINNET_RPC_URL in .env
 *
 * USAGE:
 *   source .env
 *
 *   # Dry run (simulation):
 *   forge script script/DeployMainnet.s.sol \
 *     --rpc-url $MAINNET_RPC_URL \
 *     --private-key $DEPLOYER_PRIVATE_KEY \
 *     -vvvv
 *
 *   # Live deployment:
 *   forge script script/DeployMainnet.s.sol \
 *     --rpc-url $MAINNET_RPC_URL \
 *     --broadcast \
 *     --private-key $DEPLOYER_PRIVATE_KEY \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * POST-DEPLOYMENT:
 *   1. Update backend .env with deployed factory address
 *   2. Update contracts.json with new factory address
 *   3. Set CHAIN_ENV=mainnet in backend
 *   4. Set TREASURY_ADDRESS in backend .env to the treasury wallet
 *   5. When creating groups via API, pass treasury wallet as the treasury param
 */
contract DeployMainnet is Script {

    function run() external {
        // ===================== READ CONFIGURATION =====================
        address deployer = msg.sender;
        address treasuryWallet = vm.envOr("TREASURY_WALLET", deployer);

        // Safety check
        if (treasuryWallet == deployer) {
            console.log("WARNING: TREASURY_WALLET not set, defaulting to deployer. Set TREASURY_WALLET for production.");
        }

        console.log("\n");
        console.log("======================================================================");
        console.log("  ZYBRA PROTOCOL - MAINNET DEPLOYMENT");
        console.log("======================================================================");
        console.log("\nDeployer:          ", deployer);
        console.log("Chain ID:          ", block.chainid);
        console.log("Treasury Wallet:   ", treasuryWallet);
        console.log("");

        // ===================== SAFETY CHECKS =====================
        require(block.chainid == 1 || block.chainid == 11155111, "Must be mainnet (1) or sepolia (11155111)");
        require(deployer.balance > 0.1 ether, "Deployer needs at least 0.1 ETH for gas");

        vm.startBroadcast();

        // ===================== DEPLOY FACTORY =====================
        console.log("1. Deploying ZybraGroupFactory...");
        ZybraGroupFactory factory = new ZybraGroupFactory();
        console.log("   ZybraGroupFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // ===================== DEPLOYMENT SUMMARY =====================
        console.log("\n");
        console.log("======================================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("======================================================================");
        console.log("");
        console.log("Contract Addresses:");
        console.log("  ZybraGroupFactory: ", address(factory));
        console.log("  Treasury Wallet:     ", treasuryWallet);
        console.log("");
        console.log("======================================================================");
        console.log("  NEXT STEPS");
        console.log("======================================================================");
        console.log("");
        console.log("1. Update backend .env:");
        console.log("   MAINNET_GROUP_FACTORY_ADDRESS=", address(factory));
        console.log("   TREASURY_ADDRESS=", treasuryWallet);
        console.log("");
        console.log("2. Update contracts.json groupFactory.address");
        console.log("");
        console.log("3. Set CHAIN_ENV=mainnet in backend .env");
        console.log("");
        console.log("4. Groups created via API will use TREASURY_ADDRESS as the");
        console.log("   treasury param. collectFees() sends directly to that wallet.");
        console.log("");
        console.log("5. Verify the factory contract on Etherscan:");
        console.log("   forge verify-contract ", address(factory));
        console.log("   src/ZybraGroupFactory.sol:ZybraGroupFactory");
        console.log("");
    }
}
