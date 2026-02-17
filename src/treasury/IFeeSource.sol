// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title IFeeSource
 * @author Zybra Protocol
 * @notice Interface for contracts that generate protocol fees
 * @dev Implement this interface to integrate with FeeCollector
 *
 * INTEGRATION PATTERN:
 *   1. Fee source accumulates fees internally
 *   2. FeeCollector calls collectFees() to trigger withdrawal
 *   3. Fees flow to Treasury (either directly or via FeeCollector)
 */
interface IFeeSource {
    /**
     * @notice Collect accumulated fees
     * @dev Called by FeeCollector or directly by keeper
     * @return amount Fees collected
     */
    function collectFees() external returns (uint256 amount);

    /**
     * @notice Get pending fees available for collection
     * @return Accumulated fees not yet collected
     */
    function pendingFees() external view returns (uint256);

    /**
     * @notice Get the asset used for fees
     * @return Asset token address (e.g., USDC)
     */
    function feeAsset() external view returns (address);
}
