/**
 * Complete Demo Deployment Script for ZybraGroup
 * Deploys contracts, sets up members, creates merkle tree, and starts the pool
 *
 * Run with: node scripts/demo-deploy.js
 */

const { ethers } = require('ethers');
const { ZybraPayoutOrderManager } = require('./payoutOrderManager');

// Demo Configuration
const DEMO_CONFIG = {
    // RPC and Network
    rpcUrl: 'https://eth-sepolia.g.alchemy.com/v2/1dUe6zHAjXocqykmyQks8EmNvFiPJ0p3',
    privateKey: '0xc75f244890628efbb07d29e1e237e55a65f8285998f4c17c45645fea2fba4fcb',

    // Deployed Contract Addresses (from previous deployment)
    mockUSDC: '0x9d60E70d6d164708397E7F0aBa139589c7447255',
    mockVault: '0xe1872D62bA3342BB34Df13f5Ba542C667841395E',
    factory: '0xa9222306BDD09074EBDB2dA7fC6a6C8F1dff218D',

    // Group Parameters
    contributionAmount: 100, // 100 USDC per week
    cycleLength: 4, // 4 weeks cycle

    // Demo Members (generate 4 test wallets)
    memberCount: 4
};

// ABI snippets (minimal for this demo)
const USDC_ABI = [
    "function mint(address to, uint256 amount) external",
    "function balanceOf(address account) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function decimals() view returns (uint8)"
];

const FACTORY_ABI = [
    "function deployGroup(address asset, uint256 contributionAmount, uint256 cycleLength, address admin, address vault, uint256 poolStartTime) returns (address)",
    "event GroupCreated(address indexed group, address indexed admin)"
];

const GROUP_ABI = [
    "function joinGroup(address member) external",
    "function setPayoutOrder(bytes32 merkleRoot) external",
    "function startGroup() external",
    "function membersCount() view returns (uint256)",
    "function getGroupInfo() view returns (address, address, uint256, uint256, uint256, uint256, bool, bytes32)",
    "function payoutOrderSet() view returns (bool)",
    "function poolStarted() view returns (bool)"
];

