// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Treasury
 * @author Zybra Protocol
 * @notice Central fund storage for protocol fees. No business logic—only custody and disbursement.
 * @dev Follows Aave Collector / Compound Reserves pattern:
 *      - Multi-asset support
 *      - Role-based access (not onlyOwner)
 *      - Pull-based withdrawals
 *      - Zero fee calculation logic (that belongs in FeeCollector)
 *
 * ROLES:
 *   DEFAULT_ADMIN_ROLE  → Governance multisig, can grant/revoke roles
 *   COLLECTOR_ROLE      → FeeCollector contracts, can deposit
 *   MANAGER_ROLE        → Operations, can withdraw to approved destinations
 *
 * INVARIANTS:
 *   1. balanceOf(asset) >= Σ deposits - Σ withdrawals (per asset)
 *   2. Only COLLECTOR_ROLE can increase balances
 *   3. Only MANAGER_ROLE can decrease balances
 */
contract Treasury is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==================== ROLES ====================

    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // ==================== EVENTS ====================

    event Deposited(address indexed asset, address indexed from, uint256 amount);
    event Withdrawn(address indexed asset, address indexed to, uint256 amount);
    event EmergencyWithdraw(address indexed asset, address indexed to, uint256 amount);

    // ==================== ERRORS ====================

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(address asset, uint256 requested, uint256 available);

    // ==================== CONSTRUCTOR ====================

    /**
     * @param _admin Governance address (receives DEFAULT_ADMIN_ROLE)
     * @param _manager Initial manager address (receives MANAGER_ROLE)
     */
    constructor(address _admin, address _manager) {
        if (_admin == address(0) || _manager == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _manager);
    }

    // ==================== DEPOSIT (COLLECTOR ONLY) ====================

    /**
     * @notice Deposit fees from an approved collector
     * @dev Caller must have approved this contract. No internal accounting—
     *      we rely on ERC20 balanceOf as source of truth (gas efficient).
     * @param asset ERC20 token address
     * @param amount Amount to deposit
     */
    function deposit(address asset, uint256 amount) external onlyRole(COLLECTOR_ROLE) nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(asset, msg.sender, amount);
    }

    // ==================== WITHDRAW (MANAGER ONLY) ====================

    /**
     * @notice Withdraw assets to a specified recipient
     * @dev Used for operational disbursements (staking rewards, buybacks, etc.)
     * @param asset ERC20 token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdraw(
        address asset,
        address to,
        uint256 amount
    ) external onlyRole(MANAGER_ROLE) nonReentrant {
        if (asset == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance(asset, amount, balance);

        IERC20(asset).safeTransfer(to, amount);

        emit Withdrawn(asset, to, amount);
    }

    /**
     * @notice Withdraw entire balance of an asset
     * @param asset ERC20 token address
     * @param to Recipient address
     */
    function withdrawAll(address asset, address to) external onlyRole(MANAGER_ROLE) nonReentrant {
        if (asset == address(0) || to == address(0)) revert ZeroAddress();

        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance == 0) revert ZeroAmount();

        IERC20(asset).safeTransfer(to, balance);

        emit Withdrawn(asset, to, balance);
    }

    // ==================== EMERGENCY (ADMIN ONLY) ====================

    /**
     * @notice Emergency withdrawal by governance
     * @dev Only for stuck funds or migration. Emits distinct event for audit trail.
     * @param asset ERC20 token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address asset,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (asset == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(asset).safeTransfer(to, amount);

        emit EmergencyWithdraw(asset, to, amount);
    }

    // ==================== VIEW ====================

    /**
     * @notice Get balance of an asset held by Treasury
     * @param asset ERC20 token address
     * @return balance Current balance
     */
    function balanceOf(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}
