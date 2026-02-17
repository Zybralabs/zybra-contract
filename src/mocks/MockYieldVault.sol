// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockYieldVault
 * @notice ERC4626 vault with controllable yield - matches Morpho Vault V2 interface
 * @dev For testing ZybraGroupV2 time-weighted yield distribution
 * @dev Implements full Morpho Vault V2 interface compatibility including:
 *      - ERC4626 (deposit, mint, withdraw, redeem)
 *      - ERC2612 (permit)
 *      - Morpho V2 specific (accrueInterest, gating, virtualShares, fees)
 * 
 * INTERFACE COMPATIBILITY (per https://github.com/morpho-org/vault-v2):
 * All function signatures match Morpho Vault V2 exactly:
 *   - asset() -> address (immutable)
 *   - totalAssets() -> uint256 (calls accrueInterestView internally)
 *   - convertToShares/convertToAssets (equivalent to previewDeposit/previewRedeem)
 *   - maxDeposit/maxMint/maxWithdraw/maxRedeem all return 0 (per V2 spec)
 *   - previewDeposit/previewMint/previewWithdraw/previewRedeem
 *   - deposit/mint use 'onBehalf' parameter (not 'receiver')
 *   - withdraw/redeem use (assets/shares, receiver, onBehalf) signature
 *
 * MORPHO VAULT V2 SPECIFIC BEHAVIOR:
 * - maxDeposit, maxMint, maxWithdraw, maxRedeem all return 0 (non-conventional)
 * - This is intentional per V2 spec - cannot guarantee revert-free due to caps/gates
 * - virtualShares = 10 ** max(0, 18 - assetDecimals) for inflation protection
 * - accrueInterest() updates totalAssets and mints fee shares
 * - Gating functions (canReceiveShares, canSendShares, etc.) for access control
 *
 * PRODUCTION NOTE:
 * Replace this with actual Morpho Vault V2 address on mainnet.
 * No code changes needed - just deploy with different vault address.
 */
contract MockYieldVault is ERC20, ERC20Permit, IERC4626 {
    using SafeERC20 for IERC20;

    // ==================== IMMUTABLES (matches V2) ====================
    IERC20 public immutable _asset;
    uint8 private immutable _decimals;
    uint256 public immutable virtualShares;
    
    // ==================== STORAGE (matches V2 layout) ====================
    address public owner;
    address public curator;
    
    // Interest storage
    uint128 internal _internalTotalAssets;  // Last recorded total assets
    uint64 public lastUpdate;
    uint64 public maxRate;
    
    // Fee storage (WAD units = 1e18)
    uint96 public performanceFee;
    address public performanceFeeRecipient;
    uint96 public managementFee;
    address public managementFeeRecipient;
    
    // Gating storage (addresses of gate contracts, 0 = disabled)
    address public receiveSharesGate;
    address public sendSharesGate;
    address public receiveAssetsGate;
    address public sendAssetsGate;
    
    // Role storage
    mapping(address => bool) public isAllocator;
    mapping(address => bool) public isSentinel;
    
    // Testing-specific storage
    uint256 public totalDeposited;  // Principal
    uint256 public yieldAccrued;    // Manually added yield (for testing edge cases)
    uint256 public annualYieldBps;  // Annual yield rate in bps (500 = 5% APY)
    uint256 public lastYieldUpdate; // Last time yield was calculated

    // ==================== EVENTS ====================
    event YieldGenerated(uint256 amount, uint256 newTotal);
    event YieldRateUpdated(uint256 oldRate, uint256 newRate);
    event AccrueInterest(uint128 prevTotalAssets, uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares);

    // ==================== MODIFIERS ====================
    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }

    // ==================== CONSTRUCTOR ====================
    constructor(
        address asset_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        _asset = IERC20(asset_);
        _decimals = decimals_;
        owner = msg.sender;
        lastUpdate = uint64(block.timestamp);
        lastYieldUpdate = block.timestamp;
        annualYieldBps = 500; // 5% APY default - realistic for testing
        
        // Calculate virtualShares per V2 spec: 10 ** max(0, 18 - assetDecimals)
        uint256 decimalOffset = decimals_ < 18 ? 18 - decimals_ : 0;
        virtualShares = 10 ** decimalOffset;
    }

    // ==================== ERC20 OVERRIDES ====================
    
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _decimals;
    }

    // ==================== ERC4626 VIEW FUNCTIONS ====================
    
    function asset() public view override returns (address) {
        return address(_asset);
    }

    /// @notice Total assets including yield (matches V2 behavior)
    /// @dev In V2, this calls accrueInterestView() to get newTotalAssets
    function totalAssets() public view override returns (uint256) {
        (uint256 newTotalAssets,,) = accrueInterestView();
        return newTotalAssets;
    }
    
    /// @notice Internal total assets storage (V2 compatibility)
    function _totalAssets() external view returns (uint128) {
        return _internalTotalAssets;
    }

    /// @dev Equivalent to previewDeposit per V2 spec
    function convertToShares(uint256 assets) public view override returns (uint256) {
        return previewDeposit(assets);
    }

    /// @dev Equivalent to previewRedeem per V2 spec
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return previewRedeem(shares);
    }

    /// @dev Morpho Vault V2 returns 0 for max functions (non-conventional ERC4626 behavior)
    /// @dev This is intentional - V2 cannot guarantee revert-free deposits due to caps/gates
    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Morpho Vault V2 returns 0 for max functions (non-conventional ERC4626 behavior)
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Morpho Vault V2 returns 0 for max functions (non-conventional ERC4626 behavior)
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Morpho Vault V2 returns 0 for max functions (non-conventional ERC4626 behavior)
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Preview deposit - shares minted for given assets (rounded down)
    /// @dev Matches V2: assets.mulDivDown(newTotalSupply + virtualShares, newTotalAssets + 1)
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply() + performanceFeeShares + managementFeeShares;
        // mulDivDown: (assets * (supply + virtualShares)) / (totalAssets + 1)
        return _mulDivDown(assets, newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @notice Preview mint - assets required for given shares (rounded up)
    /// @dev Matches V2: shares.mulDivUp(newTotalAssets + 1, newTotalSupply + virtualShares)
    function previewMint(uint256 shares) public view override returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply() + performanceFeeShares + managementFeeShares;
        // mulDivUp: (shares * (totalAssets + 1) + denominator - 1) / denominator
        return _mulDivUp(shares, newTotalAssets + 1, newTotalSupply + virtualShares);
    }

    /// @notice Preview withdraw - shares to burn for given assets (rounded up)
    /// @dev Matches V2: assets.mulDivUp(newTotalSupply + virtualShares, newTotalAssets + 1)
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply() + performanceFeeShares + managementFeeShares;
        return _mulDivUp(assets, newTotalSupply + virtualShares, newTotalAssets + 1);
    }

    /// @notice Preview redeem - assets received for given shares (rounded down)
    /// @dev Matches V2: shares.mulDivDown(newTotalAssets + 1, newTotalSupply + virtualShares)
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        uint256 newTotalSupply = totalSupply() + performanceFeeShares + managementFeeShares;
        return _mulDivDown(shares, newTotalAssets + 1, newTotalSupply + virtualShares);
    }

    // ==================== ERC4626 MUTATIVE FUNCTIONS ====================

    /// @notice Deposit assets and mint shares (V2 signature uses 'onBehalf')
    function deposit(uint256 assets, address onBehalf) public override returns (uint256 shares) {
        accrueInterest();
        shares = previewDeposit(assets);
        _enter(assets, shares, onBehalf);
    }

    /// @notice Mint shares by depositing assets (V2 signature uses 'onBehalf')
    function mint(uint256 shares, address onBehalf) public override returns (uint256 assets) {
        accrueInterest();
        assets = previewMint(shares);
        _enter(assets, shares, onBehalf);
    }

    /// @notice Withdraw assets by burning shares
    function withdraw(uint256 assets, address receiver, address onBehalf) public override returns (uint256 shares) {
        accrueInterest();
        shares = previewWithdraw(assets);
        _exit(assets, shares, receiver, onBehalf);
    }


    /// @notice Redeem shares for assets
    function redeem(uint256 shares, address receiver, address onBehalf) public override returns (uint256 assets) {
        accrueInterest();
        assets = previewRedeem(shares);
        _exit(assets, shares, receiver, onBehalf);
    }
    
    /// @dev Internal function for deposit and mint (matches V2 enter())
    function _enter(uint256 assets, uint256 shares, address onBehalf) internal {
        require(canReceiveShares(onBehalf), "CannotReceiveShares");
        require(canSendAssets(msg.sender), "CannotSendAssets");
        
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(onBehalf, shares);
        totalDeposited += assets;
        _internalTotalAssets += uint128(assets);
        
        emit Deposit(msg.sender, onBehalf, assets, shares);
    }
    
    /// @dev Internal function for withdraw and redeem (matches V2 exit())
    function _exit(uint256 assets, uint256 shares, address receiver, address onBehalf) internal {
        require(canSendShares(onBehalf), "CannotSendShares");
        require(canReceiveAssets(receiver), "CannotReceiveAssets");
        
        if (msg.sender != onBehalf) {
            uint256 allowed = allowance(onBehalf, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(onBehalf, msg.sender, allowed - shares);
            }
        }
        
        _burn(onBehalf, shares);
        
        // Proportional withdrawal from principal + yield
        uint256 ta = totalDeposited + yieldAccrued;
        if (ta > 0) {
            uint256 fromPrincipal = (assets * totalDeposited) / ta;
            uint256 fromYield = assets - fromPrincipal;
            totalDeposited = totalDeposited > fromPrincipal ? totalDeposited - fromPrincipal : 0;
            yieldAccrued = yieldAccrued > fromYield ? yieldAccrued - fromYield : 0;
        }
        _internalTotalAssets = _internalTotalAssets > uint128(assets) ? _internalTotalAssets - uint128(assets) : 0;
        
        _asset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, onBehalf, assets, shares);
    }

    // ==================== MORPHO V2 INTEREST ACCRUAL ====================
    
    /// @notice Accrue interest and update state (V2 compatibility)
    /// @dev Applies time-based yield to state - called before deposits/withdrawals
    function accrueInterest() public {
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = accrueInterestView();
        
        // Calculate and apply time-based yield
        uint256 timeElapsed = block.timestamp - lastYieldUpdate;
        if (timeElapsed > 0 && totalDeposited > 0) {
            uint256 timeBasedYield = (totalDeposited * annualYieldBps * timeElapsed) / (10000 * 365 days);
            yieldAccrued += timeBasedYield; // Permanently add accrued yield
        }
        
        emit AccrueInterest(_internalTotalAssets, newTotalAssets, performanceFeeShares, managementFeeShares);
        
        _internalTotalAssets = uint128(newTotalAssets);
        lastYieldUpdate = block.timestamp;
        lastUpdate = uint64(block.timestamp);
        
        // In mock: we don't mint fee shares, but could be added for full compatibility
        // if (performanceFeeShares != 0 && performanceFeeRecipient != address(0)) _mint(performanceFeeRecipient, performanceFeeShares);
        // if (managementFeeShares != 0 && managementFeeRecipient != address(0)) _mint(managementFeeRecipient, managementFeeShares);
    }
    
    /// @notice View function for interest accrual calculation (V2 compatibility)
    /// @return newTotalAssets The updated total assets
    /// @return performanceFeeShares Shares to mint for performance fee (0 in mock)
    /// @return managementFeeShares Shares to mint for management fee (0 in mock)
    function accrueInterestView() public view returns (uint256, uint256, uint256) {
        // Calculate time-based yield since last update
        uint256 timeElapsed = block.timestamp - lastYieldUpdate;
        uint256 timeBasedYield = 0;
        
        if (timeElapsed > 0 && totalDeposited > 0) {
            // Formula: yield = principal × APY × (time / 365 days)
            // = (totalDeposited × annualYieldBps × timeElapsed) / (10000 × 365 days)
            timeBasedYield = (totalDeposited * annualYieldBps * timeElapsed) / (10000 * 365 days);
        }
        
        uint256 newTotalAssets = totalDeposited + yieldAccrued + timeBasedYield;
        // Mock doesn't implement fee accrual, returns 0 for fee shares
        return (newTotalAssets, 0, 0);
    }

    // ==================== MORPHO V2 GATING FUNCTIONS ====================
    
    /// @notice Check if account can receive shares
    /// @dev Returns true if no gate set, or gate approves
    function canReceiveShares(address account) public view returns (bool) {
        if (receiveSharesGate == address(0)) return true;
        // In production: call IReceiveSharesGate(receiveSharesGate).canReceiveShares(account)
        // Silence unused param warning by referencing account
        return account != address(0); // Mock: allow all non-zero addresses
    }
    
    /// @notice Check if account can send shares
    function canSendShares(address account) public view returns (bool) {
        if (sendSharesGate == address(0)) return true;
        return account != address(0); // Mock: allow all non-zero addresses
    }
    
    /// @notice Check if account can receive assets (withdraw to)
    /// @dev address(this) is always allowed per V2 spec
    function canReceiveAssets(address account) public view returns (bool) {
        if (account == address(this)) return true;
        if (receiveAssetsGate == address(0)) return true;
        return account != address(0); // Mock: allow all non-zero addresses
    }
    
    /// @notice Check if account can send assets (deposit from)
    function canSendAssets(address account) public view returns (bool) {
        if (sendAssetsGate == address(0)) return true;
        return account != address(0); // Mock: allow all non-zero addresses
    }

    // ==================== YIELD SIMULATION FOR TESTING ====================

    /**
     * @notice Set annual yield rate (APY)
     * @param bps Annual yield in basis points (500 = 5% APY)
     */
    function setAnnualYieldRate(uint256 bps) external onlyOwner {
        // Accrue interest with old rate first
        accrueInterest();
        emit YieldRateUpdated(annualYieldBps, bps);
        annualYieldBps = bps;
    }
    
    /**
     * @notice Get current annual yield rate
     */
    function getAnnualYieldRate() external view returns (uint256) {
        return annualYieldBps;
    }

    /**
     * @notice Manual yield generation (optional - for testing specific scenarios)
     * @dev NOT NEEDED for normal operation - yield accrues automatically over time
     * @return newYield Amount of yield generated
     */
    function generateYield() external returns (uint256 newYield) {
        // Accrue time-based yield first
        accrueInterest();
        
        // Then add 1 day worth of yield as bonus (for testing)
        newYield = (totalDeposited * annualYieldBps) / (10000 * 365);
        yieldAccrued += newYield;
        _internalTotalAssets += uint128(newYield);
        emit YieldGenerated(newYield, yieldAccrued);
    }

    /**
     * @notice Generate specific amount of yield
     * @param amount Exact yield amount to add
     */
    function addYield(uint256 amount) external {
        // Transfer tokens to back the yield
        _asset.safeTransferFrom(msg.sender, address(this), amount);
        yieldAccrued += amount;
        _internalTotalAssets += uint128(amount);
        emit YieldGenerated(amount, yieldAccrued);
    }

    /**
     * @notice Force yield update (optional - for testing)
     * @dev NOT NEEDED - yield updates automatically on any deposit/withdraw/view
     */
    function forceYieldUpdate() external {
        accrueInterest();
    }
    
    /**
     * @notice Get pending yield that will accrue (view only)
     * @return Yield accrued since last update
     */
    function getPendingYield() external view returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastYieldUpdate;
        if (timeElapsed == 0 || totalDeposited == 0) return 0;
        return (totalDeposited * annualYieldBps * timeElapsed) / (10000 * 365 days);
    }

    /**
     * @notice Fund vault with tokens for yield backing
     * @param amount Amount to fund
     */
    function fundVault(uint256 amount) external {
        _asset.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Get vault statistics including time-based yield
     */
    function getStats() external view returns (
        uint256 principal,
        uint256 yield_,
        uint256 total,
        uint256 sharePrice,
        uint256 shares
    ) {
        principal = totalDeposited;
        
        // Include time-based pending yield in total yield calculation
        uint256 timeElapsed = block.timestamp - lastYieldUpdate;
        uint256 pendingYield = 0;
        if (timeElapsed > 0 && totalDeposited > 0) {
            pendingYield = (totalDeposited * annualYieldBps * timeElapsed) / (10000 * 365 days);
        }
        
        yield_ = yieldAccrued + pendingYield;
        total = totalAssets();
        shares = totalSupply();
        sharePrice = shares > 0 ? (total * 1e18) / shares : 1e18;
    }
    
    // ==================== V2 ADMIN FUNCTIONS (for testing) ====================
    
    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }
    
    function setCurator(address newCurator) external onlyOwner {
        curator = newCurator;
    }
    
    function setIsSentinel(address account, bool value) external onlyOwner {
        isSentinel[account] = value;
    }
    
    function setIsAllocator(address account, bool value) external onlyOwner {
        isAllocator[account] = value;
    }
    
    function setReceiveSharesGate(address gate) external onlyOwner {
        receiveSharesGate = gate;
    }
    
    function setSendSharesGate(address gate) external onlyOwner {
        sendSharesGate = gate;
    }
    
    function setReceiveAssetsGate(address gate) external onlyOwner {
        receiveAssetsGate = gate;
    }
    
    function setSendAssetsGate(address gate) external onlyOwner {
        sendAssetsGate = gate;
    }
    
    function setPerformanceFee(uint96 fee, address recipient) external onlyOwner {
        performanceFee = fee;
        performanceFeeRecipient = recipient;
    }
    
    function setManagementFee(uint96 fee, address recipient) external onlyOwner {
        managementFee = fee;
        managementFeeRecipient = recipient;
    }
    
    // ==================== MATH HELPERS (matches V2 MathLib) ====================
    
    /// @dev Rounds down
    function _mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }
    
    /// @dev Rounds up
    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }
}
