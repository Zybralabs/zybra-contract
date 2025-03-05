// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "forge-std/console.sol";
// import "../contracts/Zybra/pools/LZybraVault.sol";

contract DeployZybraVaultBase is Script {
    // function run() external {
    //     // Read configuration from JSON file
    //     string memory path = "../addresses/testnet.json";
    //     (address configurator, address priceFeed, address collateralAsset,address lzybra, address poolManager, address investmentManager) = readConfig(path);

    //     vm.startBroadcast();

    //     // Deploy the contract with parameters from the JSON file
    //     LZybraVault vault = new LZybraVault(
    //         configurator,
    //         priceFeed,
    //         collateralAsset,
    //         lzybra,
    //         poolManager,
    //         investmentManager
    //     );

    //     console.log("ZybraVaultBase deployed to:", address(vault));

    //     vm.stopBroadcast();
    // }

    // function readConfig(string memory path) internal pure returns (
    //     address configurator,
    //     address priceFeed,
    //     address collateralAsset,
    //     address lzybra,
    //     address poolManager,
    //     address investmentManager
    // ) {
    //     // This is a simplified version; you might use an external library to read JSON in a real scenario
    //     configurator = "0x0000000000000000000000000000000000000000"; // Placeholder, replace with actual reading logic
    //     priceFeed = "0x0000000000000000000000000000000000000000";    // Placeholder, replace with actual reading logic
    //     collateralAsset = "0x0000000000000000000000000000000000000000"; // Placeholder, replace with actual reading logic
    //     lzybra = "0x0000000000000000000000000000000000000000"; // Placeholder, replace with actual reading logic
    //     poolManager = "0x0000000000000000000000000000000000000000"; // Placeholder, replace with actual reading logic
    //     investmentManager = "0x0000000000000000000000000000000000000000"; // Placeholder, replace with actual reading logic
    // }
}
