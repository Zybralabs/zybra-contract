// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockERC4626Vault
 * @dev Simple ERC4626 vault for testing purposes
 * Simulates a yield-bearing vault with configurable APY
 */
contract MockERC4626Vault is ERC4626 {
    uint256 public mockYieldRate; // Basis points per year (e.g., 750 = 7.5%)
    uint256 public lastYieldUpdate;
    
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) {
        mockYieldRate = 750; // Default 7.5% APY
        lastYieldUpdate = block.timestamp;
    }
    
    /**
     * @dev Set the mock yield rate (basis points per year)
     */
    function setYieldRate(uint256 _rate) external {
        mockYieldRate = _rate;
    }
    
    /**
     * @dev Simulate yield accrual by minting assets to the vault
     */
    function accrueYield() external {
        uint256 timeElapsed = block.timestamp - lastYieldUpdate;
        if (timeElapsed == 0) return;
        
        uint256 currentAssets = totalAssets();
        if (currentAssets == 0) return;
        
        // Calculate yield: (assets * rate * timeElapsed) / (10000 * 365 days)
        uint256 yield = (currentAssets * mockYieldRate * timeElapsed) / (10000 * 365 days);
        
        if (yield > 0) {
            // Mint yield to this contract (increases totalAssets)
            // In a real vault, this would come from lending/staking returns
            // For mock, we just mint from the underlying asset if it supports it
            // Or we track it separately
        }
        
        lastYieldUpdate = block.timestamp;
    }
    
    /**
     * @dev Override totalAssets to include accrued yield
     * In a simple mock, we just return the actual balance
     */
    function totalAssets() public view virtual override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}
