// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../src/MockChainlinkSetup.sol";
import "../src/ERC20Setup.sol";

contract MockDependencyDeployer is Script {
    function run() external {
        

        // Deploy MockChainlink
        MockChainlinkSetup mockChainlinkSetup = new MockChainlinkSetup();
        address chainlinkMock = mockChainlinkSetup.setupMockChainlink();
        console.log("MockChainlink deployed at:", chainlinkMock);

        // Deploy ERC20
        ERC20Setup erc20Setup = new ERC20Setup();
        address erc20 = erc20Setup.setupERC20();
        console.log("ERC20 deployed at:", erc20);

        vm.stopBroadcast();
    }
}
