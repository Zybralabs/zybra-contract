/**
 * ZybraGroup Payout Order Manager
 * Handles Merkle tree generation and proof creation for ZybraGroup contract payout orders
 * 
 * Required dependencies:
 * npm install ethers keccak256 merkletreejs
 */

const { MerkleTree } = require('merkletreejs');
const keccak256 = require('keccak256');
const { ethers } = require('ethers');

class ZybraPayoutOrderManager {
    constructor() {
        this.tree = null;
        this.leaves = [];
        this.payoutOrder = [];
        this.memberWeekMapping = new Map(); // For quick lookups
    }

    /**
     * Generate Merkle tree for payout order
     * @param {string[]} members - Array of member addresses (checksummed)
     * @param {number[]} payoutOrder - Array defining the order (week numbers for each member)
     * @returns {Object} - Contains merkle root, tree, and leaves
     */
    generatePayoutOrder(members, payoutOrder) {
        // Validate inputs
        this._validateInputs(members, payoutOrder);

        // Reset state
        this.leaves = [];
        this.payoutOrder = [];
        this.memberWeekMapping.clear();

        // Create leaves: keccak256(abi.encodePacked(address, weekNumber))
        for (let i = 0; i < members.length; i++) {
            const memberAddress = ethers.utils.getAddress(members[i]); // Ensure checksum
            const weekNumber = payoutOrder[i];
            
            // Solidity abi.encodePacked equivalent
            const packed = ethers.utils.solidityPack(
                ['address', 'uint256'], 
                [memberAddress, weekNumber]
            );
            
            const leaf = keccak256(packed);
            this.leaves.push(leaf);
            
            const payoutItem = {
                member: memberAddress,
                week: weekNumber,
                leaf: '0x' + leaf.toString('hex'),
                index: i
            };
            
            this.payoutOrder.push(payoutItem);
            this.memberWeekMapping.set(`${memberAddress}-${weekNumber}`, payoutItem);
        }

        // Create Merkle tree with sorted pairs (must match contract implementation)
        this.tree = new MerkleTree(this.leaves, keccak256, { sortPairs: true });
        
        const root = this.tree.getHexRoot();
        
        return {
            root,
            tree: this.tree,
            leaves: this.payoutOrder,
            leafCount: this.leaves.length,
            schedule: this.getPayoutSchedule()
        };
    }

    /**
     * Validate inputs for Merkle tree generation
     * @param {string[]} members - Member addresses
     * @param {number[]} payoutOrder - Week assignments
     */
    _validateInputs(members, payoutOrder) {
        if (!Array.isArray(members) || !Array.isArray(payoutOrder)) {
            throw new Error('Members and payout order must be arrays');
        }

        if (members.length !== payoutOrder.length) {
            throw new Error('Members and payout order arrays must have same length');
        }

        if (members.length === 0) {
            throw new Error('Cannot create payout order for empty member list');
        }

        // Validate addresses
        for (const member of members) {
            if (!ethers.utils.isAddress(member)) {
                throw new Error(`Invalid address: ${member}`);
            }
        }

        // Validate payout order contains exactly numbers 1 to members.length
        const sortedOrder = [...payoutOrder].sort((a, b) => a - b);
        for (let i = 0; i < sortedOrder.length; i++) {
            if (sortedOrder[i] !== i + 1) {
                throw new Error(`Invalid payout order. Expected consecutive weeks 1-${members.length}, got: ${payoutOrder}`);
            }
        }

        // Check for duplicates in members
        const uniqueMembers = new Set(members.map(addr => addr.toLowerCase()));
        if (uniqueMembers.size !== members.length) {
            throw new Error('Duplicate member addresses found');
        }
    }

    /**
     * Get Merkle proof for a specific member and week
     * @param {string} memberAddress - Member's address
     * @param {number} weekNumber - Week number for payout
     * @returns {string[]} - Merkle proof array (hex strings)
     */
    getProof(memberAddress, weekNumber) {
        if (!this.tree) {
            throw new Error('Merkle tree not generated. Call generatePayoutOrder first.');
        }

        const checksumAddress = ethers.utils.getAddress(memberAddress);
        const key = `${checksumAddress}-${weekNumber}`;
        
        if (!this.memberWeekMapping.has(key)) {
            throw new Error(`No payout assignment found for member ${checksumAddress} in week ${weekNumber}`);
        }

        // Generate leaf
        const packed = ethers.utils.solidityPack(
            ['address', 'uint256'], 
            [checksumAddress, weekNumber]
        );
        const leaf = keccak256(packed);
        
        // Get proof
        const proof = this.tree.getHexProof(leaf);
        
        return proof;
    }

