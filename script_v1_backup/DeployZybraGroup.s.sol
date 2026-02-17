// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../src/ZybraGroup.sol";

contract DeployZybraGroup {
    function deploy(
        address asset,
        uint256 contributionAmount,
        uint256 cycleDuration,
        uint256 totalCycles,
        address admin,
        address vault,
        uint256 initialGroupStartTime
    ) external returns (address) {
        ZybraGroup group = new ZybraGroup(
            asset,
            contributionAmount,
            cycleDuration,
            totalCycles,
            admin,
            vault
        );

        return address(group);
    }
}