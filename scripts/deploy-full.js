/**
 * Full deployment script for ZybraGroup ecosystem
 * Deploys: MockUSDC, MockVault, ZybraGroupFactory, and a test ZybraGroup
 */

const hre = require("hardhat");
const { ethers } = require("hardhat");

async function main() {
    console.log("=== ZybraGroup Full Deployment ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deploying with account:", deployer.address);
    console.log("Account balance:", ethers.utils.formatEther(await deployer.getBalance()), "ETH\n");

    // 1. Deploy Mock USDC
    console.log("1. Deploying Mock USDC...");
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const mockUSDC = await MockERC20.deploy("Mock USDC", "USDC", 6);
    await mockUSDC.deployed();
    console.log("✓ Mock USDC deployed at:", mockUSDC.address);

    // Mint USDC to deployer (10,000 USDC)
    const mintAmount = ethers.utils.parseUnits("10000", 6);
    await mockUSDC.mint(deployer.address, mintAmount);
    console.log("✓ Minted", ethers.utils.formatUnits(mintAmount, 6), "USDC to deployer\n");

    // 2. Deploy Mock ERC4626 Vault
    console.log("2. Deploying Mock ERC4626 Vault (MetaMorpho)...");
    const MockVault = await ethers.getContractFactory("MockERC4626Vault");
    const mockVault = await MockVault.deploy(
        mockUSDC.address,
        "Mock Morpho Vault",
        "mvUSDC"
    );
    await mockVault.deployed();
    console.log("✓ Mock Vault deployed at:", mockVault.address);
    console.log("✓ Vault Name:", await mockVault.name());
    console.log("✓ Vault Symbol:", await mockVault.symbol(), "\n");

    // 3. Deploy ZybraGroupFactory
    console.log("3. Deploying ZybraGroupFactory...");
    const ZybraGroupFactory = await ethers.getContractFactory("ZybraGroupFactory");
    const factory = await ZybraGroupFactory.deploy();
    await factory.deployed();
    console.log("✓ ZybraGroupFactory deployed at:", factory.address, "\n");

    // 4. Deploy a test ZybraGroup via factory
    console.log("4. Deploying test ZybraGroup via factory...");
    const contributionAmount = ethers.utils.parseUnits("100", 6); // 100 USDC
    const cycleLength = 4; // 4 weeks
    const poolStartTime = Math.floor(Date.now() / 1000) + 3600; // Start in 1 hour

    const tx = await factory.deployGroup(
        mockUSDC.address,
        contributionAmount,
        cycleLength,
        deployer.address,
        mockVault.address,
        poolStartTime
    );
    const receipt = await tx.wait();

    // Get deployed group address from event
    const event = receipt.events?.find(e => e.event === "GroupCreated");
    const groupAddress = event?.args?.group;

    console.log("✓ ZybraGroup deployed at:", groupAddress);
    console.log("✓ Contribution Amount:", ethers.utils.formatUnits(contributionAmount, 6), "USDC");
    console.log("✓ Cycle Length:", cycleLength, "weeks");
    console.log("✓ Group Start Time:", new Date(poolStartTime * 1000).toISOString(), "\n");

    // 5. Get group details
    const ZybraGroup = await ethers.getContractFactory("ZybraGroup");
    const group = ZybraGroup.attach(groupAddress);

    const groupInfo = await group.getGroupInfo();
    console.log("=== Group Details ===");
    console.log("Admin:", groupInfo.groupAdmin);
    console.log("Asset:", groupInfo.groupAsset);
    console.log("Contribution Amount:", ethers.utils.formatUnits(groupInfo.groupContributionAmount, 6), "USDC");
    console.log("Cycle Length:", groupInfo.groupCycleLength.toString(), "seconds");
    console.log("Members Count:", groupInfo.groupMembersCount.toString());
    console.log("Is Paused:", groupInfo.isPaused);
    console.log("Merkle Root:", groupInfo.currentMerkleRoot, "\n");

    // 6. Summary
    console.log("=== Deployment Summary ===");
    console.log("Network:", hre.network.name);
    console.log("Deployer:", deployer.address);
    console.log("Deployer Balance:", ethers.utils.formatUnits(await mockUSDC.balanceOf(deployer.address), 6), "USDC");
    console.log("\n=== Contract Addresses ===");
    console.log("Mock USDC:", mockUSDC.address);
    console.log("Mock Vault (MetaMorpho):", mockVault.address);
    console.log("ZybraGroupFactory:", factory.address);
    console.log("Test ZybraGroup:", groupAddress);

    // 7. Save deployment info to file
    const fs = require('fs');
    const deploymentInfo = {
        network: hre.network.name,
        deployer: deployer.address,
        timestamp: new Date().toISOString(),
        contracts: {
            mockUSDC: {
                address: mockUSDC.address,
                name: "Mock USDC",
                symbol: "USDC",
                decimals: 6,
                deployerBalance: ethers.utils.formatUnits(await mockUSDC.balanceOf(deployer.address), 6)
            },
            mockVault: {
                address: mockVault.address,
                name: await mockVault.name(),
                symbol: await mockVault.symbol(),
                asset: await mockVault.asset()
            },
            factory: {
                address: factory.address,
                name: "ZybraGroupFactory",
                totalGroups: (await factory.totalGroups()).toString()
            },
            testGroup: {
                address: groupAddress,
                admin: deployer.address,
                contributionAmount: ethers.utils.formatUnits(contributionAmount, 6),
                cycleLength: cycleLength,
                poolStartTime: poolStartTime
            }
        }
    };

    const outputPath = './deployments/latest.json';
    fs.mkdirSync('./deployments', { recursive: true });
    fs.writeFileSync(outputPath, JSON.stringify(deploymentInfo, null, 2));
    console.log("\n✓ Deployment info saved to:", outputPath);

    console.log("\n=== Next Steps ===");
    console.log("1. Add members: group.joinGroup(memberAddress)");
    console.log("2. Set payout order: group.setPayoutOrder(merkleRoot)");
    console.log("3. Start pool: group.startGroup()");
    console.log("4. Members contribute: group.contribute()");
    console.log("5. Winners claim: group.redeemReward(merkleProof)");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
