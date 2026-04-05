// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script, console2} from "forge-std/Script.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {FeeCollector} from "../src/treasury/FeeCollector.sol";
import {ZybraGroupFactory} from "../src/ZybraGroupFactory.sol";

/**
 * @title DeployMainnet
 * @notice Deploys the full Zybra protocol stack on Ethereum mainnet.
 *
 * Deployment order (dependencies flow top → bottom):
 *   1. Treasury          – needs: admin, manager
 *   2. FeeCollector      – needs: treasury, admin, keeper
 *   3. ZybraGroupFactory – needs: treasury
 *   4. Wire-up           – COLLECTOR_ROLE must be granted from multisig post-deploy
 *   5. Ownership hand-off – factory.transferOwnership(admin) called by deployer EOA
 *
 * ┌─────────────────────────────────────────────────────────────────────────┐
 * │  MAINNET SAFETY RULES                                                   │
 * │  1. ADMIN_ADDRESS must be a multisig (Gnosis Safe), NOT a plain EOA.   │
 * │  2. Review all addresses in .env before running with --broadcast.       │
 * │  3. Run a dry-run first (no --broadcast) to review encoded calldata.    │
 * │  4. Use a hardware wallet: add --ledger --hd-paths "m/44'/60'/0'/0/0"  │
 * │     and remove PRIVATE_KEY from .env.                                   │
 * └─────────────────────────────────────────────────────────────────────────┘
 *
 * Required environment variables (.env):
 *   PRIVATE_KEY         – deployer EOA private key (gas wallet, NOT governance)
 *   ADMIN_ADDRESS       – governance multisig (DEFAULT_ADMIN_ROLE on all contracts)
 *   MANAGER_ADDRESS     – operations wallet (MANAGER_ROLE on Treasury)
 *   KEEPER_ADDRESS      – automation bot (KEEPER_ROLE on FeeCollector; can be address(0) to skip)
 *
 * Usage (dry-run, no broadcast):
 *   forge script script/DeployMainnet.s.sol \
 *     --rpc-url mainnet \
 *     -vvvv
 *
 * Usage (broadcast + verify):
 *   forge script script/DeployMainnet.s.sol \
 *     --rpc-url mainnet \
 *     --broadcast \
 *     --verify \
 *     --slow \
 *     -vvvv
 */
contract DeployMainnet is Script {
    // ─── Role identifiers (must match Treasury.sol) ───────────────────────────
    bytes32 internal constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");

    function run() external {
        // ── Load configuration from environment ───────────────────────────────
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address admin   = vm.envAddress("ADMIN_ADDRESS");
        address manager = vm.envAddress("MANAGER_ADDRESS");

        // KEEPER_ADDRESS is optional on mainnet (can be set later via grantRole)
        address keeper = vm.envOr("KEEPER_ADDRESS", address(0));

        // ── Pre-flight safety checks ──────────────────────────────────────────
        require(admin   != address(0), "DeployMainnet: ADMIN_ADDRESS not set");
        require(manager != address(0), "DeployMainnet: MANAGER_ADDRESS not set");

        // Guard: deployer should NOT be admin on mainnet (multisig separation)
        require(
            admin != deployer,
            "DeployMainnet: ADMIN_ADDRESS must not equal deployer - use a multisig"
        );

        // Guard: only run on mainnet (chainId 1)
        require(block.chainid == 1, "DeployMainnet: wrong network - expected chainId 1");

        console2.log("=== Zybra Protocol - Ethereum Mainnet Deployment ===");
        console2.log("Deployer :", deployer);
        console2.log("Admin    :", admin);
        console2.log("Manager  :", manager);
        console2.log("Keeper   :", keeper == address(0) ? "NOT SET (grant later)" : vm.toString(keeper));
        console2.log("Chain ID :", block.chainid);
        console2.log("");

        // ── Broadcast deployment transactions ─────────────────────────────────
        vm.startBroadcast(deployerKey);

        // 1. Treasury
        //    admin  → DEFAULT_ADMIN_ROLE (multisig)
        //    manager → MANAGER_ROLE
        Treasury treasury = new Treasury(admin, manager);
        console2.log("1. Treasury deployed          :", address(treasury));

        // 2. FeeCollector
        //    treasury → immutable, fees forwarded here
        //    admin    → DEFAULT_ADMIN_ROLE (can register sources)
        //    keeper   → KEEPER_ROLE (automation, optional)
        FeeCollector feeCollector = new FeeCollector(
            address(treasury),
            admin,
            keeper
        );
        console2.log("2. FeeCollector deployed       :", address(feeCollector));

        // 3. ZybraGroupFactory
        //    treasury → protocol fee destination for all groups
        //    owner    → deployer EOA (transferred to admin below)
        ZybraGroupFactory factory = new ZybraGroupFactory(address(treasury));
        console2.log("3. ZybraGroupFactory deployed  :", address(factory));

        // 4. Transfer factory ownership to admin multisig
        //    Uses the 2-step pattern in ZybraGroupFactory:
        //      deployer calls transferOwnership → admin calls acceptOwnership
        factory.transferOwnership(admin);
        console2.log("4. Factory ownership proposed -> pending owner:", admin);
        console2.log("   ACTION REQUIRED: admin must call factory.acceptOwnership()");

        vm.stopBroadcast();

        // ── Post-deploy wiring (must be done by admin multisig) ───────────────
        console2.log("");
        console2.log("=== Post-Deploy Actions Required from Admin Multisig ===");
        console2.log("");
        console2.log("A) Accept factory ownership:");
        console2.log("   factory.acceptOwnership()");
        console2.log("   factory :", address(factory));
        console2.log("");
        console2.log("B) Grant COLLECTOR_ROLE on Treasury to FeeCollector:");
        console2.log("   treasury.grantRole(COLLECTOR_ROLE, feeCollector)");
        console2.log("   COLLECTOR_ROLE :", vm.toString(COLLECTOR_ROLE));
        console2.log("   treasury       :", address(treasury));
        console2.log("   feeCollector   :", address(feeCollector));
        console2.log("");
        if (keeper == address(0)) {
            console2.log("C) Grant KEEPER_ROLE on FeeCollector to automation bot (when ready):");
            console2.log("   feeCollector.grantRole(KEEPER_ROLE, keeperBot)");
            console2.log("   feeCollector :", address(feeCollector));
            console2.log("");
        }
        console2.log("D) Register deployed ZybraGroup instances as fee sources:");
        console2.log("   feeCollector.registerSource(groupAddress)");
        console2.log("");

        // ── Final summary ─────────────────────────────────────────────────────
        console2.log("=== Deployment Summary (Mainnet) ===");
        console2.log("Treasury        :", address(treasury));
        console2.log("FeeCollector    :", address(feeCollector));
        console2.log("Factory         :", address(factory));
        console2.log("");
        console2.log("Verify on Etherscan:");
        console2.log("  forge verify-contract <address> src/treasury/Treasury.sol:Treasury --chain mainnet");
        console2.log("  forge verify-contract <address> src/treasury/FeeCollector.sol:FeeCollector --chain mainnet");
        console2.log("  forge verify-contract <address> src/ZybraGroupFactory.sol:ZybraGroupFactory --chain mainnet");
    }
}
