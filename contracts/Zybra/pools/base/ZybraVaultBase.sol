// // SPDX-License-Identifier: BUSL-1.1

// pragma solidity ^0.8.17;

// import "../../interfaces/ILZYBRA.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
// import "lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
// import "lib/openzeppelin-contracts-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
// import "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
// import "lib/openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
// import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
// import "../../interfaces/IERC7540.sol";
// import "../../interfaces/Iconfigurator.sol";

// interface IPoolManager {
//     function getTranchePrice(
//         uint64 poolId,
//         bytes16 trancheId,
//         address asset
//     ) external view returns (uint128 price, uint64 computedAt);
// }

//  contract ZybraVaultBase Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, AccessControlUpgradeable {
//     using SafeERC20 for IERC20;
//     ILZYBRA public immutable Lzybra;
//     IPoolManager public immutable poolManager;
//     AggregatorV3Interface public immutable priceFeed;
//     IERC20 public immutable collateralAsset;
//     Iconfigurator public configurator;
//     uint256 poolTotalCirculation;

//     bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER");
//     mapping(address => mapping(address => uint256))
//         public UserDepReqVaultCollatAsset;
//     mapping(address => mapping(address => uint256))
//         public UserVaultTrancheAsset; // User withdraw request tranche asset amount
//     mapping(address => mapping(address => uint256)) borrowed;
//     mapping(address => uint256) feeStored;
//     mapping(address => uint256) feeUpdatedAt;
//     mapping(address => bool) public vaultExists;




//     ///
//     //Debugging
//     ////////////
// event DebugUint(string message, uint256 value);
// event DebugBool(string message, bool value);

// //////////////////////////////

//     event RequestDepositAsset(
//         address indexed onBehalfOf,
//         address asset,
//         address _vault,
//         uint256 amount
//     );
//     event DepositAsset(
//         address indexed onBehalfOf,
//         address asset,
//         address _vault,
//         uint256 amount
//     );
//     event CancelDepositRequest(
//         address indexed onBehalfOf,
//         address asset,
//         address _vault
//     );
//     event CancelWithdrawRequest(
//         address indexed onBehalfOf,
//         address asset,
//         address _vault,
//         uint256 amount
//     );
//     event RequestWithdrawAsset(
//         address indexed sponsor,
//         address asset,
//         address _vault,
//         uint256 amount
//     );
//     event WithdrawAsset(
//         address indexed sponsor,
//         address asset,
//         address _vault,
//         uint256 amount
//     );
//     event LiquidationRecord(
//         address indexed provider,
//         address indexed keeper,
//         address indexed onBehalfOf,
//         uint256 eusdamount,
//         uint256 LiquidateAssetAmount,
//         uint256 keeperReward
//     );

//     event RepayingDebt(
//         address indexed user,
//         address _vault,
//         uint256 LZYBRAAmount
//     );
//     event FeeDistribution(address indexed feeAddress, uint256 feeAmount);

//     modifier onlyExistingVault(address _vault) {
//         require(vaultExists[_vault], "Vault does not exist");
//         _;
//     }

//   // Remove constructor and add initialize function
// function initialize(
//     address _priceFeedAddress,
//     address _collateralAsset,
//     address _lzybra,
//     address _poolmanager, 
//     address _configurator
// ) public initializer {
//     // Initialize inherited contracts
//     __Ownable_init();
//     __ReentrancyGuard_init();
//     __AccessControl_init();
//     __UUPSUpgradeable_init();

//     // Set contract variables
//     Lzybra = ILZYBRA(_lzybra);
//     priceFeed = AggregatorV3Interface(_priceFeedAddress);
//     poolManager = IPoolManager(_poolmanager);
//     configurator = Iconfigurator(_configurator);
//     collateralAsset = IERC20(_collateralAsset);

//     // Setup roles
//     _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
//     _setupRole(VAULT_MANAGER_ROLE, msg.sender);
// }

// // Add UUPS required function
// function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

//     /**
//      * @notice Request to Take part in Centrifuge Pool, and mint LZybra
//      * Emits a `DepositAsset` event.
//      *
//      * Requirements:
//      * - `assetAmount` Must be higher than 0.
//      * - `mintAmount` Send 0 if doesn't mint Lzybra
//      * - `_vault` address of the Centrifuge Vault.
//      */
//     function requestDeposit(
//         uint256 assetAmount,
//         address _vault
//     ) external virtual onlyExistingVault(_vault) nonReentrant {
//         require(assetAmount >= 0, "Deposit should not be less than 0");
//         UserDepReqVaultCollatAsset[_vault][msg.sender] += assetAmount;
//         _approveIfNeeded(address(collateralAsset), _vault, assetAmount);
//         collateralAsset.safeTransferFrom(
//             msg.sender,
//             address(this),
//             assetAmount
//         );
//         IERC7540Vault vault_ = IERC7540Vault(_vault);

