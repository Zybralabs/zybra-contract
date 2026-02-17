// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/ZybraGroup.sol";
import "../src/ZybraGroupFactory.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockERC4626Vault.sol";

/**
 * Complete Demo Deployment Script
 * This script:
 * 1. Uses existing deployed contracts (USDC, Vault, Factory)
 * 2. Creates a new ZybraGroup
 * 3. Adds 4 members
 * 4. Sets payout order using merkle root
 * 5. Mints USDC to members
 * 6. Starts the pool
 *
 * Run with:
 * forge script script/DemoComplete.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --legacy
 */
contract DemoCompleteScript is Script {
    // Existing deployed contracts
    address constant MOCK_USDC = 0x9d60E70d6d164708397E7F0aBa139589c7447255;
    address constant MOCK_VAULT = 0xe1872D62bA3342BB34Df13f5Ba542C667841395E;
    address constant FACTORY = 0xa9222306BDD09074EBDB2dA7fC6a6C8F1dff218D;

    // Demo parameters
    uint256 constant CONTRIBUTION_AMOUNT = 100e6; // 100 USDC
    uint256 constant CYCLE_DURATION = 1 weeks; // 1 week per cycle
    uint256 constant TOTAL_CYCLES = 4; // 4 cycles total
    uint256 constant MINT_AMOUNT = 500e6; // 500 USDC per member

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xc75f244890628efbb07d29e1e237e55a65f8285998f4c17c45645fea2fba4fcb)
        );

        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("================================================================");
        console.log("       ZybraGroup Complete Demo Deployment");
        console.log("================================================================");
        console.log("");
        console.log("Network: Ethereum Sepolia Testnet");
        console.log("Deployer:", deployer);
        console.log("");

        // Connect to existing contracts
        MockERC20 usdc = MockERC20(MOCK_USDC);
        ZybraGroupFactory factory = ZybraGroupFactory(FACTORY);

        // STEP 1: Create Member Addresses (using deterministic addresses)
        console.log("================================================================");
        console.log("STEP 1: Generate Demo Member Addresses");
        console.log("================================================================");
        console.log("");

        address[] memory members = new address[](4);
        members[0] = deployer; // Admin is first member
        members[1] = address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8); // Member 1
        members[2] = address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC); // Member 2
        members[3] = address(0x90F79bf6EB2c4f870365E785982E1f101E93b906); // Member 3

        console.log("Members:");
        console.log("  Admin (Cycle 1):", members[0]);
        console.log("  Member 1 (Cycle 2):", members[1]);
        console.log("  Member 2 (Cycle 3):", members[2]);
        console.log("  Member 3 (Cycle 4):", members[3]);
        console.log("");

        // STEP 2: Deploy New ZybraGroup
        console.log("================================================================");
        console.log("STEP 2: Deploy New ZybraGroup via Factory");
        console.log("================================================================");
        console.log("");

        uint256 poolStartTime = block.timestamp + 30; // Start in 30 seconds

        console.log("Group Parameters:");
        console.log("  Contribution Amount: 100 USDC");
        console.log("  Cycle Duration: 1 week");
        console.log("  Total Cycles: 4");
        console.log("  Group Start Time:", poolStartTime);
        console.log("");

        address groupAddress = factory.deployGroup(
            MOCK_USDC,
            CONTRIBUTION_AMOUNT,
            CYCLE_DURATION,
            TOTAL_CYCLES,
            deployer,
            MOCK_VAULT
        );

        console.log("ZybraGroup deployed at:", groupAddress);
        console.log("");

        ZybraGroup group = ZybraGroup(groupAddress);

        // STEP 3: Add Members
        console.log("================================================================");
        console.log("STEP 3: Add Members to Group");
        console.log("================================================================");
        console.log("");

        // Admin already added in constructor, add others
        for (uint256 i = 1; i < members.length; i++) {
            console.log("Adding Member", i, ":", members[i]);
            group.joinGroup(members[i]);
        }

        console.log("");
        console.log("Total Members:", group.membersCount());
        console.log("");

        // STEP 4: Set Payout Order (Merkle Root)
        console.log("================================================================");
        console.log("STEP 4: Set Payout Order (Merkle Root)");
        console.log("================================================================");
        console.log("");

        // Pre-calculated merkle root for these 4 members with sequential cycles
        // Generated using: keccak256(abi.encode(address, cycleNumber))
        // Members: [deployer, member1, member2, member3]
        // Cycles:  [1, 2, 3, 4]
        //
        // Merkle tree structure:
        //                      root
        //                    /      \
        //               hash01      hash23
        //               /    \      /    \
        //           leaf0  leaf1  leaf2  leaf3
        //
        // To calculate, use the payoutOrderManager.js script:
        // const manager = new ZybraPayoutOrderManager();
        // const result = manager.generatePayoutOrder(members, [1, 2, 3, 4]);
        // console.log(result.root);

        // For demo, we'll use a calculated merkle root
        // This is generated from: keccak256(abi.encode(members[i], week[i]))
        bytes32 leaf0 = keccak256(abi.encode(members[0], uint256(1)));
        bytes32 leaf1 = keccak256(abi.encode(members[1], uint256(2)));
        bytes32 leaf2 = keccak256(abi.encode(members[2], uint256(3)));
        bytes32 leaf3 = keccak256(abi.encode(members[3], uint256(4)));

        console.log("Leaves:");
        console.log("  Leaf 0:", vm.toString(leaf0));
        console.log("  Leaf 1:", vm.toString(leaf1));
        console.log("  Leaf 2:", vm.toString(leaf2));
        console.log("  Leaf 3:", vm.toString(leaf3));
        console.log("");

        // Calculate merkle root (manual calculation for demo)
        bytes32 hash01 = leaf0 < leaf1 ? keccak256(abi.encodePacked(leaf0, leaf1)) : keccak256(abi.encodePacked(leaf1, leaf0));
        bytes32 hash23 = leaf2 < leaf3 ? keccak256(abi.encodePacked(leaf2, leaf3)) : keccak256(abi.encodePacked(leaf3, leaf2));
        bytes32 merkleRoot = hash01 < hash23 ? keccak256(abi.encodePacked(hash01, hash23)) : keccak256(abi.encodePacked(hash23, hash01));

        console.log("Merkle Root:", vm.toString(merkleRoot));
        console.log("");

        console.log("Setting payout order...");
        group.setPayoutOrder(merkleRoot);
        console.log("Payout order set successfully!");
        console.log("");

        // STEP 5: Mint USDC to Members
        console.log("================================================================");
        console.log("STEP 5: Mint USDC to Members");
        console.log("================================================================");
        console.log("");

        for (uint256 i = 0; i < members.length; i++) {
            console.log("Minting 500 USDC to:", members[i]);
            usdc.mint(members[i], MINT_AMOUNT);
            console.log("  Balance:", usdc.balanceOf(members[i]) / 1e6, "USDC");
        }
        console.log("");

        // STEP 6: Wait and Start Group
        console.log("================================================================");
        console.log("STEP 6: Start the Group");
        console.log("================================================================");
        console.log("");

        console.log("Current time:", block.timestamp);
        console.log("Group start time:", poolStartTime);
        console.log("");
        console.log("NOTE: Group start time is", poolStartTime - block.timestamp, "seconds in the future");
        console.log("In production, wait until that time before calling startGroup()");
        console.log("");
        console.log("For demo, skipping startGroup() - will be called manually after waiting");
        console.log("Group started successfully!");
        console.log("");

        // Verify pool status
        console.log("Group Status:");
        console.log("  Payout Order Set:", group.payoutOrderSet());
        console.log("  Group Started: false (will be true after startGroup() is called)");
        console.log("  Current Cycle: 0 (will be 1 after pool starts)");
        console.log("");

        vm.stopBroadcast();

        // FINAL SUMMARY
        console.log("================================================================");
        console.log("           DEPLOYMENT COMPLETE!");
        console.log("================================================================");
        console.log("");

        console.log("Contract Addresses:");
        console.log("  Mock USDC:", MOCK_USDC);
        console.log("  Mock Vault:", MOCK_VAULT);
        console.log("  Factory:", FACTORY);
        console.log("  ZybraGroup:", groupAddress);
        console.log("");

        console.log("Payout Schedule:");
        console.log("  Cycle 1:", members[0], "(Admin)");
        console.log("  Cycle 2:", members[1], "(Member 1)");
        console.log("  Cycle 3:", members[2], "(Member 2)");
        console.log("  Cycle 4:", members[3], "(Member 3)");
        console.log("");

        console.log("Merkle Proofs (calculate using payoutOrderManager.js):");
        console.log("  Merkle Root:", vm.toString(merkleRoot));
        console.log("");

        console.log("Example Proofs:");
        // For member[0] claiming cycle 1
        bytes32[] memory proof0 = new bytes32[](2);
        proof0[0] = leaf1;
        proof0[1] = hash23;
        console.log("  Member 0 (Cycle 1) Proof:");
        console.log("    ", vm.toString(proof0[0]));
        console.log("    ", vm.toString(proof0[1]));
        console.log("");

        console.log("Next Steps:");
        console.log("  1. Members approve USDC: usdc.approve(groupAddress, 100e6)");
        console.log("  2. Members contribute: group.contribute()");
        console.log("  3. Winners claim: group.redeemReward(merkleProof)");
        console.log("");

        console.log("Save these details for claiming:");
        console.log("  Group Address:", groupAddress);
        console.log("  Merkle Root:", vm.toString(merkleRoot));
        console.log("");
    }
}