    /**
     * Verify a proof locally (for testing)
     * @param {string[]} proof - Merkle proof (hex strings)
     * @param {string} memberAddress - Member's address  
     * @param {number} weekNumber - Week number
     * @returns {boolean} - True if proof is valid
     */
    verifyProof(proof, memberAddress, weekNumber) {
        if (!this.tree) {
            throw new Error('Merkle tree not generated');
        }

        const checksumAddress = ethers.utils.getAddress(memberAddress);
        const packed = ethers.utils.solidityPack(
            ['address', 'uint256'], 
            [checksumAddress, weekNumber]
        );
        const leaf = keccak256(packed);
        
        return this.tree.verify(proof, leaf, this.tree.getRoot());
    }

    /**
     * Get complete payout schedule sorted by week
     * @returns {Array} - Sorted payout schedule by week
     */
    getPayoutSchedule() {
        return [...this.payoutOrder].sort((a, b) => a.week - b.week);
    }

    /**
     * Get member assigned to a specific week
     * @param {number} weekNumber - Week number
     * @returns {string|null} - Member address or null if not found
     */
    getMemberForWeek(weekNumber) {
        const item = this.payoutOrder.find(p => p.week === weekNumber);
        return item ? item.member : null;
    }

    /**
     * Get week assigned to a specific member
     * @param {string} memberAddress - Member address
     * @returns {number|null} - Week number or null if not found
     */
    getWeekForMember(memberAddress) {
        const checksumAddress = ethers.utils.getAddress(memberAddress);
        const item = this.payoutOrder.find(p => p.member === checksumAddress);
        return item ? item.week : null;
    }

    /**
     * Export complete payout data for storage
     * @returns {Object} - Complete payout data with proofs
     */
    exportPayoutData() {
        if (!this.tree) {
            throw new Error('Merkle tree not generated');
        }

        return {
            merkleRoot: this.tree.getHexRoot(),
            schedule: this.getPayoutSchedule(),
            proofs: this.payoutOrder.map(item => ({
                member: item.member,
                week: item.week,
                leaf: item.leaf,
                proof: this.getProof(item.member, item.week)
            })),
            metadata: {
                totalMembers: this.payoutOrder.length,
                totalWeeks: this.payoutOrder.length,
                createdAt: new Date().toISOString()
            }
        };
    }

    /**
     * Import payout data (useful for reconstructing from stored data)
     * @param {Object} data - Previously exported payout data
     */
    importPayoutData(data) {
        if (!data.schedule || !Array.isArray(data.schedule)) {
            throw new Error('Invalid payout data format');
        }

        const members = data.schedule.map(item => item.member);
        const weeks = data.schedule.map(item => item.week);

        // Reconstruct the tree
        this.generatePayoutOrder(members, weeks);

        // Verify imported data matches
        if (this.tree.getHexRoot() !== data.merkleRoot) {
            throw new Error('Imported data does not match reconstructed tree');
        }
    }

    /**
     * Generate random payout order (for testing)
     * @param {string[]} members - Member addresses
     * @returns {number[]} - Random week assignments
     */
    static generateRandomOrder(members) {
        const weeks = Array.from({ length: members.length }, (_, i) => i + 1);
        
        // Fisher-Yates shuffle
        for (let i = weeks.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            [weeks[i], weeks[j]] = [weeks[j], weeks[i]];
        }
        
        return weeks;
    }
}

/**
 * Contract interaction helper class
 */
class ZybraGroupContract {
    constructor(contractAddress, abi, signer) {
        this.contract = new ethers.Contract(contractAddress, abi, signer);
        this.payoutManager = new ZybraPayoutOrderManager();
    }

    /**
     * Set payout order on the smart contract
     * @param {string[]} members - Member addresses
     * @param {number[]} payoutOrder - Week assignments
     * @param {Object} options - Transaction options
     * @returns {Object} - Transaction result and payout data
     */
    async setPayoutOrder(members, payoutOrder, options = {}) {
        const result = this.payoutManager.generatePayoutOrder(members, payoutOrder);
        
        console.log('Setting payout order with Merkle root:', result.root);
        console.log('Payout schedule:', result.schedule);
        
        // Call contract function
        const tx = await this.contract.setPayoutOrder(result.root, options);
        const receipt = await tx.wait();
        
        console.log('Payout order set successfully. Transaction:', receipt.transactionHash);
        
        return {
            transaction: receipt,
            payoutData: result,
            exportData: this.payoutManager.exportPayoutData()
        };
    }

