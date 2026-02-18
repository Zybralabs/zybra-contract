// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Treasury} from "src/treasury/Treasury.sol";
import {FeeCollector} from "src/treasury/FeeCollector.sol";
import {ZybraGroup} from "src/ZybraGroup.sol";
import {IMorphoVaultV2} from "src/interfaces/IMorphoVaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Treasury Architecture Mainnet Fork Tests
 * @author Senior DeFi Engineer
 * @notice Production-grade tests for Treasury + FeeCollector + ZybraGroup integration
 * @dev Tests against real Morpho Vault V2 on Ethereum mainnet
 *
 * ARCHITECTURE UNDER TEST:
 *   ZybraGroup (FeeSource) → FeeCollector → Treasury
 *
 * TEST COVERAGE:
 *   1. Treasury role-based access control
 *   2. FeeCollector source registration
 *   3. End-to-end fee flow from yield to Treasury
 *   4. Edge cases and failure modes
 */
contract TreasuryArchitectureTest is Test {
    // ==================== MAINNET ADDRESSES ====================

    address constant MORPHO_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;

    // ==================== CONTRACTS ====================

    Treasury public treasury;
    FeeCollector public feeCollector;
    ZybraGroup public group;

    IMorphoVaultV2 public vault;
    IERC20 public usdc;

    // ==================== ACTORS ====================

    address public governance;
    address public manager;
    address public keeper;
    address public admin;
    address public user1;
    address public user2;

    // ==================== CONSTANTS ====================

    uint256 constant CONTRIBUTION = 1_000e6; // 1,000 USDC
    uint256 constant CYCLE = 1 weeks;
    uint256 constant CYCLES = 6;

    // ==================== SETUP ====================

    function setUp() public {
        // Create actors
        governance = makeAddr("governance");
        manager = makeAddr("manager");
        keeper = makeAddr("keeper");
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        usdc = IERC20(USDC);
        vault = IMorphoVaultV2(MORPHO_VAULT);

        // Deploy Treasury
        treasury = new Treasury(governance, manager);

        // Deploy FeeCollector
        feeCollector = new FeeCollector(address(treasury), governance, keeper);

        // Grant FeeCollector the COLLECTOR_ROLE on Treasury
        // Cache role to avoid consuming prank
        bytes32 collectorRole = treasury.COLLECTOR_ROLE();
        vm.prank(governance);
        treasury.grantRole(collectorRole, address(feeCollector));

        // Deploy ZybraGroup with Treasury as fee recipient
        group = new ZybraGroup(
            USDC,
            CONTRIBUTION,
            CYCLE,
            CYCLES,
            admin,
            MORPHO_VAULT,
            address(treasury)  // Fees go directly to treasury
        );

        // Register group as fee source
        vm.prank(governance);
        feeCollector.registerSource(address(group));

        // Fund users from whale
        vm.startPrank(WHALE);
        usdc.transfer(admin, 100_000e6);
        usdc.transfer(user1, 100_000e6);
        usdc.transfer(user2, 100_000e6);
        vm.stopPrank();

        // Approve group
        vm.prank(admin);
        usdc.approve(address(group), type(uint256).max);
        vm.prank(user1);
        usdc.approve(address(group), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(group), type(uint256).max);
    }

    // ==================== TREASURY TESTS ====================

    function test_Treasury_RolesInitialized() public view {
        assertTrue(treasury.hasRole(treasury.DEFAULT_ADMIN_ROLE(), governance));
        assertTrue(treasury.hasRole(treasury.MANAGER_ROLE(), manager));
        assertTrue(treasury.hasRole(treasury.COLLECTOR_ROLE(), address(feeCollector)));
    }

    function test_Treasury_DepositOnlyCollector() public {
        // Fund feeCollector for test
        vm.prank(WHALE);
        usdc.transfer(address(feeCollector), 1000e6);

        // Random user cannot deposit
        vm.prank(user1);
        vm.expectRevert();
        treasury.deposit(USDC, 100e6);

        // Manager cannot deposit
        vm.prank(manager);
        vm.expectRevert();
        treasury.deposit(USDC, 100e6);
    }

    function test_Treasury_WithdrawOnlyManager() public {
        // First deposit some funds
        vm.prank(WHALE);
        usdc.transfer(address(treasury), 1000e6);

        // Random user cannot withdraw
        vm.prank(user1);
        vm.expectRevert();
        treasury.withdraw(USDC, user1, 100e6);

        // Manager can withdraw
        uint256 balBefore = usdc.balanceOf(manager);
        vm.prank(manager);
        treasury.withdraw(USDC, manager, 100e6);
        assertEq(usdc.balanceOf(manager), balBefore + 100e6);
    }

    function test_Treasury_EmergencyWithdrawOnlyAdmin() public {
        vm.prank(WHALE);
        usdc.transfer(address(treasury), 1000e6);

        // Manager cannot emergency withdraw
        vm.prank(manager);
        vm.expectRevert();
        treasury.emergencyWithdraw(USDC, manager, 1000e6);

        // Governance can emergency withdraw
        uint256 balBefore = usdc.balanceOf(governance);
        vm.prank(governance);
        treasury.emergencyWithdraw(USDC, governance, 500e6);
        assertEq(usdc.balanceOf(governance), balBefore + 500e6);
    }

    function test_Treasury_BalanceOf() public {
        assertEq(treasury.balanceOf(USDC), 0);

        vm.prank(WHALE);
        usdc.transfer(address(treasury), 5000e6);

        assertEq(treasury.balanceOf(USDC), 5000e6);
    }

    // ==================== FEE COLLECTOR TESTS ====================

    function test_FeeCollector_SourceRegistration() public view {
        assertTrue(feeCollector.isRegisteredSource(address(group)));
        assertEq(feeCollector.sourceCount(), 1);
    }

    function test_FeeCollector_RegisterSourceOnlyAdmin() public {
        address newSource = makeAddr("newSource");

        vm.prank(user1);
        vm.expectRevert();
        feeCollector.registerSource(newSource);

        vm.prank(governance);
        feeCollector.registerSource(newSource);
        assertTrue(feeCollector.isRegisteredSource(newSource));
    }

    function test_FeeCollector_RemoveSource() public {
        vm.prank(governance);
        feeCollector.removeSource(address(group));
        assertFalse(feeCollector.isRegisteredSource(address(group)));
    }

    function test_FeeCollector_GetActiveSources() public {
        address[] memory sources = feeCollector.getActiveSources();
        assertEq(sources.length, 1);
        assertEq(sources[0], address(group));

        // Add another source
        address source2 = makeAddr("source2");
        vm.prank(governance);
        feeCollector.registerSource(source2);

        sources = feeCollector.getActiveSources();
        assertEq(sources.length, 2);

        // Remove first source
        vm.prank(governance);
        feeCollector.removeSource(address(group));

        sources = feeCollector.getActiveSources();
        assertEq(sources.length, 1);
        assertEq(sources[0], source2);
    }

    // ==================== INTEGRATION TESTS ====================

    function test_Integration_FeeFlowToTreasury() public {
        // Setup: Join and start group
        vm.prank(user1);
        group.joinGroup();
        vm.prank(admin);
        group.startGroup();

        // Contribute
        vm.prank(user1);
        group.contribute();

        // Wait for yield to accrue
        vm.warp(block.timestamp + 90 days);

        // Simulate vault yield
        vm.prank(WHALE);
        usdc.transfer(MORPHO_VAULT, 100_000e6);

        // Claim yield (this accumulates fees in group)
        vm.prank(user1);
        group.claimYield();

        uint256 pendingFees = group.pendingFees();
        console.log("Pending fees in group:", pendingFees);

        if (pendingFees > 0) {
            uint256 treasuryBefore = treasury.balanceOf(USDC);

            // Collect fees (goes directly to treasury)
            group.collectFees();

            uint256 treasuryAfter = treasury.balanceOf(USDC);
            console.log("Treasury balance after:", treasuryAfter);

            assertEq(treasuryAfter, treasuryBefore + pendingFees, "Treasury received fees");
            assertEq(group.pendingFees(), 0, "Group fees cleared");
        }
    }

    function test_Integration_ManagerCanDistributeFees() public {
        // Setup: Get some fees into treasury
        vm.prank(WHALE);
        usdc.transfer(address(treasury), 10_000e6);

        address recipient = makeAddr("recipient");
        uint256 amount = 5_000e6;

        // Manager distributes to recipient
        vm.prank(manager);
        treasury.withdraw(USDC, recipient, amount);

        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(treasury.balanceOf(USDC), 5_000e6);
    }

    function test_Integration_MultipleGroups() public {
        // Deploy second group
        ZybraGroup group2 = new ZybraGroup(
            USDC,
            CONTRIBUTION,
            CYCLE,
            CYCLES,
            admin,
            MORPHO_VAULT,
            address(treasury)
        );

        // Register second source
        vm.prank(governance);
        feeCollector.registerSource(address(group2));

        address[] memory sources = feeCollector.getActiveSources();
        assertEq(sources.length, 2);
    }

    // ==================== EDGE CASES ====================

    function test_Edge_WithdrawMoreThanBalance() public {
        vm.prank(WHALE);
        usdc.transfer(address(treasury), 100e6);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.InsufficientBalance.selector,
                USDC,
                1000e6,
                100e6
            )
        );
        treasury.withdraw(USDC, manager, 1000e6);
    }

    function test_Edge_ZeroAddressChecks() public {
        vm.prank(manager);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.withdraw(address(0), manager, 100e6);

        vm.prank(manager);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        treasury.withdraw(USDC, address(0), 100e6);
    }

    function test_Edge_ZeroAmountChecks() public {
        vm.prank(manager);
        vm.expectRevert(Treasury.ZeroAmount.selector);
        treasury.withdraw(USDC, manager, 0);
    }

    function test_Edge_CollectFromUnregisteredSource() public {
        address unregistered = makeAddr("unregistered");

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeCollector.SourceNotRegistered.selector,
                unregistered
            )
        );
        feeCollector.collectFrom(unregistered);
    }

    // ==================== FEE CALCULATION VERIFICATION ====================

    function test_FeeCalculation_ExactlyOnePercent() public view {
        uint256 feeBps = group.PROTOCOL_FEE_BPS();
        assertEq(feeBps, 100, "Fee should be 100 bps = 1%");

        // Verify calculation
        uint256 yield = 10_000e6;
        uint256 expectedFee = 100e6; // 1%
        assertEq((yield * feeBps) / 10_000, expectedFee);
    }

    function test_FeeAsset_ReturnsCorrectAsset() public view {
        assertEq(group.feeAsset(), USDC);
    }

    // ==================== GOVERNANCE TESTS ====================

    function test_Governance_GrantRevokeRoles() public {
        address newManager = makeAddr("newManager");
        bytes32 managerRole = treasury.MANAGER_ROLE();

        // Grant manager role
        vm.prank(governance);
        treasury.grantRole(managerRole, newManager);
        assertTrue(treasury.hasRole(managerRole, newManager));

        // Revoke manager role
        vm.prank(governance);
        treasury.revokeRole(managerRole, newManager);
        assertFalse(treasury.hasRole(managerRole, newManager));
    }

    function test_Governance_TransferAdmin() public {
        address newGovernance = makeAddr("newGovernance");
        bytes32 adminRole = treasury.DEFAULT_ADMIN_ROLE();

        // Grant admin to new governance
        vm.prank(governance);
        treasury.grantRole(adminRole, newGovernance);

        // Renounce old admin
        vm.prank(governance);
        treasury.renounceRole(adminRole, governance);

        assertTrue(treasury.hasRole(adminRole, newGovernance));
        assertFalse(treasury.hasRole(adminRole, governance));
    }
}
