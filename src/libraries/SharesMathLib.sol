// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @title SharesMathLib
/// @notice Library for converting between shares and assets in Morpho markets
/// @dev Uses virtual shares/assets to prevent manipulation and handle edge cases
library SharesMathLib {
    /// @notice Virtual shares added to prevent division by zero and manipulation
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    /// @notice Virtual assets added to prevent division by zero and manipulation
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Convert shares to assets, rounding down
    /// @param shares Amount of shares to convert
    /// @param totalAssets Total assets in the market
    /// @param totalShares Total shares in the market
    /// @return assets Amount of assets corresponding to the shares
    function toAssetsDown(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        return mulDivDown(
            shares,
            totalAssets + VIRTUAL_ASSETS,
            totalShares + VIRTUAL_SHARES
        );
    }

    /// @notice Convert shares to assets, rounding up
    /// @param shares Amount of shares to convert
    /// @param totalAssets Total assets in the market
    /// @param totalShares Total shares in the market
    /// @return assets Amount of assets corresponding to the shares
    function toAssetsUp(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        return mulDivUp(
            shares,
            totalAssets + VIRTUAL_ASSETS,
            totalShares + VIRTUAL_SHARES
        );
    }

    /// @notice Multiply two numbers and divide by a third, rounding down
    /// @dev Equivalent to (x * y) / denominator, but prevents overflow
    function mulDivDown(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        assembly {
            // Store x * y in z.
            z := mul(x, y)

            // Equivalent to require(denominator != 0 && (x == 0 || (x * y) / x == y))
            if iszero(and(iszero(iszero(denominator)), or(iszero(x), eq(div(z, x), y)))) {
                revert(0, 0)
            }

            // Divide z by the denominator.
            z := div(z, denominator)
        }
    }

    /// @notice Multiply two numbers and divide by a third, rounding up
    /// @dev Equivalent to ceil((x * y) / denominator)
    function mulDivUp(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        assembly {
            // Store x * y in z.
            z := mul(x, y)

            // Equivalent to require(denominator != 0 && (x == 0 || (x * y) / x == y))
            if iszero(and(iszero(iszero(denominator)), or(iszero(x), eq(div(z, x), y)))) {
                revert(0, 0)
            }

            // If x * y modulo the denominator is strictly greater than 0,
            // 1 is added to round up the division of x * y by the denominator.
            z := add(gt(mod(mul(x, y), denominator), 0), div(z, denominator))
        }
    }
}