    /**
     * Claim payout for a member (redeemReward)
     * @param {string} memberAddress - Member claiming (only needed for proof generation)
     * @param {number} weekNumber - Week to claim (only needed for proof generation)
     * @param {Object} options - Transaction options
     * @returns {Object} - Transaction receipt with payout details
     *
     * UPDATED: ZybraGroup.redeemReward() now only takes merkleProof parameter.
     * The contract automatically:
     * - Gets current week from block.timestamp
     * - Calculates payout amount (contributions + yield)
     * - Validates the member's assigned week via merkle proof
     */
    async claimPayout(memberAddress, weekNumber, options = {}) {
        // Generate merkle proof for member's assigned week
        const proof = this.payoutManager.getProof(memberAddress, weekNumber);

        console.log(`Claiming payout for ${memberAddress} for week ${weekNumber}`);
        console.log('Using proof:', proof);

        // Get expected payout amount for display (optional, for logging)
        const expectedPayout = await this.contract.getExpectedPayoutAmount();
        console.log(`Expected payout amount: ${ethers.utils.formatUnits(expectedPayout, 6)} USDC`);

        // Call contract function - UPDATED: Only merkleProof parameter
        // Contract automatically:
        // - Uses getCurrentWeek() to determine current week
        // - Validates proof matches keccak256(abi.encode(msg.sender, currentWeek))
        // - Calculates payout = (contributionAmount * memberCount) + accumulatedYield
        const tx = await this.contract.redeemReward(
            proof,
            options
        );

        const receipt = await tx.wait();
        console.log('Payout claimed successfully. Transaction:', receipt.transactionHash);

        // Extract payout amount from RewardRedeemed event
        const rewardEvent = receipt.events?.find(e => e.event === 'RewardRedeemed');
        if (rewardEvent) {
            const payoutAmount = rewardEvent.args.amount;
            console.log(`Actual payout received: ${ethers.utils.formatUnits(payoutAmount, 6)} USDC`);
        }

        return receipt;
    }

    /**
     * Get current contract state
     * UPDATED: Uses new view functions from optimized ZybraGroup
     */
    async getContractState() {
        const [
            payoutOrderSet,
            payoutOrderMerkleRoot,
            currentWeek,
            poolStarted,
            memberCount,
            poolStatus,
            currentReward
        ] = await Promise.all([
            this.contract.payoutOrderSet(),
            this.contract.payoutOrderMerkleRoot(),
            this.contract.getCurrentWeek(),
            this.contract.poolStarted(),
            this.contract.membersCount(),
            this.contract.getGroupStatus(),
            this.contract.getCurrentReward()
        ]);

        return {
            payoutOrderSet,
            payoutOrderMerkleRoot,
            currentWeek: currentWeek.toNumber(),
            poolStarted,
            memberCount: memberCount.toNumber(),
            poolStatus: {
                started: poolStatus.started,
                ended: poolStatus.ended,
                currentWeek: poolStatus.currentWeek.toNumber(),
                totalMembers: poolStatus.totalMembers.toNumber(),
                activeMembers: poolStatus.activeMembers.toNumber(),
                accumulatedYield: ethers.utils.formatUnits(poolStatus.accumulatedYield, 6),
                vaultBalance: ethers.utils.formatUnits(poolStatus.vaultBalance, 6)
            },
            currentReward: {
                totalAssets: ethers.utils.formatUnits(currentReward.totalAssets, 6),
                totalDeposited: ethers.utils.formatUnits(currentReward.totalDeposited, 6),
                netYield: ethers.utils.formatUnits(currentReward.netYield, 6)
            }
        };
    }

    /**
     * Get current reward details (yield calculation)
     * @returns {Object} - Reward breakdown with yield
     *
     * Uses optimized getCurrentReward() which returns:
     * - totalAssets: contract balance + vault assets
     * - totalDeposited: total amount deposited to vault
     * - netYield: vaultAssets - totalDeposited (winner takes ALL)
     */
    async getCurrentReward() {
        const reward = await this.contract.getCurrentReward();

        return {
            totalAssets: ethers.utils.formatUnits(reward.totalAssets, 6),
            totalDeposited: ethers.utils.formatUnits(reward.totalDeposited, 6),
            netYield: ethers.utils.formatUnits(reward.netYield, 6),
            raw: {
                totalAssets: reward.totalAssets,
                totalDeposited: reward.totalDeposited,
                netYield: reward.netYield
            }
        };
    }

    /**
     * Get expected payout amount for current week
     * @returns {Object} - Expected payout details
     *
     * Uses getExpectedPayoutAmount() which returns:
     * - ALL contributions for the week + ALL accumulated yield
     * - Winner-takes-all model (yield NOT divided by memberCount)
     */
    async getExpectedPayout() {
        const payout = await this.contract.getExpectedPayoutAmount();

        return {
            formatted: ethers.utils.formatUnits(payout, 6),
            raw: payout,
            currency: 'USDC'
        };
    }

