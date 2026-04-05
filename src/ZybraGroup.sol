// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMorphoVaultV2} from "./interfaces/IMorphoVaultV2.sol";
import {IFeeSource} from "./treasury/IFeeSource.sol";

/// @notice Minimal interface to read treasury from the deploying factory
interface IZybraGroupFactory {
    function treasury() external view returns (address);
}

contract ZybraGroup is IFeeSource, ReentrancyGuard {
    using SafeERC20 for IERC20;

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

    // Factory address — immutable, treasury is read from factory at runtime (one-to-all pattern)
    address public immutable factory;

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
    uint256 public constant PROTOCOL_FEE_BPS = 1000; // 10% flat fee
    uint256 public constant ACC_PRECISION = 1e12;    // Accumulator scaling factor
    uint256 public constant END_GROUP_GRACE_PERIOD = 7 days; // [FIX: H-02] Auto-end grace period
    uint256 public constant MIN_FEE_AUTO_COLLECT = 1e6; // 1 USDC threshold for auto-forwarding (gas optimization)
    uint256 public constant MAX_YIELD_PER_ACCRUAL_BPS = 1000; // [FIX: AUDIT-02] 10% of capital max per single accrual (flash-loan protection)

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
        address _vault
    ) {
        if (_asset == address(0) || _admin == address(0) || _vault == address(0)) revert ZeroAddress();
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
        factory = msg.sender; // deployer is the factory (or test contract)

        // Auto-add admin as first member
        _addMember(_admin);
    }

    /// @notice Treasury address — always read from the factory (single source of truth)
    /// @dev No storage in group. Factory owner calls factory.setTreasury() once → all groups see it.
    function treasury() public view returns (address) {
        return IZybraGroupFactory(factory).treasury();
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

        // [FIX: AUDIT-02] Cap yield per accrual to prevent flash-loan share price inflation.
        // If an attacker donates to the vault to temporarily spike convertToAssets(),
        // newYield would be artificially inflated. Capping at MAX_YIELD_PER_ACCRUAL_BPS
        // of capital ensures only realistic yield is materialized per call.
        // Any excess is deferred to the next accrual when the vault price normalizes.
        if (_totalCap > 0) {
            uint256 maxYield = (_totalCap * MAX_YIELD_PER_ACCRUAL_BPS) / 10000;
            if (newYield > maxYield) {
                newYield = maxYield;
                // Re-derive totalEverYield so lastMaterializedYield advances correctly
                totalEverYield = lastMaterializedYield + newYield;
            }
        }

        if (_totalCap == 0) {
            // No capital to distribute to — all goes to fees
            totalAccumulatedFees += newYield;
            lastMaterializedYield = totalEverYield;
            _autoCollectFees();
            return;
        }

        uint256 fee = (newYield * PROTOCOL_FEE_BPS) / 10000;
        uint256 distributable = newYield - fee;

        accRewardPerShare += (distributable * ACC_PRECISION) / _totalCap;
        totalAccumulatedFees += fee;
        lastMaterializedYield = totalEverYield;

        // Auto-forward fees to treasury (Aave Reserve Factor pattern)
        _autoCollectFees();
    }

    /**
     * @dev Auto-forward accumulated protocol fees to treasury when threshold is met.
     *      Piggybacked on user transactions — no separate keeper/bot needed.
     *
     * PATTERN: Aave V3 "mint-to-treasury" / SushiSwap MasterChef "dev mint"
     *   - Fees accumulate in the vault as yield accrues
     *   - When accumulated fees >= MIN_FEE_AUTO_COLLECT (1 USDC), they're
     *     withdrawn from the vault and sent to the immutable treasury
     *   - Piggybacks on the gas of whatever user action triggered _accrueRewards()
     *   - Uses try/catch so fee collection failure never blocks user operations
     *   - Below-threshold dust is collected via the permissionless collectFees() fallback
     *
     * GAS: ~30K overhead on user tx when threshold is crossed (1 SLOAD + 1 vault.withdraw)
     *      Zero overhead when fees are below threshold.
     */
    function _autoCollectFees() internal {
        uint256 pending = totalAccumulatedFees - totalFeesWithdrawn;
        if (pending < MIN_FEE_AUTO_COLLECT) return;

        uint256 vaultShares = vault.balanceOf(address(this));
        if (vaultShares == 0) return;

        uint256 maxWithdrawable = vault.convertToAssets(vaultShares);

        // Reserve: don't drain vault below what users need (capital + pending yield buffer)
        // This prevents auto-collect from causing user withdrawal failures in the same tx
        uint256 _totalCap = totalCapitalInGroup;
        uint256 withdrawableForFees = maxWithdrawable > _totalCap ? maxWithdrawable - _totalCap : 0;

        uint256 toCollect = pending > withdrawableForFees ? withdrawableForFees : pending;
        if (toCollect < MIN_FEE_AUTO_COLLECT) return;

        // Try/catch: fee failure must NEVER block user's contribute/withdraw/claim
        address _treasury = treasury();
        try vault.withdraw(toCollect, _treasury, address(this)) returns (uint256 sharesBurned) {
            if (sharesBurned > 0) {
                totalFeesWithdrawn += toCollect;
                emit FeesCollected(_treasury, toCollect);
            }
        } catch {
            // Fee collection deferred — will retry on next user action
        }
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
     *      [FIX: H-03] Handle ERC4626 rounding dust — if withdraw requires
     *      more shares than available, cap at what available shares support.
     *      ERC4626 rounds UP on withdraw (vault-favorable), so accumulated
     *      rounding across many deposits can leave the contract 1+ shares short.
     */
    function _safeVaultWithdraw(uint256 assets, address receiver) internal {
        uint256 vaultShares = vault.balanceOf(address(this));
        uint256 sharesToBurn = vault.previewWithdraw(assets);

        if (sharesToBurn > vaultShares) {
            // ERC4626 rounding dust: cap withdrawal to what available shares support
            // previewRedeem rounds DOWN (user-adverse), ensuring we don't over-redeem
            assets = vault.previewRedeem(vaultShares);
            if (assets == 0) revert WithdrawFailed();
        }

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
    // [FIX: AUDIT-03] Added nonReentrant to prevent cross-function reentrancy
    // via vault callbacks triggered by _accrueRewards() → _autoCollectFees() → vault.withdraw()
    function endGroup() external nonReentrant {
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

        // [FIX: H-04] Prevent contributions after all cycles have elapsed
        // getCurrentCycle() caps at totalCycles, so the `> totalCycles` check below
        // is dead code. This explicit time guard closes the gap.
        if (block.timestamp >= groupStartTime + totalCycles * cycleDuration) revert InvalidCycle();

        uint256 currentCycle = getCurrentCycle();
        if (currentCycle == 0 || currentCycle > totalCycles) revert InvalidCycle();
        if (contributedInCycle[msg.sender][currentCycle]) revert AlreadyContributed();

        // Accrue all pending vault yield into accumulator BEFORE changing capital
        _accrueRewards();

        uint256 amount = contributionAmount;

        // [FIX: AUDIT-04] Measure actual tokens received to guard against fee-on-transfer tokens.
        // If the token charges a transfer fee, the contract receives less than `amount`.
        // Recording nominal `amount` while receiving less would inflate totalCapitalInGroup
        // beyond actual vault holdings, eventually causing withdrawal failures.
        uint256 balBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - balBefore;
        if (received != amount) revert FeeOnTransferNotSupported();

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

    /// @notice Claim accumulated yield without withdrawing capital
    /// @dev No pause check — users must always be able to exit with yield.
    ///      Pause only blocks new inflows (contribute/join), never exits.
    function claimYield() external nonReentrant {
        _claimYieldTo(msg.sender);
    }

    /// @notice Claim yield to an alternative receiver (USDC blacklist escape hatch)
    /// @param receiver Address to receive the yield tokens
    function claimYieldTo(address receiver) external nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        _claimYieldTo(receiver);
    }

    function _claimYieldTo(address receiver) internal {
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
        _safeVaultWithdraw(pending, receiver);
        emit YieldClaimed(msg.sender, pending);
    }

    /// @notice Withdraw all capital + pending yield
    /// @dev No pause check — users must always be able to exit.
    ///      Pause only blocks new inflows (contribute/join), never exits.
    function withdraw() external nonReentrant {
        _withdrawTo(msg.sender);
    }

    /// @notice Withdraw capital + yield to an alternative receiver (USDC blacklist escape hatch)
    /// @param receiver Address to receive capital + yield
    function withdrawTo(address receiver) external nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        _withdrawTo(receiver);
    }

    function _withdrawTo(address receiver) internal {
        if (members[msg.sender].isActive != 1) revert NotMember();

        _accrueRewards();

        Member memory m = members[msg.sender];
        uint256 capital = m.capitalInGroup;
        uint256 yieldAmount = _pendingReward(m);
        uint256 totalAmount = capital + yieldAmount;

        if (totalAmount == 0) revert InvalidAmount();

        // Pro-rata cap: if vault is impaired (bad debt, depeg), limit each
        // user to their proportional share so losses are socialized fairly.
        uint256 vaultShares_ = vault.balanceOf(address(this));
        uint256 vaultValue_ = vaultShares_ > 0 ? vault.convertToAssets(vaultShares_) : 0;
        if (vaultValue_ < totalCapitalInGroup && totalCapitalInGroup > 0) {
            // Vault impaired — cap withdrawal pro-rata to actual vault value
            totalAmount = (vaultValue_ * capital) / totalCapitalInGroup;
            yieldAmount = 0; // no yield payout when vault is underwater
            capital = totalAmount;
        }

        // Clear member fully
        members[msg.sender] = Member(0, 0, 0, 0);
        activeMembersCount -= 1;
        totalCapitalInGroup -= uint256(m.capitalInGroup);

        // Track yield for totalEverYield reconstruction
        if (yieldAmount > 0) {
            totalDistributedYield += yieldAmount;
        }

        _safeVaultWithdraw(totalAmount, receiver);
        emit Withdrawn(msg.sender, capital, yieldAmount);
    }

    /// @notice Emergency withdraw — capital only, works even when paused
    /// @dev Escape hatch. Accrues rewards before state changes so forfeited
    ///      yield is redistributed to remaining members, not locked.
    function emergencyWithdraw() external nonReentrant {
        _emergencyWithdrawTo(msg.sender);
    }

    /// @notice Emergency withdraw to alternative receiver (USDC blacklist escape hatch)
    function emergencyWithdrawTo(address receiver) external nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        _emergencyWithdrawTo(receiver);
    }

    function _emergencyWithdrawTo(address receiver) internal {
        // NOTE: No pause check — this IS the escape hatch
        Member memory m = members[msg.sender];
        if (m.isActive != 1) revert NotMember();
        uint256 capital = m.capitalInGroup;
        if (capital == 0) revert InvalidAmount();

        // Accrue rewards before reducing totalCapitalInGroup
        _accrueRewards();

        // Pro-rata cap: if vault is impaired, limit to fair share (mirrors _withdrawTo)
        uint256 withdrawAmount = capital;
        {
            uint256 vaultShares_ = vault.balanceOf(address(this));
            uint256 vaultValue_ = vaultShares_ > 0 ? vault.convertToAssets(vaultShares_) : 0;
            if (vaultValue_ < totalCapitalInGroup && totalCapitalInGroup > 0) {
                withdrawAmount = (vaultValue_ * capital) / totalCapitalInGroup;
            }
        }

        // Calculate forfeited yield for event transparency
        uint256 forfeitedYield = _pendingReward(m);

        // Clear member
        members[msg.sender] = Member(0, 0, 0, 0);
        activeMembersCount -= 1;
        totalCapitalInGroup -= capital;

        // Redistribute forfeited yield to remaining members.
        // forfeitedYield is already post-fee (the 10% protocol fee was already taken
        // during _accrueRewards). Inject directly into the accumulator to avoid
        // re-running through _accrueRewards which would charge the fee a second time.
        if (forfeitedYield > 0 && totalCapitalInGroup > 0) {
            accRewardPerShare += (forfeitedYield * ACC_PRECISION) / totalCapitalInGroup;
        } else if (forfeitedYield > 0) {
            // No remaining members — convert forfeited yield to protocol fees
            // to prevent permanent vault lockup
            totalAccumulatedFees += forfeitedYield;
        }

        // Withdraw capped amount
        _safeVaultWithdraw(withdrawAmount, receiver);
        emit EmergencyWithdrawn(msg.sender, withdrawAmount, forfeitedYield);
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Collect protocol fees — permissionless fallback for dust/manual collection
     * @dev Primary fee collection is automatic via _autoCollectFees() piggybacked
     *      on every user action. This function exists as a fallback to sweep:
     *      1. Dust amounts below MIN_FEE_AUTO_COLLECT threshold
     *      2. Fees from inactive groups where no user actions trigger auto-collect
     *      Anyone can call — fees always flow to immutable treasury.
     */
    function collectFees() external nonReentrant returns (uint256 amount) {
        _accrueRewards();

        amount = totalAccumulatedFees > totalFeesWithdrawn
            ? totalAccumulatedFees - totalFeesWithdrawn
            : 0;

        // Auto-collect may have already forwarded fees — return 0 instead of reverting
        if (amount == 0) return 0;

        // Without this, vault losses (bad debt, depeg) could allow fee withdrawal
        // from user principal, since fees were accrued when vault was healthy.
        uint256 vaultShares = vault.balanceOf(address(this));
        uint256 maxWithdrawable = vaultShares > 0 ? vault.convertToAssets(vaultShares) : 0;
        uint256 _totalCap = totalCapitalInGroup;
        uint256 withdrawableForFees = maxWithdrawable > _totalCap ? maxWithdrawable - _totalCap : 0;
        if (amount > withdrawableForFees) {
            amount = withdrawableForFees;
        }
        if (amount == 0) return 0;

        totalFeesWithdrawn += amount;

        // [FIX: H-01] Validate vault withdrawal return
        address _treasury = treasury();
        _safeVaultWithdraw(amount, _treasury);
        emit FeesCollected(_treasury, amount);
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
        // [FIX: AUDIT-REAUDIT] Mirror _accrueRewards() cap to prevent view overstatement
        if (newYield > 0 && totalCapitalInGroup > 0) {
            uint256 maxYield = (totalCapitalInGroup * MAX_YIELD_PER_ACCRUAL_BPS) / 10000;
            if (newYield > maxYield) newYield = maxYield;
        }
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
                // [FIX: AUDIT-REAUDIT] Mirror _accrueRewards() cap
                uint256 maxYield = (_totalCap * MAX_YIELD_PER_ACCRUAL_BPS) / 10000;
                if (newYield > maxYield) newYield = maxYield;
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
                    // [FIX: AUDIT-REAUDIT] Mirror _accrueRewards() cap
                    uint256 maxYield = (_totalCap * MAX_YIELD_PER_ACCRUAL_BPS) / 10000;
                    if (newYield > maxYield) newYield = maxYield;
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
