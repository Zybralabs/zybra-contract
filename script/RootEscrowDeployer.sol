// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../contracts/Zybra/Root.sol";
import "../contracts/Zybra/Escrow.sol";

contract RootEscrowDeployer is Script {
    function deploy(address deployer) external returns (address, address) {
        console.log("depoloy",msg.sender);
        Escrow escrow = new Escrow(deployer);
        Root root = new Root(address(escrow), 48 hours, deployer);

        console.log("Escrow deployed at:", address(escrow));
        console.log("Root deployed at:", address(root));

        return (address(escrow), address(root));
    }
}
