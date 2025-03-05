// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ILzybraVault.sol"; // Import your LzybraVault

contract VaultManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    LzybraVault public vault;

    uint256 public liquidationPenalty; // Liquidation penalty in percentage
    uint256 public auctionStartPremium; // Percentage premium for starting auction price
    uint256 public auctionStepTime; // Time in seconds between price steps in the auction
    uint256 public auctionCut; // Percentage decrease per step in the auction price

    struct Auction {
        address vaultOwner;
        uint256 debtAmount;
        uint256 collateralAmount;
        uint256 startPrice;
        uint256 startTime;
        bool isActive;
    }

    mapping(uint256 => Auction) public auctions;
    uint256 public auctionCounter;

    event VaultLiquidated(
        address indexed vaultOwner,
        uint256 indexed auctionId,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event AuctionStarted(
        uint256 indexed auctionId,
        address indexed vaultOwner,
        uint256 startTime,
        uint256 startPrice
    );
    event AuctionPriceReduced(
        uint256 indexed auctionId,
        uint256 newPrice
    );
    event AuctionClosed(
        uint256 indexed auctionId,
        address indexed buyer,
        uint256 finalPrice
    );

    modifier onlyAuthorized() {
    require(msg.sender == owner() || msg.sender == address(zfiStakingLiquidation), "Not authorized");
    _;
}

    /**
     * @dev Constructor to initialize the VaultManager contract.
     * @param _vault Reference to the LzybraVault contract.
     * @param _liquidationPenalty Initial penalty applied to seized collateral during liquidation.
     * @param _auctionStartPremium Initial premium for the starting auction price, in percentage.
     * @param _auctionStepTime Time interval in seconds between each auction price decay step.
     * @param _auctionCut Percentage decrease in auction price per step.
     */
    constructor(
        LzybraVault _vault,
        uint256 _liquidationPenalty,
        uint256 _auctionStartPremium,
        uint256 _auctionStepTime,
        uint256 _auctionCut
    ) {
        require(_liquidationPenalty <= 50, "Penalty too high");
        require(_auctionStartPremium > 0, "Invalid start premium");
        require(_auctionCut <= 100, "Invalid auction cut");

        vault = _vault;
        liquidationPenalty = _liquidationPenalty;
        auctionStartPremium = _auctionStartPremium;
        auctionStepTime = _auctionStepTime;
        auctionCut = _auctionCut;
    }

    /**
     * @notice Fetches the collateral and debt for a given vault owner.
     * @param vaultOwner Address of the vault owner.
     * @return collateralAmount Collateral in the vault.
     * @return debtAmount Debt associated with the vault.
     */
    function getVaultCollateral(address vaultOwner)
        external
        view
        returns (uint256 collateralAmount, uint256 debtAmount)
    {
        collateralAmount = vault.UserAsset(vaultOwner, address(vault.collateralAsset()));
        debtAmount = vault.getBorrowed(vaultOwner, address(vault.collateralAsset()));
    }

    /**
     * @notice Liquidates an undercollateralized vault and starts an auction.
     * @param vaultOwner Address of the vault owner to be liquidated.
     * @dev Callable only by authorized parties.
     */
   function liquidateVault(address vaultOwner) external nonReentrant onlyAuthorized {
    (uint256 collateralAmount, uint256 debtAmount) = getVaultCollateral(vaultOwner);
    require(collateralAmount < debtAmount, "Vault not undercollateralized");

    uint256 collateralToSeize = (collateralAmount * (100 + liquidationPenalty)) / 100;

    vault.liquidation(
        msg.sender,
        vaultOwner,
        collateralToSeize,
        Asset({
            assetType: AssetType.ERC20,
            assetAddress: address(vault.collateralAsset()),
            amount: collateralToSeize,
            tokenId: 0,
            assetPrice: AssetPrice(vault.usdc_price_feed(), 0, 0)
        }),
        new bytes(0)
    );

    uint256 startPrice = (debtAmount * (100 + auctionStartPremium)) / 100;

    auctions[auctionCounter] = Auction({
        vaultOwner: vaultOwner,
        debtAmount: debtAmount,
        collateralAmount: collateralToSeize,
        startPrice: startPrice,
        startTime: block.timestamp,
        isActive: true
    });

    emit VaultLiquidated(vaultOwner, auctionCounter, debtAmount, collateralToSeize);
    emit AuctionStarted(auctionCounter, vaultOwner, block.timestamp, startPrice);

    auctionCounter++;
}

    /**
     * @notice Calculates the current auction price for a given auction based on elapsed time.
     * @param auctionId The ID of the auction.
     * @return The current price for the auction.
     */
    function getCurrentAuctionPrice(uint256 auctionId) public view returns (uint256) {
        Auction memory auction = auctions[auctionId];
        require(auction.isActive, "Auction not active");

        uint256 elapsedTime = block.timestamp - auction.startTime;
        uint256 steps = elapsedTime / auctionStepTime;
        uint256 priceDecayFactor = auctionCut**steps;

        return (auction.startPrice * priceDecayFactor) / (100**steps);
    }

    /**
     * @notice Allows a buyer to purchase collateral from an active auction.
     * @param auctionId The ID of the auction.
     * @dev The buyer must send sufficient funds to match the current auction price.
     */
    function buyFromAuction(uint256 auctionId) external payable nonReentrant {
        Auction storage auction = auctions[auctionId];
        require(auction.isActive, "Auction not active");

        uint256 currentPrice = getCurrentAuctionPrice(auctionId);
        require(msg.value >= currentPrice, "Insufficient payment");

        auction.isActive = false;

        // Transfer collateral to buyer
        IERC20(vault.collateralAsset()).safeTransfer(msg.sender, auction.collateralAmount);

        // Send funds to contract owner
        payable(owner()).transfer(currentPrice);

        emit AuctionClosed(auctionId, msg.sender, currentPrice);
    }

    // --- Governance and Utility Functions ---

    /**
     * @notice Update the liquidation penalty percentage.
     * @param _liquidationPenalty New liquidation penalty.
     */
    function setLiquidationPenalty(uint256 _liquidationPenalty) external onlyOwner {
        require(_liquidationPenalty <= 50, "Penalty too high");
        liquidationPenalty = _liquidationPenalty;
    }

    /**
     * @notice Update auction start premium.
     * @param _auctionStartPremium New auction start premium as a percentage.
     */
    function setAuctionStartPremium(uint256 _auctionStartPremium) external onlyOwner {
        require(_auctionStartPremium > 0, "Invalid start premium");
        auctionStartPremium = _auctionStartPremium;
    }

    /**
     * @notice Update auction step time in seconds.
     * @param _auctionStepTime New auction step time.
     */
    function setAuctionStepTime(uint256 _auctionStepTime) external onlyOwner {
        auctionStepTime = _auctionStepTime;
    }

    /**
     * @notice Update the auction price reduction per step.
     * @param _auctionCut New auction cut percentage.
     */
    function setAuctionCut(uint256 _auctionCut) external onlyOwner {
        require(_auctionCut <= 100, "Invalid auction cut");
        auctionCut = _auctionCut;
    }
}