//         vault_.requestDeposit(assetAmount, msg.sender, address(this));
//         emit RequestDepositAsset(
//             msg.sender,
//             address(collateralAsset),
//             _vault,
//             assetAmount
//         );
//     }

//     /**
//      * @notice Deposit USDT, update the interest distribution, can mint LZybra directly
//      * Emits a `DepositAsset` event.
//      *
//      * Requirements:
//      * - `assetAmount` Must be higher than 0.
//      * - `mintAmount` Send 0 if doesn't mint Lzybra
//      * - `_vault` address of the Centrifuge Vault.
//      */
//     function deposit(
//         address _vault,
//         uint256 mintAmount
//     ) external virtual onlyExistingVault(_vault) nonReentrant {
//         IERC7540Vault vault_ = IERC7540Vault(_vault);
//         uint256 assetAmount = vault_.claimableDepositRequest(0, msg.sender);
//         require(assetAmount > 0, "Deposit should not be less than 0");
//         UserVaultTrancheAsset[_vault][msg.sender] += vault_.deposit(
//             assetAmount,
//             address(this),
//             msg.sender
//         );
//         UserDepReqVaultCollatAsset[_vault][msg.sender] = 0;

//         _mintLZYBRA(msg.sender, _vault, msg.sender, mintAmount);
//         _checkHealth(msg.sender, _vault);

//         emit DepositAsset(
//             msg.sender,
//             address(collateralAsset),
//             _vault,
//             assetAmount
//         );
//     }

//     /**
//      * @notice Withdraw collateral assets to an address
//      * Emits a `WithdrawAsset` event.
//      *
//      * Requirements:
//      * - `onBehalfOf` cannot be the zero address.
//      * - `tranche_amount` Must be higher than 0.
//      * - `_vault` address of the Centrifuge Vault.
//      * @dev Withdraw collateral. Check user’s collateral ratio after withdrawal, should be higher than `safeCollateralRatio`
//      */
//     function withdraw(
//         address _vault
//     ) external virtual onlyExistingVault(_vault) nonReentrant {
//         _withdraw(msg.sender, _vault);
//     }

//     /**
//      * @notice Burn the amount of Lzybra and payback the amount of minted Lzybra
//      * Emits a `Burn` event.
//      * Requirements:
//      * - `onBehalfOf` cannot be the zero address.
//      * - `tranche_amount` Must be higher than 0.
//      * - `_vault` address of the Centrifuge Vault.
//      * @dev Calling the internal`_repay`function.
//      */

//     function requestWithdraw(
//         uint256 tranche_amount,
//         address onBehalfOf,
//         address _vault
//     ) external virtual onlyExistingVault(_vault) nonReentrant {
//         require(onBehalfOf != address(0), "Invalid beneficiary address");
//         require(tranche_amount != 0, "Invalid tranche amount");

//         // Check if the user has enough assets in the vault for the requested amount
//         require(
//             UserVaultTrancheAsset[_vault][msg.sender] != 0 &&
//                 UserVaultTrancheAsset[_vault][msg.sender] >= tranche_amount,
//             "Insufficient assets for withdrawal"
//         );

//         // Proceed with the withdrawal if the collateral check passes
//         uint256 lzybra_amount = calc_share(tranche_amount, _vault);
//         IERC7540Vault vault_ = IERC7540Vault(_vault);
//         _approveIfNeeded(vault_.share(), address(vault_), tranche_amount);
//         vault_.requestRedeem(tranche_amount, msg.sender, address(this));

//         // Repay the user's debt with the calculated LZYBRA amount
//         _repay(msg.sender, _vault, onBehalfOf, lzybra_amount);

//         emit RequestWithdrawAsset(
//             msg.sender,
//             address(collateralAsset),
//             _vault,
//             tranche_amount
//         );
//     }

//     /**
//      * @notice Cancel Deposit Request
//      * Emits a `Burn` event.
//      * Requirements:
//      * - `onBehalfOf` cannot be the zero address.
//      * - `amount` Must be higher than 0.
//      * - `_vault` address of the Centrifuge Vault.
//      * @dev Calling the internal`_repay`function.
//      */

