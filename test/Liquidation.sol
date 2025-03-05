// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import "./BaseTest.sol";
import {CastLib} from "../contracts/Zybra/libraries/CastLib.sol";

contract LiquidationAndRepaymentTest is BaseTest {
    using CastLib for *;

function testLiquidation() public {
    // Initial deposit parameters
    uint256 depositAmount = 1000 * 10 ** 18;
    uint256 liquidationAmount = 500 * 10 ** 18; // 50% of deposit amount
    uint128 initialPrice = 2 * 10 ** 18;

    console2.log("=============== Initial Setup ===============");

    // Deploy and set up vault
    address vault_ = deploySimpleVault();
    ERC7540Vault vault = ERC7540Vault(vault_);
    Lzybravault.addVault(vault_);
    configurator.setKeeperRatio(vault_, 5);
    lzybra.grantBurnRole(address(Lzybravault));

    console2.log("=============== Set Initial Tranche Price ===============");

    // Set initial tranche price
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        initialPrice,
        uint64(block.timestamp)
    );

    console2.log("=============== Deposit Funds ===============");

    // Deposit funds to vault
    deposit(vault_, investor, depositAmount, 0);

    // Initial collateral ratio check
    (bool initialLiquidate, uint256 initialCollateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Initial collateral ratio:", initialCollateralRatio);
    console2.log("Should liquidate (initial):", initialLiquidate);

    console2.log("=============== Update Price to Trigger Liquidation ===============");

    // Reduce price to trigger a low collateral ratio
    uint128 newPrice = initialPrice / 4; // Price falls to 0.5
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        newPrice,
        uint64(block.timestamp)
    );

    console2.log("New tranche price:", newPrice);

    // Set up collateral thresholds for liquidation
    configurator.setSafeCollateralRatio(address(Lzybravault), 200 * 1e18);
    configurator.setBadCollateralRatio(address(Lzybravault), 110 * 1e18);

    // Check if allowance is sufficient for liquidation
    uint256 currentAllowance = lzybra.allowance(address(this), address(Lzybravault));
    if (currentAllowance < liquidationAmount) {
        lzybra.approve(address(Lzybravault), liquidationAmount);
    }

    console2.log("=============== Trigger Liquidation ===============");

    // Expect a liquidation event to occur
    vm.expectEmit(true, true, true, true);

    // Trigger liquidation
    vm.prank(address(this));
    Lzybravault.liquidation(
        address(this),
        vault_,
        investor,
        liquidationAmount
    );

    // Validate remaining collateral balance
    uint256 expectedCollateralAfterLiquidation = depositAmount - liquidationAmount;
    assertEq(
        vault.maxDeposit(investor),
        expectedCollateralAfterLiquidation,
        "Collateral balance mismatch post-liquidation"
    );

    // Final collateral ratio check to confirm post-liquidation status
    (bool finalLiquidateCheck, uint256 finalCollateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Final collateral ratio after liquidation:", finalCollateralRatio);
    console2.log("Should liquidate (final):", finalLiquidateCheck);
}


 function testRepayingDebt() public {
    // Initial deposit and repayment parameters
    uint256 depositAmount = 1000 * 10 ** 18;
    uint256 mintAmount = 200 * 10 ** 18; // Minted debt amount
    uint256 repayAmount = 100 * 10 ** 18; // Partially repaying the debt
    uint128 initialPrice = 2 * 10 ** 18;

    // Deploy and set up vault
    address vault_ = deploySimpleVault();
    ERC7540Vault vault = ERC7540Vault(vault_);
    Lzybravault.addVault(vault_);
    configurator.setKeeperRatio(vault_, 5);
    configurator.setSafeCollateralRatio(address(Lzybravault), 165 * 1e18);
    configurator.setBadCollateralRatio(address(Lzybravault), 110 * 1e18);
    lzybra.grantBurnRole(address(Lzybravault));

    // Set initial tranche price
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        initialPrice,
        uint64(block.timestamp)
    );

    // Deposit funds to vault
    deposit(vault_, investor, depositAmount, mintAmount);

    // Check if allowance is sufficient for repayment
    uint256 currentAllowance = lzybra.allowance(investor, address(Lzybravault));
    if (currentAllowance < repayAmount) {
        vm.prank(investor);
        lzybra.approve(address(Lzybravault), repayAmount);
    }

    // Expect RepayingDebt event
    vm.expectEmit(true, true, true, true);

    // Repay debt
    vm.prank(investor);
    Lzybravault.repayingDebt(investor, vault_, repayAmount);

    // Validate the debt amount after repayment
    uint256 remainingDebt = Lzybravault.getBorrowed(vault_, investor);
    assertEq(
        remainingDebt,
        mintAmount - repayAmount,
        "Remaining debt does not match expected value after repayment"
    );

    // Final collateral ratio check
    (bool shouldLiquidate, uint256 collateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Collateral ratio after partial repayment:", collateralRatio);
    console2.log("Should liquidate after partial repayment:", shouldLiquidate);
}

function testMultipleLiquidations() public {
    uint256 depositAmount = 2000 * 10 ** 18; // Collateral deposit
    uint256 initialLiquidationAmount = 500 * 10 ** 18; // Amount for the first liquidation
    uint128 initialPrice = 2 * 10 ** 18; // Initial price in tranche

    console2.log("=============== Initial Setup ===============");

    // Deploy and set up vault
    address vault_ = deploySimpleVault();
    ERC7540Vault vault = ERC7540Vault(vault_);
    Lzybravault.addVault(vault_);
    configurator.setKeeperRatio(vault_, 5); // Keeper reward ratio
    configurator.setSafeCollateralRatio(address(Lzybravault), 165 * 1e18); // Safe collateral ratio at 165%
    configurator.setBadCollateralRatio(address(Lzybravault), 110 * 1e18); // Bad collateral ratio threshold at 110%
    lzybra.grantBurnRole(address(Lzybravault)); // Grant burn role for LZYBRA

    // Set initial tranche price
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        initialPrice,
        uint64(block.timestamp)
    );

    console2.log("=============== Deposit Collateral ===============");

    uint256 lzybraAmount = ((depositAmount * initialPrice * 100) / 170) / 1e18;
    console2.log("LZYBRA amount for 170% collateral:", lzybraAmount);

    // Deposit collateral
    deposit(vault_, investor, depositAmount, lzybraAmount);
    deposit(vault_, address(this), depositAmount, lzybraAmount);

    console2.log("=============== Price Drop for First Liquidation ===============");

    // Drop the asset price to bring collateral ratio to 110%
    uint128 newPrice = (initialPrice * 110) / 170; // Adjust price to reach 110% collateral ratio
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        newPrice,
        uint64(block.timestamp)
    );

    console2.log("New tranche price for first liquidation:", newPrice);

    // Calculate keeper reward and reduced asset for the first liquidation
    uint256 keeperRatio = configurator.vaultKeeperRatio(vault_);
    uint256 keeperReward = (initialLiquidationAmount * keeperRatio) / 100;

    // Calculate the expected reduced asset after applying keeper reward
    uint256 expectedReducedAsset = initialLiquidationAmount;
    if (keeperReward > 0) {
        expectedReducedAsset -= keeperReward;
    }
    uint256 expectedCollateralAfterFirst = depositAmount - expectedReducedAsset;

    console2.log("Keeper reward:", keeperReward);
    console2.log("expectedCollateralAfterFirst", expectedCollateralAfterFirst);

    // Approve LZYBRA tokens for liquidation
    if (lzybra.allowance(address(this), address(Lzybravault)) < initialLiquidationAmount) {
        lzybra.approve(address(Lzybravault), lzybraAmount);
    }

    console2.log("Triggering first liquidation...");
    vm.prank(address(this));
    Lzybravault.liquidation(
        address(this),
        vault_,
        investor,
        initialLiquidationAmount
    );

    // Assert post-first liquidation collateral balance
    assertEq(
        Lzybravault.getUserTrancheAsset(vault_, investor),
        expectedCollateralAfterFirst,
        "Collateral balance mismatch post-initial liquidation"
    );

    console2.log("=============== Price Increase After First Liquidation ===============");

    // Increase the asset price to restore collateral ratio
    uint128 increasedPrice = initialPrice;
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        increasedPrice,
        uint64(block.timestamp)
    );

    console2.log("Increased tranche price to restore collateral ratio:", increasedPrice);

    // Verify collateral ratio after price increase
    (bool canLiquidateAfterIncrease, uint256 collateralRatioAfterIncrease) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Collateral ratio after price increase:", collateralRatioAfterIncrease);

    console2.log("=============== Further Price Drop for Second Liquidation ===============");

    // Drop the price again for the second liquidation
    uint128 reducedPrice = (initialPrice * 110) / 170;
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        reducedPrice,
        uint64(block.timestamp)
    );

    console2.log("New tranche price for second liquidation:", reducedPrice);

    // Calculate keeper reward and reduced asset for the second liquidation
    uint256 secondLiquidationAmount = 500 * 10 ** 18;
    uint256 secondKeeperReward = (secondLiquidationAmount * keeperRatio) / 100;

    uint256 expectedReducedAssetSecond = secondLiquidationAmount;
    if (secondKeeperReward > 0) {
        expectedReducedAssetSecond -= secondKeeperReward;
    }
    uint256 expectedCollateralAfterSecond = expectedCollateralAfterFirst - expectedReducedAssetSecond;

    console2.log("Second keeper reward:", secondKeeperReward);
    console2.log("expectedCollateralAfterSecond:", expectedCollateralAfterSecond);

    // Approve LZYBRA tokens for the second liquidation
    if (lzybra.allowance(address(this), address(Lzybravault)) < secondLiquidationAmount) {
        lzybra.approve(address(Lzybravault), lzybraAmount);
    }

    console2.log("Triggering second liquidation...");
    vm.prank(address(this));
    Lzybravault.liquidation(
        address(this),
        vault_,
        investor,
        secondLiquidationAmount
    );

    // Final collateral balance check
    assertEq(
        Lzybravault.getUserTrancheAsset(vault_, investor),
        expectedCollateralAfterSecond,
        "Collateral balance mismatch post-second liquidation"
    );

    // Verify final collateral ratio after all liquidations
    (bool finalLiquidationCheck, uint256 finalCollateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Final collateral ratio after all liquidations:", finalCollateralRatio);
}










    function testLiquidationAtThreshold() public {
        uint256 depositAmount = 1500 * 10 ** 18;
        uint128 initialPrice = 2 * 10 ** 18;
        uint128 newPrice = initialPrice / 3; // New price to bring collateral close to threshold

        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        Lzybravault.addVault(vault_);
        configurator.setKeeperRatio(address(Lzybravault), 5);
        lzybra.grantBurnRole(address(Lzybravault));

        centrifugeChain.updateTranchePrice(
            vault.poolId(),
            vault.trancheId(),
            defaultAssetId,
            initialPrice,
            uint64(block.timestamp)
        );
        console2.log("Initial Price Set:", initialPrice);

        uint256 lzybra_amount = (depositAmount * 100) / 160; // Adjusted to 160% collateral
        console2.log("LZYBRA amount for 160% collateral:", lzybra_amount);

        configurator.setSafeCollateralRatio(address(Lzybravault), 165 * 1e18);
        configurator.setBadCollateralRatio(address(Lzybravault), 110 * 1e18);

        deposit(vault_, investor, depositAmount, lzybra_amount);
        deposit(vault_, address(this), depositAmount, lzybra_amount);
        console2.log(
            "balanceosds",
            Lzybravault.getBorrowed(vault_, address(this))
        );

        // Re-check collateral ratio to ensure it aligns with expectations
        (bool liquidate, uint256 collateralRatio) = Lzybravault
            .getCollateralRatioAndLiquidationInfo(investor, address(vault_));
        console2.log("Before price drop - should liquidate:", liquidate);
        console2.log("Before price drop - collateral ratio:", collateralRatio);

        // Reduce asset price
        centrifugeChain.updateTranchePrice(
            vault.poolId(),
            vault.trancheId(),
            defaultAssetId,
            newPrice,
            uint64(block.timestamp)
        );
        console2.log("New Price Set:", newPrice);
        console2.log("New Price Set:", newPrice);

        // Set liquidation amount, apply consistent scaling
        uint256 liquidationAmount = 400 * 10 ** 18;
        uint256 tranchePrice = Lzybravault.getTrancheAssetPrice(
            address(vault_)
        );
        uint256 scaledApprovalAmount = (liquidationAmount * tranchePrice * 10) /
            1e17; // Scale correctly to match price
        lzybra.approve(address(Lzybravault), scaledApprovalAmount);
        // Final check for liquidation status
        (bool shouldLiquidate, uint256 updatedCollateralRatio) = Lzybravault
            .getCollateralRatioAndLiquidationInfo(investor, address(vault_));
        console2.log(
            "After price drop - should liquidate:",
            (liquidationAmount * tranchePrice) / 1e18
        );
        console2.log("After price drop - should liquidate:", shouldLiquidate);
        console2.log(
            "After price drop - collateral ratio:",
            updatedCollateralRatio
        );

        vm.prank(address(this));
        Lzybravault.liquidation(
            address(this),
            vault_,
            investor,
            liquidationAmount
        );

        console2.log("Post-liquidation balance check");

        uint256 expectedBalance = depositAmount - liquidationAmount;
        console2.log("Expected balance after liquidation:", expectedBalance);
        assertTrue(lzybra_amount > Lzybravault.getBorrowed(vault_, investor));
    }

  function testFullRepayment() public {
    uint256 depositAmount = 1000 * 10 ** 18;
    uint256 mintAmount = 200 * 10 ** 18;
    uint128 initialPrice = 2 * 10 ** 18;

    address vault_ = deploySimpleVault();
    ERC7540Vault vault = ERC7540Vault(vault_);
    Lzybravault.addVault(vault_);
    
    // Configure vault and collateral thresholds
    configurator.setKeeperRatio(vault_, 5);
    configurator.setSafeCollateralRatio(address(Lzybravault), 165 * 1e18);
    configurator.setBadCollateralRatio(address(Lzybravault), 110 * 1e18);
    lzybra.grantBurnRole(address(Lzybravault));

    // Set initial tranche price
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        initialPrice,
        uint64(block.timestamp)
    );

    // Deposit collateral and mint debt
    deposit(vault_, investor, depositAmount, mintAmount);

    // Initial collateral ratio check
    (bool liquidate, uint256 collateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Initial collateral ratio:", collateralRatio);
    console2.log("Should liquidate (initial):", liquidate);

    // First partial repayment
    uint256 firstRepayAmount = 50 * 10 ** 18;
    uint256 currentAllowance = lzybra.allowance(investor, address(Lzybravault));
    if (currentAllowance < firstRepayAmount) {
        vm.prank(investor);
        lzybra.approve(address(Lzybravault), firstRepayAmount);
    }

    vm.prank(investor);
    Lzybravault.repayingDebt(investor, vault_, firstRepayAmount);

    // Check remaining debt after first repayment
    uint256 remainingDebtAfterFirstRepayment = mintAmount - firstRepayAmount;
    assertEq(
        Lzybravault.getBorrowed(vault_, investor),
        remainingDebtAfterFirstRepayment,
        "Incorrect remaining debt after first repayment"
    );

    // Second partial repayment to fully repay the debt
    uint256 secondRepayAmount = remainingDebtAfterFirstRepayment;
    currentAllowance = lzybra.allowance(investor, address(Lzybravault));
    if (currentAllowance < secondRepayAmount) {
        vm.prank(investor);
        lzybra.approve(address(Lzybravault), secondRepayAmount);
    }

    vm.prank(investor);
    Lzybravault.repayingDebt(investor, vault_, secondRepayAmount);

    // Final debt check to confirm full repayment
    assertEq(
        Lzybravault.getBorrowed(vault_, investor),
        0,
        "Remaining debt should be zero after full repayment"
    );

    // Final collateral ratio check to ensure no liquidation risk
    (bool shouldLiquidateAfterFullRepayment, uint256 finalCollateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Final collateral ratio after full repayment:", finalCollateralRatio);
    console2.log("Should liquidate (after full repayment):", shouldLiquidateAfterFullRepayment);
}


 function testSmallFractionalRepayment() public {
    uint256 depositAmount = 1000 * 10 ** 18;
    uint256 mintAmount = 200 * 10 ** 18;
    uint256 smallRepayAmount = 1 * 10 ** 18; // Small fraction to repay
    uint128 initialPrice = 2 * 10 ** 18;

    address vault_ = deploySimpleVault();
    ERC7540Vault vault = ERC7540Vault(vault_);
    Lzybravault.addVault(vault_);
    
    configurator.setKeeperRatio(vault_, 5);
    configurator.setSafeCollateralRatio(address(Lzybravault), 165 * 1e18);
    configurator.setBadCollateralRatio(address(Lzybravault), 110 * 1e18);
    lzybra.grantBurnRole(address(Lzybravault));

    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        initialPrice,
        uint64(block.timestamp)
    );

    deposit(vault_, investor, depositAmount, mintAmount);

    // Initial collateral ratio check
    (bool liquidate, uint256 collateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Initial collateral ratio:", collateralRatio);
    console2.log("Should liquidate (initial):", liquidate);

    // Set allowance for the Lzybravault to cover small repayment amount
    uint256 currentAllowance = lzybra.allowance(investor, address(Lzybravault));
    if (currentAllowance < smallRepayAmount) {
        vm.prank(investor);
        lzybra.approve(address(Lzybravault), smallRepayAmount*10);
    }

    // Repay small amount
    vm.prank(investor);
    Lzybravault.repayingDebt(investor, vault_, smallRepayAmount);

    // Remaining debt should decrease by the exact smallRepayAmount
    uint256 remainingDebt = mintAmount - smallRepayAmount;
    assertEq(
        Lzybravault.getBorrowed(vault_, investor),
        remainingDebt,
        "Incorrect remaining debt after small fractional repayment"
    );

    // Collateral ratio check after small repayment
    (bool shouldLiquidateAfterRepayment, uint256 updatedCollateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Collateral ratio after small repayment:", updatedCollateralRatio);
    console2.log("Should liquidate (after small repayment):", shouldLiquidateAfterRepayment);
}



 function testRepaymentWithPriceFluctuation() public {
    uint256 depositAmount = 1500 * 10 ** 18;
    uint256 mintAmount = 300 * 10 ** 18;
    uint256 repayAmount = 100 * 10 ** 18;
    uint128 initialPrice = 2 * 10 ** 18;

    address vault_ = deploySimpleVault();
    ERC7540Vault vault = ERC7540Vault(vault_);
    Lzybravault.addVault(vault_);
    
    // Configure the vault and collateral thresholds
    configurator.setKeeperRatio(vault_, 5);
    configurator.setSafeCollateralRatio(address(Lzybravault), 165 * 1e18);
    configurator.setBadCollateralRatio(address(Lzybravault), 110 * 1e18);
    lzybra.grantBurnRole(address(Lzybravault));

    // Set initial tranche price
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        initialPrice,
        uint64(block.timestamp)
    );

    // Deposit collateral and mint debt
    deposit(vault_, investor, depositAmount, mintAmount);

    // Initial collateral ratio check
    (bool liquidate, uint256 collateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Initial collateral ratio:", collateralRatio);
    console2.log("Should liquidate (initial):", liquidate);

    // Simulate price increase before repayment
    uint128 increasedPrice = (initialPrice * 3) / 2;
    centrifugeChain.updateTranchePrice(
        vault.poolId(),
        vault.trancheId(),
        defaultAssetId,
        increasedPrice,
        uint64(block.timestamp)
    );
    console2.log("Updated tranche price after increase:", increasedPrice);

    // Check allowance and ensure it's sufficient
    uint256 currentAllowance = lzybra.allowance(investor, address(Lzybravault));
    if (currentAllowance < repayAmount) {
        vm.prank(investor);
        lzybra.approve(address(Lzybravault), repayAmount);
    }

    // Approve and repay partial amount
    vm.prank(investor);
    Lzybravault.repayingDebt(investor, vault_, repayAmount);

    // Check remaining debt
    uint256 remainingDebt = mintAmount - repayAmount;
    assertEq(
        Lzybravault.getBorrowed(vault_, investor),
        remainingDebt,
        "Remaining debt mismatch after repayment with price fluctuation"
    );

    // Final collateral ratio check after repayment
    (bool shouldLiquidateAfterRepayment, uint256 updatedCollateralRatio) = Lzybravault.getCollateralRatioAndLiquidationInfo(investor, vault_);
    console2.log("Collateral ratio after repayment with price fluctuation:", updatedCollateralRatio);
    console2.log("Should liquidate (after repayment with price fluctuation):", shouldLiquidateAfterRepayment);
}


}
