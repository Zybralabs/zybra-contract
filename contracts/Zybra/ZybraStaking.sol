// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./StableLzybraSwap.sol";  // Assumes swap contract exists to handle Lzybra conversions

interface IVaultManager {
    function getVaultCollateral(address vaultOwner) external view returns (uint256 collateralAmount, uint256 debtAmount);
    function liquidateVault(address vaultOwner, uint256 auctionId) external;
}

interface IPoolManager {
    function getTranchePrice(uint64 poolId, bytes16 trancheId, address asset) external view returns (uint128 price, uint64 computedAt);
}

contract LzybraCentrifugeStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public zfiToken;
    IVaultManager public vaultManager;
    StableLzybraSwap public stableLzybraSwap;  // Reference to the StableLzybraSwap contract
    IPoolManager public poolManager;  // Centrifuge Pool Manager
    AggregatorV3Interface public priceFeed;
    IERC20 public collateralAsset;
    
    uint256 public totalStaked;
    uint256 public totalProfitDistributed;
    uint256 public keeperRewardPercent = 2;  // Percent of liquidation profit to keepers

    struct Staker {
        uint256 amountStaked;
        uint256 rewardDebt;
    }

    mapping(address => Staker) public stakers;
    uint256 public accProfitPerShare;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event ProfitDistributed(uint256 amount);
    event LiquidationTriggered(address indexed liquidator, uint256 auctionId, uint256 profit, uint256 keeperReward);
    event RewardWithdrawn(address indexed user, uint256 reward);

    constructor(
        IERC20 _zfiToken,
        IVaultManager _vaultManager,
        StableLzybraSwap _stableLzybraSwap,
        IPoolManager _poolManager,
        AggregatorV3Interface _priceFeed,
        IERC20 _collateralAsset
    ) {
        zfiToken = _zfiToken;
        vaultManager = _vaultManager;
        stableLzybraSwap = _stableLzybraSwap;
        poolManager = _poolManager;
        priceFeed = _priceFeed;
        collateralAsset = _collateralAsset;
    }

    // --- Conversion Functions for Collateral to Lzybra and Liquidation Handling ---

    function _convertCollateralToLzybra(uint256 collateralAmount) internal {
        require(collateralAsset.balanceOf(address(this)) >= collateralAmount, "Insufficient collateral");

        collateralAsset.safeApprove(address(stableLzybraSwap), collateralAmount);
        stableLzybraSwap.convertToLzybra(collateralAmount);
    }

    function _convertRwaToUSDC(address rwaToken, uint256 rwaAmount) internal returns (uint256) {
        require(IERC20(rwaToken).balanceOf(address(this)) >= rwaAmount, "Insufficient RWA for conversion");
        IERC20(rwaToken).safeApprove(address(stableLzybraSwap), rwaAmount);
        uint256 usdcAmount = stableLzybraSwap.convertRwaToUSDC(rwaAmount);
        require(usdcAmount > 0, "RWA to USDC conversion failed");
        return usdcAmount;
    }

    // --- Staking and Unstaking Functions ---

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Cannot stake 0");

        Staker storage staker = stakers[msg.sender];

        zfiToken.safeTransferFrom(msg.sender, address(this), amount);
        staker.amountStaked += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        Staker storage staker = stakers[msg.sender];
        require(staker.amountStaked >= amount, "Insufficient staked amount");

        _distributeReward(staker);

        staker.amountStaked -= amount;
        totalStaked -= amount;
        zfiToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    // --- Liquidation and Profit Distribution Functions ---

    function triggerLiquidation(address vaultOwner, uint256 auctionId) external nonReentrant {
        (uint256 collateralAmount, uint256 debtAmount) = vaultManager.getVaultCollateral(vaultOwner);
        require(collateralAmount < debtAmount, "Vault is not undercollateralized");

        uint256 amountToConvert = debtAmount - collateralAmount;
        _convertCollateralToLzybra(amountToConvert);

        vaultManager.liquidateVault(vaultOwner, auctionId);

        uint256 rwaReceived = getRwaAmountFromLiquidation();  // Placeholder for actual liquidation integration
        uint256 usdcAmount = _convertRwaToUSDC(address(collateralAsset), rwaReceived);

        uint256 profitAmount = _convertUSDCToZFI(usdcAmount);

        uint256 keeperReward = (profitAmount * keeperRewardPercent) / 100;
        uint256 stakerProfit = profitAmount - keeperReward;
        
        if (keeperReward > 0) {
            zfiToken.safeTransfer(msg.sender, keeperReward);
        }

        _distributeLiquidationProfit(stakerProfit);

        emit LiquidationTriggered(msg.sender, auctionId, profitAmount, keeperReward);
    }

    function _distributeLiquidationProfit(uint256 profitAmount) internal {
        require(totalStaked > 0, "No stakers to distribute profit");
        accProfitPerShare += (profitAmount * 1e12) / totalStaked;
        totalProfitDistributed += profitAmount;
        emit ProfitDistributed(profitAmount);
    }

    // --- Profit Withdrawal Functions ---

    function withdrawReward() external nonReentrant {
        Staker storage staker = stakers[msg.sender];
        uint256 pendingReward = _calculatePendingReward(staker);

        require(pendingReward > 0, "No reward to withdraw");

        staker.rewardDebt = staker.amountStaked * accProfitPerShare / 1e12;
        zfiToken.safeTransfer(msg.sender, pendingReward);

        emit RewardWithdrawn(msg.sender, pendingReward);
    }

    function _distributeReward(Staker storage staker) internal {
        uint256 pendingReward = _calculatePendingReward(staker);
        if (pendingReward > 0) {
            zfiToken.safeTransfer(msg.sender, pendingReward);
        }
        staker.rewardDebt = staker.amountStaked * accProfitPerShare / 1e12;
    }

    function getRwaAmountFromLiquidation() internal view returns (uint256) {
        return 1000;  // Placeholder, replace with actual logic for RWA amount obtained from liquidation
    }

    function _calculatePendingReward(Staker storage staker) internal view returns (uint256) {
        return (staker.amountStaked * accProfitPerShare / 1e12) - staker.rewardDebt;
    }

    function pendingReward(address stakerAddress) external view returns (uint256) {
        Staker storage staker = stakers[stakerAddress];
        return _calculatePendingReward(staker);
    }

    // --- Governance Functions ---

    function updateVaultManager(IVaultManager _vaultManager) external onlyOwner {
        vaultManager = _vaultManager;
    }

    function updateStableLzybraSwap(StableLzybraSwap _stableLzybraSwap) external onlyOwner {
        stableLzybraSwap = _stableLzybraSwap;
    }

    function setKeeperRewardPercent(uint256 _keeperRewardPercent) external onlyOwner {
        require(_keeperRewardPercent <= 10, "Max 10%");
        keeperRewardPercent = _keeperRewardPercent;
    }

    function manualProfitDeposit(uint256 profitAmount) external onlyOwner {
        _distributeLiquidationProfit(profitAmount);
    }

    receive() external payable {}
}
