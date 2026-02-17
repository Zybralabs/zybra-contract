// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/ZybraGroupFactory.sol";
import "../src/ZybraGroup.sol";

contract DeployGroups is Script {
    address constant FACTORY_ADDRESS = 0xa9222306BDD09074EBDB2dA7fC6a6C8F1dff218D;
    address constant VAULT_ADDRESS = 0xe1872D62bA3342BB34Df13f5Ba542C667841395E;
    address constant USDC_ADDRESS = 0x9d60E70d6d164708397E7F0aBa139589c7447255;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("========================================");
        console.log("ZYBRA GROUP DEPLOYMENT");
        console.log("========================================");
        console.log("Deployer Address:", deployer);
        console.log("Factory Address:", FACTORY_ADDRESS);
        console.log("Vault Address:", VAULT_ADDRESS);
        console.log("USDC Address:", USDC_ADDRESS);
        console.log("");
        
        ZybraGroupFactory factory = ZybraGroupFactory(FACTORY_ADDRESS);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Calculate pool start times
        uint256 poolStart1 = block.timestamp + 1 days;
        uint256 poolStart2 = block.timestamp + 3 days;
        
        console.log("========================================");
        console.log("GROUP 1: Small Weekly ROSCA");
        console.log("========================================");
        console.log("Asset: USDC");
        console.log("Contribution Amount: 10 USDC");
        console.log("Cycle Duration: 1 week");
        console.log("Total Cycles: 4");
        console.log("Group Start Time:", poolStart1);
        console.log("");

        address group1 = factory.deployGroup(
            USDC_ADDRESS,
            10_000_000,
            1 weeks,
            4,
            deployer,
            VAULT_ADDRESS
        );
        
        console.log("GROUP 1 DEPLOYED AT:", group1);
        console.log("");
        
        console.log("========================================");
        console.log("GROUP 2: Medium Monthly ROSCA");
        console.log("========================================");
        console.log("Asset: USDC");
        console.log("Contribution Amount: 50 USDC");
        console.log("Cycle Duration: 2 weeks");
        console.log("Total Cycles: 8");
        console.log("Group Start Time:", poolStart2);
        console.log("");

        address group2 = factory.deployGroup(
            USDC_ADDRESS,
            50_000_000,
            2 weeks,
            8,
            deployer,
            VAULT_ADDRESS
        );
        
        console.log("GROUP 2 DEPLOYED AT:", group2);
        console.log("");
        
        vm.stopBroadcast();
        
        console.log("========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("GROUP 1:", group1);
        console.log("GROUP 2:", group2);
        console.log("========================================");
    }
}
