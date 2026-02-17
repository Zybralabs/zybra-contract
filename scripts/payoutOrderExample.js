/**
 * Complete example demonstrating ZybraGroup payout order flow
 * This script shows how to:
 * 1. Generate Merkle tree for custom payout order
 * 2. Set payout order on contract
 * 3. Generate proofs for claiming
 * 4. Test the complete flow
 */

const { ethers } = require('ethers');
const { ZybraPayoutOrderManager, ZybraGroupContract } = require('./payoutOrderManager');

// Mock contract ABI (replace with actual ABI)
const ZYBRA_GROUP_ABI = [
    "function setPayoutOrder(bytes32 _merkleRoot) external",
    "function redeemReward(uint256 payoutNumber, uint256 amount, bytes32[] calldata merkleProof) external",
    "function payoutOrderSet() external view returns (bool)",
    "function payoutOrderMerkleRoot() external view returns (bytes32)",
    "function currentWeek() external view returns (uint256)",
    "function poolStarted() external view returns (bool)",
    "function membersCount() external view returns (uint256)",
    "function membersList(uint256) external view returns (address)",
    "function members(address) external view returns (uint256, bool, uint256, bool, uint256)"
];

async function demonstrateCompleteFlow() {
    console.log('='.repeat(60));
    console.log('ZybraGroup Payout Order Complete Flow Demo');
    console.log('='.repeat(60));
    
    try {
        // Step 1: Setup test data
        console.log('\n1. Setting up test data...');
        
        const testMembers = [
            '0x742d35Cc6635C0532925a3b8D47D8c982312BC3f',
            '0x8ba1f109551bD432803012645Hac136c0532925a3b',
            '0x9aC25c2f21B1679147c0532925a3b8D47D8c23445',
            '0x123D40ef502155CC6635C0532925a3b8D47D8c99',
            '0x456BE809551bD432803012645Hac136c053292aa'
        ];
        
        // Custom payout order: who gets paid in which week
        // [3, 1, 5, 2, 4] means:
        // - Member 0 gets paid in week 3
        // - Member 1 gets paid in week 1  
        // - Member 2 gets paid in week 5
        // - Member 3 gets paid in week 2
        // - Member 4 gets paid in week 4
        const customPayoutOrder = [3, 1, 5, 2, 4];
        
        console.log('Members:', testMembers);
        console.log('Custom payout order:', customPayoutOrder);
        
        // Step 2: Generate Merkle tree
        console.log('\n2. Generating Merkle tree...');
        
        const payoutManager = new ZybraPayoutOrderManager();
        const result = payoutManager.generatePayoutOrder(testMembers, customPayoutOrder);
        
        console.log('✅ Merkle Root:', result.root);
        console.log('✅ Total leaves:', result.leafCount);
        
        // Step 3: Display payout schedule
        console.log('\n3. Payout Schedule:');
        console.log('-'.repeat(60));
        console.log('Week | Member Address                              ');
        console.log('-'.repeat(60));
        
        const schedule = payoutManager.getPayoutSchedule();
        schedule.forEach(item => {
            console.log(`${item.week.toString().padStart(4)} | ${item.member}`);
        });
        
        // Step 4: Generate and verify proofs for each member
        console.log('\n4. Generating and verifying proofs...');
        console.log('-'.repeat(80));
        console.log('Member                                      | Week | Proof Valid');
        console.log('-'.repeat(80));
        
        const allProofs = [];
        
        for (const item of schedule) {
            const proof = payoutManager.getProof(item.member, item.week);
            const isValid = payoutManager.verifyProof(proof, item.member, item.week);
            
            allProofs.push({
                member: item.member,
                week: item.week,
                proof,
                isValid
            });
            
            const shortAddress = `${item.member.substring(0, 6)}...${item.member.substring(38)}`;
            console.log(`${shortAddress.padEnd(43)} | ${item.week.toString().padStart(4)} | ${isValid ? '✅' : '❌'}`);
        }
        
        // Step 5: Simulate contract interaction (without actual deployment)
        console.log('\n5. Contract Interaction Simulation...');
        
        // This would be the actual contract call:
        console.log('Setting payout order on contract:');
        console.log(`contract.setPayoutOrder("${result.root}")`);
        
        // Step 6: Simulate claiming process
        console.log('\n6. Simulating claim process...');
        console.log('-'.repeat(80));
        
        // Example: Member 1 (index 1) claims their assigned week (week 1)
        const claimingMember = testMembers[1];
        const claimingWeek = customPayoutOrder[1]; // Should be week 1
        const claimingProof = payoutManager.getProof(claimingMember, claimingWeek);
        
        console.log(`Member claiming: ${claimingMember}`);
        console.log(`Claiming week: ${claimingWeek}`);
        console.log(`Proof length: ${claimingProof.length}`);
        console.log(`Proof: [${claimingProof.join(', ')}]`);
        
        // This would be the actual contract call:
        const claimAmount = ethers.utils.parseEther('1000'); // 1000 tokens
        console.log('\nContract call would be:');
        console.log(`contract.redeemReward(${claimingWeek}, "${claimAmount}", [${claimingProof.map(p => `"${p}"`).join(', ')}])`);
        
        // Step 7: Export complete data for storage
        console.log('\n7. Exporting complete payout data...');
        
        const exportData = payoutManager.exportPayoutData();
        
        // Save to file (optional)
        const fs = require('fs').promises;
        await fs.writeFile(
            'payout_data.json', 
            JSON.stringify(exportData, null, 2)
        );
        console.log('✅ Payout data exported to payout_data.json');
        
        // Step 8: Summary
        console.log('\n8. Summary:');
        console.log('-'.repeat(40));
        console.log(`Total members: ${testMembers.length}`);
        console.log(`Total weeks: ${testMembers.length}`);
        console.log(`Merkle root: ${result.root}`);
        console.log(`All proofs valid: ${allProofs.every(p => p.isValid) ? '✅' : '❌'}`);
        
        // Return data for further use
        return {
            merkleRoot: result.root,
            schedule,
            proofs: allProofs,
            exportData
        };
        
    } catch (error) {
        console.error('❌ Error in demonstration:', error.message);
        console.error(error.stack);
        throw error;
    }
}

