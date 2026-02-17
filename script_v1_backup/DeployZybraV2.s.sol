// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {ZybraGroupFactoryV2} from "src/ZybraGroupFactoryV2.sol";
import {ZybraGroupV2} from "src/ZybraGroupV2.sol";

/**
 * @title DeployZybraV2
 * @notice Deployment script for ZybraGroupFactoryV2 and initial group
 */
contract DeployZybraV2 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("==========================================");
        console.log("Deploying Zybra V2 Contracts");
        console.log("==========================================");
        console.log("Deployer:", deployer);
        console.log("Network:", block.chainid);
        console.log("==========================================");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Factory
        ZybraGroupFactoryV2 factory = new ZybraGroupFactoryV2();
        console.log("ZybraGroupFactoryV2 deployed at:", address(factory));

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("==========================================");
        console.log("Factory:", address(factory));
        console.log("==========================================");
        console.log("\nNEXT STEPS:");
        console.log("1. Deploy a group using factory.deployGroup()");
        console.log("2. Set the MockMorphVault as the vault parameter");
        console.log("   Vault: 0x12E67553083756a5ee2F072847c2CD0998904CCd");
        console.log("3. Use USDC: 0x9d60E70d6d164708397E7F0aBa139589c7447255");
        console.log("==========================================");
    }
}

/**
 * @title DeployZybraV2WithGroup
 * @notice Deploy factory AND create an initial group with MockMorphVault
 */
contract DeployZybraV2WithGroup is Script {
    // MockMorphVault deployed earlier
    address constant MOCK_MORPH_VAULT = 0x12E67553083756a5ee2F072847c2CD0998904CCd;
    address constant USDC = 0x9d60E70d6d164708397E7F0aBa139589c7447255;

    // Group parameters
    uint256 constant CONTRIBUTION_AMOUNT = 100e6; // 100 USDC
    uint256 constant CYCLE_DURATION = 7 days;     // 1 week cycles
    uint256 constant TOTAL_CYCLES = 12;            // 12 cycles (3 months)

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("==========================================");
        console.log("Deploying Zybra V2 with Initial Group");
        console.log("==========================================");
        console.log("Deployer:", deployer);
        console.log("Network:", block.chainid);
        console.log("USDC:", USDC);
        console.log("MockMorphVault:", MOCK_MORPH_VAULT);
        console.log("==========================================");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Factory
        ZybraGroupFactoryV2 factory = new ZybraGroupFactoryV2();
        console.log("\nZybraGroupFactoryV2 deployed at:", address(factory));

        // Deploy initial group
        address groupAddress = factory.deployGroup(
            USDC,
            CONTRIBUTION_AMOUNT,
            CYCLE_DURATION,
            TOTAL_CYCLES,
            deployer, // admin
            MOCK_MORPH_VAULT
        );

        console.log("ZybraGroupV2 deployed at:", groupAddress);

        vm.stopBroadcast();

        console.log("\n==========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("==========================================");
        console.log("Factory:", address(factory));
        console.log("Group:", groupAddress);
        console.log("Vault:", MOCK_MORPH_VAULT);
        console.log("USDC:", USDC);
        console.log("==========================================");
        console.log("\nGroup Configuration:");
        console.log("- Contribution: 100 USDC per cycle");
        console.log("- Cycle Duration: 7 days");
        console.log("- Total Cycles: 12");
        console.log("- Admin:", deployer);
        console.log("- APY: 150% (from MockMorphVault)");
        console.log("==========================================");
        console.log("\nUSAGE:");
        console.log("1. Members join: group.joinGroup(memberAddress)");
        console.log("2. Admin starts: group.startGroup()");
        console.log("3. Members contribute: group.contribute()");
        console.log("4. Yield distributes automatically");
        console.log("5. Members claim: group.claimYield()");
        console.log("==========================================");
    }
}