//     function cancelWithdrawRequest(
//         address _vault
//     ) external virtual onlyExistingVault(_vault) {
//         require(
//             UserVaultTrancheAsset[msg.sender][_vault] != 0,
//             "there is no request in process"
//         );
//         IERC7540Vault vault_ = IERC7540Vault(_vault);
//         vault_.cancelRedeemRequest(0, msg.sender);
//         emit CancelDepositRequest(msg.sender, vault_.asset(), _vault);
//     }

//     /**
//      * @notice Cancel Deposit Request
//      * Emits a `Burn` event.
//      * Requirements:
//      * - `onBehalfOf` cannot be the zero address.
//      * - `amount` Must be higher than 0.
//      * - `_vault` address of the Centrifuge Vault.
//      * @dev Calling the internal`_repay`function.
//      */

//     function cancelDepositRequest(
//         address _vault
//     ) external virtual onlyExistingVault(_vault) {
//         require(
//             UserDepReqVaultCollatAsset[msg.sender][_vault] != 0,
//             "there is no request in process"
//         );
//         IERC7540Vault vault_ = IERC7540Vault(_vault);
//         vault_.cancelDepositRequest(0, msg.sender);
//         emit CancelDepositRequest(msg.sender, vault_.asset(), _vault);
//     }

//     /**
//      * @notice Claim Cancel Deposit Request
//      * Emits a `Burn` event.
//      * Requirements:
//      * - `onBehalfOf` cannot be the zero address.
//      * - `amount` Must be higher than 0.
//      * - `_vault` address of the Centrifuge Vault.
//      * @dev Calling the internal`_repay`function.
//      */

//     function ClaimcancelDepositRequest(
//         address _vault
//     ) external virtual onlyExistingVault(_vault) {
//         IERC7540Vault vault_ = IERC7540Vault(_vault);
//         uint256 claimableAsset = vault_.claimableCancelDepositRequest(
//             0,
//             msg.sender
//         );
//         require(claimableAsset > 0, "No deposit available to claim");
//         collateralAsset.safeTransferFrom(
//             msg.sender,
//             address(this),
//             claimableAsset
//         );
//         //make sure
//         UserDepReqVaultCollatAsset[_vault][msg.sender] -= claimableAsset;
//     }

//     /**
//      * @notice add New Centrifuge Vault
//      * Requirements:
//      * - `_vault` address of the Centrifuge Vault.
//      * @dev only Owner can call this.
//      */

//     function addVault(address _vault) external onlyRole(VAULT_MANAGER_ROLE) {
//         require(!vaultExists[_vault], "Vault already exists");
//         vaultExists[_vault] = true;
//     }

//     /**
//      * @notice Remove Centrifuge Vault
//      * Requirements:
//      * - `_vault` address of the Centrifuge Vault.
//      * @dev only Owner can call this.
//      */

//     function removeVault(address _vault) external onlyRole(VAULT_MANAGER_ROLE) {
//         require(vaultExists[_vault], "Vault does not exist");
//         delete vaultExists[_vault];
//     }

//     /**
//      * @notice Keeper liquidates borrowers whose collateral ratio is below badCollateralRatio, using Lzybra provided by Liquidation Provider.
//      *
//      * Requirements:
//      * - onBehalfOf Collateral Ratio should be below badCollateralRatio
//      * - assetAmount should be less than 50% of collateral
//      * - provider should authorize Zybra to utilize Lzybra
//      * - `_vault` address of the Centrifuge Vault.
//      * @dev After liquidation, borrower's debt is reduced by assetAmount * assetPrice, providers and keepers can receive up to an additional 10% liquidation reward.
//      */

//     function liquidation(
//         address provider,
//         address _vault,
//         address onBehalfOf,
//         uint256 assetAmount
//     ) external virtual onlyExistingVault(_vault) {
//         // Get liquidation status and collateral ratio for the user
//         (
//             bool shouldLiquidate,
//             uint256 onBehalfOfCollateralRatio
//         ) = getCollateralRatioAndLiquidationInfo(onBehalfOf, _vault);

//         require(
//             shouldLiquidate,
//             "Collateral ratio is above liquidation threshold"
//         );

//         // Validate the amount to be liquidated, ensuring it's no more than 50% of the collateral
//         require(
//             assetAmount * 2 <= UserVaultTrancheAsset[_vault][onBehalfOf],
//             "A max of 50% collateral can be liquidated"
//         );

