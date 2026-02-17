// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title PercentageMath
 * @notice Library for percentage and basis point calculations
 * @dev Used for protocol fees, penalties, and proportional distributions
 */
library PercentageMath {
    uint256 internal constant PERCENTAGE_FACTOR = 1e4; // 10000 = 100.00%
    uint256 internal constant HALF_PERCENTAGE_FACTOR = 5e3; // For rounding
    
    /**
     * @notice Calculate percentage of a value
     * @param value The base value
     * @param bps Basis points (100 = 1%)
     * @return The calculated percentage
     */
    function percentMul(uint256 value, uint256 bps) internal pure returns (uint256) {
        if (value == 0 || bps == 0) return 0;
        
        // Overflow check
        require(value <= (type(uint256).max - HALF_PERCENTAGE_FACTOR) / bps, "PercentageMath: overflow");
        
        return (value * bps + HALF_PERCENTAGE_FACTOR) / PERCENTAGE_FACTOR;
    }
    
    /**
     * @notice Calculate percentage without rounding
     * @param value The base value
     * @param bps Basis points (100 = 1%)
     * @return The calculated percentage (floor)
     */
    function percentMulFloor(uint256 value, uint256 bps) internal pure returns (uint256) {
        if (value == 0 || bps == 0) return 0;
        
        require(value <= type(uint256).max / bps, "PercentageMath: overflow");
        
        return (value * bps) / PERCENTAGE_FACTOR;
    }
    
    /**
     * @notice Calculate protocol fee with linear progression
     * @param cycle Current cycle number
     * @param totalCycles Total cycles in pool
     * @param startPercentile When fees start (e.g., 40 = after 40% of cycles)
     * @param maxFeeBps Maximum fee in basis points at end (e.g., 1000 = 10%)
     * @return feeBps Fee in basis points for this cycle
     */
    function calculateLinearFee(
        uint256 cycle,
        uint256 totalCycles,
        uint256 startPercentile,
        uint256 maxFeeBps
    ) internal pure returns (uint256 feeBps) {
        if (cycle == 0 || cycle > totalCycles) return 0;
        
        // Calculate when fees start
        uint256 feeStartCycle = (totalCycles * startPercentile) / 100;
        if (cycle <= feeStartCycle) return 0;
        
        // Linear progression from 0 to maxFeeBps
        uint256 cyclesAfterThreshold = cycle - feeStartCycle;
        uint256 totalFeeCycles = totalCycles - feeStartCycle;
        
        // Prevent division by zero
        if (totalFeeCycles == 0) return 0;
        
        return (cyclesAfterThreshold * maxFeeBps) / totalFeeCycles;
    }
    
    /**
     * @notice Calculate proportional share
     * @param totalAmount Total amount to distribute
     * @param userPortion User's portion (e.g., capital)
     * @param totalPortion Total of all portions (e.g., total capital)
     * @return User's proportional share
     */
    function proportionalShare(
        uint256 totalAmount,
        uint256 userPortion,
        uint256 totalPortion
    ) internal pure returns (uint256) {
        if (totalAmount == 0 || userPortion == 0 || totalPortion == 0) return 0;
        
        require(userPortion <= totalPortion, "PercentageMath: portion exceeds total");
        require(totalAmount <= type(uint256).max / userPortion, "PercentageMath: overflow");
        
        return (totalAmount * userPortion) / totalPortion;
    }
}
