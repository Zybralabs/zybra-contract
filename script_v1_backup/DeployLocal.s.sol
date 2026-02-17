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
 * @title DeployLocal
 * @dev Quick deployment script for local testing (Anvil)
 * @notice Deploys complete ecosystem with pre-funded accounts
 */
contract DeployLocal is Script {
    /* DEPLOYED CONTRACTS */
    MockERC20 public mockUSDC;
    MockMorpho public mockMorpho;
    MetaMorphoFactory public metaMorphoFactory;
    MockMetaMorpho public mockMetaMorphoVault;
    ZybraGroupFactory public zybraFactory;
    ZybraGroup public testGroup;

    /* ANVIL DEFAULT ACCOUNTS */
    address public constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address public constant MEMBER1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public constant MEMBER2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address public constant MEMBER3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address public constant MEMBER4 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    function run() external {
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

        console.log("=== Local Deployment (Anvil) ===");
        console.log("Deployer:", DEPLOYER);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock USDC
        console.log("1. Deploying Mock USDC...");
        mockUSDC = new MockERC20("USD Coin", "USDC", 6);
        console.log("   Mock USDC:", address(mockUSDC));

        // 2. Deploy MockMorpho
        console.log("2. Deploying MockMorpho...");
        mockMorpho = new MockMorpho();
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
        metaMorphoFactory = new MetaMorphoFactory(address(mockMorpho));
        console.log("   MetaMorphoFactory:", address(metaMorphoFactory));

        // 5. Deploy MockMetaMorpho Vault
        console.log("5. Deploying MockMetaMorpho vault...");
        address vaultAddress = metaMorphoFactory.deployVaultWithDefaultMorpho(
            address(mockUSDC),
            "MetaMorpho USDC Vault",
            "mmUSDC",
            DEPLOYER
        );
        mockMetaMorphoVault = MockMetaMorpho(vaultAddress);
        console.log("   MockMetaMorpho Vault:", vaultAddress);

        // 6. Configure Vault
        console.log("6. Configuring vault...");
        mockMetaMorphoVault.submitCap(marketParams, 1_000_000e6);
        mockMetaMorphoVault.setFee(0.05e18); // 5% fee
        console.log("   Configured with 1M USDC cap and 5% fee");

        // 7. Fund and Initialize Vault
        console.log("7. Funding vault...");
        mockUSDC.mint(DEPLOYER, 100_000e6);
        mockUSDC.approve(address(mockMetaMorphoVault), 50_000e6);
        mockMetaMorphoVault.deposit(50_000e6, DEPLOYER);
        mockMetaMorphoVault.supplyToMarket(marketParams, 50_000e6);
        console.log("   Funded with 50,000 USDC");

        // 8. Deploy ZybraGroupFactory
        console.log("8. Deploying ZybraGroupFactory...");
        zybraFactory = new ZybraGroupFactory();
        console.log("   ZybraGroupFactory:", address(zybraFactory));

        // 9. Deploy Test Group
        console.log("9. Deploying test ZybraGroup...");
        address testGroupAddress = zybraFactory.deployGroup(
            address(mockUSDC),
            100e6, // 100 USDC per contribution
            1 weeks, // 1 week per cycle
            4, // 4 total cycles
            DEPLOYER,
            address(mockMetaMorphoVault)
        );
        testGroup = ZybraGroup(testGroupAddress);
        console.log("   Test ZybraGroup:", testGroupAddress);

        // 10. Fund test accounts
        console.log("10. Funding test accounts...");
        mockUSDC.mint(MEMBER1, 10_000e6);
        mockUSDC.mint(MEMBER2, 10_000e6);
        mockUSDC.mint(MEMBER3, 10_000e6);
        mockUSDC.mint(MEMBER4, 10_000e6);
        console.log("   Funded 4 members with 10,000 USDC each");

        vm.stopBroadcast();

        // Print summary
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Contracts:");
        console.log("  USDC:", address(mockUSDC));
        console.log("  Morpho:", address(mockMorpho));
        console.log("  Vault:", address(mockMetaMorphoVault));
        console.log("  Group:", address(testGroup));
        console.log("");
        console.log("Test Accounts:");
        console.log("  Deployer:", DEPLOYER);
        console.log("  Member 1:", MEMBER1);
        console.log("  Member 2:", MEMBER2);
        console.log("  Member 3:", MEMBER3);
        console.log("  Member 4:", MEMBER4);
        console.log("");
        console.log("Quick Start:");
        console.log("  1. Start Anvil: anvil");
        console.log("  2. Deploy: forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast");
        console.log("  3. Interact using cast or frontend");
    }
}