//         // Verify provider authorization to transfer LZYBRA for liquidation
//         require(
//             Lzybra.allowance(provider, address(this)) != 0 ||
//                 msg.sender == provider,
//             "Provider should authorize LZYBRA for liquidation"
//         );

//         // Calculate the equivalent LZYBRA amount for the specified asset amount
//         uint256 assetPrice = getTrancheAssetPrice(_vault);
//         uint256 LZYBRAAmount = (assetAmount * assetPrice) / 1e18;

//         // Repay the user's debt with the calculated LZYBRA amount
//         _repay(provider, _vault, onBehalfOf, LZYBRAAmount);

//         // Determine the adjusted collateral to be seized based on the collateral ratio
//         uint256 reducedAsset = assetAmount;
//         if (
//             onBehalfOfCollateralRatio > 1e20 &&
//             onBehalfOfCollateralRatio < 11e19
//         ) {
//             reducedAsset = (assetAmount * onBehalfOfCollateralRatio) / 1e20;
//         }
//         if (onBehalfOfCollateralRatio >= 11e19) {
//             reducedAsset = (assetAmount * 11) / 10;
//         }

//         // Calculate the keeper's reward if applicable
//         uint256 reward2keeper;
//         uint256 keeperRatio = 10; // 10% of the liquidated amount
//         if (
//             msg.sender != provider &&
//             onBehalfOfCollateralRatio >= 1e20 + keeperRatio * 1e18
//         ) {
//             reward2keeper = (assetAmount * keeperRatio) / 100;
//             IERC20(IERC7540Vault(_vault).share()).safeTransfer(msg.sender, reward2keeper);
//         }

//         // Transfer the remaining collateral to the provider after deducting the keeper's reward
//         IERC20(IERC7540Vault(_vault).share()).safeTransfer(provider, reducedAsset - reward2keeper);
//         UserVaultTrancheAsset[_vault][onBehalfOf] -= (reducedAsset +
//             reward2keeper);

//         // Emit an event to log the liquidation details
//         emit LiquidationRecord(
//             provider,
//             msg.sender,
//             onBehalfOf,
//             LZYBRAAmount,
//             reducedAsset,
//             reward2keeper
//         );
//     }

//     function repayingDebt(
//         address provider,
//         address _vault,
//         uint256 lzybra_amount
//     ) external virtual {
//         // Ensure repayment amount does not exceed provider's current debt
//         require(
//             borrowed[_vault][provider] >= lzybra_amount,
//             "Repayment amount exceeds provider's debt"
//         );

//         // Retrieve the provider's collateral ratio and liquidation status
//         (
//             ,
//             uint256 providerCollateralRatio
//         ) = getCollateralRatioAndLiquidationInfo(provider, _vault);

//         // Ensure the collateral ratio is healthy (at least 100%) for debt repayment
//         require(
//             providerCollateralRatio >=
//                 configurator.getSafeCollateralRatio(address(this))
//         );

//         // Execute the repayment
//         _repay(provider, _vault, provider, lzybra_amount);

//         emit RepayingDebt(msg.sender, _vault, lzybra_amount);
//     }

//     // function getCollateralRatioAndLiquidationInfo(
//     //     address user,
//     //     address _vault
//     // ) public view returns (bool shouldLiquidate, uint256 collateralRatio) {
//     //     require(vaultExists[_vault], "Vault does not exist");

//     //     // Get the user's tranche asset amount and the current price of the asset
//     //     uint256 userCollateralAmount = UserVaultTrancheAsset[_vault][user];
//     //     uint256 trancheAssetPrice = getTrancheAssetPrice(_vault);

//     //     // Calculate the USD value of the collateral
//     //     uint256 collateralValueInUSD = (userCollateralAmount *
//     //         trancheAssetPrice) / 1e18;

//     //     // Get the user's total borrowed amount in LZYBRA (assumed to be in USD)
//     //     uint256 userDebtAmount = getBorrowed(_vault, user);

//     //     // Avoid division by zero: if the user has no debt, return max collateral ratio and no liquidation
//     //     if (userDebtAmount == 0) {
//     //         return (false, type(uint256).max); // No liquidation if no debt, max ratio
//     //     }

//     //     // Calculate the collateral ratio
//     //     collateralRatio = (collateralValueInUSD * 1e18) / userDebtAmount;

