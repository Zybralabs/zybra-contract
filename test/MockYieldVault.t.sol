// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {MockYieldVault} from "src/mocks/MockYieldVault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

contract MockYieldVaultTimeBasedTest is Test {
    MockYieldVault public vault;
    MockERC20 public asset;

    address public owner;
    address public alice;

    uint256 public constant INITIAL_BALANCE = 1_000_000_000; // 1000 USDC (6 decimals)

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");

        asset = new MockERC20("USD Coin", "USDC", 6);

        vm.prank(owner);
        vault = new MockYieldVault(address(asset), "Mock Yield Vault", "myvUSDC", 6);

        asset.mint(alice, INITIAL_BALANCE);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
    }

    function test_TimeBasedYieldAccruesAfterDeposit() public {
        uint256 depositAmount = 24_000_000; // 24 USDC

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Immediately after deposit, totalAssets == deposit
        assertEq(vault.totalAssets(), depositAmount);

        // Warp 1 day to accrue yield
        vm.warp(block.timestamp + 1 days);

        uint256 totalAfter = vault.totalAssets();
        assertGt(totalAfter, depositAmount);
    }

    function test_AccrueInterestUpdatesStateWithoutManualGenerateYield() public {
        uint256 depositAmount = 100_000_000; // 100 USDC

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        // Warp 30 days
        vm.warp(block.timestamp + 30 days);

        // Calling accrueInterest should update yieldAccrued
        uint256 beforeYield = vault.yieldAccrued();
        vault.accrueInterest();
        uint256 afterYield = vault.yieldAccrued();

        assertGt(afterYield, beforeYield);
        assertGt(vault.totalAssets(), depositAmount);
    }
}
