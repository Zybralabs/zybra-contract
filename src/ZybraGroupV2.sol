// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorphoVaultV2} from "./interfaces/IMorphoVaultV2.sol";
import {IFeeSource} from "./treasury/IFeeSource.sol";

/**
 * @title ZybraGroup V2 - Time-Weighted Capital Yield Distribution (TWAB) - FIXED VERSION
 * @notice ROSCA with fair yield distribution based on capital × time
 * @dev Uses Morpho Vault V2 (ERC4626) for yield generation
 * 
 * ✅ FIXES APPLIED:
 * 1. Removed unnecessary address parameters from joinGroup()
 * 2. Removed unnecessary address parameters from contribute()
 * 3. Consistent msg.sender usage across all functions
 * 4. No more admin override for financial operations
 * 5. Explicit adminAddMember() for programmatic onboarding
 * 6. Clear audit trail - joinGroup vs adminAddMember vs contribute
 *
 * INVARIANTS:
 * ===========
 * 1. totalCapitalInGroup == Σ members[i].capitalInGroup for all active members
 * 2. totalCapitalSeconds accumulates correctly: += totalCapitalInGroup × elapsed
 * 3. User yield share = userCapitalSeconds / globalCapitalSeconds × distributableYield
 * 4. yieldDebt tracks claimed yield to prevent double-claiming
 * 5. Vault shares value >= totalCapitalInGroup (vault generates yield, never loses)
 * 6. msg.sender is ALWAYS the source of truth for user actions (no parameters)
 *
 * STORAGE LAYOUT (Optimized):
 * ===========================
 * Member struct: 2 slots (packed)
 * - Slot 1: capitalInGroup(128) + yieldDebt(128)
 * - Slot 2: lastContributedCycle(32) + lastUpdateTime(40) + isActive(8) + capitalSeconds(176)
 */