//     //     // Determine if the collateral ratio falls below the liquidation threshold
//     //     uint256 badCollateralRatio = configurator.getBadCollateralRatio(
//     //         address(this)
//     //     );
//     //     shouldLiquidate = collateralRatio < badCollateralRatio;
//     // }

//     //Debug
// function getCollateralRatioAndLiquidationInfo(
//     address user,
//     address _vault
// ) public returns (bool shouldLiquidate, uint256 collateralRatio) {
//     require(vaultExists[_vault], "Vault does not exist");

//     // Get the user's tranche asset amount and the current price of the asset
//     uint256 userCollateralAmount = UserVaultTrancheAsset[_vault][user];
//     uint256 trancheAssetPrice = getTrancheAssetPrice(_vault);

//     // Calculate the USD value of the collateral
//     uint256 collateralValueInUSD = (userCollateralAmount * trancheAssetPrice) / 1e18;

//     // Get the user's total borrowed amount in LZYBRA (assumed to be in USD)
//     uint256 userDebtAmount = getBorrowed(_vault, user);

//     // Avoid division by zero: if the user has no debt, return max collateral ratio and no liquidation
//     if (userDebtAmount == 0) {
//         return (false, type(uint256).max); // No liquidation if no debt, max ratio
//     }

//     // Calculate the collateral ratio, scaling it to 1e18 = 100%
//     collateralRatio = ((collateralValueInUSD * 1e18) / userDebtAmount) * 100;

//     // Retrieve the badCollateralRatio threshold, scaled to 1e18 = 100%
//     uint256 badCollateralRatio = configurator.getBadCollateralRatio(address(this));

//     // Set shouldLiquidate flag based on whether collateralRatio is below the threshold
//     shouldLiquidate = collateralRatio < badCollateralRatio;

//     // Emit debug information (optional: consider only including in development or testing)
//     emit DebugUint("Collateral Value in USD", collateralValueInUSD);
//     emit DebugUint("User Debt Amount", userDebtAmount);
//     emit DebugUint("Calculated Collateral Ratio (scaled to 1e18 for 100%)", collateralRatio);
//     emit DebugUint("Bad Collateral Ratio Threshold (scaled to 1e18 for 100%)", badCollateralRatio);
//     emit DebugBool("Should Liquidate", shouldLiquidate);
// }



//     /**
//      * @dev Refresh LBR reward before adding providers debt. Refresh Zybra generated service fee before adding totalSupply. Check providers collateralRatio cannot below `safeCollateralRatio`after minting.
//      */
//     function _mintLZYBRA(
//         address _provider,
//         address _vault,
//         address _onBehalfOf,
//         uint256 _mintAmount
//     ) internal virtual {
//         require(
//             poolTotalCirculation + _mintAmount <=
//                 configurator.mintVaultMaxSupply(address(this)),
//             "ESL"
//         );
//         _updateFee(_provider, _vault);

//         borrowed[_vault][_provider] += _mintAmount;

//         Lzybra.mint(_onBehalfOf, _mintAmount);
//         poolTotalCirculation += _mintAmount;
//     }

//     /**
//      * @notice Burn _provideramount Lzybra to payback minted Lzybra for _onBehalfOf.
//      *
//      * @dev rePAY the User debt so the Collateral Ratio for user is mantained.
//      */
//  function _repay(
//     address _provider,
//     address _vault,
//     address _onBehalfOf,
//     uint256 _amount
// ) internal virtual {
//     // Transfer Lzybra tokens from provider to contract
//     Lzybra.transferFrom(_provider, address(this), _amount);

//     // Burn the transferred tokens
//     Lzybra.burn(_provider, _amount);
//     // Update balances
//     borrowed[_vault][_onBehalfOf] -= _amount;
//     poolTotalCirculation -= _amount;
// }


//     function _withdraw(address _provider, address _vault) internal virtual {
//         IERC7540Vault vault_ = IERC7540Vault(_vault);

//         uint256 claimableWithdrawMax = vault_.claimableRedeemRequest(
//             0,
//             _provider
//         );
//         require(claimableWithdrawMax > 0, "Claimable Amount is zero.");

//         uint256 _amount = vault_.redeem(
//             claimableWithdrawMax,
//             address(this),
//             _provider
//         );

//         if (getBorrowed(_vault, _provider) > 0) {
//             _checkHealth(_provider, _vault);
//         }

//         _updateFee(_provider, _vault);
//         uint256 fee = feeStored[_provider];

//         UserVaultTrancheAsset[_vault][_provider] -= claimableWithdrawMax;

//         collateralAsset.safeTransfer(_provider, _amount - fee);

