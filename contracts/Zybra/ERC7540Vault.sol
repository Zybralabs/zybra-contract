// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Auth} from "contracts/Zybra/Auth.sol";
import {IRoot} from "contracts/Zybra/interfaces/IRoot.sol";
import {EIP712Lib} from "contracts/Zybra/libraries/EIP712Lib.sol";
import {IRecoverable} from "contracts/Zybra/interfaces/IRoot.sol";
import {ITranche} from "contracts/Zybra/interfaces/token/ITranche.sol";
import {SignatureLib} from "contracts/Zybra/libraries/SignatureLib.sol";
import {SafeTransferLib} from "contracts/Zybra/libraries/SafeTransferLib.sol";
import {IInvestmentManager} from "contracts/Zybra/interfaces/IInvestmentManager.sol";
import "contracts/Zybra/interfaces/IERC7540.sol";
import "contracts/Zybra/interfaces/IERC7575.sol";
import "contracts/Zybra/interfaces/IERC20.sol";

/// @title  ERC7540Vault
/// @notice Asynchronous Tokenized Vault standard implementation for Centrifuge pools
///
/// @dev    Each vault issues shares of Centrifuge tranches as restricted ERC-20 tokens
///         against asset deposits based on the current share price.
///
///         ERC-7540 is an extension of the ERC-4626 standard by 'requestDeposit' & 'requestRedeem' methods, where
///         deposit and redeem orders are submitted to the pools to be included in the execution of the following epoch.
///         After execution users can use the deposit, mint, redeem and withdraw functions to get their shares
///         and/or assets from the pools.
contract ERC7540Vault is Auth, IERC7540Vault {
    /// @dev Requests for Centrifuge pool are non-fungible and all have ID = 0
    uint256 private constant REQUEST_ID = 0;

    IRoot public immutable root;
    address public immutable escrow;
    IInvestmentManager public manager;

    /// @inheritdoc IERC7540Vault
    uint64 public immutable poolId;
    /// @inheritdoc IERC7540Vault
    bytes16 public immutable trancheId;

    /// @inheritdoc IERC7575
    address public immutable asset;

    /// @inheritdoc IERC7575
    address public immutable share;
    uint8 internal immutable _shareDecimals;

    /// --- ERC7741 ---
    bytes32 private immutable nameHash;
    bytes32 private immutable versionHash;
    uint256 public immutable deploymentChainId;
    bytes32 private immutable _DOMAIN_SEPARATOR;
    bytes32 public constant AUTHORIZE_OPERATOR_TYPEHASH =
        keccak256("AuthorizeOperator(address controller,address operator,bool approved,bytes32 nonce,uint256 deadline)");

    /// @inheritdoc IERC7741
    mapping(address controller => mapping(bytes32 nonce => bool used)) public authorizations;

    /// @inheritdoc IERC7540Operator
    mapping(address => mapping(address => bool)) public isOperator;

    // --- Events ---
    event File(bytes32 indexed what, address data);

    constructor(
        uint64 poolId_,
        bytes16 trancheId_,
        address asset_,
        address share_,
        address root_,
        address escrow_,
        address manager_
    ) Auth(msg.sender) {
        poolId = poolId_;
        trancheId = trancheId_;
        asset = asset_;
        share = share_;
        _shareDecimals = IERC20Metadata(share).decimals();
        root = IRoot(root_);
        escrow = escrow_;
        manager = IInvestmentManager(manager_);

        nameHash = keccak256(bytes("Centrifuge"));
        versionHash = keccak256(bytes("1"));
        deploymentChainId = block.chainid;
        _DOMAIN_SEPARATOR = EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "manager") manager = IInvestmentManager(data);
        else revert("ERC7540Vault/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // --- ERC-7540 methods ---
    /// @inheritdoc IERC7540Deposit
    function requestDeposit(uint256 assets, address controller, address owner) public returns (uint256) {
        require(owner == msg.sender || isOperator[owner][msg.sender], "ERC7540Vault/invalid-owner");
        require(IERC20(asset).balanceOf(owner) >= assets, "ERC7540Vault/insufficient-balance");

        require(
            manager.requestDeposit(address(this), assets, controller, owner, msg.sender),
            "ERC7540Vault/request-deposit-failed"
        );
        SafeTransferLib.safeTransferFrom(asset, owner, address(escrow), assets);

        emit DepositRequest(controller, owner, REQUEST_ID, msg.sender, assets);
        return REQUEST_ID;
    }

    /// @inheritdoc IERC7540Deposit
    function pendingDepositRequest(uint256, address controller) public view returns (uint256 pendingAssets) {
        pendingAssets = manager.pendingDepositRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256, address controller) external view returns (uint256 claimableAssets) {
        claimableAssets = maxDeposit(controller);
    }

    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 shares, address controller, address owner) public returns (uint256) {
        require(ITranche(share).balanceOf(owner) >= shares, "ERC7540Vault/insufficient-balance");

        // If msg.sender is operator of owner, the transfer is executed as if
        // the sender is the owner, to bypass the allowance check
        address sender = isOperator[owner][msg.sender] ? owner : msg.sender;

        require(
            manager.requestRedeem(address(this), shares, controller, owner, sender),
            "ERC7540Vault/request-redeem-failed"
        );

        require(
            ITranche(share).checkTransferRestriction(owner, address(escrow), shares), "ERC7540Vault/restrictions-failed"
        );

        try ITranche(share).authTransferFrom(sender, owner, address(escrow), shares) returns (bool) {}
        catch {
            // Support tranche tokens that block authTransferFrom. In this case ERC20 approval needs to be set
            require(ITranche(share).transferFrom(owner, address(escrow), shares), "ERC7540Vault/transfer-from-failed");
        }

        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
        return REQUEST_ID;
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256, address controller) public view returns (uint256 pendingShares) {
        pendingShares = manager.pendingRedeemRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 claimableShares) {
        claimableShares = maxRedeem(controller);
    }

    // --- Asynchronous cancellation methods ---
    /// @inheritdoc IERC7540CancelDeposit
    function cancelDepositRequest(uint256, address controller) external {
        _validateController(controller);
        manager.cancelDepositRequest(address(this), controller, msg.sender);
        emit CancelDepositRequest(controller, REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IERC7540CancelDeposit
    function pendingCancelDepositRequest(uint256, address controller) public view returns (bool isPending) {
        isPending = manager.pendingCancelDepositRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelDeposit
    function claimableCancelDepositRequest(uint256, address controller) public view returns (uint256 claimableAssets) {
        claimableAssets = manager.claimableCancelDepositRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelDeposit
    function claimCancelDepositRequest(uint256, address receiver, address controller)
        external
        returns (uint256 assets)
    {
        _validateController(controller);
        assets = manager.claimCancelDepositRequest(address(this), receiver, controller);
        emit CancelDepositClaim(receiver, controller, REQUEST_ID, msg.sender, assets);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function cancelRedeemRequest(uint256, address controller) external {
        _validateController(controller);
        manager.cancelRedeemRequest(address(this), controller, msg.sender);
        emit CancelRedeemRequest(controller, REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function pendingCancelRedeemRequest(uint256, address controller) public view returns (bool isPending) {
        isPending = manager.pendingCancelRedeemRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function claimableCancelRedeemRequest(uint256, address controller) public view returns (uint256 claimableShares) {
        claimableShares = manager.claimableCancelRedeemRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function claimCancelRedeemRequest(uint256, address receiver, address controller)
        external
        returns (uint256 shares)
    {
        _validateController(controller);
        shares = manager.claimCancelRedeemRequest(address(this), receiver, controller);
        emit CancelRedeemClaim(receiver, controller, REQUEST_ID, msg.sender, shares);
    }

    /// @inheritdoc IERC7540Operator
    function setOperator(address operator, bool approved) public virtual returns (bool success) {
        require(msg.sender != operator, "ERC7540Vault/cannot-set-self-as-operator");
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        success = true;
    }

    /// @inheritdoc IERC7540Vault
    function setEndorsedOperator(address owner, bool approved) public virtual {
        require(msg.sender != owner, "ERC7540Vault/cannot-set-self-as-operator");
        require(root.endorsed(msg.sender), "ERC7540Vault/not-endorsed");
        isOperator[owner][msg.sender] = approved;
        emit OperatorSet(owner, msg.sender, approved);
    }

    /// @inheritdoc IERC7741
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == deploymentChainId
            ? _DOMAIN_SEPARATOR
            : EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
    }

    /// @inheritdoc IERC7741
    function authorizeOperator(
        address controller,
        address operator,
        bool approved,
        bytes32 nonce,
        uint256 deadline,
        bytes memory signature
    ) external returns (bool success) {
        require(controller != operator, "ERC7540Vault/cannot-set-self-as-operator");
        require(block.timestamp <= deadline, "ERC7540Vault/expired");
        require(!authorizations[controller][nonce], "ERC7540Vault/authorization-used");

        authorizations[controller][nonce] = true;

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(AUTHORIZE_OPERATOR_TYPEHASH, controller, operator, approved, nonce, deadline))
            )
        );

        require(SignatureLib.isValidSignature(controller, digest, signature), "ERC7540Vault/invalid-authorization");

        isOperator[controller][operator] = approved;
        emit OperatorSet(controller, operator, approved);

        success = true;
    }

    /// @inheritdoc IERC7741
    function invalidateNonce(bytes32 nonce) external {
        authorizations[msg.sender][nonce] = true;
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC7540Deposit).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC7540Operator).interfaceId || interfaceId == type(IERC7540CancelDeposit).interfaceId
            || interfaceId == type(IERC7540CancelRedeem).interfaceId || interfaceId == type(IERC7575).interfaceId
            || interfaceId == type(IERC7741).interfaceId || interfaceId == type(IERC7714).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // --- ERC-4626 methods ---
    /// @inheritdoc IERC7575
    function totalAssets() external view returns (uint256) {
        return convertToAssets(IERC20Metadata(share).totalSupply());
    }

    /// @inheritdoc IERC7575
    /// @notice     The calculation is based on the token price from the most recent epoch retrieved from Centrifuge.
    ///             The actual conversion MAY change between order submission and execution.
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        shares = manager.convertToShares(address(this), assets);
    }

    /// @inheritdoc IERC7575
    /// @notice     The calculation is based on the token price from the most recent epoch retrieved from Centrifuge.
    ///             The actual conversion MAY change between order submission and execution.
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        assets = manager.convertToAssets(address(this), shares);
    }

    /// @inheritdoc IERC7575
    function maxDeposit(address controller) public view returns (uint256 maxAssets) {
        maxAssets = manager.maxDeposit(address(this), controller);
    }

    /// @inheritdoc IERC7540Deposit
    function deposit(uint256 assets, address receiver, address controller) public returns (uint256 shares) {
        _validateController(controller);
        shares = manager.deposit(address(this), assets, receiver, controller);
        emit Deposit(receiver, controller, assets, shares);
    }

    /// @inheritdoc IERC7575
    /// @notice     When claiming deposit requests using deposit(), there can be some precision loss leading to dust.
    ///             It is recommended to use mint() to claim deposit requests instead.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = deposit(assets, receiver, msg.sender);
    }

    /// @inheritdoc IERC7575
    function maxMint(address controller) public view returns (uint256 maxShares) {
        maxShares = manager.maxMint(address(this), controller);
    }

    /// @inheritdoc IERC7540Deposit
    function mint(uint256 shares, address receiver, address controller) public returns (uint256 assets) {
        _validateController(controller);
        assets = manager.mint(address(this), shares, receiver, controller);
        emit Deposit(receiver, controller, assets, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = mint(shares, receiver, msg.sender);
    }

    /// @inheritdoc IERC7575
    function maxWithdraw(address controller) public view returns (uint256 maxAssets) {
        maxAssets = manager.maxWithdraw(address(this), controller);
    }

    /// @inheritdoc IERC7575
    /// @notice     DOES NOT support controller != msg.sender since shares are already transferred on requestRedeem
    function withdraw(uint256 assets, address receiver, address controller) public returns (uint256 shares) {
        _validateController(controller);
        shares = manager.withdraw(address(this), assets, receiver, controller);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @inheritdoc IERC7575
    function maxRedeem(address controller) public view returns (uint256 maxShares) {
        maxShares = manager.maxRedeem(address(this), controller);
    }

    /// @inheritdoc IERC7575
    /// @notice     DOES NOT support controller != msg.sender since shares are already transferred on requestRedeem.
    ///             When claiming redemption requests using redeem(), there can be some precision loss leading to dust.
    ///             It is recommended to use withdraw() to claim redemption requests instead.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _validateController(controller);
        assets = manager.redeem(address(this), shares, receiver, controller);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewDeposit(uint256) external pure returns (uint256) {
        revert();
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewMint(uint256) external pure returns (uint256) {
        revert();
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewWithdraw(uint256) external pure returns (uint256) {
        revert();
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewRedeem(uint256) external pure returns (uint256) {
        revert();
    }

    // --- Event emitters ---
    function onRedeemRequest(address controller, address owner, uint256 shares) public auth {
        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
    }

    function onDepositClaimable(address controller, uint256 assets, uint256 shares) public auth {
        emit DepositClaimable(controller, REQUEST_ID, assets, shares);
    }

    function onRedeemClaimable(address controller, uint256 assets, uint256 shares) public auth {
        emit RedeemClaimable(controller, REQUEST_ID, assets, shares);
    }

    function onCancelDepositClaimable(address controller, uint256 assets) public auth {
        emit CancelDepositClaimable(controller, REQUEST_ID, assets);
    }

    function onCancelRedeemClaimable(address controller, uint256 shares) public auth {
        emit CancelRedeemClaimable(controller, REQUEST_ID, shares);
    }

    // --- Helpers ---
    /// @notice Price of 1 unit of share, quoted in the decimals of the asset.
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** _shareDecimals);
    }

    /// @notice Returns timestamp of the last share price update.
    function priceLastUpdated() external view returns (uint64) {
        return manager.priceLastUpdated(address(this));
    }

    /// @inheritdoc IERC7714
    function isPermissioned(address controller) external view returns (bool) {
        return ITranche(share).checkTransferRestriction(address(0), controller, 0);
    }

    /// @notice Ensures msg.sender can operate on behalf of controller.
    function _validateController(address controller) internal view {
        require(controller == msg.sender || isOperator[controller][msg.sender], "ERC7540Vault/invalid-controller");
    }
}