/**
 * Example with actual contract interaction (requires deployed contract)
 */
async function contractInteractionExample() {
    console.log('\n' + '='.repeat(60));
    console.log('Contract Interaction Example');
    console.log('='.repeat(60));
    
    // Setup (you would need to replace these with actual values)
    const contractAddress = '0x1234567890123456789012345678901234567890'; // Replace with actual
    const privateKey = 'your-private-key-here'; // Replace with actual
    const rpcUrl = 'https://your-rpc-endpoint'; // Replace with actual
    
    try {
        // Setup provider and signer
        const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
        const signer = new ethers.Wallet(privateKey, provider);
        
        // Create contract interaction helper
        const zybraContract = new ZybraGroupContract(contractAddress, ZYBRA_GROUP_ABI, signer);
        
        // Get current contract state
        console.log('Getting contract state...');
        const state = await zybraContract.getContractState();
        console.log('Contract state:', state);
        
        if (state.payoutOrderSet) {
            console.log('⚠️  Payout order already set, cannot demonstrate setPayoutOrder');
            return;
        }
        
        // Example members (you would get these from the contract)
        const members = [
            '0x742d35Cc6635C0532925a3b8D47D8c982312BC3f',
            '0x8ba1f109551bD432803012645Hac136c0532925a3b',
            '0x9aC25c2f21B1679147c0532925a3b8D47D8c23445'
        ];
        
        const payoutOrder = [2, 1, 3];
        
        // Set payout order
        console.log('Setting payout order...');
        const result = await zybraContract.setPayoutOrder(members, payoutOrder, {
            gasLimit: 300000
        });
        
        console.log('✅ Payout order set successfully!');
        console.log('Transaction hash:', result.transaction.transactionHash);
        
        // Later, when claiming:
        const memberToClaim = members[1]; // Second member
        const weekToClaim = 1; // They're assigned to week 1
        const amountToClaim = ethers.utils.parseEther('1000');
        
        // This would typically be called by the member themselves
        /*
        console.log('Claiming payout...');
        const claimResult = await zybraContract.claimPayout(
            memberToClaim,
            weekToClaim,
            amountToClaim.toString(),
            { gasLimit: 400000 }
        );
        console.log('✅ Payout claimed!');
        console.log('Transaction hash:', claimResult.transactionHash);
        */
        
    } catch (error) {
        console.error('❌ Contract interaction error:', error.message);
        
        if (error.code === 'INSUFFICIENT_FUNDS') {
            console.error('💡 Make sure the signer account has enough ETH for gas fees');
        } else if (error.code === 'CALL_EXCEPTION') {
            console.error('💡 Contract call failed - check if conditions are met (admin access, pool not started, etc.)');
        }
    }
}

/**
 * Test different payout scenarios
 */
async function testScenarios() {
    console.log('\n' + '='.repeat(60));
    console.log('Testing Different Scenarios');
    console.log('='.repeat(60));
    
    const scenarios = [
        {
            name: 'Small Group (3 members)',
            members: 3,
            description: 'Testing basic functionality with minimal group'
        },
        {
            name: 'Medium Group (10 members)', 
            members: 10,
            description: 'Testing with typical group size'
        },
        {
            name: 'Large Group (20 members)',
            members: 20,
            description: 'Testing scalability with larger group'
        }
    ];
    
    for (const scenario of scenarios) {
        console.log(`\nTesting: ${scenario.name}`);
        console.log(`Description: ${scenario.description}`);
        console.log('-'.repeat(40));
        
        try {
            // Generate test data
            const members = Array.from({ length: scenario.members }, () => 
                ethers.Wallet.createRandom().address
            );
            const randomOrder = ZybraPayoutOrderManager.generateRandomOrder(members);
            
            // Create manager and generate tree
            const manager = new ZybraPayoutOrderManager();
            const result = manager.generatePayoutOrder(members, randomOrder);
            
            console.log(`✅ Generated Merkle tree with ${result.leafCount} leaves`);
            console.log(`✅ Merkle root: ${result.root}`);
            
            // Test a few random proofs
            const testCount = Math.min(3, scenario.members);
            let validProofs = 0;
            
            for (let i = 0; i < testCount; i++) {
                const member = members[i];
                const week = randomOrder[i];
                const proof = manager.getProof(member, week);
                const isValid = manager.verifyProof(proof, member, week);
                
                if (isValid) validProofs++;
            }
            
            console.log(`✅ Verified ${validProofs}/${testCount} proofs successfully`);
            
        } catch (error) {
            console.error(`❌ Scenario failed: ${error.message}`);
        }
    }
}

// Main execution
async function main() {
    try {
        // Run the complete demonstration
        const demoResult = await demonstrateCompleteFlow();
        
        // Test different scenarios
        await testScenarios();
        
        // Contract interaction example (commented out as it requires actual contract)
        // await contractInteractionExample();
        
        console.log('\n🎉 All demonstrations completed successfully!');
        
    } catch (error) {
        console.error('❌ Main execution failed:', error.message);
        process.exit(1);
    }
}

// Run if called directly
if (require.main === module) {
    main();
}

module.exports = {
    demonstrateCompleteFlow,
    contractInteractionExample,
    testScenarios
};