    /**
     * Check if a member can claim for a specific week
     * @param {string} memberAddress - Member address
     * @param {number} weekNumber - Week number
     * @returns {Object} - Claim eligibility details
     */
    async canMemberClaim(memberAddress, weekNumber) {
        const result = await this.contract.canMemberClaim(memberAddress, weekNumber);

        return {
            canClaim: result.canClaim,
            reason: result.reason,
            memberAddress,
            weekNumber
        };
    }

    /**
     * Get member's contribution status for current cycle
     * @param {string} memberAddress - Member address
     * @returns {Object} - Contribution details
     */
    async getMemberContributionStatus(memberAddress) {
        const currentWeek = await this.contract.getCurrentWeek();
        const contributionAmount = await this.contract.contributionAmount();
        const contributed = await this.contract.getMemberContributionForCycle(
            memberAddress,
            currentWeek
        );
        const hasContributed = await this.contract.hasContributedThisCycle(memberAddress);

        return {
            currentWeek: currentWeek.toNumber(),
            contributionRequired: ethers.utils.formatUnits(contributionAmount, 6),
            contributionMade: ethers.utils.formatUnits(contributed, 6),
            hasContributed,
            needsToContribute: !hasContributed
        };
    }

    /**
     * Get comprehensive pool and yield status
     * @returns {Object} - Complete pool status including yield details
     */
    async getGroupAndYieldStatus() {
        const [poolStatus, currentReward, expectedPayout, currentWeek] = await Promise.all([
            this.contract.getGroupStatus(),
            this.contract.getCurrentReward(),
            this.contract.getExpectedPayoutAmount(),
            this.contract.getCurrentWeek()
        ]);

        return {
            pool: {
                started: poolStatus.started,
                ended: poolStatus.ended,
                currentWeek: poolStatus.currentWeek.toNumber(),
                totalMembers: poolStatus.totalMembers.toNumber(),
                activeMembers: poolStatus.activeMembers.toNumber()
            },
            yield: {
                totalAssets: ethers.utils.formatUnits(currentReward.totalAssets, 6),
                totalDeposited: ethers.utils.formatUnits(currentReward.totalDeposited, 6),
                accumulatedYield: ethers.utils.formatUnits(currentReward.netYield, 6),
                vaultBalance: ethers.utils.formatUnits(poolStatus.vaultBalance, 6)
            },
            payout: {
                expectedAmount: ethers.utils.formatUnits(expectedPayout, 6),
                currentWeek: currentWeek.toNumber(),
                currency: 'USDC'
            }
        };
    }
}

// Export classes and utility functions
module.exports = {
    ZybraPayoutOrderManager,
    ZybraGroupContract,
    
    // Utility functions
    generateRandomPayoutOrder: ZybraPayoutOrderManager.generateRandomOrder,
    
    // Helper function for testing
    createTestScenario: (memberCount = 5) => {
        const members = Array.from({ length: memberCount }, (_, i) => 
            ethers.Wallet.createRandom().address
        );
        const randomOrder = ZybraPayoutOrderManager.generateRandomOrder(members);
        
        return { members, payoutOrder: randomOrder };
    }
};

// Example usage (uncomment to run)
/*
async function example() {
    try {
        const manager = new ZybraPayoutOrderManager();

        // Test scenario
        const testMembers = [
            '0x1234567890123456789012345678901234567890',
            '0x2345678901234567890123456789012345678901',
            '0x3456789012345678901234567890123456789012'
        ];

        const testOrder = [2, 1, 3]; // Member 0 gets week 2, Member 1 gets week 1, Member 2 gets week 3

        // Generate payout order
        const result = manager.generatePayoutOrder(testMembers, testOrder);
        console.log('Merkle Root:', result.root);
        console.log('Schedule:', result.schedule);

        // Get proof for member 1 claiming week 1
        const proof = manager.getProof(testMembers[1], 1);
        console.log('Proof for member 1, week 1:', proof);

        // Verify proof
        const isValid = manager.verifyProof(proof, testMembers[1], 1);
        console.log('Proof valid:', isValid);

        // Export complete data
        const exportData = manager.exportPayoutData();
        console.log('Export data:', JSON.stringify(exportData, null, 2));

    } catch (error) {
        console.error('Error:', error.message);
    }
}

// example();
*/

