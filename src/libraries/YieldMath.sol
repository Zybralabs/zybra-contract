// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title YieldMath
 * @notice Library for yield distribution calculations
 * @dev Handles capital-weighted yield calculations and vault interactions
 */
library YieldMath {
    /**
     * @notice Calculate new yield generated since last snapshot
     * @param vaultValue Current total value in vault
     * @param totalCapital Total principal capital deposited
     * @param lastSnapshot Last recorded total yield
     * @return newYield Newly generated yield since last snapshot
     */
    function calculateNewYield(
        uint256 vaultValue,
        uint256 totalCapital,
        uint256 lastSnapshot
    ) internal pure returns (uint256 newYield) {
        // Total accumulated yield
        uint256 totalYield = vaultValue > totalCapital ? vaultValue - totalCapital : 0;
        
        // New yield since last distribution
        newYield = totalYield > lastSnapshot ? totalYield - lastSnapshot : 0;
        
        return newYield;
    }
    
    /**
     * @notice Calculate member's proportional yield share
     * @param totalYield Total yield to distribute
     * @param memberCapital Member's capital in pool
     * @param totalCapital Total capital in pool
     * @return memberYield Member's share of yield
     */
    function calculateMemberYield(
        uint256 totalYield,
        uint256 memberCapital,
        uint256 totalCapital
    ) internal pure returns (uint256 memberYield) {
        if (totalYield == 0 || memberCapital == 0 || totalCapital == 0) {
            return 0;
        }
        
        require(memberCapital <= totalCapital, "YieldMath: invalid capital");
        require(totalYield <= type(uint256).max / memberCapital, "YieldMath: overflow");
        
        return (totalYield * memberCapital) / totalCapital;
    }
    
    /**
     * @notice Split yield between protocol fee and distributable amount
     * @param totalYield Total yield generated
     * @param feeBps Protocol fee in basis points
     * @return protocolFee Fee amount for protocol
     * @return distributable Amount to distribute to members
     */
    function splitYield(
        uint256 totalYield,
        uint256 feeBps
    ) internal pure returns (uint256 protocolFee, uint256 distributable) {
        if (totalYield == 0 || feeBps == 0) {
            return (0, totalYield);
        }
        
        require(feeBps <= 10000, "YieldMath: invalid fee");
        
        protocolFee = (totalYield * feeBps) / 10000;
        distributable = totalYield - protocolFee;
        
        return (protocolFee, distributable);
    }
    
    /**
     * @notice Calculate emergency withdrawal with penalty
     * @param totalAmount Total amount (capital + yield)
     * @param penaltyBps Penalty in basis points
     * @return amountToSend Amount after penalty
     * @return penalty Penalty amount
     */
    function calculateWithdrawalWithPenalty(
        uint256 totalAmount,
        uint256 penaltyBps
    ) internal pure returns (uint256 amountToSend, uint256 penalty) {
        if (totalAmount == 0 || penaltyBps == 0) {
            return (totalAmount, 0);
        }
        
        require(penaltyBps <= 10000, "YieldMath: invalid penalty");
        
        penalty = (totalAmount * penaltyBps) / 10000;
        amountToSend = totalAmount - penalty;
        
        return (amountToSend, penalty);
    }
}
