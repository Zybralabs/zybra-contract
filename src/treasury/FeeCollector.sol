// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFeeSource} from "./IFeeSource.sol";
import {ITreasury} from "./ITreasury.sol";

/**
 * @title FeeCollector
 * @author Zybra Protocol
 * @notice Aggregates fees from multiple sources and forwards to Treasury.
 * @dev Follows Morpho fee recipient pattern with batched collection:
 *      - Registered fee sources (ZybraGroupV2 instances)
 *      - Pull-based collection (sources approve, we transferFrom)
 *      - Batched forwarding to Treasury
 *
 * WHY SEPARATE FROM TREASURY:
 *   - Treasury = pure custody (minimal attack surface)
 *   - FeeCollector = aggregation logic (can be upgraded independently)
 *   - Mirrors Aave's Collector + ReservesFactor separation
 *
 * ROLES:
 *   DEFAULT_ADMIN_ROLE  → Governance, can add/remove sources
 *   KEEPER_ROLE         → Automation (Gelato/Chainlink), can trigger collection
 *
 * INVARIANTS:
 *   1. Only registered sources can have fees collected
 *   2. All collected fees flow to Treasury (no intermediate custody)
 */
contract FeeCollector is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==================== ROLES ====================

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ==================== STATE ====================

    /// @notice Treasury address (immutable after deployment)
    ITreasury public immutable treasury;

    /// @notice Registered fee sources
    mapping(address => bool) public isRegisteredSource;
    address[] public sources;

    /// @notice Total fees collected per asset (for accounting/analytics)
    mapping(address => uint256) public totalCollected;

    // ==================== EVENTS ====================

    event SourceRegistered(address indexed source);
    event SourceRemoved(address indexed source);
    event FeesCollected(address indexed source, address indexed asset, uint256 amount);
    event FeesBatched(address indexed asset, uint256 totalAmount);

    // ==================== ERRORS ====================

    error ZeroAddress();
    error SourceNotRegistered(address source);
    error SourceAlreadyRegistered(address source);
    error NoFeesToCollect();

    // ==================== CONSTRUCTOR ====================

    /**
     * @param _treasury Treasury contract address
     * @param _admin Governance address
     * @param _keeper Initial keeper address (automation)
     */
    constructor(address _treasury, address _admin, address _keeper) {
        if (_treasury == address(0) || _admin == address(0)) revert ZeroAddress();

        treasury = ITreasury(_treasury);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        if (_keeper != address(0)) {
            _grantRole(KEEPER_ROLE, _keeper);
        }
    }

    // ==================== SOURCE MANAGEMENT ====================

    /**
     * @notice Register a fee source (e.g., ZybraGroupV2 instance)
     * @param source Address of the fee-generating contract
     */
    function registerSource(address source) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (source == address(0)) revert ZeroAddress();
        if (isRegisteredSource[source]) revert SourceAlreadyRegistered(source);

        isRegisteredSource[source] = true;
        sources.push(source);

        emit SourceRegistered(source);
    }

    /**
     * @notice Remove a fee source
     * @dev Does not remove from array (gas), just marks inactive
     * @param source Address of the fee-generating contract
     */
    function removeSource(address source) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isRegisteredSource[source]) revert SourceNotRegistered(source);

        isRegisteredSource[source] = false;

        emit SourceRemoved(source);
    }

    // ==================== FEE COLLECTION ====================

    /**
     * @notice Collect fees from a single source and forward to Treasury
     * @dev Source must have approved this contract for the fee asset
     * @param source Address of the fee source
     * @return amount Fees collected
     */
    function collectFrom(address source) external nonReentrant returns (uint256 amount) {
        if (!isRegisteredSource[source]) revert SourceNotRegistered(source);

        return _collectFrom(source);
    }

    /**
     * @notice Collect fees from all registered sources
     * @dev Callable by KEEPER_ROLE or DEFAULT_ADMIN_ROLE
     * @return totalAmount Total fees collected across all sources
     */
    function collectAll() external onlyRole(KEEPER_ROLE) nonReentrant returns (uint256 totalAmount) {
        uint256 len = sources.length;
        for (uint256 i = 0; i < len; ) {
            address source = sources[i];
            if (isRegisteredSource[source]) {
                totalAmount += _collectFrom(source);
            }
            unchecked { ++i; }
        }

        if (totalAmount == 0) revert NoFeesToCollect();
    }

    /**
     * @notice Internal collection logic
     * @dev Pull from source → approve Treasury → deposit
     */
    function _collectFrom(address source) internal returns (uint256 amount) {
        // Get pending fees from source
        IFeeSource feeSource = IFeeSource(source);
        uint256 pending = feeSource.pendingFees();
        
        if (pending == 0) return 0;

        address asset = feeSource.feeAsset();

        // Pull fees from source (source must approve this contract)
        // Note: Some sources may use push (transferring directly to us)
        // This handles both patterns
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        
        try feeSource.collectFees() returns (uint256 collected) {
            amount = collected;
        } catch {
            // Source may have pushed directly, check balance delta
            amount = IERC20(asset).balanceOf(address(this)) - balBefore;
        }

        if (amount == 0) return 0;

        // Forward to Treasury
        IERC20(asset).forceApprove(address(treasury), amount);
        treasury.deposit(asset, amount);

        totalCollected[asset] += amount;

        emit FeesCollected(source, asset, amount);
    }

    // ==================== VIEW ====================

    /**
     * @notice Get all registered sources
     * @return Active source addresses
     */
    function getActiveSources() external view returns (address[] memory) {
        uint256 len = sources.length;
        uint256 activeCount = 0;

        // Count active
        for (uint256 i = 0; i < len; ) {
            if (isRegisteredSource[sources[i]]) {
                unchecked { ++activeCount; }
            }
            unchecked { ++i; }
        }

        // Build array
        address[] memory active = new address[](activeCount);
        uint256 j = 0;
        for (uint256 i = 0; i < len; ) {
            if (isRegisteredSource[sources[i]]) {
                active[j] = sources[i];
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }

        return active;
    }

    /**
     * @notice Get total pending fees across all sources for an asset
     * @param asset Token address to check
     * @return pending Total pending fees
     */
    function totalPendingFees(address asset) external view returns (uint256 pending) {
        uint256 len = sources.length;
        for (uint256 i = 0; i < len; ) {
            address source = sources[i];
            if (isRegisteredSource[source]) {
                IFeeSource feeSource = IFeeSource(source);
                if (feeSource.feeAsset() == asset) {
                    pending += feeSource.pendingFees();
                }
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Number of registered sources
     */
    function sourceCount() external view returns (uint256) {
        return sources.length;
    }
}
