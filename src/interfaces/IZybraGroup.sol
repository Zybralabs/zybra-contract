// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorphoVaultV2} from "./IMorphoVaultV2.sol";

/// @title IZybraGroup
/// @notice Interface for the ZybraGroup ROSCA contract with MasterChef-style yield distribution
interface IZybraGroup {
    // ==================== STRUCTS ====================

    struct Member {
        uint128 capitalInGroup;
        uint128 rewardDebt;
        uint32 lastContributedCycle;
        uint8 isActive;
    }

    // ==================== EVENTS ====================

    event Joined(address indexed member);
    event Left(address indexed member);
    event GroupStarted(uint256 timestamp);
    event GroupEnded(uint256 timestamp);
    event Contributed(address indexed member, uint256 amount, uint256 cycle);
    event YieldClaimed(address indexed member, uint256 amount);
    event Withdrawn(address indexed member, uint256 capital, uint256 yield);
    event EmergencyWithdrawn(address indexed member, uint256 capital, uint256 forfeitedYield);
    event FeesCollected(address indexed treasury, uint256 amount);
    event AdminTransferProposed(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event TokenSwept(address indexed token, uint256 amount);
    event Paused();
    event Unpaused();

    // ==================== ERRORS ====================

    error NotAdmin();
    error NotPendingAdmin();
    error NotMember();
    error ContractPaused();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidCycle();
    error AlreadyMember();
    error GroupAlreadyStarted();
    error GroupNotStarted();
    error GroupAlreadyEnded();
    error InsufficientMembers();
    error AlreadyContributed();
    error NothingToClaim();
    error VaultAssetMismatch();
    error DepositFailed();
    error WithdrawFailed();
    error CannotSweep();
    error GroupNotExpired();
    error FeeOnTransferNotSupported();

    // ==================== STATE ACCESSORS ====================

    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function asset() external view returns (IERC20);
    function vault() external view returns (IMorphoVaultV2);
    function contributionAmount() external view returns (uint256);
    function cycleDuration() external view returns (uint256);
    function totalCycles() external view returns (uint256);
    function factory() external view returns (address);
    function groupStartTime() external view returns (uint256);
    function groupEnded() external view returns (bool);
    function paused() external view returns (bool);
    function activeMembersCount() external view returns (uint256);
    function accRewardPerShare() external view returns (uint256);
    function totalCapitalInGroup() external view returns (uint256);
    function totalDistributedYield() external view returns (uint256);
    function totalFeesWithdrawn() external view returns (uint256);
    function totalAccumulatedFees() external view returns (uint256);
    function lastMaterializedYield() external view returns (uint256);
    function members(address member) external view returns (
        uint128 capitalInGroup,
        uint128 rewardDebt,
        uint32 lastContributedCycle,
        uint8 isActive
    );
    function contributedInCycle(address member, uint256 cycle) external view returns (bool);
    function membersList(uint256 index) external view returns (address);
    function treasury() external view returns (address);

    // ==================== CONSTANTS ====================

    function MAX_MEMBERS() external view returns (uint256);
    function MIN_MEMBERS() external view returns (uint256);
    function MIN_CONTRIBUTION() external view returns (uint256);
    function MAX_CONTRIBUTION() external view returns (uint256);
    function PROTOCOL_FEE_BPS() external view returns (uint256);
    function ACC_PRECISION() external view returns (uint256);
    function END_GROUP_GRACE_PERIOD() external view returns (uint256);
    function MIN_FEE_AUTO_COLLECT() external view returns (uint256);
    function MAX_YIELD_PER_ACCRUAL_BPS() external view returns (uint256);

    // ==================== SETUP PHASE ====================

    function joinGroup() external;
    function leaveGroup() external;
    function startGroup() external;
    function endGroup() external;

    // ==================== ACTIVE PHASE ====================

    function contribute() external;
    function claimYield() external;
    function claimYieldTo(address receiver) external;
    function withdraw() external;
    function withdrawTo(address receiver) external;
    function emergencyWithdraw() external;
    function emergencyWithdrawTo(address receiver) external;

    // ==================== ADMIN FUNCTIONS ====================

    function collectFees() external returns (uint256 amount);
    function pendingFees() external view returns (uint256);
    function feeAsset() external view returns (address);
    function transferAdmin(address _newAdmin) external;
    function acceptAdmin() external;
    function pause() external;
    function unpause() external;
    function sweepToken(IERC20 token) external;

    // ==================== VIEW FUNCTIONS ====================

    function getCurrentCycle() external view returns (uint256);
    function getGroupEndDeadline() external view returns (uint256);
    function pendingYield(address user) external view returns (uint256);
    function getMemberInfo(address member) external view returns (
        uint256 capitalInGroup,
        uint256 pendingYieldAmount,
        uint256 lastContributedCycle,
        bool isActive
    );
    function getGroupStatus() external view returns (
        bool started,
        bool ended,
        uint256 currentCycle,
        uint256 totalMembers,
        uint256 totalCapital,
        uint256 totalYield,
        uint256 feesAccumulated
    );
    function membersCount() external view returns (uint256);
    function getMembersListLength() external view returns (uint256);
    function getMemberAt(uint256 index) external view returns (address);
}
