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
 * @title DeploySepolia
 * @dev Deployment script for Sepolia testnet
 */
contract DeploySepolia is Script {
    function run() external {
        // Load from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Sepolia Testnet Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock USDC
        console.log("1. Deploying Mock USDC...");
        MockERC20 mockUSDC = new MockERC20("USD Coin", "USDC", 6);
        console.log("   Mock USDC:", address(mockUSDC));

        // 2. Deploy MockMorpho
        console.log("2. Deploying MockMorpho...");
        MockMorpho mockMorpho = new MockMorpho();
        console.log("   MockMorpho:", address(mockMorpho));

        // 3. Create Morpho Market
        console.log("3. Creating Morpho market...");
        MarketParams memory marketParams = MarketParams({
            loanToken: address(mockUSDC),
            collateralToken: address(0),
            oracle: address(0),
            irm: address(1),
            lltv: 0
        });
        mockMorpho.createMarket(marketParams);
        Id marketId = Id.wrap(keccak256(abi.encode(marketParams)));
        console.log("   Market ID:", uint256(Id.unwrap(marketId)));

        // 4. Deploy MetaMorphoFactory
        console.log("4. Deploying MetaMorphoFactory...");
        MetaMorphoFactory metaMorphoFactory = new MetaMorphoFactory(address(mockMorpho));
        console.log("   MetaMorphoFactory:", address(metaMorphoFactory));

        // 5. Deploy MockMetaMorpho Vault
        console.log("5. Deploying MockMetaMorpho vault...");
        address vaultAddress = metaMorphoFactory.deployVaultWithDefaultMorpho(
            address(mockUSDC),
            "MetaMorpho USDC Vault",
            "mmUSDC",
            deployer
        );
        MockMetaMorpho vault = MockMetaMorpho(vaultAddress);
        console.log("   Vault:", vaultAddress);

        // 6. Configure Vault
        console.log("6. Configuring vault...");
        vault.submitCap(marketParams, 1_000_000e6);
        vault.setFee(0.05e18); // 5%
        console.log("   Set cap: 1M USDC, fee: 5%");

        // 7. Fund vault
        console.log("7. Funding vault...");
        mockUSDC.mint(deployer, 20_000e6);
        mockUSDC.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, deployer);
        console.log("   Deposited 10,000 USDC (automatically supplied to Morpho)");

        // 8. Deploy ZybraGroupFactory
        console.log("8. Deploying ZybraGroupFactory...");
        ZybraGroupFactory zybraFactory = new ZybraGroupFactory();
        console.log("   ZybraGroupFactory:", address(zybraFactory));

        // 9. Deploy test ZybraGroup
        console.log("9. Deploying test ZybraGroup...");
        uint256 poolStartTime = block.timestamp + 1 hours;
        address groupAddress = zybraFactory.deployGroup(
            address(mockUSDC),
            100e6, // 100 USDC
            1 weeks, // cycleDuration - 1 week
            4,     // totalCycles - 4 cycles
            deployer,
            vaultAddress
        );
        console.log("   ZybraGroup:", groupAddress);

        // 10. Mint test USDC
        console.log("10. Minting test USDC...");
        mockUSDC.mint(deployer, 50_000e6);
        console.log("   Minted 50,000 USDC");

        vm.stopBroadcast();

        // Print summary
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Mock USDC:", address(mockUSDC));
        console.log("MockMorpho:", address(mockMorpho));
        console.log("MetaMorphoFactory:", address(metaMorphoFactory));
        console.log("MockMetaMorpho Vault:", vaultAddress);
        console.log("ZybraGroupFactory:", address(zybraFactory));
        console.log("Test ZybraGroup:", groupAddress);
        console.log("");
        console.log("Market ID:", uint256(Id.unwrap(marketId)));
        console.log("Group Start Time:", poolStartTime);
        console.log("");
        console.log("Save these addresses for testing!");
    }
}
