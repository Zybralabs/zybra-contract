// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
// Adapted from https://github.com/morpho-org/vault-v2/blob/main/src/interfaces/IVaultV2.sol
pragma solidity ^0.8.18;

/**
 * @title IMorphoVaultV2
 * @notice Interface for Morpho Vault V2 - ERC4626-compliant yield vault
 * @dev The vault is compliant with ERC-4626 and ERC-2612 (permit extension)
 * @dev Note: max functions always return zero (gross underestimation for safety)
 * @dev totalSupply is not updated to include shares minted to fee recipients.
 *      One can call accrueInterestView to compute the updated totalSupply.
 */
interface IMorphoVaultV2 {
    // ==================== ERC20 FUNCTIONS ====================
    
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 shares) external returns (bool);
    function transferFrom(address from, address to, uint256 shares) external returns (bool);
    function approve(address spender, uint256 shares) external returns (bool);
    function nonces(address owner) external view returns (uint256);
    
    // ==================== ERC4626 FUNCTIONS ====================
    
    /// @notice The underlying asset of the vault (immutable)
    function asset() external view returns (address);
    
    /// @notice Total assets managed by the vault (including yield)
    /// @dev Returns newTotalAssets from accrueInterestView()
    function totalAssets() external view returns (uint256);
    
    /// @notice Convert shares to assets (rounded down)
    /// @dev Takes into account performance and management fees
    /// @dev Equivalent to previewRedeem
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    
    /// @notice Convert assets to shares (rounded down)
    /// @dev Takes into account performance and management fees
    /// @dev Equivalent to previewDeposit
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    
    /// @notice Preview deposit - returns shares that would be minted (rounded down)
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    
    /// @notice Preview mint - returns assets that would be deposited (rounded up)
    function previewMint(uint256 shares) external view returns (uint256 assets);
    
    /// @notice Preview withdraw - returns shares that would be redeemed (rounded up)
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    
    /// @notice Preview redeem - returns assets that would be withdrawn (rounded down)
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    
    /// @notice Deposit assets and mint shares
    /// @param assets Amount of assets to deposit
    /// @param onBehalf Address to receive the shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
    
    /// @notice Mint shares by depositing assets
    /// @param shares Amount of shares to mint
    /// @param onBehalf Address to receive the shares
    /// @return assets Amount of assets deposited
    function mint(uint256 shares, address onBehalf) external returns (uint256 assets);
    
    /// @notice Withdraw assets by burning shares
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address to receive the assets
    /// @param onBehalf Address whose shares are burned (requires allowance if not msg.sender)
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares);
    
    /// @notice Redeem shares for assets
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive the assets
    /// @param onBehalf Address whose shares are burned (requires allowance if not msg.sender)
    /// @return assets Amount of assets withdrawn
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);
    
    /// @notice Max deposit (always returns 0 - gross underestimation for safety)
    /// @dev Cannot guarantee revert-free deposits due to caps/gates
    function maxDeposit(address) external pure returns (uint256);
    
    /// @notice Max mint (always returns 0 - gross underestimation for safety)
    function maxMint(address) external pure returns (uint256);
    
    /// @notice Max withdraw (always returns 0 - gross underestimation for safety)
    function maxWithdraw(address) external pure returns (uint256);
    
    /// @notice Max redeem (always returns 0 - gross underestimation for safety)
    function maxRedeem(address) external pure returns (uint256);
    
    // ==================== ERC2612 PERMIT ====================
    
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function permit(
        address owner,
        address spender,
        uint256 shares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    
    // ==================== VAULT V2 SPECIFIC ====================
    
    /// @notice Virtual shares for inflation attack protection (immutable)
    /// @dev Equals 10 ** max(0, 18 - assetDecimals)
    function virtualShares() external view returns (uint256);
    
    /// @notice Accrue interest and update fee shares
    /// @dev Updates _totalAssets, mints fee shares, sets lastUpdate
    function accrueInterest() external;
    
    /// @notice View function for accrueInterest calculation
    /// @return newTotalAssets Updated total assets (min of realAssets and maxTotalAssets)
    /// @return performanceFeeShares Shares to mint for performance fee
    /// @return managementFeeShares Shares to mint for management fee
    function accrueInterestView() external view returns (
        uint256 newTotalAssets,
        uint256 performanceFeeShares,
        uint256 managementFeeShares
    );
    
    /// @notice Last recorded total assets (internal storage)
    function _totalAssets() external view returns (uint128);
    
    /// @notice Timestamp of last interest accrual
    function lastUpdate() external view returns (uint64);
    
    /// @notice Maximum rate of share price increase per second (WAD units)
    function maxRate() external view returns (uint64);
    
    /// @notice First total assets of the transaction (transient storage)
    /// @dev Used to prevent bypassing relative caps with flashloans
    function firstTotalAssets() external view returns (uint256);
    
    // ==================== GATING FUNCTIONS ====================
    
    /// @notice Check if account can receive shares
    function canReceiveShares(address account) external view returns (bool);
    
    /// @notice Check if account can send shares
    function canSendShares(address account) external view returns (bool);
    
    /// @notice Check if account can receive assets (withdraw to)
    /// @dev address(this) is always allowed
    function canReceiveAssets(address account) external view returns (bool);
    
    /// @notice Check if account can send assets (deposit from)
    function canSendAssets(address account) external view returns (bool);
    
    /// @notice Gate contract for receiving shares
    function receiveSharesGate() external view returns (address);
    
    /// @notice Gate contract for sending shares
    function sendSharesGate() external view returns (address);
    
    /// @notice Gate contract for receiving assets
    function receiveAssetsGate() external view returns (address);
    
    /// @notice Gate contract for sending assets
    function sendAssetsGate() external view returns (address);
    
    // ==================== ROLE GETTERS ====================
    
    function owner() external view returns (address);
    function curator() external view returns (address);
    function isAllocator(address account) external view returns (bool);
    function isSentinel(address account) external view returns (bool);
    
    // ==================== FEE GETTERS ====================
    
    /// @notice Performance fee in WAD units
    function performanceFee() external view returns (uint96);
    function performanceFeeRecipient() external view returns (address);
    
    /// @notice Management fee in WAD units
    function managementFee() external view returns (uint96);
    function managementFeeRecipient() external view returns (address);
    
    // ==================== ADAPTER INFO ====================
    
    function adaptersLength() external view returns (uint256);
    function adapters(uint256 index) external view returns (address);
    function isAdapter(address account) external view returns (bool);
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
    function adapterRegistry() external view returns (address);
    function forceDeallocatePenalty(address adapter) external view returns (uint256);
    
    // ==================== CAPS ====================
    
    function absoluteCap(bytes32 id) external view returns (uint256);
    function relativeCap(bytes32 id) external view returns (uint256);
    function allocation(bytes32 id) external view returns (uint256);
    
    // ==================== TIMELOCK ====================
    
    function timelock(bytes4 selector) external view returns (uint256);
    function abdicated(bytes4 selector) external view returns (bool);
    function executableAt(bytes memory data) external view returns (uint256);
    
    // ==================== MULTICALL ====================
    
    /// @notice Batch multiple admin calls
    function multicall(bytes[] memory data) external;
    
    // ==================== OWNER FUNCTIONS ====================
    
    function setOwner(address newOwner) external;
    function setCurator(address newCurator) external;
    function setIsSentinel(address account, bool newIsSentinel) external;
    function setName(string memory newName) external;
    function setSymbol(string memory newSymbol) external;
    
    // ==================== TIMELOCK FUNCTIONS ====================
    
    function submit(bytes memory data) external;
    function revoke(bytes memory data) external;
    
    // ==================== CURATOR FUNCTIONS (timelocked) ====================
    
    function setIsAllocator(address account, bool newIsAllocator) external;
    function setReceiveSharesGate(address newReceiveSharesGate) external;
    function setSendSharesGate(address newSendSharesGate) external;
    function setReceiveAssetsGate(address newReceiveAssetsGate) external;
    function setSendAssetsGate(address newSendAssetsGate) external;
    function setAdapterRegistry(address newAdapterRegistry) external;
    function addAdapter(address account) external;
    function removeAdapter(address account) external;
    function increaseTimelock(bytes4 selector, uint256 newDuration) external;
    function decreaseTimelock(bytes4 selector, uint256 newDuration) external;
    function abdicate(bytes4 selector) external;
    function setPerformanceFee(uint256 newPerformanceFee) external;
    function setManagementFee(uint256 newManagementFee) external;
    function setPerformanceFeeRecipient(address newPerformanceFeeRecipient) external;
    function setManagementFeeRecipient(address newManagementFeeRecipient) external;
    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function decreaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function decreaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function setForceDeallocatePenalty(address adapter, uint256 newForceDeallocatePenalty) external;
    
    // ==================== ALLOCATOR FUNCTIONS ====================
    
    function allocate(address adapter, bytes memory data, uint256 assets) external;
    function deallocate(address adapter, bytes memory data, uint256 assets) external;
    function setLiquidityAdapterAndData(address newLiquidityAdapter, bytes memory newLiquidityData) external;
    function setMaxRate(uint256 newMaxRate) external;
    
    // ==================== FORCE DEALLOCATE ====================
    
    /// @notice Force deallocate with penalty
    /// @param adapter The adapter to deallocate from
    /// @param data The adapter-specific data
    /// @param assets Amount of assets to deallocate
    /// @param onBehalf Address that pays the penalty
    /// @return penaltyShares Amount of shares burned as penalty
    function forceDeallocate(address adapter, bytes memory data, uint256 assets, address onBehalf) 
        external returns (uint256 penaltyShares);
    
    // ==================== EVENTS ====================
    // Note: Events are defined in EventsLib in the original contract
    // Key events: Deposit, Withdraw, Transfer, Approval, AccrueInterest,
    //             Allocate, Deallocate, ForceDeallocate
}