// UPDATED Example: Contract integration with new ZybraGroup functions
/*
async function exampleContractIntegration() {
    try {
        // Setup (assuming you have provider and signer)
        const provider = new ethers.providers.JsonRpcProvider('YOUR_RPC_URL');
        const signer = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);

        const contractAddress = '0xYourContractAddress';
        const abi = []; // Your ZybraGroup ABI

        const zybraContract = new ZybraGroupContract(contractAddress, abi, signer);

        // 1. Get current pool and yield status
        console.log('\n=== Group and Yield Status ===');
        const status = await zybraContract.getGroupAndYieldStatus();
        console.log('Group Started:', status.pool.started);
        console.log('Current Week:', status.pool.currentWeek);
        console.log('Total Members:', status.pool.totalMembers);
        console.log('Active Members:', status.pool.activeMembers);
        console.log('Accumulated Yield:', status.yield.accumulatedYield, 'USDC');
        console.log('Expected Payout:', status.payout.expectedAmount, 'USDC');

        // 2. Get current reward breakdown
        console.log('\n=== Reward Breakdown ===');
        const reward = await zybraContract.getCurrentReward();
        console.log('Total Assets:', reward.totalAssets, 'USDC');
        console.log('Total Deposited:', reward.totalDeposited, 'USDC');
        console.log('Net Yield:', reward.netYield, 'USDC');

        // 3. Check if member can claim
        console.log('\n=== Claim Eligibility ===');
        const memberAddress = '0xMemberAddress';
        const currentWeek = status.pool.currentWeek;
        const eligibility = await zybraContract.canMemberClaim(memberAddress, currentWeek);
        console.log('Can Claim:', eligibility.canClaim);
        console.log('Reason:', eligibility.reason);

        // 4. Get member contribution status
        console.log('\n=== Member Contribution Status ===');
        const contribStatus = await zybraContract.getMemberContributionStatus(memberAddress);
        console.log('Current Week:', contribStatus.currentWeek);
        console.log('Contribution Required:', contribStatus.contributionRequired, 'USDC');
        console.log('Contribution Made:', contribStatus.contributionMade, 'USDC');
        console.log('Has Contributed:', contribStatus.hasContributed);

        // 5. Claim payout (if eligible)
        if (eligibility.canClaim) {
            console.log('\n=== Claiming Payout ===');
            // UPDATED: claimPayout now only needs memberAddress and weekNumber
            // It automatically generates proof and calls redeemReward(merkleProof)
            const receipt = await zybraContract.claimPayout(memberAddress, currentWeek);
            console.log('Claim successful! Transaction:', receipt.transactionHash);
        }

    } catch (error) {
        console.error('Error:', error.message);
    }
}

// exampleContractIntegration();
*/

// Quick reference for key changes:
/*
=== KEY UPDATES TO ZybraGroup CONTRACT ===

1. redeemReward() function signature changed:
   OLD: redeemReward(weekNumber, amount, merkleProof)
   NEW: redeemReward(merkleProof)

   The contract now automatically:
   - Gets current week from block.timestamp via getCurrentWeek()
   - Calculates payout amount (contributions + yield)
   - Uses merkle proof to verify: keccak256(abi.encode(msg.sender, currentWeek))

2. Yield calculation optimized:
   - Uses totalDepositedToVault state variable for tracking
   - Yield = vaultAssets - totalDepositedToVault
   - Winner takes ALL yield (not divided by member count)
   - Auto-deposit to vault on contribute() for immediate yield generation

3. New view functions added:
   - getCurrentReward(): Returns (totalAssets, totalDeposited, netYield)
   - getExpectedPayoutAmount(): Returns total payout for current week
   - getGroupStatus(): Returns comprehensive pool status with yield
   - canMemberClaim(address, week): Check if member can claim
   - getMemberContributionForCycle(address, cycle): Get contribution amount
   - hasContributedThisCycle(address): Check if contributed for current week

4. Auto-deposit flow:
   - contribute() now automatically deposits to vault
   - No need for manual depositToMorpho() calls
   - Yield starts accumulating immediately

=== INTEGRATION CHANGES ===

1. claimPayout() updated:
   - Removed 'amount' parameter (contract calculates it)
   - Only takes memberAddress and weekNumber for proof generation
   - Calls contract.redeemReward(proof) with just merkle proof

2. New helper functions:
   - getCurrentReward(): Get yield breakdown
   - getExpectedPayout(): Get expected payout amount
   - canMemberClaim(): Check claim eligibility
   - getMemberContributionStatus(): Get member's contribution details
   - getGroupAndYieldStatus(): Get comprehensive status

3. getContractState() enhanced:
   - Now includes poolStatus and currentReward data
   - Returns formatted USDC amounts
   - Shows accumulated yield and vault balance
*/