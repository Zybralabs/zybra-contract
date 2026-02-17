// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, Id, MarketParams, Position, Market} from "../interfaces/IMorpho.sol";

/**
 * @title MockMetaMorpho
 * @dev Simplified mock implementation of MetaMorpho vault for testing
 * @notice This mock provides basic ERC4626 functionality with Morpho integration
 * Key simplifications:
 * - No supply/withdraw queues
 * - Simplified fee mechanism
 * - No timelock for parameter changes
 * - Basic single-market allocation
 */
contract MockMetaMorpho is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /* ERRORS */
    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error MaxFeeExceeded();
    error MarketNotCreated();
    error AllCapsReached();

    /* EVENTS */
    event SetCap(address indexed caller, Id indexed id, uint256 supplyCap);
    event ReallocateSupply(address indexed caller, Id indexed id, uint256 suppliedAssets, uint256 suppliedShares);
    event ReallocateWithdraw(address indexed caller, Id indexed id, uint256 withdrawnAssets, uint256 withdrawnShares);
    event SetFee(address indexed caller, uint256 newFee);
    event SetFeeRecipient(address indexed newFeeRecipient);
    event AccrueInterest(uint256 newTotalAssets, uint256 feeShares);

    /* CONSTANTS */
    uint256 public constant MAX_FEE = 0.1e18; // 10% max fee (in WAD)
    uint256 public constant WAD = 1e18;

    /* IMMUTABLES */
    IMorpho public immutable MORPHO;

    /* STORAGE */
    address public owner;
    address public feeRecipient;
    uint96 public fee; // Performance fee in WAD (e.g., 0.1e18 = 10%)

    // Market configuration
    mapping(Id => uint256) public caps; // Supply cap per market
    Id[] public enabledMarkets; // List of enabled market IDs

    uint256 public lastTotalAssets;

    /* MODIFIERS */
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /* CONSTRUCTOR */
    constructor(
        address morpho,
        address asset_,
        string memory name_,
        string memory symbol_,
        address initialOwner
    ) ERC20(name_, symbol_) ERC4626(IERC20(asset_)) {
        if (morpho == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        MORPHO = IMorpho(morpho);
        owner = initialOwner;
        feeRecipient = initialOwner;

        // Approve Morpho to spend vault's assets
        IERC20(asset_).forceApprove(morpho, type(uint256).max);
    }

    /* OWNER FUNCTIONS */

    /**
     * @notice Set the supply cap for a specific market
     * @param marketParams The market parameters
     * @param newSupplyCap The new supply cap (0 to disable)
     */
    function submitCap(MarketParams memory marketParams, uint256 newSupplyCap) external onlyOwner {
        Id id = Id.wrap(keccak256(abi.encode(marketParams)));

        // Check if market exists in Morpho
        if (MORPHO.market(id).lastUpdate == 0) revert MarketNotCreated();

        uint256 oldCap = caps[id];

        // If enabling a market (cap goes from 0 to non-zero), add to enabled markets
        if (oldCap == 0 && newSupplyCap > 0) {
            enabledMarkets.push(id);
        }

        // If disabling a market (cap goes to 0), remove from enabled markets
        if (oldCap > 0 && newSupplyCap == 0) {
            _removeEnabledMarket(id);
        }

        caps[id] = newSupplyCap;

        emit SetCap(msg.sender, id, newSupplyCap);
    }

    /**
     * @notice Set the performance fee
     * @param newFee The new fee in WAD (e.g., 0.1e18 = 10%)
     */
    function setFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_FEE) revert MaxFeeExceeded();

        // Accrue fee with old rate before changing
        _accrueFee();

        fee = uint96(newFee);

        emit SetFee(msg.sender, newFee);
    }

    /**
     * @notice Set the fee recipient address
     * @param newFeeRecipient The new fee recipient
     */
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert ZeroAddress();

        // Accrue fee to old recipient before changing
        _accrueFee();

        feeRecipient = newFeeRecipient;

        emit SetFeeRecipient(newFeeRecipient);
    }

    /**
     * @notice Transfer ownership
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    /* ALLOCATION FUNCTIONS */

    /**
     * @notice Supply assets to a Morpho market
     * @param marketParams The market parameters
     * @param assets Amount of assets to supply
     */
    function supplyToMarket(MarketParams memory marketParams, uint256 assets) external onlyOwner {
        if (assets == 0) revert ZeroAmount();

        Id id = Id.wrap(keccak256(abi.encode(marketParams)));
        uint256 supplyCap = caps[id];

        if (supplyCap == 0) revert AllCapsReached();

        // Check current supply
        uint256 currentSupply = _getSupplyAssets(id);
        if (currentSupply + assets > supplyCap) revert AllCapsReached();

        // Supply to Morpho
        (, uint256 suppliedShares) = MORPHO.supply(marketParams, assets, 0, address(this), hex"");

        emit ReallocateSupply(msg.sender, id, assets, suppliedShares);
    }

    /**
     * @notice Withdraw assets from a Morpho market
     * @param marketParams The market parameters
     * @param assets Amount of assets to withdraw (0 to withdraw all)
     */
    function withdrawFromMarket(MarketParams memory marketParams, uint256 assets) external onlyOwner {
        Id id = Id.wrap(keccak256(abi.encode(marketParams)));

        // If assets is 0, withdraw all shares
        uint256 shares = 0;
        if (assets == 0) {
            shares = MORPHO.position(id, address(this)).supplyShares;
        }

        (uint256 withdrawnAssets, uint256 withdrawnShares) =
            MORPHO.withdraw(marketParams, assets, shares, address(this), address(this));

        emit ReallocateWithdraw(msg.sender, id, withdrawnAssets, withdrawnShares);
    }

    /* ERC4626 OVERRIDES */

    /**
     * @inheritdoc ERC4626
     * @dev Returns the total assets held by the vault across all Morpho markets
     */
    function totalAssets() public view override returns (uint256 assets) {
        // Sum up assets from all enabled markets
        for (uint256 i = 0; i < enabledMarkets.length; i++) {
            Id id = enabledMarkets[i];
            assets += _getSupplyAssets(id);
        }

        // Add any idle assets in the vault
        assets += IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @inheritdoc ERC4626
     * @dev Deposit assets and supply to Morpho markets
     */
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        // Accrue fees before deposit
        uint256 newTotalAssets = _accrueFee();
        lastTotalAssets = newTotalAssets;

        // Standard ERC4626 deposit
        shares = super.deposit(assets, receiver);

        // Try to supply to Morpho markets
        _supplyToMorpho(assets);

        lastTotalAssets = totalAssets();
    }

    /**
     * @inheritdoc ERC4626
     * @dev Mint shares and supply to Morpho markets
     */
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        // Accrue fees before mint
        uint256 newTotalAssets = _accrueFee();
        lastTotalAssets = newTotalAssets;

        // Standard ERC4626 mint
        assets = super.mint(shares, receiver);

        // Try to supply to Morpho markets
        _supplyToMorpho(assets);

        lastTotalAssets = totalAssets();
    }

    /**
     * @inheritdoc ERC4626
     * @dev Withdraw assets from Morpho markets
     */
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        returns (uint256 shares)
    {
        // Accrue fees before withdrawal
        _accrueFee();

        // Withdraw from Morpho if needed
        _withdrawFromMorpho(assets);

        // Standard ERC4626 withdrawal
        shares = super.withdraw(assets, receiver, owner_);

        lastTotalAssets = totalAssets();
    }

    /**
     * @inheritdoc ERC4626
     * @dev Redeem shares and withdraw from Morpho markets
     */
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        returns (uint256 assets)
    {
        // Accrue fees before redemption
        _accrueFee();

        // Calculate assets to withdraw
        assets = previewRedeem(shares);

        // Withdraw from Morpho if needed
        _withdrawFromMorpho(assets);

        // Standard ERC4626 redemption
        assets = super.redeem(shares, receiver, owner_);

        lastTotalAssets = totalAssets();
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @dev Supply idle assets to Morpho markets up to their caps
     */
    function _supplyToMorpho(uint256 assetsToSupply) internal {
        uint256 remaining = assetsToSupply;

        for (uint256 i = 0; i < enabledMarkets.length && remaining > 0; i++) {
            Id id = enabledMarkets[i];
            uint256 supplyCap = caps[id];

            if (supplyCap == 0) continue;

            MarketParams memory marketParams = MORPHO.idToMarketParams(id);
            uint256 currentSupply = _getSupplyAssets(id);
            uint256 availableCap = supplyCap > currentSupply ? supplyCap - currentSupply : 0;

            if (availableCap == 0) continue;

            uint256 toSupply = remaining < availableCap ? remaining : availableCap;

            try MORPHO.supply(marketParams, toSupply, 0, address(this), hex"") returns (uint256, uint256 suppliedShares) {
                emit ReallocateSupply(msg.sender, id, toSupply, suppliedShares);
                remaining -= toSupply;
            } catch {
                // Skip market if supply fails
                continue;
            }
        }
    }

    /**
     * @dev Withdraw assets from Morpho markets
     */
    function _withdrawFromMorpho(uint256 assetsNeeded) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));

        if (idle >= assetsNeeded) return; // Enough idle assets

        uint256 remaining = assetsNeeded - idle;

        for (uint256 i = 0; i < enabledMarkets.length && remaining > 0; i++) {
            Id id = enabledMarkets[i];
            MarketParams memory marketParams = MORPHO.idToMarketParams(id);

            uint256 availableToWithdraw = _getSupplyAssets(id);

            if (availableToWithdraw == 0) continue;

            uint256 toWithdraw = remaining < availableToWithdraw ? remaining : availableToWithdraw;

            try MORPHO.withdraw(marketParams, toWithdraw, 0, address(this), address(this))
                returns (uint256 withdrawnAssets, uint256 withdrawnShares)
            {
                emit ReallocateWithdraw(msg.sender, id, withdrawnAssets, withdrawnShares);
                remaining -= withdrawnAssets;
            } catch {
                // Skip market if withdrawal fails
                continue;
            }
        }
    }

    /**
     * @dev Accrue performance fees and mint shares to fee recipient
     * @return newTotalAssets The vault's total assets after accruing interest
     */
    function _accrueFee() internal returns (uint256 newTotalAssets) {
        newTotalAssets = totalAssets();

        if (fee == 0 || feeRecipient == address(0)) {
            emit AccrueInterest(newTotalAssets, 0);
            return newTotalAssets;
        }

        uint256 totalInterest = newTotalAssets > lastTotalAssets
            ? newTotalAssets - lastTotalAssets
            : 0;

        if (totalInterest == 0) {
            emit AccrueInterest(newTotalAssets, 0);
            return newTotalAssets;
        }

        // Calculate fee: feeAssets = totalInterest * fee / WAD
        uint256 feeAssets = totalInterest.mulDiv(fee, WAD);

        if (feeAssets > 0) {
            // Convert fee assets to shares
            uint256 supply = totalSupply();
            uint256 feeShares = supply == 0
                ? feeAssets
                : feeAssets.mulDiv(supply, newTotalAssets - feeAssets, Math.Rounding.Floor);

            if (feeShares > 0) {
                _mint(feeRecipient, feeShares);
                emit AccrueInterest(newTotalAssets, feeShares);
            }
        }

        lastTotalAssets = newTotalAssets;
    }

    /**
     * @dev Remove a market from the enabled markets array
     */
    function _removeEnabledMarket(Id id) internal {
        for (uint256 i = 0; i < enabledMarkets.length; i++) {
            if (Id.unwrap(enabledMarkets[i]) == Id.unwrap(id)) {
                // Move last element to this position and pop
                enabledMarkets[i] = enabledMarkets[enabledMarkets.length - 1];
                enabledMarkets.pop();
                break;
            }
        }
    }

    /**
     * @dev Calculate supply assets from shares for a given market
     * @param id The market ID
     * @return The amount of supply assets for this vault in the market
     */
    function _getSupplyAssets(Id id) internal view returns (uint256) {
        Position memory pos = MORPHO.position(id, address(this));
        Market memory mkt = MORPHO.market(id);

        if (mkt.totalSupplyShares == 0) return 0;

        // Convert shares to assets: assets = shares * totalSupplyAssets / totalSupplyShares
        return (pos.supplyShares * mkt.totalSupplyAssets) / mkt.totalSupplyShares;
    }

    /* VIEW FUNCTIONS */

    /**
     * @notice Get the number of enabled markets
     */
    function enabledMarketsCount() external view returns (uint256) {
        return enabledMarkets.length;
    }

    /**
     * @notice Get supply shares for a market
     */
    function supplyShares(Id id) external view returns (uint256) {
        return MORPHO.position(id, address(this)).supplyShares;
    }

    /**
     * @notice Get expected supply assets for a market
     */
    function getSupplyAssets(Id id) external view returns (uint256) {
        return _getSupplyAssets(id);
    }
}
