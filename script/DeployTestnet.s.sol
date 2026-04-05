// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script, console2} from "forge-std/Script.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {FeeCollector} from "../src/treasury/FeeCollector.sol";
import {ZybraGroupFactory} from "../src/ZybraGroupFactory.sol";

/**
 * @title DeployTestnet
 * @notice Deploys the full Zybra protocol stack on Sepolia testnet.
 *
 * Deployment order (dependencies flow top → bottom):
 *   1. Treasury          – needs: admin, manager
 *   2. FeeCollector      – needs: treasury, admin, keeper
 *   3. ZybraGroupFactory – needs: treasury
 *   4. Wire-up           – grant COLLECTOR_ROLE on Treasury to FeeCollector
 *
 * Required environment variables (.env):
 *   PRIVATE_KEY         – deployer private key (funds deployment gas)
 *   ADMIN_ADDRESS       – governance / multisig address (DEFAULT_ADMIN_ROLE)
 *   MANAGER_ADDRESS     – operations wallet (MANAGER_ROLE on Treasury)
 *   KEEPER_ADDRESS      – automation bot (KEEPER_ROLE on FeeCollector)
 *
 * Usage:
 *   forge script script/DeployTestnet.s.sol \
 *     --rpc-url sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployTestnet is Script {
    // ─── Role identifiers (must match Treasury.sol) ───────────────────────────
    bytes32 internal constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");

    function run() external {
        // ── Load configuration from environment ───────────────────────────────
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address admin   = vm.envAddress("ADMIN_ADDRESS");
        address manager = vm.envAddress("MANAGER_ADDRESS");
        address keeper  = vm.envAddress("KEEPER_ADDRESS");

        // ── Pre-flight checks ─────────────────────────────────────────────────
        require(admin   != address(0), "DeployTestnet: ADMIN_ADDRESS not set");
        require(manager != address(0), "DeployTestnet: MANAGER_ADDRESS not set");
        require(keeper  != address(0), "DeployTestnet: KEEPER_ADDRESS not set");

        console2.log("=== Zybra Protocol - Sepolia Testnet Deployment ===");
        console2.log("Deployer :", deployer);
        console2.log("Admin    :", admin);
        console2.log("Manager  :", manager);
        console2.log("Keeper   :", keeper);
        console2.log("Chain ID :", block.chainid);
        console2.log("");

        // ── Broadcast deployment transactions ─────────────────────────────────
        vm.startBroadcast(deployerKey);

        // 1. Treasury
        Treasury treasury = new Treasury(admin, manager);
        console2.log("1. Treasury deployed          :", address(treasury));

        // 2. FeeCollector
        FeeCollector feeCollector = new FeeCollector(
            address(treasury),
            admin,
            keeper
        );
        console2.log("2. FeeCollector deployed       :", address(feeCollector));

        // 3. ZybraGroupFactory
        ZybraGroupFactory factory = new ZybraGroupFactory(address(treasury));
        console2.log("3. ZybraGroupFactory deployed  :", address(factory));

        // 4. Grant COLLECTOR_ROLE on Treasury to FeeCollector
        //    (deployer is not admin — admin must call this manually if a multisig)
        //    If admin == deployer we can wire it here; otherwise emit instructions.
        if (admin == deployer) {
            treasury.grantRole(COLLECTOR_ROLE, address(feeCollector));
            console2.log("4. COLLECTOR_ROLE granted to FeeCollector (wired in script)");
        } else {
            console2.log("4. ACTION REQUIRED: grant COLLECTOR_ROLE on Treasury to FeeCollector");
            console2.log("   Call treasury.grantRole(COLLECTOR_ROLE, feeCollector) from:", admin);
        }

        vm.stopBroadcast();

        // ── Deployment summary ────────────────────────────────────────────────
        console2.log("");
        console2.log("=== Deployment Summary (Sepolia) ===");
        console2.log("Treasury        :", address(treasury));
        console2.log("FeeCollector    :", address(feeCollector));
        console2.log("Factory         :", address(factory));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  - If admin != deployer, grant COLLECTOR_ROLE on Treasury to FeeCollector");
        console2.log("  - Register any initial fee sources via feeCollector.registerSource(group)");
        console2.log("  - (Optional) Transfer factory ownership: factory.transferOwnership(admin)");
        console2.log("  - Verify contracts on Etherscan with --verify flag");
    }
}
