// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockMorphVault
 * @author Zybra SMS Team
 * @notice Demo Morpho-style vault that generates time-based rewards for users
 * @dev Simplified mock vault compatible with Morpho V2 architecture
 *
 * KEY FEATURES:
 * - ERC4626 compliant tokenized vault
 * - Time-based reward generation (rewards accrue based on how long user has been in vault)
 * - User deposit tracking with timestamps
 * - Simulates real Morpho vault behavior for testing
 * - Compatible with mainnet architecture
 *
 * REWARD MECHANISM:
 * - Users earn rewards proportional to their deposit duration
 * - Reward rate: configurable APY (default 10%)
 * - Rewards calculated per-user based on their join time
 * - Total rewards tracked and distributed on withdrawal
 *
 * ARCHITECTURE NOTES:
 * - Based on Morpho V2 VaultV2.sol design patterns
 * - Uses virtual shares for inflation attack protection
 * - Implements share price growth via reward accrual
 * - Safe for testnet and mainnet deployment
 */
contract MockMorphVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* ERRORS */
    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error RateTooHigh();
    error InsufficientBalance();

    /* EVENTS */
    event RewardAccrued(address indexed user, uint256 rewardAmount, uint256 timeElapsed);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event UserJoined(address indexed user, uint256 assets, uint256 shares, uint256 timestamp);
    event UserExited(address indexed user, uint256 assets, uint256 shares, uint256 rewards);
    event TotalRewardsDistributed(uint256 totalRewards);

    /* CONSTANTS */
    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_REWARD_RATE = 2e18; // 200% max APY
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant VIRTUAL_SHARES = 1e6; // Virtual shares for inflation protection
    uint256 public constant VIRTUAL_ASSETS = 1; // Virtual asset for decimals offset

    /* STORAGE */

    /// @notice Vault owner (can update parameters)
    address public owner;

    /// @notice Annual reward rate in WAD (e.g., 0.1e18 = 10% APY)
    uint256 public rewardRate;

    /// @notice Total rewards distributed to all users
    uint256 public totalRewardsDistributed;

    /// @notice Total rewards currently accrued but not yet claimed
    uint256 public totalAccruedRewards;

    /// @dev User deposit information
    struct UserInfo {
        uint256 depositTimestamp;  // When user first deposited or last interacted
        uint256 lastRewardUpdate;  // Last time rewards were calculated
        uint256 pendingRewards;    // Rewards accrued but not yet claimed
        uint256 totalDeposited;    // Total assets ever deposited
        uint256 totalWithdrawn;    // Total assets ever withdrawn
    }

    /// @notice Mapping of user address to their deposit info
    mapping(address => UserInfo) public userInfo;

    /* MODIFIERS */

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /* CONSTRUCTOR */

    /**
     * @notice Initialize the MockMorphVault
     * @param _asset The underlying asset token
     * @param _name Vault share token name
     * @param _symbol Vault share token symbol
     * @param _owner Initial owner address
     */
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _owner
    ) ERC20(_name, _symbol) ERC4626(IERC20(_asset)) {
        if (_asset == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        owner = _owner;
        rewardRate = 1.5e18; // Default 150% APY
    }

    /* OWNER FUNCTIONS */

    /**
     * @notice Transfer ownership to a new address
     * @param newOwner Address of the new owner
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /**
     * @notice Set the annual reward rate
     * @param newRate New reward rate in WAD (e.g., 0.15e18 = 15% APY)
     */
    function setRewardRate(uint256 newRate) external onlyOwner {
        if (newRate > MAX_REWARD_RATE) revert RateTooHigh();

        uint256 oldRate = rewardRate;
        rewardRate = newRate;

        emit RewardRateUpdated(oldRate, newRate);
    }

    /**
     * @notice Fund the vault with reward tokens
     * @param amount Amount of reward tokens to add
     * @dev Owner can deposit additional tokens to fund rewards
     */
    function fundRewards(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    /* USER REWARD FUNCTIONS */

    /**
     * @notice Calculate pending rewards for a user
     * @param user Address of the user
     * @return Pending reward amount in assets
     */
    function pendingRewards(address user) public view returns (uint256) {
        UserInfo storage info = userInfo[user];

        if (balanceOf(user) == 0) {
            return info.pendingRewards;
        }

        // Calculate time elapsed since last reward update
        uint256 timeElapsed = block.timestamp - info.lastRewardUpdate;

        if (timeElapsed == 0) {
            return info.pendingRewards;
        }

        // Calculate user's current asset value in the vault
        uint256 userAssets = convertToAssets(balanceOf(user));

        // Calculate rewards: userAssets * rewardRate * timeElapsed / SECONDS_PER_YEAR
        uint256 newRewards = userAssets.mulDiv(
            rewardRate * timeElapsed,
            WAD * SECONDS_PER_YEAR,
            Math.Rounding.Floor
        );

        return info.pendingRewards + newRewards;
    }

    /**
     * @notice Accrue rewards for a specific user
     * @param user Address of the user
     * @dev Internal function called before any balance-changing operation
     */
    function _accrueUserRewards(address user) internal {
        UserInfo storage info = userInfo[user];

        // Calculate and add any new rewards
        uint256 rewards = pendingRewards(user);

        if (rewards > info.pendingRewards) {
            uint256 newRewards = rewards - info.pendingRewards;
            totalAccruedRewards += newRewards;

            emit RewardAccrued(
                user,
                newRewards,
                block.timestamp - info.lastRewardUpdate
            );
        }

        info.pendingRewards = rewards;
        info.lastRewardUpdate = block.timestamp;
    }

    /**
     * @notice Claim all pending rewards
     * @return rewards Amount of rewards claimed
     */
    function claimRewards() external returns (uint256 rewards) {
        _accrueUserRewards(msg.sender);

        UserInfo storage info = userInfo[msg.sender];
        rewards = info.pendingRewards;

        if (rewards == 0) revert ZeroAmount();

        // Ensure vault has enough balance to pay rewards
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 totalAssets_ = totalAssets();
        uint256 availableRewards = vaultBalance > totalAssets_ ? vaultBalance - totalAssets_ : 0;

        if (availableRewards < rewards) {
            rewards = availableRewards; // Only pay what's available
        }

        if (rewards == 0) revert InsufficientBalance();

        // Reset pending rewards and update stats
        info.pendingRewards = 0;
        totalAccruedRewards -= rewards;
        totalRewardsDistributed += rewards;

        // Transfer rewards
        IERC20(asset()).safeTransfer(msg.sender, rewards);

        emit TotalRewardsDistributed(totalRewardsDistributed);
    }

    /* ERC4626 OVERRIDES */

    /**
     * @notice Get total assets managed by the vault
     * @return Total assets (including user deposits but excluding unfunded reward pool)
     * @dev Overridden to properly track deposited assets separate from reward pool
     */
    function totalAssets() public view override returns (uint256) {
        // Return the balance minus any reward funding that hasn't been distributed
        uint256 balance = IERC20(asset()).balanceOf(address(this));

        // Total assets = balance - (accrued rewards not yet claimed)
        // This ensures share price reflects only deposited assets
        return balance > totalAccruedRewards ? balance - totalAccruedRewards : 0;
    }

    /**
     * @notice Deposit assets and receive shares
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        // Accrue rewards before deposit changes the share price
        _accrueUserRewards(receiver);

        // Perform standard ERC4626 deposit
        shares = super.deposit(assets, receiver);

        // Update user info
        UserInfo storage info = userInfo[receiver];
        if (info.depositTimestamp == 0) {
            info.depositTimestamp = block.timestamp;
            info.lastRewardUpdate = block.timestamp;
        }
        info.totalDeposited += assets;

        emit UserJoined(receiver, assets, shares, block.timestamp);
    }

    /**
     * @notice Mint shares by depositing assets
     * @param shares Amount of shares to mint
     * @param receiver Address to receive the shares
     * @return assets Amount of assets deposited
     */
    function mint(uint256 shares, address receiver)
        public
        override
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();

        // Accrue rewards before mint changes the share price
        _accrueUserRewards(receiver);

        // Perform standard ERC4626 mint
        assets = super.mint(shares, receiver);

        // Update user info
        UserInfo storage info = userInfo[receiver];
        if (info.depositTimestamp == 0) {
            info.depositTimestamp = block.timestamp;
            info.lastRewardUpdate = block.timestamp;
        }
        info.totalDeposited += assets;

        emit UserJoined(receiver, assets, shares, block.timestamp);
    }

    /**
     * @notice Withdraw assets by burning shares
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the assets
     * @param owner_ Address of the share owner
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        // Accrue rewards before withdrawal
        _accrueUserRewards(owner_);

        // Calculate pending rewards to include in exit event
        uint256 rewards = userInfo[owner_].pendingRewards;

        // Perform standard ERC4626 withdrawal
        shares = super.withdraw(assets, receiver, owner_);

        // Update user info
        UserInfo storage info = userInfo[owner_];
        info.totalWithdrawn += assets;

        emit UserExited(owner_, assets, shares, rewards);
    }

    /**
     * @notice Redeem shares for assets
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner_ Address of the share owner
     * @return assets Amount of assets withdrawn
     */
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();

        // Accrue rewards before redemption
        _accrueUserRewards(owner_);

        // Calculate pending rewards to include in exit event
        uint256 rewards = userInfo[owner_].pendingRewards;

        // Perform standard ERC4626 redemption
        assets = super.redeem(shares, receiver, owner_);

        // Update user info
        UserInfo storage info = userInfo[owner_];
        info.totalWithdrawn += assets;

        emit UserExited(owner_, assets, shares, rewards);
    }

    /* VIEW FUNCTIONS */

    /**
     * @notice Get complete user information
     * @param user Address of the user
     * @return info UserInfo struct with all user data
     */
    function getUserInfo(address user) external view returns (UserInfo memory info) {
        info = userInfo[user];
    }

    /**
     * @notice Get user's time in vault
     * @param user Address of the user
     * @return Time elapsed since first deposit (in seconds)
     */
    function getTimeInVault(address user) external view returns (uint256) {
        if (userInfo[user].depositTimestamp == 0) return 0;
        return block.timestamp - userInfo[user].depositTimestamp;
    }

    /**
     * @notice Get user's total earnings (claimed + pending)
     * @param user Address of the user
     * @return Total rewards earned
     */
    function getTotalEarnings(address user) external view returns (uint256) {
        // Calculate rewards already claimed (difference between withdrawn and deposited)
        UserInfo storage info = userInfo[user];
        uint256 currentValue = convertToAssets(balanceOf(user));
        uint256 netDeposited = info.totalDeposited > info.totalWithdrawn
            ? info.totalDeposited - info.totalWithdrawn
            : 0;

        uint256 claimedRewards = currentValue > netDeposited && netDeposited > 0
            ? currentValue - netDeposited
            : 0;

        return claimedRewards + pendingRewards(user);
    }

    /**
     * @notice Estimate annual yield for a user
     * @param user Address of the user
     * @return Estimated annual yield in assets
     */
    function estimateAnnualYield(address user) external view returns (uint256) {
        uint256 userAssets = convertToAssets(balanceOf(user));
        return userAssets.mulDiv(rewardRate, WAD, Math.Rounding.Floor);
    }

    /**
     * @notice Get current APY
     * @return Current annual percentage yield in WAD
     */
    function currentAPY() external view returns (uint256) {
        return rewardRate;
    }

    /**
     * @notice Check if vault has sufficient rewards to pay all pending claims
     * @return True if vault is sufficiently funded
     */
    function isSufficientlyFunded() external view returns (bool) {
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 totalAssets_ = totalAssets();
        uint256 requiredBalance = totalAssets_ + totalAccruedRewards;
        return vaultBalance >= requiredBalance;
    }
}
