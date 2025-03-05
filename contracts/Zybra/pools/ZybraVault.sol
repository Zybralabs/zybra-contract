// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../interfaces/IZRusd.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../interfaces/IERC7540.sol";
import "../interfaces/Iconfigurator.sol";
import "../libraries/TokenDecimalUtils.sol";

interface IPoolManager {
    function getTranchePrice(
        uint64 poolId,
        bytes16 trancheId,
        address asset
    ) external view returns (uint128 price, uint64 computedAt);
}

contract ZybraVault is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using TokenDecimalUtils for uint256;
    IZRusd public ZRusd;
    IPoolManager public poolManager;
    AggregatorV3Interface public priceFeed;
    IERC20 public collateralAsset;
    Iconfigurator public configurator;
    uint256 poolTotalCirculation;

    uint8 private constant USDC_DECIMALS = 6;
    uint8 private constant DEFAULT_DECIMALS = 18;

    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER");
    mapping(address => mapping(address => uint256))
        public UserDepReqVaultCollatAsset;
    mapping(address => mapping(address => uint256))
        public UserVaultTrancheAsset; // User withdraw request tranche asset amount
    mapping(address => mapping(address => uint256)) borrowed;
    mapping(address => uint256) feeStored;
    mapping(address => uint256) feeUpdatedAt;
    mapping(address => bool) public vaultExists;
    mapping(address => bool) public vaultPaused;
    mapping(address => mapping(address => uint256))
        public withdrawalRequestTimestamps;

    event RequestDepositAsset(
        address indexed onBehalfOf,
        address asset,
        address _vault,
        uint256 amount
    );
    event DepositAsset(
        address indexed onBehalfOf,
        address asset,
        address _vault,
        uint256 amount
    );
    event CancelDepositRequest(
        address indexed onBehalfOf,
        address asset,
        address _vault
    );
    event CancelWithdrawRequest(
        address indexed onBehalfOf,
        address asset,
        address _vault,
        uint256 amount
    );
    event RequestWithdrawAsset(
        address indexed sponsor,
        address asset,
        address _vault,
        uint256 amount
    );
    event WithdrawAsset(
        address indexed sponsor,
        address asset,
        address _vault,
        uint256 amount
    );
    event LiquidationRecord(
        address indexed provider,
        address indexed keeper,
        address indexed onBehalfOf,
        uint256 eusdamount,
        uint256 LiquidateAssetAmount,
        uint256 keeperReward
    );

    event RepayingDebt(
        address indexed user,
        address _vault,
        uint256 LZYBRAAmount
    );
    event FeeDistribution(address indexed feeAddress, uint256 feeAmount);

    event VaultPaused(address indexed vault);
    event VaultUnpaused(address indexed vault);
    event PoolManagerUpdated(address indexed newPoolManager);

    modifier onlyExistingVault(address _vault) {
        require(vaultExists[_vault], "Vault does not exist");
        _;
    }

    modifier whenVaultNotPaused(address _vault) {
        require(!vaultPaused[_vault], "Vault operations are paused");
        _;
    }

    // Remove constructor and add initialize function
    function initialize(
        address _priceFeedAddress,
        address _collateralAsset,
        address _lzybra,
        address _poolmanager,
        address _configurator
    ) public initializer {
        // Initialize inherited contracts
        __Ownable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        // Set contract variables
        ZRusd = IZRusd(_lzybra);
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        poolManager = IPoolManager(_poolmanager);
        configurator = Iconfigurator(_configurator);
        collateralAsset = IERC20(_collateralAsset);

        // Setup roles
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(VAULT_MANAGER_ROLE, msg.sender);
    }

    // Add UUPS required function
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /**
     * @notice Request to Take part in Centrifuge Pool, and mint LZybra
     * Emits a `DepositAsset` event.
     *
     * Requirements:
     * - `assetAmount` Must be higher than 0.
     * - `mintAmount` Send 0 if doesn't mint ZRusd
     * - `_vault` address of the Centrifuge Vault.
     */
    function requestDeposit(
        uint256 assetAmount,
        address _vault
    ) external virtual onlyExistingVault(_vault) nonReentrant {
        require(assetAmount > 0, "Deposit should not be less than 0");
        UserDepReqVaultCollatAsset[_vault][msg.sender] += assetAmount;
        _approveIfNeeded(address(collateralAsset), _vault, assetAmount);
        collateralAsset.safeTransferFrom(
            msg.sender,
            address(this),
            assetAmount
        );
        IERC7540Vault vault_ = IERC7540Vault(_vault);

        vault_.requestDeposit(assetAmount, msg.sender, address(this));
        emit RequestDepositAsset(
            msg.sender,
            address(collateralAsset),
            _vault,
            assetAmount
        );
    }

    /**
     * @notice Deposit USDT, update the interest distribution, can mint LZybra directly
     * Emits a `DepositAsset` event.
     *
     * Requirements:
     * - `assetAmount` Must be higher than 0.
     * - `mintAmount` Send 0 if doesn't mint ZRusd
     * - `_vault` address of the Centrifuge Vault.
     */
    function deposit(
        address _vault,
        uint256 mintAmount,
        uint256 minTrancheReceived
    )
        external
        virtual
        onlyExistingVault(_vault)
        whenVaultNotPaused(_vault)
        nonReentrant
    {
        IERC7540Vault vault_ = IERC7540Vault(_vault);

        // Get claimable deposit amount for user
        uint256 assetAmount = vault_.claimableDepositRequest(0, msg.sender);
        require(assetAmount > 0, "No claimable deposit");

        // Execute deposit in vault to receive shares
        uint256 trancheReceived = vault_.deposit(
            assetAmount,
            address(this),
            msg.sender
        );
        require(trancheReceived >= minTrancheReceived, "Slippage too high");

        // Update user's asset balances
        UserVaultTrancheAsset[_vault][msg.sender] += trancheReceived;
        UserDepReqVaultCollatAsset[_vault][msg.sender] = 0;

        // Mint ZRusd tokens if requested
        if (mintAmount > 0) {
            _mintLZYBRA(msg.sender, _vault, msg.sender, mintAmount);
            _checkHealth(msg.sender, _vault);
        }

        emit DepositAsset(
            msg.sender,
            address(collateralAsset),
            _vault,
            assetAmount
        );
    }

    /**
     * @notice Withdraw collateral assets to an address
     * Emits a `WithdrawAsset` event.
     *
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `tranche_amount` Must be higher than 0.
     * - `_vault` address of the Centrifuge Vault.
     * @dev Withdraw collateral. Check user’s collateral ratio after withdrawal, should be higher than `safeCollateralRatio`
     */
    function withdraw(
        address _vault
    ) external virtual onlyExistingVault(_vault) nonReentrant {
        _withdraw(msg.sender, _vault);
    }

    /**
     * @notice Burn the amount of ZRusd and payback the amount of minted ZRusd
     * Emits a `Burn` event.
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `tranche_amount` Must be higher than 0.
     * - `_vault` address of the Centrifuge Vault.
     * @dev Calling the internal`_repay`function.
     */

    function requestWithdraw(
        uint256 trancheAmount,
        address onBehalfOf,
        address _vault
    )
        external
        virtual
        onlyExistingVault(_vault)
        whenVaultNotPaused(_vault)
        nonReentrant
    {
        require(onBehalfOf != address(0), "Invalid beneficiary address");
        require(trancheAmount > 0, "Amount must be greater than 0");
        require(
            UserVaultTrancheAsset[_vault][msg.sender] >= trancheAmount,
            "Insufficient assets"
        );

        // Calculate ZRusd debt to repay based on tranche amount
        uint256 zrusdAmount = calc_share(trancheAmount, _vault);

        // Get vault instance
        IERC7540Vault vault_ = IERC7540Vault(_vault);

        // Approve vault to use tranche shares
        _approveIfNeeded(vault_.share(), address(vault_), trancheAmount);

        // Request redemption of shares
        vault_.requestRedeem(trancheAmount, msg.sender, address(this));

        // Record withdrawal request timestamp
        withdrawalRequestTimestamps[msg.sender][_vault] = block.timestamp;

        // Repay ZRusd debt
        _repay(msg.sender, _vault, onBehalfOf, zrusdAmount);

        emit RequestWithdrawAsset(
            msg.sender,
            address(collateralAsset),
            _vault,
            trancheAmount
        );
    }

    /**
     * @notice Cancel Deposit Request
     * Emits a `Burn` event.
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     * - `_vault` address of the Centrifuge Vault.
     * @dev Calling the internal`_repay`function.
     */

    function cancelWithdrawRequest(
        address _vault
    ) external virtual onlyExistingVault(_vault) {
        require(
            UserVaultTrancheAsset[msg.sender][_vault] != 0,
            "there is no request in process"
        );
        IERC7540Vault vault_ = IERC7540Vault(_vault);
        vault_.cancelRedeemRequest(0, msg.sender);
        emit CancelDepositRequest(msg.sender, vault_.asset(), _vault);
    }

    /**
     * @notice Cancel Deposit Request
     * Emits a `Burn` event.
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     * - `_vault` address of the Centrifuge Vault.
     * @dev Calling the internal`_repay`function.
     */

    function cancelDepositRequest(
        address _vault
    ) external virtual onlyExistingVault(_vault) {
        require(
            UserDepReqVaultCollatAsset[msg.sender][_vault] != 0,
            "there is no request in process"
        );
        IERC7540Vault vault_ = IERC7540Vault(_vault);
        vault_.cancelDepositRequest(0, msg.sender);
        emit CancelDepositRequest(msg.sender, vault_.asset(), _vault);
    }

    /**
     * @notice Claim Cancel Deposit Request
     * Emits a `Burn` event.
     * Requirements:
     * - `onBehalfOf` cannot be the zero address.
     * - `amount` Must be higher than 0.
     * - `_vault` address of the Centrifuge Vault.
     * @dev Calling the internal`_repay`function.
     */

    function ClaimcancelDepositRequest(
        address _vault
    ) external virtual onlyExistingVault(_vault) {
        IERC7540Vault vault_ = IERC7540Vault(_vault);
        uint256 claimableAsset = vault_.claimableCancelDepositRequest(
            0,
            msg.sender
        );
        require(claimableAsset > 0, "No deposit available to claim");
        collateralAsset.safeTransferFrom(
            msg.sender,
            address(this),
            claimableAsset
        );
        //make sure
        UserDepReqVaultCollatAsset[_vault][msg.sender] -= claimableAsset;
    }

    /**
     * @notice add New Centrifuge Vault
     * Requirements:
     * - `_vault` address of the Centrifuge Vault.
     * @dev only Owner can call this.
     */

    function addVault(address _vault) external onlyRole(VAULT_MANAGER_ROLE) {
        require(!vaultExists[_vault], "VAE");
        require(
            IERC7540Vault(_vault).supportsInterface(type(IERC7540).interfaceId),
            "NVA"
        );
        vaultExists[_vault] = true;
    }

    function updatePoolManager(
        address _newPoolManager
    ) external onlyRole(VAULT_MANAGER_ROLE) {
        require(_newPoolManager != address(0), "Invalid pool manager address");
        poolManager = IPoolManager(_newPoolManager);

        emit PoolManagerUpdated(_newPoolManager);
    }

    /**
     * @notice Remove Centrifuge Vault
     * Requirements:
     * - `_vault` address of the Centrifuge Vault.
     * @dev only Owner can call this.
     */

    function removeVault(address _vault) external onlyRole(VAULT_MANAGER_ROLE) {
        require(vaultExists[_vault], "VE");
        delete vaultExists[_vault];
    }

    /**
     * @notice Keeper liquidates borrowers whose collateral ratio is below badCollateralRatio, using ZRusd provided by Liquidation Provider.
     *
     * Requirements:
     * - onBehalfOf Collateral Ratio should be below badCollateralRatio
     * - assetAmount should be less than 50% of collateral
     * - provider should authorize Zybra to utilize ZRusd
     * - `_vault` address of the Centrifuge Vault.
     * @dev After liquidation, borrower's debt is reduced by assetAmount * assetPrice, providers and keepers can receive up to an additional 10% liquidation reward.
     */

    function liquidation(
        address provider,
        address _vault,
        address onBehalfOf,
        uint256 assetAmount
    )
        external
        virtual
        nonReentrant
        onlyExistingVault(_vault)
        whenVaultNotPaused(_vault)
    {
        // Get vault instance and token information
        IERC7540Vault vault_ = IERC7540Vault(_vault);
        address trancheTokenAddress = vault_.share();

        // Get liquidation status and collateral ratio for the user
        (
            bool shouldLiquidate,
            uint256 onBehalfOfCollateralRatio
        ) = getCollateralRatioAndLiquidationInfo(onBehalfOf, _vault);

        require(
            shouldLiquidate,
            "Collateral ratio is above liquidation threshold"
        );

        // Get user's total assets and normalize for comparison (tranche tokens might be 18 decimals)
        uint256 userAssets = UserVaultTrancheAsset[_vault][onBehalfOf];
        uint256 normalizedUserAssets = TokenDecimalUtils.normalizeToDecimals18(
            userAssets,
            trancheTokenAddress,
            DEFAULT_DECIMALS
        );

        // Normalize the liquidation amount for comparison
        uint256 normalizedAssetAmount = TokenDecimalUtils.normalizeToDecimals18(
            assetAmount,
            trancheTokenAddress,
            DEFAULT_DECIMALS
        );

        // Ensure liquidation amount is no more than 50% of collateral (using normalized values)
        require(
            normalizedAssetAmount * 2 <= normalizedUserAssets,
            "A max of 50% collateral can be liquidated"
        );

        // Check provider authorization to transfer ZRusd for liquidation
        require(
            ZRusd.allowance(provider, address(this)) >= ZRusdAmount ||
                msg.sender == provider,
            "Provider should authorize ZRusd for liquidation"
        );

        // Get price (already in 18 decimals from getTrancheAssetPrice)
        uint256 assetPrice = getTrancheAssetPrice(_vault);

        // Calculate ZRusd amount - both normalized asset amount and price are in 18 decimals
        uint256 ZRusdAmount = (normalizedAssetAmount * assetPrice) / 1e18;

        // Repay the user's debt with the calculated amount
        _repay(provider, _vault, onBehalfOf, ZRusdAmount);

        // Determine collateral to seize based on health ratio
        uint256 reducedAsset = assetAmount; // Original amount in tranche token decimals

        // Calculate liquidation bonus if applicable (maintain original token decimals)
        if (
            onBehalfOfCollateralRatio > 1e20 &&
            onBehalfOfCollateralRatio < 11e19
        ) {
            // Scale reducedAsset based on collateral ratio
            uint256 scaledAmount = (assetAmount * onBehalfOfCollateralRatio) /
                1e20;
            reducedAsset = scaledAmount > userAssets
                ? userAssets
                : scaledAmount;
        } else if (onBehalfOfCollateralRatio >= 11e19) {
            // Apply 10% bonus (1.1x)
            uint256 bonusAmount = (assetAmount * 11) / 10;
            reducedAsset = bonusAmount > userAssets ? userAssets : bonusAmount;
        }

        // Calculate keeper reward if applicable
        uint256 reward2keeper = 0;
        uint256 keeperRatio = configurator.vaultKeeperRatio(address(this));

        if (
            msg.sender != provider &&
            onBehalfOfCollateralRatio >= 1e20 + keeperRatio * 1e18
        ) {
            // Calculate keeper reward in tranche token decimals
            reward2keeper = (assetAmount * keeperRatio) / 100;

            // Ensure total liquidation doesn't exceed user's assets
            if (reducedAsset + reward2keeper > userAssets) {
                uint256 excess = (reducedAsset + reward2keeper) - userAssets;
                // Reduce keeper reward first
                if (excess <= reward2keeper) {
                    reward2keeper -= excess;
                } else {
                    // If excess is greater than reward, adjust both
                    reward2keeper = 0;
                    reducedAsset = userAssets;
                }
            }

            // Transfer reward to keeper if applicable
            if (reward2keeper > 0) {
                IERC20(trancheTokenAddress).safeTransfer(
                    msg.sender,
                    reward2keeper
                );
            }
        }

        // Transfer remaining collateral to provider
        uint256 providerAmount = reducedAsset > reward2keeper
            ? reducedAsset - reward2keeper
            : 0;
        if (providerAmount > 0) {
            IERC20(trancheTokenAddress).safeTransfer(provider, providerAmount);
        }

        // Update user's asset balance
        UserVaultTrancheAsset[_vault][onBehalfOf] -= (reducedAsset +
            reward2keeper);

        // Emit liquidation event
        emit LiquidationRecord(
            provider,
            msg.sender,
            onBehalfOf,
            ZRusdAmount,
            reducedAsset,
            reward2keeper
        );
    }

    function repayingDebt(
        address provider,
        address _vault,
        uint256 lzybra_amount
    ) external virtual {
        // Ensure repayment amount does not exceed provider's current debt
        require(
            borrowed[_vault][provider] >= lzybra_amount,
            "Repayment amount exceeds provider's debt"
        );

        // Retrieve the provider's collateral ratio and liquidation status
        (
            ,
            uint256 providerCollateralRatio
        ) = getCollateralRatioAndLiquidationInfo(provider, _vault);

        // Ensure the collateral ratio is healthy (at least 100%) for debt repayment
        require(
            providerCollateralRatio >=
                configurator.getSafeCollateralRatio(address(this))
        );

        // Execute the repayment
        _repay(provider, _vault, provider, lzybra_amount);

        emit RepayingDebt(msg.sender, _vault, lzybra_amount);
    }

    function getCollateralRatioAndLiquidationInfo(
        address user,
        address _vault
    ) public view returns (bool shouldLiquidate, uint256 collateralRatio) {
        require(vaultExists[_vault], "Vault does not exist");

        // Get vault instance
        IERC7540Vault vault_ = IERC7540Vault(_vault);
        address trancheTokenAddress = vault_.share();

        // Get the user's tranche asset amount and normalize to 18 decimals
        uint256 userCollateralAmount = UserVaultTrancheAsset[_vault][user];
        uint256 normalizedCollateralAmount = _normalizeTokenAmount(
            userCollateralAmount,
            trancheTokenAddress
        );

        // Get price (already in 18 decimals)
        uint256 trancheAssetPrice = getTrancheAssetPrice(_vault);

        // Calculate the USD value of the collateral (in 18 decimals)
        uint256 collateralValueInUSD = (normalizedCollateralAmount *
            trancheAssetPrice) / 1e18;

        // Get the user's total borrowed amount (always in 18 decimals)
        uint256 userDebtAmount = getBorrowed(_vault, user);

        // Avoid division by zero
        if (userDebtAmount == 0) {
            return (false, type(uint256).max);
        }

        // Calculate the collateral ratio (normalize to 1e18)
        collateralRatio = (collateralValueInUSD * 1e18) / userDebtAmount;

        // Check against liquidation threshold
        uint256 badCollateralRatio = configurator.getBadCollateralRatio(
            address(this)
        );
        shouldLiquidate = collateralRatio < badCollateralRatio;
    }

    /**
     * @dev Refresh LBR reward before adding providers debt. Refresh Zybra generated service fee before adding totalSupply. Check providers collateralRatio cannot below `safeCollateralRatio`after minting.
     */
    function _mintLZYBRA(
        address _provider,
        address _vault,
        address _onBehalfOf,
        uint256 _mintAmount
    ) internal virtual {
        require(
            poolTotalCirculation + _mintAmount <=
                configurator.mintVaultMaxSupply(address(this)),
            "ESL"
        );
        _updateFee(_provider, _vault);

        borrowed[_vault][_provider] += _mintAmount;

        ZRusd.mint(_onBehalfOf, _mintAmount);
        poolTotalCirculation += _mintAmount;
    }

    /**
     * @notice Burn _provideramount ZRusd to payback minted ZRusd for _onBehalfOf.
     *
     * @dev rePAY the User debt so the Collateral Ratio for user is mantained.
     */
    function _repay(
        address _provider,
        address _vault,
        address _onBehalfOf,
        uint256 _amount
    ) internal virtual {
        // Use safeTransferFrom instead of transferFrom
        ZRusd.safeTransferFrom(_provider, address(this), _amount);

        // For burn, we need to ensure there's a way to check success
        bool burnSuccess = ZRusd.burn(_provider, _amount);
        require(burnSuccess, "Burn operation failed");

        // Update balances
        borrowed[_vault][_onBehalfOf] -= _amount;
        poolTotalCirculation -= _amount;
    }

    function _withdraw(address _provider, address _vault) internal virtual {
        IERC7540Vault vault_ = IERC7540Vault(_vault);
        address trancheTokenAddress = vault_.share();

        // Verify minimum time has passed to prevent front-running
        uint256 requestTimestamp = withdrawalRequestTimestamps[_provider][
            _vault
        ];
        require(requestTimestamp > 0, "No withdrawal request found");

        // Check if there's a claimable redeem request
        uint256 claimableShares = vault_.claimableRedeemRequest(0, _provider);
        require(claimableShares > 0, "No claimable redemption");

        // Execute redemption to receive assets
        uint256 assetsReceived = vault_.redeem(
            claimableShares,
            address(this),
            _provider
        );

        // Check health if user still has debt
        if (getBorrowed(_vault, _provider) > 0) {
            _checkHealth(_provider, _vault);
        }

        // Update fee and get fee amount
        _updateFee(_provider, _vault);
        uint256 fee = feeStored[_provider];

        // Update user's tranche balance
        UserVaultTrancheAsset[_vault][_provider] -= claimableShares;

        // Convert received assets to proper decimals if needed
        uint256 normalizedAssetsReceived = TokenDecimalUtils
            .normalizeToDecimals18(
                assetsReceived,
                address(collateralAsset),
                USDC_DECIMALS
            );
        uint256 normalizedFee = TokenDecimalUtils.normalizeToDecimals18(
            fee,
            address(collateralAsset),
            USDC_DECIMALS
        );

        // Calculate amount to transfer in 18 decimals
        uint256 normalizedAmountToTransfer = normalizedAssetsReceived >
            normalizedFee
            ? normalizedAssetsReceived - normalizedFee
            : 0;

        // Convert back to collateral asset decimals
        uint256 amountToTransfer = TokenDecimalUtils.denormalizeFromDecimals18(
            normalizedAmountToTransfer,
            address(collateralAsset),
            USDC_DECIMALS
        );

        collateralAsset.safeTransfer(_provider, amountToTransfer);

        emit WithdrawAsset(
            _provider,
            address(collateralAsset),
            _vault,
            amountToTransfer
        );
    }

    /**
     * @dev Approve tokens only if allowance is insufficient.
     */
    function _approveIfNeeded(
        address asset,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = IERC20(asset).allowance(
            address(this),
            spender
        );
        if (currentAllowance < amount) {
            bool success = IERC20(asset).approve(
                spender,
                (amount - currentAllowance)
            );
            require(success, "Approval failed");
        }
    }

    function pauseVault(address _vault) external onlyRole(VAULT_MANAGER_ROLE) {
        require(vaultExists[_vault], "Vault does not exist");
        vaultPaused[_vault] = true;
        emit VaultPaused(_vault);
    }

    function unpauseVault(
        address _vault
    ) external onlyRole(VAULT_MANAGER_ROLE) {
        require(vaultExists[_vault], "Vault does not exist");
        vaultPaused[_vault] = false;
        emit VaultUnpaused(_vault);
    }
    /**
     * @dev Get USD value of current collateral asset and minted ZRusd through price oracle / Collateral asset USD value must higher than safe Collateral Ratio.
     */
    function _checkHealth(address user, address _vault) internal view {
        (
            bool shouldLiquidate,
            uint256 collateralRatio
        ) = getCollateralRatioAndLiquidationInfo(user, _vault);

        uint256 safeCollateralRatio = configurator.getSafeCollateralRatio(
            address(this)
        );
        require(
            collateralRatio >= safeCollateralRatio,
            "Collateral ratio is below safe threshold"
        );
    }

    // Replace the existing _updateFee function with this:
    function _updateFee(address user, address _vault) internal {
        if (block.timestamp > feeUpdatedAt[user]) {
            // Calculate only the fee for the period since last update
            uint256 timeElapsed = block.timestamp - feeUpdatedAt[user];
            uint256 newFee = (borrowed[_vault][user] *
                configurator.vaultMintFeeApy(address(this)) *
                timeElapsed) /
                (86_400 * 365) /
                10_000;

            // Add the new fee to the stored amount
            feeStored[user] += newFee;

            // Update the timestamp to prevent double-charging
            feeUpdatedAt[user] = block.timestamp;
        }
    }

    // Simplify _newFee to just calculate the fee amount without state changes
    function _newFee(
        address user,
        address _vault
    ) internal view returns (uint256) {
        if (feeUpdatedAt[user] == 0 || feeUpdatedAt[user] >= block.timestamp) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - feeUpdatedAt[user];
        return
            (borrowed[_vault][user] *
                configurator.vaultMintFeeApy(address(this)) *
                timeElapsed) /
            (86_400 * 365) /
            10_000;
    }

    /**
     * @dev Returns the current borrowing amount for the user, including borrowed[_vault] shares and accumulated fees.
     * @param user The address of the user.
     * @return The total borrowing amount for the user.
     */
    function getBorrowed(
        address _vault,
        address user
    ) public view returns (uint256) {
        return borrowed[_vault][user] + feeStored[user] + _newFee(user, _vault);
    }

    function getPoolTotalCirculation() external view returns (uint256) {
        return poolTotalCirculation;
    }

    function isVault(address _vault) external view returns (bool) {
        return vaultExists[_vault];
    }

    function getAsset(address _vault) external view returns (address) {
        IERC7540Vault vault_ = IERC7540Vault(_vault);
        return vault_.asset();
    }

    function getUserTrancheAsset(
        address vault,
        address user
    ) external view returns (uint256) {
        return UserVaultTrancheAsset[vault][user];
    }
    function getVaultType() external pure returns (uint8) {
        return 0;
    }

    function calc_share(
        uint256 amount,
        address _vault
    ) public view returns (uint256) {
        uint256 borrowedAmount = borrowed[_vault][msg.sender];
        uint256 userAssetAmount = UserVaultTrancheAsset[_vault][msg.sender];
        require(userAssetAmount > 0, "UserAsset must be greater than zero");

        // Get vault instance
        IERC7540Vault vault_ = IERC7540Vault(_vault);
        address trancheTokenAddress = vault_.share();

        // Normalize values to 18 decimals for calculation
        uint256 normalizedAmount = TokenDecimalUtils.normalizeToDecimals18(
            amount,
            trancheTokenAddress,
            DEFAULT_DECIMALS
        );
        uint256 normalizedUserAssetAmount = TokenDecimalUtils
            .normalizeToDecimals18(
                userAssetAmount,
                trancheTokenAddress,
                DEFAULT_DECIMALS
            );

        // Calculate debt share with proper decimal handling
        uint256 zrusdAmount = (borrowedAmount * normalizedAmount) /
            normalizedUserAssetAmount;

        return zrusdAmount;
    }

    function getCollateralAssetPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    function getTrancheAssetPrice(
        address _vault
    ) public view returns (uint256) {
        IERC7540Vault vault_ = IERC7540Vault(_vault);
        (uint128 latestPrice, uint64 computedAt) = poolManager.getTranchePrice(
            vault_.poolId(),
            vault_.trancheId(),
            vault_.asset()
        );

        require(latestPrice > 0, "ICP");
        require(block.timestamp - computedAt < 24 hours, "CPO");

        // Make sure price is normalized to 18 decimals
        // Note: Assuming tranche price from poolManager is already in 18 decimals
        return latestPrice;
    }
}