//         emit WithdrawAsset(
//             _provider,
//             address(collateralAsset),
//             _vault,
//             _amount
//         );
//     }

//     /**
//      * @dev Approve tokens only if allowance is insufficient.
//      */
//     function _approveIfNeeded(
//         address asset,
//         address spender,
//         uint256 amount
//     ) internal {
//         uint256 currentAllowance = IERC20(asset).allowance(
//             address(this),
//             spender
//         );
//         if (currentAllowance < amount) {
//             bool success = IERC20(asset).approve(
//                 spender,
//                 (amount - currentAllowance) * 10
//             );
//             require(success, "Approval failed");
//         }
//     }

//     /**
//      * @dev Get USD value of current collateral asset and minted Lzybra through price oracle / Collateral asset USD value must higher than safe Collateral Ratio.
//      */
//     // function _checkHealth(address user, address _vault) internal view {
//     //     (
//     //         bool shouldLiquidate,
//     //         uint256 collateralRatio
//     //     ) = getCollateralRatioAndLiquidationInfo(user, _vault);

//     //     uint256 safeCollateralRatio = configurator.getSafeCollateralRatio(
//     //         address(this)
//     //     );
//     //     require(
//     //         collateralRatio >= safeCollateralRatio,
//     //         "Collateral ratio is below safe threshold"
//     //     );
//     // }


// ////Debug

//      function _checkHealth(address user, address _vault) internal {
//         (
//             bool shouldLiquidate,
//             uint256 collateralRatio
//         ) = getCollateralRatioAndLiquidationInfo(user, _vault);

//         uint256 safeCollateralRatio = configurator.getSafeCollateralRatio(
//             address(this)
//         );
//         require(
//             collateralRatio >= safeCollateralRatio,
//             "Collateral ratio is below safe threshold"
//         );
//     }

//     function _updateFee(address user, address _vault) internal {
//         if (block.timestamp > feeUpdatedAt[user]) {
//             feeStored[user] += _newFee(user, _vault);
//             feeUpdatedAt[user] = block.timestamp;
//         }
//     }

//     function _newFee(
//         address user,
//         address _vault
//     ) internal view returns (uint256) {
//         return
//             (borrowed[_vault][user] *
//                 configurator.vaultMintFeeApy(address(this)) *
//                 (block.timestamp - feeUpdatedAt[user])) /
//             (86_400 * 365) /
//             10_000;
//     }

//     /**
//      * @dev Returns the current borrowing amount for the user, including borrowed[_vault] shares and accumulated fees.
//      * @param user The address of the user.
//      * @return The total borrowing amount for the user.
//      */
//     function getBorrowed(
//         address _vault,
//         address user
//     ) public view returns (uint256) {
//         return borrowed[_vault][user] + feeStored[user] + _newFee(user, _vault);
//     }

//     function getPoolTotalCirculation() external view returns (uint256) {
//         return poolTotalCirculation;
//     }

//     function isVault(address _vault) external view returns (bool) {
//         return vaultExists[_vault];
//     }

//     function getAsset(address _vault) external view returns (address) {
//         IERC7540Vault vault_ = IERC7540Vault(_vault);
//         return vault_.asset();
//     }

//     function getUserTrancheAsset(
//         address vault,
//         address user
//     ) external view returns (uint256) {
//         return UserVaultTrancheAsset[vault][user];
//     }
//     function getVaultType() external pure returns (uint8) {
//         return 0;
//     }

//     function calc_share(
//         uint256 amount,
//         address _vault
//     ) public view returns (uint256) {
//         uint256 borrowedAmount = borrowed[_vault][msg.sender];
//         uint256 userAssetAmount = UserVaultTrancheAsset[_vault][msg.sender];
//         require(userAssetAmount > 0, "UserAsset must be greater than zero");

//         // Calculate the share with proper scaling
//         return (borrowedAmount * amount) / userAssetAmount;
//     }

//     function getCollateralAssetPrice() public view returns (uint256) {
//         (, int256 price, , , ) = priceFeed.latestRoundData();
//         return uint256(price);
//     }

//     function getTrancheAssetPrice(
//         address _vault
//     ) public view returns (uint256) {
//         IERC7540Vault vault_ = IERC7540Vault(_vault);
//         (uint128 latestPrice, ) = poolManager.getTranchePrice(
//             vault_.poolId(),
//             vault_.trancheId(),
//             vault_.asset()
//         );
//         return latestPrice;
//     }
// }
