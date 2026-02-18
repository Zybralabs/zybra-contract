// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorphoVaultV2} from "./interfaces/IMorphoVaultV2.sol";
import {IFeeSource} from "./treasury/IFeeSource.sol";


contract ZybraGroup is IFeeSource, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ==================== STORAGE ====================

    struct Member {
        uint128 capitalInGroup;      // Total capital contributed (slot 1)
        uint128 rewardDebt;          // userCapital * accRewardPerShare / ACC_PRECISION at last checkpoint (slot 1)
        uint32 lastContributedCycle; // Last cycle contributed (slot 2)
        uint8 isActive;              // 1=active, 0=inactive (slot 2)
        // 216 bits remaining in slot 2
    }

    // Admin — mutable for 2-step transfer (V2 had immutable)
    address public admin;
    address public pendingAdmin;

    // Immutables
    IERC20 public immutable asset;
    IMorphoVaultV2 public immutable vault;
    uint256 public immutable contributionAmount;
    uint256 public immutable cycleDuration;
    uint256 public immutable totalCycles;

    // Treasury
    address public treasury;

    // Group lifecycle
    uint256 public groupStartTime;
    bool public groupEnded;
    bool public paused;
    uint256 public activeMembersCount;

    // ===== Accumulator yield tracking (MasterChef pattern) =====
    uint256 public accRewardPerShare;        // Accumulated yield per unit of capital (scaled by ACC_PRECISION)
    uint256 public totalCapitalInGroup;      // Sum of all active members' capital
    uint256 public totalDistributedYield;    // Cumulative yield paid to users via claim/withdraw
    uint256 public totalFeesWithdrawn;       // Cumulative fees sent to treasury via collectFees
    uint256 public totalAccumulatedFees;     // Total fees computed by accumulator (≥ totalFeesWithdrawn)
    uint256 public lastMaterializedYield;    // Total yield ever materialized into accumulator

    // Mappings
    mapping(address => Member) public members;
    mapping(address => mapping(uint256 => bool)) public contributedInCycle;
    address[] public membersList;

    // Constants
    uint256 public constant MAX_MEMBERS = 50;
    uint256 public constant MIN_MEMBERS = 2;
    uint256 public constant MIN_CONTRIBUTION = 1e6;
    uint256 public constant MAX_CONTRIBUTION = 1000e6;
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1% flat fee
    uint256 public constant ACC_PRECISION = 1e12;    // Accumulator scaling factor
    uint256 public constant END_GROUP_GRACE_PERIOD = 7 days; // [FIX: H-02] Auto-end grace period

    // ==================== EVENTS ====================

    event Joined(address indexed member);
    event Left(address indexed member);
    event GroupStarted(uint256 timestamp);
    event GroupEnded(uint256 timestamp);
    event Contributed(address indexed member, uint256 amount, uint256 cycle);
    event YieldClaimed(address indexed member, uint256 amount);
    event Withdrawn(address indexed member, uint256 capital, uint256 yield);
    event EmergencyWithdrawn(address indexed member, uint256 capital, uint256 forfeitedYield);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
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

    // ==================== MODIFIERS ====================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ==================== CONSTRUCTOR ====================

    constructor(
        address _asset,
        uint256 _amount,
        uint256 _cycleDuration,
        uint256 _totalCycles,
        address _admin,
        address _vault,
        address _treasury
    ) {
        if (_asset == address(0) || _admin == address(0) || _vault == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_amount < MIN_CONTRIBUTION || _amount > MAX_CONTRIBUTION) revert InvalidAmount();
        if (_cycleDuration == 0 || _totalCycles == 0 || _totalCycles > 52) revert InvalidCycle();

        // [FIX: MEDIUM-04] Validate vault asset matches group asset
        if (IMorphoVaultV2(_vault).asset() != _asset) revert VaultAssetMismatch();

        admin = _admin;
        asset = IERC20(_asset);
        contributionAmount = _amount;
        cycleDuration = _cycleDuration;
        totalCycles = _totalCycles;
        vault = IMorphoVaultV2(_vault);
        treasury = _treasury;

        // Auto-add admin
        _addMember(_admin);
    }

    // ==================== INTERNAL: ACCUMULATOR ====================

    /**
     * @dev Materialize new vault yield into the accumulator.
     *      Called before every state-changing operation.
     *
     * MATH:
     *   totalEverYield = vaultYieldRemaining + totalDistributedYield + totalFeesWithdrawn
     *   newYield = totalEverYield - lastMaterializedYield
     *   fee = newYield * PROTOCOL_FEE_BPS / 10000
     *   distributable = newYield - fee
     *   accRewardPerShare += distributable * ACC_PRECISION / totalCapitalInGroup
     *
     * This ensures totalEverYield is reconstructed from vault + history,
     * making it ORDER-INDEPENDENT. Whether Alice or Bob claims first,
     * totalEverYield is the same.
     */
    function _accrueRewards() internal {
        uint256 _totalCap = totalCapitalInGroup;

        uint256 vaultShares = vault.balanceOf(address(this));
        uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        uint256 vaultYield = vaultValue > _totalCap ? vaultValue - _totalCap : 0;

        uint256 totalEverYield = vaultYield + totalDistributedYield + totalFeesWithdrawn;

        if (totalEverYield <= lastMaterializedYield) return;

        uint256 newYield = totalEverYield - lastMaterializedYield;

        if (_totalCap == 0) {
            // No capital to distribute to — all goes to fees
            totalAccumulatedFees += newYield;
            lastMaterializedYield = totalEverYield;
            return;
        }

        uint256 fee = (newYield * PROTOCOL_FEE_BPS) / 10000;
        uint256 distributable = newYield - fee;

        accRewardPerShare += (distributable * ACC_PRECISION) / _totalCap;
        totalAccumulatedFees += fee;
        lastMaterializedYield = totalEverYield;
    }

    /**
     * @dev Calculate pending yield for a member (view-safe, no state writes)
     */
    function _pendingReward(Member memory m) internal view returns (uint256) {
        if (m.capitalInGroup == 0) return 0;
        uint256 reward = (uint256(m.capitalInGroup) * accRewardPerShare) / ACC_PRECISION;
        return reward > m.rewardDebt ? reward - m.rewardDebt : 0;
    }

    /**
     * @dev Safely withdraw from vault and validate return value
     *      [FIX: H-01] Validate vault.withdraw() shares burned > 0
     */
    function _safeVaultWithdraw(uint256 assets, address receiver) internal {
        uint256 sharesBurned = vault.withdraw(assets, receiver, address(this));
        if (sharesBurned == 0) revert WithdrawFailed();
    }

    // ==================== SETUP PHASE ====================

    function joinGroup() external whenNotPaused {
        if (groupStartTime != 0) revert GroupAlreadyStarted();
        _addMember(msg.sender);
    }

    function _addMember(address member) internal {
        if (members[member].isActive == 1) revert AlreadyMember();
        if (activeMembersCount >= MAX_MEMBERS) revert InvalidAmount();

        members[member] = Member({
            capitalInGroup: 0,
            rewardDebt: 0,
            lastContributedCycle: 0,
            isActive: 1
        });
        membersList.push(member);
        // [FIX: L-02] Use checked arithmetic
        activeMembersCount += 1;

        emit Joined(member);
    }

    function leaveGroup() external {
        if (groupStartTime != 0) revert GroupAlreadyStarted();
        if (members[msg.sender].isActive != 1) revert NotMember();

        members[msg.sender].isActive = 0;
        // [FIX: L-02] Use checked arithmetic
        activeMembersCount -= 1;

        emit Left(msg.sender);
    }

    function startGroup() external onlyAdmin {
        if (groupStartTime != 0) revert GroupAlreadyStarted();
        // [FIX: LOW-02] Require minimum members for a ROSCA
        if (activeMembersCount < MIN_MEMBERS) revert InsufficientMembers();

        groupStartTime = block.timestamp;
        emit GroupStarted(block.timestamp);
    }

    /**
     * @notice End the group
     * @dev Admin can end anytime. [FIX: H-02] After all cycles + grace period,
     *      ANY address can end the group — prevents admin key loss from blocking.
     */
    function endGroup() external {
        if (groupStartTime == 0) revert GroupNotStarted();
        if (groupEnded) revert GroupAlreadyEnded();

        // Admin can always end; non-admin only after expiry
        if (msg.sender != admin) {
            uint256 deadline = groupStartTime + (totalCycles * cycleDuration) + END_GROUP_GRACE_PERIOD;
            if (block.timestamp < deadline) revert GroupNotExpired();
        }

        // [FIX: MEDIUM-03] Snapshot yield state at group end
        _accrueRewards();

        groupEnded = true;
        emit GroupEnded(block.timestamp);
    }

    // ==================== ACTIVE PHASE ====================

    /**
     * @notice Contribute for current cycle
     * @dev Accrues rewards, then increases capital with correct debt adjustment.
     *      The debt formula `rewardDebt += amount * accRewardPerShare / PRECISION`
     *      ensures existing pending yield is preserved while new capital only
     *      earns from this point forward.
     */
    function contribute() external nonReentrant whenNotPaused {
        if (members[msg.sender].isActive != 1) revert NotMember();
        if (groupStartTime == 0) revert GroupNotStarted();
        if (groupEnded) revert GroupAlreadyEnded();

        uint256 currentCycle = getCurrentCycle();
        if (currentCycle == 0 || currentCycle > totalCycles) revert InvalidCycle();
        if (contributedInCycle[msg.sender][currentCycle]) revert AlreadyContributed();

        // Accrue all pending vault yield into accumulator BEFORE changing capital
        _accrueRewards();

        uint256 amount = contributionAmount;
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // Update member capital — preserve existing pending yield via debt adjustment
        Member memory m = members[msg.sender];
        unchecked { m.capitalInGroup += uint128(amount); }
        // Additive debt: only new capital's share of current accRewardPerShare
        // This preserves any pending yield from before this contribution
        m.rewardDebt += uint128((amount * accRewardPerShare) / ACC_PRECISION);
        m.lastContributedCycle = uint32(currentCycle);
        members[msg.sender] = m;

        contributedInCycle[msg.sender][currentCycle] = true;
        // [FIX: L-02] Use checked arithmetic
        totalCapitalInGroup += amount;

        // Deposit to vault — [FIX: MEDIUM-06] validate shares returned
        asset.forceApprove(address(vault), amount);
        uint256 sharesMinted = vault.deposit(amount, address(this));
        if (sharesMinted == 0) revert DepositFailed();

        emit Contributed(msg.sender, amount, currentCycle);
    }

    /**
     * @notice Claim accumulated yield without withdrawing capital
     * @dev Order-independent: accRewardPerShare is pre-computed.
     *      Whether Alice or Bob claims first, they get identical yield per capital unit.
     */
    function claimYield() external nonReentrant whenNotPaused {
        if (members[msg.sender].isActive != 1) revert NotMember();

        _accrueRewards();

        Member memory m = members[msg.sender];
        uint256 pending = _pendingReward(m);
        if (pending == 0) revert NothingToClaim();

        // Update debt to current state — prevents double-claiming
        m.rewardDebt = uint128((uint256(m.capitalInGroup) * accRewardPerShare) / ACC_PRECISION);
        members[msg.sender] = m;

        // Track distributed yield for totalEverYield reconstruction
        totalDistributedYield += pending;

        // CEI: state updated before external call
        // [FIX: H-01] Validate vault withdrawal return
        _safeVaultWithdraw(pending, msg.sender);
        emit YieldClaimed(msg.sender, pending);
    }

    /**
     * @notice Withdraw all capital + pending yield
     * @dev Clears member completely. Capital removed from pool.
     */
    function withdraw() external nonReentrant whenNotPaused {
        if (members[msg.sender].isActive != 1) revert NotMember();

        _accrueRewards();

        Member memory m = members[msg.sender];
        uint256 capital = m.capitalInGroup;
        uint256 yieldAmount = _pendingReward(m);
        uint256 totalAmount = capital + yieldAmount;

        if (totalAmount == 0) revert InvalidAmount();

        // Clear member fully
        members[msg.sender] = Member(0, 0, 0, 0);
        // [FIX: L-02] Use checked arithmetic
        activeMembersCount -= 1;
        totalCapitalInGroup -= capital;

        // Track yield for totalEverYield reconstruction
        if (yieldAmount > 0) {
            totalDistributedYield += yieldAmount;
        }

        // [FIX: H-01] Validate vault withdrawal return
        _safeVaultWithdraw(totalAmount, msg.sender);
        emit Withdrawn(msg.sender, capital, yieldAmount);
    }

    /**
     * @notice Emergency withdraw — capital only, works even when paused
     * @dev [FIX: MEDIUM-01] Escape hatch. No yield calculation.
     *      Users can always recover their principal.
     *      [FIX: M-01] Accrues rewards before state changes to prevent
     *      yield dust lockup for remaining members.
     */
    function emergencyWithdraw() external nonReentrant {
        // NOTE: No pause check — this IS the escape hatch
        Member memory m = members[msg.sender];
        if (m.isActive != 1) revert NotMember();
        uint256 capital = m.capitalInGroup;
        if (capital == 0) revert InvalidAmount();

        // [FIX: M-01] Accrue rewards before reducing totalCapitalInGroup
        _accrueRewards();

        // Calculate forfeited yield for event transparency
        uint256 forfeitedYield = _pendingReward(m);

        // Clear member
        members[msg.sender] = Member(0, 0, 0, 0);
        // [FIX: L-02] Use checked arithmetic
        activeMembersCount -= 1;
        totalCapitalInGroup -= capital;

        // Withdraw ONLY capital — yield stays for other users
        // [FIX: H-01] Validate vault withdrawal return
        _safeVaultWithdraw(capital, msg.sender);
        emit EmergencyWithdrawn(msg.sender, capital, forfeitedYield);
    }

    // ==================== ADMIN FUNCTIONS ====================

    function setTreasury(address newTreasury) external onlyAdmin {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Collect protocol fees — [FIX: HIGH-02] admin only
     * @dev Computes pending = totalAccumulatedFees - totalFeesWithdrawn.
     *      Fees are always correctly calculated via the accumulator,
     *      never double-counted.
     */
    function collectFees() external onlyAdmin nonReentrant returns (uint256 amount) {
        _accrueRewards();

        amount = totalAccumulatedFees > totalFeesWithdrawn
            ? totalAccumulatedFees - totalFeesWithdrawn
            : 0;
        if (amount == 0) revert InvalidAmount();

        // Cap at actual vault value to handle rounding dust
        uint256 vaultShares = vault.balanceOf(address(this));
        uint256 maxWithdrawable = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        if (amount > maxWithdrawable) {
            amount = maxWithdrawable;
        }
        if (amount == 0) revert InvalidAmount();

        totalFeesWithdrawn += amount;

        // [FIX: H-01] Validate vault withdrawal return
        _safeVaultWithdraw(amount, treasury);
        emit FeesCollected(treasury, amount);
    }

    function pendingFees() external view returns (uint256) {
        // Compute live pending fees including un-materialized yield
        uint256 vaultShares = vault.balanceOf(address(this));
        uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        uint256 vaultYield = vaultValue > totalCapitalInGroup ? vaultValue - totalCapitalInGroup : 0;
        uint256 totalEverYield = vaultYield + totalDistributedYield + totalFeesWithdrawn;

        uint256 newYield = totalEverYield > lastMaterializedYield
            ? totalEverYield - lastMaterializedYield
            : 0;
        uint256 newFees = (newYield * PROTOCOL_FEE_BPS) / 10000;
        uint256 totalFees = totalAccumulatedFees + newFees;
        return totalFees > totalFeesWithdrawn ? totalFees - totalFeesWithdrawn : 0;
    }

    function feeAsset() external view returns (address) {
        return address(asset);
    }

    // ===== 2-Step Admin Transfer [FIX: MEDIUM-02] =====

    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = _newAdmin;
        emit AdminTransferProposed(admin, _newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    function pause() external onlyAdmin {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused();
    }

    /**
     * @notice Recover tokens accidentally sent to this contract
     * @dev [FIX: LOW-03] Cannot sweep the group's asset or vault shares
     */
    function sweepToken(IERC20 token) external onlyAdmin {
        if (address(token) == address(asset)) revert CannotSweep();
        if (address(token) == address(vault)) revert CannotSweep();
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert InvalidAmount();
        token.safeTransfer(admin, balance);
        emit TokenSwept(address(token), balance);
    }

    // ==================== VIEW FUNCTIONS ====================

    function getCurrentCycle() public view returns (uint256) {
        uint256 start = groupStartTime;
        if (start == 0 || block.timestamp < start) return 0;

        uint256 cycle;
        unchecked { cycle = ((block.timestamp - start) / cycleDuration) + 1; }
        return cycle > totalCycles ? totalCycles : cycle;
    }

    /**
     * @notice Deadline after which any address can call endGroup()
     * @dev Returns 0 if group hasn't started. [FIX: H-02]
     */
    function getGroupEndDeadline() external view returns (uint256) {
        if (groupStartTime == 0) return 0;
        return groupStartTime + (totalCycles * cycleDuration) + END_GROUP_GRACE_PERIOD;
    }

    function pendingYield(address user) external view returns (uint256) {
        Member memory m = members[user];
        if (m.capitalInGroup == 0 || m.isActive == 0) return 0;

        // Simulate _accrueRewards to get live accRewardPerShare
        uint256 _accRPS = accRewardPerShare;
        uint256 _totalCap = totalCapitalInGroup;

        if (_totalCap > 0) {
            uint256 vaultShares = vault.balanceOf(address(this));
            uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
            uint256 vaultYield = vaultValue > _totalCap ? vaultValue - _totalCap : 0;
            uint256 totalEverYield = vaultYield + totalDistributedYield + totalFeesWithdrawn;

            if (totalEverYield > lastMaterializedYield) {
                uint256 newYield = totalEverYield - lastMaterializedYield;
                uint256 fee = (newYield * PROTOCOL_FEE_BPS) / 10000;
                uint256 distributable = newYield - fee;
                _accRPS += (distributable * ACC_PRECISION) / _totalCap;
            }
        }

        uint256 reward = (uint256(m.capitalInGroup) * _accRPS) / ACC_PRECISION;
        return reward > m.rewardDebt ? reward - m.rewardDebt : 0;
    }

    function getMemberInfo(address member) external view returns (
        uint256 capitalInGroup,
        uint256 pendingYieldAmount,
        uint256 lastContributedCycle,
        bool isActive
    ) {
        Member memory m = members[member];

        uint256 pending = 0;
        if (m.capitalInGroup > 0 && m.isActive == 1) {
            uint256 _accRPS = accRewardPerShare;
            uint256 _totalCap = totalCapitalInGroup;

            if (_totalCap > 0) {
                uint256 vaultShares = vault.balanceOf(address(this));
                uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
                uint256 vaultYield = vaultValue > _totalCap ? vaultValue - _totalCap : 0;
                uint256 totalEverYield = vaultYield + totalDistributedYield + totalFeesWithdrawn;

                if (totalEverYield > lastMaterializedYield) {
                    uint256 newYield = totalEverYield - lastMaterializedYield;
                    uint256 fee = (newYield * PROTOCOL_FEE_BPS) / 10000;
                    _accRPS += ((newYield - fee) * ACC_PRECISION) / _totalCap;
                }
            }

            uint256 reward = (uint256(m.capitalInGroup) * _accRPS) / ACC_PRECISION;
            pending = reward > m.rewardDebt ? reward - m.rewardDebt : 0;
        }

        return (uint256(m.capitalInGroup), pending, uint256(m.lastContributedCycle), m.isActive == 1);
    }

    function getGroupStatus() external view returns (
        bool started,
        bool ended,
        uint256 currentCycle,
        uint256 totalMembers,
        uint256 totalCapital,
        uint256 totalYield,
        uint256 feesAccumulated
    ) {
        uint256 vaultShares = vault.balanceOf(address(this));
        uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        uint256 yieldAmount = vaultValue > totalCapitalInGroup ? vaultValue - totalCapitalInGroup : 0;

        uint256 pendingFeesAmount = totalAccumulatedFees > totalFeesWithdrawn
            ? totalAccumulatedFees - totalFeesWithdrawn
            : 0;

        return (
            groupStartTime != 0,
            groupEnded,
            getCurrentCycle(),
            activeMembersCount,
            totalCapitalInGroup,
            yieldAmount,
            pendingFeesAmount
        );
    }

    function membersCount() external view returns (uint256) {
        return activeMembersCount;
    }

    function getMembersListLength() external view returns (uint256) {
        return membersList.length;
    }

    function getMemberAt(uint256 index) external view returns (address) {
        return membersList[index];
    }
}