async function main() {
    console.log("╔═══════════════════════════════════════════════════════════╗");
    console.log("║       ZybraGroup Complete Demo Deployment                 ║");
    console.log("╚═══════════════════════════════════════════════════════════╝\n");

    // Setup provider and signer
    const provider = new ethers.providers.JsonRpcProvider(DEMO_CONFIG.rpcUrl);
    const signer = new ethers.Wallet(DEMO_CONFIG.privateKey, provider);

    console.log("📍 Network: Ethereum Sepolia Testnet");
    console.log("👤 Deployer:", signer.address);
    console.log("💰 Balance:", ethers.utils.formatEther(await signer.getBalance()), "ETH\n");

    // Connect to contracts
    const usdc = new ethers.Contract(DEMO_CONFIG.mockUSDC, USDC_ABI, signer);
    const factory = new ethers.Contract(DEMO_CONFIG.factory, FACTORY_ABI, signer);

    // Step 1: Generate Demo Member Wallets
    console.log("═══════════════════════════════════════════════════════════");
    console.log("STEP 1: Generate Demo Member Wallets");
    console.log("═══════════════════════════════════════════════════════════\n");

    const members = [];
    const memberWallets = [];

    // Admin is first member
    members.push(signer.address);
    memberWallets.push({ address: signer.address, privateKey: DEMO_CONFIG.privateKey, role: 'Admin' });

    // Generate additional members
    for (let i = 1; i < DEMO_CONFIG.memberCount; i++) {
        const wallet = ethers.Wallet.createRandom();
        members.push(wallet.address);
        memberWallets.push({
            address: wallet.address,
            privateKey: wallet.privateKey,
            role: `Member ${i}`
        });
    }

    console.log("Generated Members:");
    memberWallets.forEach((wallet, idx) => {
        console.log(`  ${idx + 1}. ${wallet.role}`);
        console.log(`     Address: ${wallet.address}`);
        console.log(`     Private Key: ${wallet.privateKey}\n`);
    });

    // Step 2: Deploy New ZybraGroup
    console.log("═══════════════════════════════════════════════════════════");
    console.log("STEP 2: Deploy New ZybraGroup via Factory");
    console.log("═══════════════════════════════════════════════════════════\n");

    const contributionAmount = ethers.utils.parseUnits(DEMO_CONFIG.contributionAmount.toString(), 6);
    const poolStartTime = Math.floor(Date.now() / 1000) + 300; // Start in 5 minutes

    console.log("Group Parameters:");
    console.log("  Contribution Amount:", DEMO_CONFIG.contributionAmount, "USDC");
    console.log("  Cycle Length:", DEMO_CONFIG.cycleLength, "weeks");
    console.log("  Group Start Time:", new Date(poolStartTime * 1000).toISOString());
    console.log("  Admin:", signer.address);
    console.log("\nDeploying...");

    const deployTx = await factory.deployGroup(
        DEMO_CONFIG.mockUSDC,
        contributionAmount,
        DEMO_CONFIG.cycleLength,
        signer.address,
        DEMO_CONFIG.mockVault,
        poolStartTime
    );

    console.log("Transaction sent:", deployTx.hash);
    const receipt = await deployTx.wait();

    // Get group address from event
    const event = receipt.events?.find(e => e.event === 'GroupCreated');
    const groupAddress = event?.args?.group;

    console.log("✅ ZybraGroup deployed at:", groupAddress);
    console.log("✅ Transaction confirmed in block:", receipt.blockNumber, "\n");

    // Connect to the deployed group
    const group = new ethers.Contract(groupAddress, GROUP_ABI, signer);

    // Step 3: Add Members to Group
    console.log("═══════════════════════════════════════════════════════════");
    console.log("STEP 3: Add Members to Group");
    console.log("═══════════════════════════════════════════════════════════\n");

    // Admin is already added in constructor, so add the rest
    for (let i = 1; i < members.length; i++) {
        console.log(`Adding Member ${i}: ${members[i]}`);
        const tx = await group.joinGroup(members[i]);
        await tx.wait();
        console.log("  ✅ Added successfully\n");
    }

    const memberCount = await group.membersCount();
    console.log(`✅ Total Members: ${memberCount.toString()}\n`);

    // Step 4: Generate Merkle Tree and Set Payout Order
    console.log("═══════════════════════════════════════════════════════════");
    console.log("STEP 4: Generate Merkle Tree & Set Payout Order");
    console.log("═══════════════════════════════════════════════════════════\n");

    const payoutManager = new ZybraPayoutOrderManager();

    // Sequential payout order: member 0 gets week 1, member 1 gets week 2, etc.
    const payoutOrder = [1, 2, 3, 4];

    console.log("Payout Order:");
    members.forEach((member, idx) => {
        console.log(`  Week ${payoutOrder[idx]}: ${member} (${memberWallets[idx].role})`);
    });
    console.log("");

    const merkleResult = payoutManager.generatePayoutOrder(members, payoutOrder);
    console.log("Merkle Root:", merkleResult.root);
    console.log("Total Leaves:", merkleResult.leafCount, "\n");

    console.log("Setting payout order on contract...");
    const setPayoutTx = await group.setPayoutOrder(merkleResult.root);
    await setPayoutTx.wait();
    console.log("✅ Payout order set successfully!\n");

    // Verify
    const isPayoutOrderSet = await group.payoutOrderSet();
    console.log("Payout Order Set:", isPayoutOrderSet, "\n");

    // Step 5: Mint USDC to All Members
    console.log("═══════════════════════════════════════════════════════════");
    console.log("STEP 5: Mint USDC to Members");
    console.log("═══════════════════════════════════════════════════════════\n");

    const mintAmount = ethers.utils.parseUnits("500", 6); // 500 USDC each

    for (let i = 0; i < members.length; i++) {
        console.log(`Minting to ${memberWallets[i].role}: ${members[i]}`);
        const tx = await usdc.mint(members[i], mintAmount);
        await tx.wait();
        const balance = await usdc.balanceOf(members[i]);
        console.log(`  ✅ Balance: ${ethers.utils.formatUnits(balance, 6)} USDC\n`);
    }

    // Step 6: Start the Group (wait until start time)
    console.log("═══════════════════════════════════════════════════════════");
    console.log("STEP 6: Start the Group");
    console.log("═══════════════════════════════════════════════════════════\n");

    const currentTime = Math.floor(Date.now() / 1000);
    if (currentTime < poolStartTime) {
        const waitTime = poolStartTime - currentTime;
        console.log(`⏳ Waiting ${waitTime} seconds until pool start time...`);
        console.log(`   Current time: ${new Date(currentTime * 1000).toISOString()}`);
        console.log(`   Start time:   ${new Date(poolStartTime * 1000).toISOString()}\n`);

        // Wait
        await new Promise(resolve => setTimeout(resolve, (waitTime + 5) * 1000));
    }

    console.log("Starting pool...");
    const startTx = await group.startGroup();
    await startTx.wait();
    console.log("✅ Group started successfully!\n");

    // Verify
    const poolStarted = await group.poolStarted();
    console.log("Group Started:", poolStarted, "\n");

    // Final Summary
    console.log("═══════════════════════════════════════════════════════════");
    console.log("🎉 DEPLOYMENT COMPLETE!");
    console.log("═══════════════════════════════════════════════════════════\n");

    console.log("📋 Deployment Summary:\n");
    console.log("Contract Addresses:");
    console.log("  Mock USDC:", DEMO_CONFIG.mockUSDC);
    console.log("  Mock Vault:", DEMO_CONFIG.mockVault);
    console.log("  Factory:", DEMO_CONFIG.factory);
    console.log("  ZybraGroup:", groupAddress);
    console.log("");

    console.log("Group Configuration:");
    console.log("  Contribution Amount:", DEMO_CONFIG.contributionAmount, "USDC per week");
    console.log("  Cycle Length:", DEMO_CONFIG.cycleLength, "weeks");
    console.log("  Total Members:", memberCount.toString());
    console.log("  Payout Order Set: ✅");
    console.log("  Group Started: ✅");
    console.log("");

    console.log("Member Details:");
    memberWallets.forEach((wallet, idx) => {
        const proof = payoutManager.getProof(wallet.address, payoutOrder[idx]);
        console.log(`\n  ${wallet.role}:`);
        console.log(`    Address: ${wallet.address}`);
        console.log(`    Week: ${payoutOrder[idx]}`);
        console.log(`    USDC Balance: 500 USDC`);
        console.log(`    Merkle Proof: [${proof.length} elements]`);
        if (idx === 0) {
            console.log(`    Proof: ${JSON.stringify(proof)}`);
        }
    });

    console.log("\n\n═══════════════════════════════════════════════════════════");
    console.log("📝 Next Steps:");
    console.log("═══════════════════════════════════════════════════════════\n");

    console.log("1. Members can now contribute:");
    console.log("   - Each member must contribute 100 USDC per week");
    console.log("   - Use: group.contribute() (after approving USDC)\n");

    console.log("2. Winners can claim payouts:");
    console.log("   - Week 1 winner:", memberWallets[0].role);
    console.log("   - Week 2 winner:", memberWallets[1].role);
    console.log("   - Week 3 winner:", memberWallets[2].role);
    console.log("   - Week 4 winner:", memberWallets[3].role);
    console.log("   - Use: group.redeemReward(merkleProof)\n");

    console.log("3. Check status:");
    console.log("   - Current week: group.getCurrentWeek()");
    console.log("   - Expected payout: group.getExpectedPayoutAmount()");
    console.log("   - Group status: group.getGroupStatus()\n");

    // Save deployment info
    const deploymentInfo = {
        network: "sepolia",
        timestamp: new Date().toISOString(),
        contracts: {
            mockUSDC: DEMO_CONFIG.mockUSDC,
            mockVault: DEMO_CONFIG.mockVault,
            factory: DEMO_CONFIG.factory,
            zybraGroup: groupAddress
        },
        groupConfig: {
            contributionAmount: DEMO_CONFIG.contributionAmount,
            cycleLength: DEMO_CONFIG.cycleLength,
            poolStartTime: poolStartTime,
            poolStartTimeISO: new Date(poolStartTime * 1000).toISOString()
        },
        members: memberWallets.map((wallet, idx) => ({
            role: wallet.role,
            address: wallet.address,
            privateKey: wallet.privateKey,
            payoutWeek: payoutOrder[idx],
            merkleProof: payoutManager.getProof(wallet.address, payoutOrder[idx])
        })),
        merkleRoot: merkleResult.root
    };

    const fs = require('fs');
    const outputPath = './deployments/demo-latest.json';
    fs.mkdirSync('./deployments', { recursive: true });
    fs.writeFileSync(outputPath, JSON.stringify(deploymentInfo, null, 2));

    console.log("💾 Deployment info saved to:", outputPath);
    console.log("\n✨ All set! The pool is now live and ready for contributions!\n");
}

// Run the script
if (require.main === module) {
    main()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error("\n❌ Error:", error);
            process.exit(1);
        });
}

module.exports = { main, DEMO_CONFIG };