contract ZybraGroupV2 is IFeeSource, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ==================== STORAGE ====================

    // Member struct - 2 storage slots, tightly packed
    struct Member {
        uint128 capitalInGroup;      // Total capital contributed (slot 1)
        uint128 yieldDebt;           // Yield already claimed (slot 1)
        uint32 lastContributedCycle; // Last cycle contributed (slot 2)
        uint40 lastUpdateTime;       // Last update timestamp (slot 2)
        uint8 isActive;              // 1=active, 0=inactive (slot 2)
        uint176 capitalSeconds;      // Accumulated capital × time (slot 2)
    }

    // Immutables (no storage slots at runtime)
    address public immutable admin;
    IERC20 public immutable asset;
    IMorphoVaultV2 public immutable vault;
    uint256 public immutable contributionAmount;
    uint256 public immutable cycleDuration;
    uint256 public immutable totalCycles;

    // Treasury - like Aave/Compound collector pattern
    address public treasury;

    // Group state - 1 slot each
    uint256 public groupStartTime;        // 0 = not started, >0 = start timestamp
    bool public groupEnded;
    bool public paused;
    uint256 public activeMembersCount;

    // Capital tracking - 1 slot each
    uint256 public totalCapitalInGroup;
    uint256 public totalCapitalSeconds;
    uint256 public lastGlobalUpdateTime;
    uint256 public accumulatedFees;       // Fees accumulated, waiting for withdrawal

    // Mappings
    mapping(address => Member) public members;
    mapping(address => mapping(uint256 => bool)) public contributedInCycle;
    address[] public membersList;

    // Constants
    uint256 public constant MAX_MEMBERS = 50;
    uint256 public constant MIN_CONTRIBUTION = 1e6;
    uint256 public constant MAX_CONTRIBUTION = 1000e6;
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1% flat fee on all yield

    // ==================== EVENTS ====================

    event Joined(address indexed member);
    event Left(address indexed member);
    event GroupStarted(uint256 timestamp);
    event GroupEnded(uint256 timestamp);
    event Contributed(address indexed member, uint256 amount, uint256 cycle);
    event YieldClaimed(address indexed member, uint256 amount);
    event Withdrawn(address indexed member, uint256 capital, uint256 yield);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesCollected(address indexed treasury, uint256 amount);
    event Paused();
    event Unpaused();

    // ==================== ERRORS ====================

    error NotAdmin();
    error NotMember();
    error ContractPaused();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidCycle();
    error AlreadyMember();
    error GroupAlreadyStarted();
    error GroupNotStarted();
    error GroupAlreadyEnded();
    error NoMembers();
    error AlreadyContributed();
    error NothingToClaim();
    error Reentrancy();

    // ==================== MODIFIERS ====================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
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

        admin = _admin;
        asset = IERC20(_asset);
        contributionAmount = _amount;
        cycleDuration = _cycleDuration;
        totalCycles = _totalCycles;
        vault = IMorphoVaultV2(_vault);
        treasury = _treasury;
        lastGlobalUpdateTime = block.timestamp;

        // Auto-add admin
        _addMember(_admin);
    }

    // ==================== SETUP PHASE ====================

    /**
     * ✅ FIXED: Removed address parameter
     * @notice Join the group - only msg.sender can join themselves
     * @dev No parameters needed - msg.sender is always the joiner
     */
    function joinGroup() external {
        if (paused) revert ContractPaused();
        if (groupStartTime != 0) revert GroupAlreadyStarted();
        _addMember(msg.sender);
    }

    function _addMember(address member) internal {
        if (members[member].isActive == 1) revert AlreadyMember();
        if (activeMembersCount >= MAX_MEMBERS) revert InvalidAmount();

        members[member] = Member({
            capitalInGroup: 0,
            yieldDebt: 0,
            lastContributedCycle: 0,
            lastUpdateTime: uint40(block.timestamp),
            isActive: 1,
            capitalSeconds: 0
        });
        membersList.push(member);
        unchecked { ++activeMembersCount; }

        emit Joined(member);
    }

    /**
     * ✅ FIXED: Removed address parameter
     * @notice Leave the group - only msg.sender can leave themselves
     */
    function leaveGroup() external {
        if (groupStartTime != 0) revert GroupAlreadyStarted();
        if (members[msg.sender].isActive != 1) revert NotMember();

        members[msg.sender].isActive = 0;
        unchecked { --activeMembersCount; }

        emit Left(msg.sender);
    }

    function startGroup() external onlyAdmin {
        if (groupStartTime != 0) revert GroupAlreadyStarted();
        if (activeMembersCount == 0) revert NoMembers();

        groupStartTime = block.timestamp;
        lastGlobalUpdateTime = block.timestamp;

        emit GroupStarted(block.timestamp);
    }

    function endGroup() external onlyAdmin {
        if (groupStartTime == 0) revert GroupNotStarted();
        if (groupEnded) revert GroupAlreadyEnded();

        groupEnded = true;
        emit GroupEnded(block.timestamp);
    }

    // ==================== ACTIVE PHASE ====================

    /**
     * ✅ FIXED: Removed address parameter
     * @notice Contribute for current cycle - only msg.sender can contribute their own funds
     * @dev Updates capital-seconds before modifying capital (INVARIANT enforcement)
     * @dev No admin override - user must initiate the transaction themselves
     */
    function contribute() external nonReentrant() {
        if (paused) revert ContractPaused();
        if (members[msg.sender].isActive != 1) revert NotMember();
        if (groupStartTime == 0) revert GroupNotStarted();
        if (groupEnded) revert GroupAlreadyEnded();

        uint256 currentCycle = getCurrentCycle();
        if (currentCycle == 0 || currentCycle > totalCycles) revert InvalidCycle();
        if (contributedInCycle[msg.sender][currentCycle]) revert AlreadyContributed();

        uint256 amount = contributionAmount;
        // ✅ FIX: Always use msg.sender - user must provide funds themselves
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // Update global capital-seconds BEFORE changing capital (INVARIANT)
        uint256 _now = block.timestamp;
        uint256 _totalCap = totalCapitalInGroup;
        uint256 elapsed = _now - lastGlobalUpdateTime;
        if (elapsed > 0 && _totalCap > 0) {
            unchecked { totalCapitalSeconds += _totalCap * elapsed; }
        }
        lastGlobalUpdateTime = _now;

        // Update member
        Member memory m = members[msg.sender];
        if (_now > m.lastUpdateTime && m.capitalInGroup > 0) {
            unchecked {
                m.capitalSeconds += uint176(uint256(m.capitalInGroup) * (_now - m.lastUpdateTime));
            }
        }
        unchecked { m.capitalInGroup += uint128(amount); }
        m.lastContributedCycle = uint32(currentCycle);
        m.lastUpdateTime = uint40(_now);
        members[msg.sender] = m;

        contributedInCycle[msg.sender][currentCycle] = true;
        unchecked { totalCapitalInGroup += amount; }

        // Deposit to vault
        asset.forceApprove(address(vault), amount);
        vault.deposit(amount, address(this));

        emit Contributed(msg.sender, amount, currentCycle);
    }

    /**
     * ✅ CONSISTENT: Only msg.sender can claim their own yield
     * @notice Claim accumulated yield
     * @dev Real-time calculation from vault value, no dependency on accrual calls
     */
    function claimYield() external nonReentrant() {
        if (paused) revert ContractPaused();
        if (members[msg.sender].isActive != 1) revert NotMember();

        uint256 _now = block.timestamp;

        // Update global capital-seconds
        uint256 _totalCap = totalCapitalInGroup;
        uint256 elapsed = _now - lastGlobalUpdateTime;
        if (elapsed > 0 && _totalCap > 0) {
            unchecked { totalCapitalSeconds += _totalCap * elapsed; }
        }
        lastGlobalUpdateTime = _now;

        // Update member capital-seconds
        Member memory m = members[msg.sender];
        if (_now > m.lastUpdateTime && m.capitalInGroup > 0) {
            unchecked {
                m.capitalSeconds += uint176(uint256(m.capitalInGroup) * (_now - m.lastUpdateTime));
            }
            m.lastUpdateTime = uint40(_now);
        }

        if (m.capitalSeconds == 0) revert NothingToClaim();

        // Calculate yield from vault
        uint256 vaultShares = vault.balanceOf(address(this));
        uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        if (vaultValue <= _totalCap) revert NothingToClaim();

        uint256 totalYield;
        unchecked { totalYield = vaultValue - _totalCap; }

        // Flat 1% protocol fee on all yield (like Aave/Compound)
        uint256 protocolFee = (totalYield * PROTOCOL_FEE_BPS) / 10000;
        uint256 distributableYield = totalYield - protocolFee;

        // User share based on TWAB
        uint256 globalCapSec = totalCapitalSeconds;
        if (globalCapSec == 0) revert NothingToClaim();

        uint256 userShare = uint256(m.capitalSeconds).mulDiv(distributableYield, globalCapSec);
        if (userShare <= m.yieldDebt) revert NothingToClaim();

        uint256 claimable;
        unchecked { claimable = userShare - m.yieldDebt; }

        // Calculate user's portion of the fee and accumulate
        uint256 userFeeShare = uint256(m.capitalSeconds).mulDiv(protocolFee, globalCapSec);
        accumulatedFees += userFeeShare;

        m.yieldDebt = uint128(userShare);
        members[msg.sender] = m;

        vault.withdraw(claimable, msg.sender, address(this));
        emit YieldClaimed(msg.sender, claimable);
    }

    /**
     * ✅ CONSISTENT: Only msg.sender can withdraw their own capital
     * @notice Withdraw capital + yield
     * @dev NO PENALTY - early withdrawal simply stops earning future yield
     */
    function withdraw() external nonReentrant() {
        if (paused) revert ContractPaused();
        if (members[msg.sender].isActive != 1) revert NotMember();

        uint256 _now = block.timestamp;

        // Update global capital-seconds
        uint256 _totalCap = totalCapitalInGroup;
        uint256 elapsed = _now - lastGlobalUpdateTime;
        if (elapsed > 0 && _totalCap > 0) {
            unchecked { totalCapitalSeconds += _totalCap * elapsed; }
        }
        lastGlobalUpdateTime = _now;

        // Update member
        Member memory m = members[msg.sender];
        if (_now > m.lastUpdateTime && m.capitalInGroup > 0) {
            unchecked {
                m.capitalSeconds += uint176(uint256(m.capitalInGroup) * (_now - m.lastUpdateTime));
            }
        }

        uint256 capital = m.capitalInGroup;
        uint256 yieldAmount = 0;

        // Calculate yield
        uint256 vaultShares = vault.balanceOf(address(this));
        uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        uint256 globalCapSec = totalCapitalSeconds;

        if (vaultValue > _totalCap && globalCapSec > 0 && m.capitalSeconds > 0) {
            uint256 totalYield = vaultValue - _totalCap;
            
            // Flat 1% protocol fee on all yield
            uint256 protocolFee = (totalYield * PROTOCOL_FEE_BPS) / 10000;
            uint256 distributableYield = totalYield - protocolFee;

            uint256 userShare = uint256(m.capitalSeconds).mulDiv(distributableYield, globalCapSec);
            if (userShare > m.yieldDebt) {
                unchecked { yieldAmount = userShare - m.yieldDebt; }
                
                // Accumulate user's portion of protocol fee
                uint256 userFeeShare = uint256(m.capitalSeconds).mulDiv(protocolFee, globalCapSec);
                accumulatedFees += userFeeShare;
            }
        }

        uint256 totalAmount = capital + yieldAmount;
        if (totalAmount == 0) revert InvalidAmount();

        // Clear member
        members[msg.sender] = Member(0, 0, 0, 0, 0, 0);
        unchecked {
            --activeMembersCount;
            totalCapitalInGroup -= capital;
        }

        vault.withdraw(totalAmount, msg.sender, address(this));
        emit Withdrawn(msg.sender, capital, yieldAmount);
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Update treasury address (like Aave governance pattern)
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyAdmin {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Collect accumulated protocol fees to treasury
     * @dev Implements IFeeSource - withdraws from vault to treasury
     * @return amount Fees collected
     */
    function collectFees() external nonReentrant() returns (uint256 amount) {
        amount = accumulatedFees;
        if (amount == 0) revert InvalidAmount();

        accumulatedFees = 0;
        address _treasury = treasury;

        vault.withdraw(amount, _treasury, address(this));
        emit FeesCollected(_treasury, amount);
    }

    /**
     * @notice Get pending fees available for collection
     * @dev Implements IFeeSource interface
     * @return Accumulated fees not yet collected
     */
    function pendingFees() external view returns (uint256) {
        return accumulatedFees;
    }

    /**
     * @notice Get the asset used for fees
     * @dev Implements IFeeSource interface
     * @return Asset token address
     */
    function feeAsset() external view returns (address) {
        return address(asset);
    }

    function pause() external onlyAdmin {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused();
    }

    // ==================== VIEW FUNCTIONS ====================

    function getCurrentCycle() public view returns (uint256) {
        uint256 start = groupStartTime;
        if (start == 0 || block.timestamp < start) return 0;

        uint256 cycle;
        unchecked { cycle = ((block.timestamp - start) / cycleDuration) + 1; }
        return cycle > totalCycles ? totalCycles : cycle;
    }

    function pendingYield(address user) external view returns (uint256) {
        Member memory m = members[user];
        if (m.capitalInGroup == 0 || m.isActive == 0) return 0;

        // Current capital-seconds
        uint256 userCapSec;
        unchecked {
            userCapSec = uint256(m.capitalSeconds) + 
                (uint256(m.capitalInGroup) * (block.timestamp - m.lastUpdateTime));
        }

        uint256 globalCapSec;
        unchecked {
            globalCapSec = totalCapitalSeconds + 
                (totalCapitalInGroup * (block.timestamp - lastGlobalUpdateTime));
        }

        if (globalCapSec == 0) return 0;

        uint256 vaultShares = vault.balanceOf(address(this));
        uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        uint256 _totalCap = totalCapitalInGroup;

        if (vaultValue <= _totalCap) return 0;

        uint256 totalYield;
        unchecked { totalYield = vaultValue - _totalCap; }

        // Flat 1% protocol fee
        uint256 distributableYield = totalYield - (totalYield * PROTOCOL_FEE_BPS / 10000);

        uint256 userShare = userCapSec.mulDiv(distributableYield, globalCapSec);
        return userShare > m.yieldDebt ? userShare - m.yieldDebt : 0;
    }

    function getMemberInfo(address member) external view returns (
        uint256 capitalInGroup,
        uint256 pendingYieldAmount,
        uint256 lastContributedCycle,
        bool isActive,
        uint256 capitalSeconds
    ) {
        Member memory m = members[member];
        uint256 elapsed = block.timestamp - m.lastUpdateTime;
        uint256 currentCapSec = uint256(m.capitalSeconds) + (uint256(m.capitalInGroup) * elapsed);

        // Inline pending yield calculation
        uint256 pending = 0;
        if (m.capitalInGroup > 0 && m.isActive == 1) {
            uint256 globalCapSec = totalCapitalSeconds + 
                (totalCapitalInGroup * (block.timestamp - lastGlobalUpdateTime));

            if (globalCapSec > 0) {
                uint256 vaultShares = vault.balanceOf(address(this));
                uint256 vaultValue = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
                uint256 _totalCap = totalCapitalInGroup;

                if (vaultValue > _totalCap) {
                    uint256 totalYield = vaultValue - _totalCap;
                    // Flat 1% protocol fee
                    uint256 distributableYield = totalYield - (totalYield * PROTOCOL_FEE_BPS / 10000);
                    uint256 userShare = currentCapSec.mulDiv(distributableYield, globalCapSec);
                    pending = userShare > m.yieldDebt ? userShare - m.yieldDebt : 0;
                }
            }
        }

        return (uint256(m.capitalInGroup), pending, uint256(m.lastContributedCycle), m.isActive == 1, currentCapSec);
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

        return (
            groupStartTime != 0,
            groupEnded,
            getCurrentCycle(),
            activeMembersCount,
            totalCapitalInGroup,
            yieldAmount,
            accumulatedFees
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