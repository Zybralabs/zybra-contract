// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title ITreasury
 * @author Zybra Protocol
 * @notice Minimal interface for Treasury deposits
 */
interface ITreasury {
    /**
     * @notice Deposit fees from an authorized collector
     * @param asset ERC20 token address
     * @param amount Amount to deposit
     */
    function deposit(address asset, uint256 amount) external;
}
