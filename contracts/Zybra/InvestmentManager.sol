// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Auth} from "contracts/Zybra/Auth.sol";
import {CastLib} from "contracts/Zybra/libraries/CastLib.sol";
import {MathLib} from "contracts/Zybra/libraries/MathLib.sol";
import {SafeTransferLib} from "contracts/Zybra/libraries/SafeTransferLib.sol";
import {MessagesLib} from "contracts/Zybra/libraries/MessagesLib.sol";
import {BytesLib} from "contracts/Zybra/libraries/BytesLib.sol";
import {IERC20, IERC20Metadata} from "contracts/Zybra/interfaces/IERC20.sol";
import {IPoolManager} from "contracts/Zybra/interfaces/IPoolManager.sol";
import {IInvestmentManager, InvestmentState} from "contracts/Zybra/interfaces/IInvestmentManager.sol";
import {ITranche} from "contracts/Zybra/interfaces/token/ITranche.sol";
import {IERC7540Vault} from "contracts/Zybra/interfaces/IERC7540.sol";
import {IGateway} from "contracts/Zybra/interfaces/gateway/IGateway.sol";
import {IRecoverable} from "contracts/Zybra/interfaces/IRoot.sol";

/// @title  Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract InvestmentManager is Auth, IInvestmentManager {
    using BytesLib for bytes;
    using MathLib for uint256;
    using CastLib for *;

    /// @dev Prices are fixed-point integers with 18 decimals
    uint8 internal constant PRICE_DECIMALS = 18;

    address public immutable root;
    address public immutable escrow;

    IGateway public gateway;
    IPoolManager public poolManager;

    /// @inheritdoc IInvestmentManager
    mapping(address vault => mapping(address investor => InvestmentState)) public investments;

    constructor(address root_, address escrow_) Auth(msg.sender) {
        root = root_;
        escrow = escrow_;
    }

    // --- Administration ---
    /// @inheritdoc IInvestmentManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("InvestmentManager/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // --- Outgoing message handling ---
    /// @inheritdoc IInvestmentManager
    function requestDeposit(address vault, uint256 assets, address controller, address, /* owner */ address source)
        public
        auth
        returns (bool)
    {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        uint128 _assets = assets.toUint128();
        require(_assets != 0, "InvestmentManager/zero-amount-not-allowed");

        uint64 poolId = vault_.poolId();
        address asset = vault_.asset();
        require(poolManager.isAllowedAsset(poolId, asset), "InvestmentManager/asset-not-allowed");

        require(
            _canTransfer(vault, address(0), controller, convertToShares(vault, assets)),
            "InvestmentManager/transfer-not-allowed"
        );

        InvestmentState storage state = investments[vault][controller];
        require(state.pendingCancelDepositRequest != true, "InvestmentManager/cancellation-is-pending");

        state.pendingDepositRequest = state.pendingDepositRequest + _assets;
        gateway.send(
            abi.encodePacked(
                uint8(MessagesLib.Call.DepositRequest),
                poolId,
                vault_.trancheId(),
                controller.toBytes32(),
                poolManager.assetToId(asset),
                _assets
            ),
            source
        );

        return true;
    }

    /// @inheritdoc IInvestmentManager
    function requestRedeem(address vault, uint256 shares, address controller, /* owner */ address, address source)
        public
        auth
        returns (bool)
    {
        uint128 _shares = shares.toUint128();
        require(_shares != 0, "InvestmentManager/zero-amount-not-allowed");
        IERC7540Vault vault_ = IERC7540Vault(vault);

        // You cannot redeem using a disallowed asset, instead another vault will have to be used
        require(poolManager.isAllowedAsset(vault_.poolId(), vault_.asset()), "InvestmentManager/asset-not-allowed");

        return _processRedeemRequest(vault, _shares, controller, source, false);
    }

    /// @dev    triggered indicates if the the _processRedeemRequest call was triggered from centrifugeChain
    function _processRedeemRequest(address vault, uint128 shares, address controller, address source, bool triggered)
        internal
        returns (bool)
    {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        InvestmentState storage state = investments[vault][controller];
        require(state.pendingCancelRedeemRequest != true || triggered, "InvestmentManager/cancellation-is-pending");

        state.pendingRedeemRequest = state.pendingRedeemRequest + shares;

        gateway.send(
            abi.encodePacked(
                uint8(MessagesLib.Call.RedeemRequest),
                vault_.poolId(),
                vault_.trancheId(),
                controller.toBytes32(),
                poolManager.assetToId(vault_.asset()),
                shares
            ),
            source
        );

        return true;
    }

    /// @inheritdoc IInvestmentManager
    function cancelDepositRequest(address vault, address controller, address source) public auth {
        IERC7540Vault _vault = IERC7540Vault(vault);

        InvestmentState storage state = investments[vault][controller];
        require(state.pendingDepositRequest > 0, "InvestmentManager/no-pending-deposit-request");
        require(state.pendingCancelDepositRequest != true, "InvestmentManager/cancellation-is-pending");
        state.pendingCancelDepositRequest = true;

        gateway.send(
            abi.encodePacked(
                uint8(MessagesLib.Call.CancelDepositRequest),
                _vault.poolId(),
                _vault.trancheId(),
                controller.toBytes32(),
                poolManager.assetToId(_vault.asset())
            ),
            source
        );
    }

    /// @inheritdoc IInvestmentManager
    function cancelRedeemRequest(address vault, address controller, address source) public auth {
        IERC7540Vault _vault = IERC7540Vault(vault);
        uint256 approximateTranchesPayout = pendingRedeemRequest(vault, controller);
        require(approximateTranchesPayout > 0, "InvestmentManager/no-pending-redeem-request");
        require(
            _canTransfer(vault, address(0), controller, approximateTranchesPayout),
            "InvestmentManager/transfer-not-allowed"
        );

        InvestmentState storage state = investments[vault][controller];
        require(state.pendingCancelRedeemRequest != true, "InvestmentManager/cancellation-is-pending");
        state.pendingCancelRedeemRequest = true;

        gateway.send(
            abi.encodePacked(
                uint8(MessagesLib.Call.CancelRedeemRequest),
                _vault.poolId(),
                _vault.trancheId(),
                controller.toBytes32(),
                poolManager.assetToId(_vault.asset())
            ),
            source
        );
    }

    // --- Incoming message handling ---
    /// @inheritdoc IInvestmentManager
    function handle(bytes calldata message) public auth {
        MessagesLib.Call call = MessagesLib.messageType(message);

        if (call == MessagesLib.Call.FulfilledDepositRequest) {
            fulfillDepositRequest(
                message.toUint64(1),
                message.toBytes16(9),
                message.toAddress(25),
                message.toUint128(57),
                message.toUint128(73),
                message.toUint128(89)
            );
        } else if (call == MessagesLib.Call.FulfilledRedeemRequest) {
            fulfillRedeemRequest(
                message.toUint64(1),
                message.toBytes16(9),
                message.toAddress(25),
                message.toUint128(57),
                message.toUint128(73),
                message.toUint128(89)
            );
        } else if (call == MessagesLib.Call.FulfilledCancelDepositRequest) {
            fulfillCancelDepositRequest(
                message.toUint64(1),
                message.toBytes16(9),
                message.toAddress(25),
                message.toUint128(57),
                message.toUint128(73),
                message.toUint128(89)
            );
        } else if (call == MessagesLib.Call.FulfilledCancelRedeemRequest) {
            fulfillCancelRedeemRequest(
                message.toUint64(1),
                message.toBytes16(9),
                message.toAddress(25),
                message.toUint128(57),
                message.toUint128(73)
            );
        } else if (call == MessagesLib.Call.TriggerRedeemRequest) {
            triggerRedeemRequest(
                message.toUint64(1),
                message.toBytes16(9),
                message.toAddress(25),
                message.toUint128(57),
                message.toUint128(73)
            );
        } else {
            revert("InvestmentManager/invalid-message");
        }
    }

    /// @inheritdoc IInvestmentManager
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault = poolManager.getVault(poolId, trancheId, assetId);

        InvestmentState storage state = investments[vault][user];
        require(state.pendingDepositRequest != 0, "InvestmentManager/no-pending-deposit-request");
        state.depositPrice = _calculatePrice(vault, _maxDeposit(vault, user) + assets, state.maxMint + shares);
        state.maxMint = state.maxMint + shares;
        state.pendingDepositRequest = state.pendingDepositRequest > assets ? state.pendingDepositRequest - assets : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        // Mint to escrow. Recipient can claim by calling deposit / mint
        ITranche tranche = ITranche(IERC7540Vault(vault).share());
        tranche.mint(address(escrow), shares);

        IERC7540Vault(vault).onDepositClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManager
    function fulfillRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public auth {
        address vault = poolManager.getVault(poolId, trancheId, assetId);

        InvestmentState storage state = investments[vault][user];
        require(state.pendingRedeemRequest != 0, "InvestmentManager/no-pending-redeem-request");

        // Calculate new weighted average redeem price and update order book values
        state.redeemPrice =
            _calculatePrice(vault, state.maxWithdraw + assets, ((maxRedeem(vault, user)) + shares).toUint128());
        state.maxWithdraw = state.maxWithdraw + assets;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        // Burn redeemed tranche tokens from escrow
        ITranche tranche = ITranche(IERC7540Vault(vault).share());
        tranche.burn(address(escrow), shares);

        IERC7540Vault(vault).onRedeemClaimable(user, assets, shares);
    }

    /// @inheritdoc IInvestmentManager
    function fulfillCancelDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) public auth {
        address vault = poolManager.getVault(poolId, trancheId, assetId);

        InvestmentState storage state = investments[vault][user];
        require(state.pendingCancelDepositRequest == true, "InvestmentManager/no-pending-cancel-deposit-request");

        state.claimableCancelDepositRequest = state.claimableCancelDepositRequest + assets;
        state.pendingDepositRequest =
            state.pendingDepositRequest > fulfillment ? state.pendingDepositRequest - fulfillment : 0;

        if (state.pendingDepositRequest == 0) delete state.pendingCancelDepositRequest;

        IERC7540Vault(vault).onCancelDepositClaimable(user, assets);
    }

    /// @inheritdoc IInvestmentManager
    function fulfillCancelRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        address vault = poolManager.getVault(poolId, trancheId, assetId);
        InvestmentState storage state = investments[vault][user];
        require(state.pendingCancelRedeemRequest == true, "InvestmentManager/no-pending-cancel-redeem-request");

        state.claimableCancelRedeemRequest = state.claimableCancelRedeemRequest + shares;
        state.pendingRedeemRequest = state.pendingRedeemRequest > shares ? state.pendingRedeemRequest - shares : 0;

        if (state.pendingRedeemRequest == 0) delete state.pendingCancelRedeemRequest;

        IERC7540Vault(vault).onCancelRedeemClaimable(user, shares);
    }

    /// @inheritdoc IInvestmentManager
    function triggerRedeemRequest(uint64 poolId, bytes16 trancheId, address user, uint128 assetId, uint128 shares)
        public
        auth
    {
        require(shares != 0, "InvestmentManager/tranche-token-amount-is-zero");
        address vault = poolManager.getVault(poolId, trancheId, assetId);

        // If there's any unclaimed deposits, claim those first
        InvestmentState storage state = investments[vault][user];
        uint128 tokensToTransfer = shares;
        if (state.maxMint >= shares) {
            // The full redeem request is covered by the claimable amount
            tokensToTransfer = 0;
            state.maxMint = state.maxMint - shares;
        } else if (state.maxMint != 0) {
            // The redeem request is only partially covered by the claimable amount
            tokensToTransfer = shares - state.maxMint;
            state.maxMint = 0;
        }

        require(_processRedeemRequest(vault, shares, user, msg.sender, true), "InvestmentManager/failed-redeem-request");

        // Transfer the tranche token amount that was not covered by tokens still in escrow for claims,
        // from user to escrow (lock tranche tokens in escrow)
        if (tokensToTransfer != 0) {
            require(
                ITranche(address(IERC7540Vault(vault).share())).authTransferFrom(
                    user, user, address(escrow), tokensToTransfer
                ),
                "InvestmentManager/transfer-failed"
            );
        }

        emit TriggerRedeemRequest(poolId, trancheId, user, poolManager.idToAsset(assetId), shares);
        IERC7540Vault(vault).onRedeemRequest(user, user, shares);
    }

    // --- View functions ---
    /// @inheritdoc IInvestmentManager
    function convertToShares(address vault, uint256 _assets) public view returns (uint256 shares) {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        (uint128 latestPrice,) = poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
        shares = uint256(_calculateShares(_assets.toUint128(), vault, latestPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IInvestmentManager
    function convertToAssets(address vault, uint256 _shares) public view returns (uint256 assets) {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        (uint128 latestPrice,) = poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
        assets = uint256(_calculateAssets(_shares.toUint128(), vault, latestPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IInvestmentManager
    function maxDeposit(address vault, address user) public view returns (uint256 assets) {
        if (!_canTransfer(vault, address(escrow), user, 0)) return 0;
        assets = uint256(_maxDeposit(vault, user));
    }

    function _maxDeposit(address vault, address user) internal view returns (uint128 assets) {
        InvestmentState memory state = investments[vault][user];
        assets = _calculateAssets(state.maxMint, vault, state.depositPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IInvestmentManager
    function maxMint(address vault, address user) public view returns (uint256 shares) {
        if (!_canTransfer(vault, address(escrow), user, 0)) return 0;
        shares = uint256(investments[vault][user].maxMint);
    }

    /// @inheritdoc IInvestmentManager
    function maxWithdraw(address vault, address user) public view returns (uint256 assets) {
        assets = uint256(investments[vault][user].maxWithdraw);
    }

    /// @inheritdoc IInvestmentManager
    function maxRedeem(address vault, address user) public view returns (uint256 shares) {
        InvestmentState memory state = investments[vault][user];
        shares = uint256(_calculateShares(state.maxWithdraw, vault, state.redeemPrice, MathLib.Rounding.Down));
    }

    /// @inheritdoc IInvestmentManager
    function pendingDepositRequest(address vault, address user) public view returns (uint256 assets) {
        assets = uint256(investments[vault][user].pendingDepositRequest);
    }

    /// @inheritdoc IInvestmentManager
    function pendingRedeemRequest(address vault, address user) public view returns (uint256 shares) {
        shares = uint256(investments[vault][user].pendingRedeemRequest);
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelDepositRequest(address vault, address user) public view returns (bool isPending) {
        isPending = investments[vault][user].pendingCancelDepositRequest;
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelRedeemRequest(address vault, address user) public view returns (bool isPending) {
        isPending = investments[vault][user].pendingCancelRedeemRequest;
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelDepositRequest(address vault, address user) public view returns (uint256 assets) {
        assets = investments[vault][user].claimableCancelDepositRequest;
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelRedeemRequest(address vault, address user) public view returns (uint256 shares) {
        shares = investments[vault][user].claimableCancelRedeemRequest;
    }

    /// @inheritdoc IInvestmentManager
    function priceLastUpdated(address vault) public view returns (uint64 lastUpdated) {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        (, lastUpdated) = poolManager.getTranchePrice(vault_.poolId(), vault_.trancheId(), vault_.asset());
    }

    // --- Vault claim functions ---
    /// @inheritdoc IInvestmentManager
    function deposit(address vault, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        require(assets <= _maxDeposit(vault, controller), "InvestmentManager/exceeds-max-deposit");

        InvestmentState storage state = investments[vault][controller];
        uint128 sharesUp = _calculateShares(assets.toUint128(), vault, state.depositPrice, MathLib.Rounding.Up);
        uint128 sharesDown = _calculateShares(assets.toUint128(), vault, state.depositPrice, MathLib.Rounding.Down);
        _processDeposit(state, sharesUp, sharesDown, vault, receiver);
        shares = uint256(sharesDown);
    }

    /// @inheritdoc IInvestmentManager
    function mint(address vault, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        InvestmentState storage state = investments[vault][controller];
        uint128 shares_ = shares.toUint128();
        _processDeposit(state, shares_, shares_, vault, receiver);
        assets = uint256(_calculateAssets(shares_, vault, state.depositPrice, MathLib.Rounding.Down));
    }

    function _processDeposit(
        InvestmentState storage state,
        uint128 sharesUp,
        uint128 sharesDown,
        address vault,
        address receiver
    ) internal {
        require(sharesUp <= state.maxMint, "InvestmentManager/exceeds-deposit-limits");
        state.maxMint = state.maxMint > sharesUp ? state.maxMint - sharesUp : 0;
        if (sharesDown > 0) {
            require(
                IERC20(IERC7540Vault(vault).share()).transferFrom(address(escrow), receiver, sharesDown),
                "InvestmentManager/tranche-tokens-transfer-failed"
            );
        }
    }

    /// @inheritdoc IInvestmentManager
    function redeem(address vault, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        require(shares <= maxRedeem(vault, controller), "InvestmentManager/exceeds-max-redeem");

        InvestmentState storage state = investments[vault][controller];
        uint128 assetsUp = _calculateAssets(shares.toUint128(), vault, state.redeemPrice, MathLib.Rounding.Up);
        uint128 assetsDown = _calculateAssets(shares.toUint128(), vault, state.redeemPrice, MathLib.Rounding.Down);
        _processRedeem(state, assetsUp, assetsDown, vault, receiver);
        assets = uint256(assetsDown);
    }

    /// @inheritdoc IInvestmentManager
    function withdraw(address vault, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        InvestmentState storage state = investments[vault][controller];
        uint128 assets_ = assets.toUint128();
        _processRedeem(state, assets_, assets_, vault, receiver);
        shares = uint256(_calculateShares(assets_, vault, state.redeemPrice, MathLib.Rounding.Down));
    }

    function _processRedeem(
        InvestmentState storage state,
        uint128 assetsUp,
        uint128 assetsDown,
        address vault,
        address receiver
    ) internal {
        IERC7540Vault vault_ = IERC7540Vault(vault);
        require(assetsUp <= state.maxWithdraw, "InvestmentManager/exceeds-redeem-limits");
        state.maxWithdraw = state.maxWithdraw > assetsUp ? state.maxWithdraw - assetsUp : 0;
        if (assetsDown > 0) SafeTransferLib.safeTransferFrom(vault_.asset(), address(escrow), receiver, assetsDown);
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelDepositRequest(address vault, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        InvestmentState storage state = investments[vault][controller];
        assets = state.claimableCancelDepositRequest;
        state.claimableCancelDepositRequest = 0;
        if (assets > 0) {
            SafeTransferLib.safeTransferFrom(IERC7540Vault(vault).asset(), address(escrow), receiver, assets);
        }
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelRedeemRequest(address vault, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        InvestmentState storage state = investments[vault][controller];
        shares = state.claimableCancelRedeemRequest;
        state.claimableCancelRedeemRequest = 0;
        if (shares > 0) {
            require(
                IERC20(IERC7540Vault(vault).share()).transferFrom(address(escrow), receiver, shares),
                "InvestmentManager/tranche-tokens-transfer-failed"
            );
        }
    }

    // --- Helpers ---
    /// @dev    Calculates share amount based on asset amount and share price. Returned value is in share decimals.
    function _calculateShares(uint128 assets, address vault, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 shares)
    {
        if (price == 0 || assets == 0) {
            shares = 0;
        } else {
            (uint8 assetDecimals, uint8 shareDecimals) = _getPoolDecimals(vault);

            uint256 sharesInPriceDecimals =
                _toPriceDecimals(assets, assetDecimals).mulDiv(10 ** PRICE_DECIMALS, price, rounding);

            shares = _fromPriceDecimals(sharesInPriceDecimals, shareDecimals);
        }
    }

    /// @dev    Calculates asset amount based on share amount and share price. Returned value is in asset decimals.
    function _calculateAssets(uint128 shares, address vault, uint256 price, MathLib.Rounding rounding)
        internal
        view
        returns (uint128 assets)
    {
        if (price == 0 || shares == 0) {
            assets = 0;
        } else {
            (uint8 assetDecimals, uint8 shareDecimals) = _getPoolDecimals(vault);

            uint256 assetsInPriceDecimals =
                _toPriceDecimals(shares, shareDecimals).mulDiv(price, 10 ** PRICE_DECIMALS, rounding);

            assets = _fromPriceDecimals(assetsInPriceDecimals, assetDecimals);
        }
    }

    /// @dev    Calculates share price and returns the value in price decimals
    function _calculatePrice(address vault, uint128 assets, uint128 shares) internal view returns (uint256) {
        if (assets == 0 || shares == 0) {
            return 0;
        }

        (uint8 assetDecimals, uint8 shareDecimals) = _getPoolDecimals(vault);
        return _toPriceDecimals(assets, assetDecimals).mulDiv(
            10 ** PRICE_DECIMALS, _toPriceDecimals(shares, shareDecimals), MathLib.Rounding.Down
        );
    }

    /// @dev    When converting assets to shares using the price,
    ///         all values are normalized to PRICE_DECIMALS
    function _toPriceDecimals(uint128 _value, uint8 decimals) internal pure returns (uint256) {
        if (PRICE_DECIMALS == decimals) return uint256(_value);
        return uint256(_value) * 10 ** (PRICE_DECIMALS - decimals);
    }

    /// @dev    Converts decimals of the value from the price decimals back to the intended decimals
    function _fromPriceDecimals(uint256 _value, uint8 decimals) internal pure returns (uint128) {
        if (PRICE_DECIMALS == decimals) return _value.toUint128();
        return (_value / 10 ** (PRICE_DECIMALS - decimals)).toUint128();
    }

    /// @dev    Returns the asset decimals and the share decimals for a given vault
    function _getPoolDecimals(address vault) internal view returns (uint8 assetDecimals, uint8 shareDecimals) {
        assetDecimals = IERC20Metadata(IERC7540Vault(vault).asset()).decimals();
        shareDecimals = IERC20Metadata(IERC7540Vault(vault).share()).decimals();
    }

    /// @dev    Checks transfer restrictions for the vault shares. Sender (from) and receiver (to) have both to pass the
    ///         restrictions for a successful share transfer.
    function _canTransfer(address vault, address from, address to, uint256 value) internal view returns (bool) {
        ITranche share = ITranche(IERC7540Vault(vault).share());
        return share.checkTransferRestriction(from, to, value);
    }
}
