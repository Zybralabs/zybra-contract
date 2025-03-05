// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title TokenDecimalUtils
 * @dev Library for handling token decimal conversions
 * Provides utilities to normalize token amounts to 18 decimals and convert back
 */
library TokenDecimalUtils {
    /**
     * @dev Normalizes a token amount to 18 decimals
     * @param amount The amount to normalize
     * @param tokenAddress The address of the token
     * @param fallbackDecimals The fallback decimals to use if decimals() method fails
     * @return The normalized amount with 18 decimals
     */
    function normalizeToDecimals18(uint256 amount, address tokenAddress, uint8 fallbackDecimals) internal view returns (uint256) {
        uint8 decimals = getTokenDecimals(tokenAddress, fallbackDecimals);
        
        // If already 18 decimals, return as is
        if (decimals == 18) return amount;
        
        // Convert to 18 decimals
        if (decimals < 18) {
            return amount * (10**(18 - decimals));
        } else {
            return amount / (10**(decimals - 18));
        }
    }
    
    /**
     * @dev Converts an amount from 18 decimals to a token's native decimals
     * @param normalizedAmount The 18-decimal amount to convert
     * @param tokenAddress The address of the token
     * @param fallbackDecimals The fallback decimals to use if decimals() method fails
     * @return The denormalized amount with the token's native decimals
     */
    function denormalizeFromDecimals18(uint256 normalizedAmount, address tokenAddress, uint8 fallbackDecimals) internal view returns (uint256) {
        uint8 decimals = getTokenDecimals(tokenAddress, fallbackDecimals);
        
        // If already 18 decimals, return as is
        if (decimals == 18) return normalizedAmount;
        
        // Convert from 18 decimals to token's decimals
        if (decimals < 18) {
            return normalizedAmount / (10**(18 - decimals));
        } else {
            return normalizedAmount * (10**(decimals - 18));
        }
    }
    
    /**
     * @dev Gets the decimals of a token
     * @param tokenAddress The address of the token
     * @param fallbackDecimals The fallback decimals to use if decimals() method fails
     * @return The token's decimal places
     */
    function getTokenDecimals(address tokenAddress, uint8 fallbackDecimals) internal view returns (uint8) {
        try IERC20Metadata(tokenAddress).decimals() returns (uint8 _decimals) {
            return _decimals;
        } catch {
            // Return fallback decimals if decimals() method is not available
            return fallbackDecimals;
        }
    }
    
    /**
     * @dev Safely multiplies two numbers with a specific number of decimals
     * @param a First number
     * @param b Second number
     * @param decimals Decimal places to maintain in result
     * @return Result of a * b with specified decimal precision
     */
    function mulDiv(uint256 a, uint256 b, uint256 decimals) internal pure returns (uint256) {
        return (a * b) / (10**decimals);
    }
    
    /**
     * @dev Converts between two token amounts with different decimal places
     * @param amount The amount to convert
     * @param fromDecimals Source token's decimal places
     * @param toDecimals Target token's decimal places
     * @return The converted amount
     */
    function convertDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals < toDecimals) {
            return amount * (10**(toDecimals - fromDecimals));
        } else {
            return amount / (10**(fromDecimals - toDecimals));
        }
    }
}