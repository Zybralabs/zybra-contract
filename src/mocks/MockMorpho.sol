// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IMorpho, Id, MarketParams, Position, Market, Authorization, Signature} from "../interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title MockMorpho
 * @dev Mock implementation of Morpho protocol for testing on Sepolia
 * @notice This is a simplified version that simulates basic supply/withdraw functionality
 */
contract MockMorpho is IMorpho {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    // Storage
    mapping(Id => Market) public markets;
    mapping(Id => mapping(address => Position)) public positions;
    mapping(Id => MarketParams) public marketParamsStorage;
    mapping(address => mapping(address => bool)) public authorizations;
    mapping(address => uint256) public nonces;

    address public owner;
    address public feeRecipient;
    mapping(address => bool) public irmsEnabled;
    mapping(uint256 => bool) public lltvsEnabled;

    // Mock yield rate (5% APY = ~0.000000158 per second)
    uint256 public constant MOCK_YIELD_RATE = 158; // basis points per second * 1e9

    bytes32 public DOMAIN_SEPARATOR;

    constructor() {
        owner = msg.sender;
        feeRecipient = msg.sender;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("MockMorpho"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    // View functions
    function position(Id id, address user) external view override returns (Position memory) {
        return positions[id][user];
    }

    function market(Id id) external view override returns (Market memory) {
        return markets[id];
    }

    function idToMarketParams(Id id) external view override returns (MarketParams memory) {
        return marketParamsStorage[id];
    }

    function isIrmEnabled(address irm) external view override returns (bool) {
        return irmsEnabled[irm];
    }

    function isLltvEnabled(uint256 lltv) external view override returns (bool) {
        return lltvsEnabled[lltv];
    }

    function isAuthorized(address authorizer, address authorized) external view override returns (bool) {
        return authorizations[authorizer][authorized];
    }

    function nonce(address authorizer) external view override returns (uint256) {
        return nonces[authorizer];
    }

    // Owner functions
    function setOwner(address newOwner) external override {
        require(msg.sender == owner, "Not owner");
        owner = newOwner;
    }

    function enableIrm(address irm) external override {
        require(msg.sender == owner, "Not owner");
        irmsEnabled[irm] = true;
    }

    function enableLltv(uint256 lltv) external override {
        require(msg.sender == owner, "Not owner");
        lltvsEnabled[lltv] = true;
    }

    function setFee(MarketParams memory, uint256 /* newFee */) external override {
        require(msg.sender == owner, "Not owner");
        // Mock implementation - fee not used
    }

    function setFeeRecipient(address newFeeRecipient) external override {
        require(msg.sender == owner, "Not owner");
        feeRecipient = newFeeRecipient;
    }

    // Market creation
    function createMarket(MarketParams memory marketParams) external override {
        Id id = Id.wrap(keccak256(abi.encode(marketParams)));

        require(markets[id].lastUpdate == 0, "Market already exists");

        markets[id] = Market({
            totalSupplyAssets: 0,
            totalSupplyShares: 0,
            totalBorrowAssets: 0,
            totalBorrowShares: 0,
            lastUpdate: uint128(block.timestamp),
            fee: 0
        });

        marketParamsStorage[id] = marketParams;

        // Enable the IRM and LLTV automatically for testing
        irmsEnabled[marketParams.irm] = true;
        lltvsEnabled[marketParams.lltv] = true;
    }

    // Supply function with mock yield
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory
    ) external override returns (uint256 assetsSupplied, uint256 sharesSupplied) {
        Id id = Id.wrap(keccak256(abi.encode(marketParams)));

        require(markets[id].lastUpdate > 0, "Market does not exist");

        // Accrue mock interest
        _accrueInterest(id);

        // Transfer tokens from sender
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        // Calculate shares (1:1 for simplicity, or based on current ratio)
        Market storage m = markets[id];

        if (shares == 0) {
            // User wants to supply exact assets
            if (m.totalSupplyShares == 0) {
                sharesSupplied = assets;
            } else {
                sharesSupplied = (assets * m.totalSupplyShares) / m.totalSupplyAssets;
            }
            assetsSupplied = assets;
        } else {
            // User wants exact shares
            if (m.totalSupplyShares == 0) {
                assetsSupplied = shares;
            } else {
                assetsSupplied = (shares * m.totalSupplyAssets) / m.totalSupplyShares;
            }
            sharesSupplied = shares;
        }

        // Update position
        positions[id][onBehalf].supplyShares += sharesSupplied;

        // Update market using SafeCast
        m.totalSupplyAssets += assetsSupplied.toUint128();
        m.totalSupplyShares += sharesSupplied.toUint128();

        return (assetsSupplied, sharesSupplied);
    }

    // Withdraw function
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external override returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn) {
        Id id = Id.wrap(keccak256(abi.encode(marketParams)));

        require(markets[id].lastUpdate > 0, "Market does not exist");

        // Accrue mock interest
        _accrueInterest(id);

        Market storage m = markets[id];
        Position storage pos = positions[id][onBehalf];

        if (assets == 0) {
            // User wants to withdraw exact shares
            sharesWithdrawn = shares;
            if (m.totalSupplyShares == 0) {
                assetsWithdrawn = 0;
            } else {
                assetsWithdrawn = (shares * m.totalSupplyAssets) / m.totalSupplyShares;
            }
        } else {
            // User wants to withdraw exact assets
            assetsWithdrawn = assets;
            if (m.totalSupplyAssets == 0) {
                sharesWithdrawn = 0;
            } else {
                sharesWithdrawn = (assets * m.totalSupplyShares) / m.totalSupplyAssets;
            }
        }

        require(pos.supplyShares >= sharesWithdrawn, "Insufficient shares");

        // Update position
        pos.supplyShares -= sharesWithdrawn;

        // Update market using SafeCast
        m.totalSupplyAssets -= assetsWithdrawn.toUint128();
        m.totalSupplyShares -= sharesWithdrawn.toUint128();

        // Transfer tokens to receiver
        IERC20(marketParams.loanToken).safeTransfer(receiver, assetsWithdrawn);

        return (assetsWithdrawn, sharesWithdrawn);
    }

    // Mock interest accrual (adds ~5% APY)
    function _accrueInterest(Id id) internal {
        Market storage m = markets[id];

        uint256 timeDelta = block.timestamp - m.lastUpdate;
        if (timeDelta > 0 && m.totalSupplyAssets > 0) {
            // Simple interest: assets * rate * time
            uint256 interest = (uint256(m.totalSupplyAssets) * MOCK_YIELD_RATE * timeDelta) / 1e18;
            m.totalSupplyAssets += interest.toUint128();
            m.lastUpdate = block.timestamp.toUint128();
        }
    }

    function accrueInterest(MarketParams memory marketParams) external override {
        Id id = Id.wrap(keccak256(abi.encode(marketParams)));
        _accrueInterest(id);
    }

    // Unimplemented functions (not needed for basic testing)
    function borrow(MarketParams memory, uint256, uint256, address, address) external pure override returns (uint256, uint256) {
        revert("Not implemented");
    }

    function repay(MarketParams memory, uint256, uint256, address, bytes memory) external pure override returns (uint256, uint256) {
        revert("Not implemented");
    }

    function supplyCollateral(MarketParams memory, uint256, address, bytes memory) external pure override {
        revert("Not implemented");
    }

    function withdrawCollateral(MarketParams memory, uint256, address, address) external pure override {
        revert("Not implemented");
    }

    function liquidate(MarketParams memory, address, uint256, uint256, bytes memory) external pure override returns (uint256, uint256) {
        revert("Not implemented");
    }

    function flashLoan(address, uint256, bytes calldata) external pure override {
        revert("Not implemented");
    }

    function setAuthorization(address authorized, bool newIsAuthorized) external override {
        authorizations[msg.sender][authorized] = newIsAuthorized;
    }

    function setAuthorizationWithSig(Authorization calldata /* auth */, Signature calldata /* sig */) external pure override {
        revert("Not implemented");
    }

    function extSloads(bytes32[] memory) external pure override returns (bytes32[] memory) {
        revert("Not implemented");
    }
}
