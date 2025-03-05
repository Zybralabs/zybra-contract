// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "../contracts/Zybra/factories/ERC7540VaultFactory.sol";
import "../contracts/Zybra/token/RestrictionManager.sol";
import "../contracts/Zybra/factories/TrancheFactory.sol";

contract FactoryDeployer is Script {
    function call(address root, address deployer) external returns (address, address, address) {
        ERC7540VaultFactory vaultFactory = new ERC7540VaultFactory(root);
        RestrictionManager restrictionManager = new RestrictionManager(root, deployer);
        TrancheFactory trancheFactory = new TrancheFactory(root, deployer);

        console.log("VaultFactory deployed at:", address(vaultFactory));
        console.log("RestrictionManager deployed at:", address(restrictionManager));
        console.log("TrancheFactory deployed at:", address(trancheFactory));

        return (address(vaultFactory), address(restrictionManager), address(trancheFactory));
    }
}
