/**
 * Check Group Yield Status - Compare on-chain vs subgraph data
 * Investigate why yield is 0 across all groups
 */

const { ethers } = require('ethers');
require('dotenv').config();

// Sepolia RPC - using public Ankr endpoint
const RPC_URL = 'https://rpc.ankr.com/eth_sepolia';

// Groups from subgraph with capital
const GROUPS_TO_CHECK = [
  { address: '0x6ff65454fc73657e0b59cc21bef0533eb13379a7', capital: '100000000', started: true },
  { address: '0x0dd384f29ad882e08eba05900175f4b0750a405c', capital: '200000000', started: true },
  { address: '0xc80374896d1fd967772d37f4902ee3e9958d0ab0', capital: '2000000000', started: true },
  { address: '0xab0e9e644789a41f9614bc3aa52fbe92f9b67cc1', capital: '24000000', started: true }
];

// Minimal ABI for ZybraGroupV2
const ZYBRA_GROUP_ABI = [
  'function getGroupStatus() external view returns (bool started, bool ended, uint256 currentCycle, uint256 totalMembers, uint256 totalCapital, uint256 totalYield, uint256 feesAccumulated)',
  'function vault() external view returns (address)',
  'function totalCapitalInGroup() external view returns (uint256)',
  'function groupStartTime() external view returns (uint256)'
];

// Minimal ABI for Morpho Vault (ERC4626)
const VAULT_ABI = [
  'function balanceOf(address account) external view returns (uint256)',
  'function convertToAssets(uint256 shares) external view returns (uint256)',
  'function totalAssets() external view returns (uint256)',
  'function asset() external view returns (address)'
];

async function checkGroupYield() {
  console.log('\n🔍 YIELD INVESTIGATION REPORT');
  console.log('═'.repeat(80));
  console.log(`Network: Sepolia`);
  console.log(`Checking ${GROUPS_TO_CHECK.length} groups with capital...`);
  console.log('═'.repeat(80));

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  
  for (const group of GROUPS_TO_CHECK) {
    try {
      console.log(`\n📊 Group: ${group.address}`);
      console.log(`   Expected Capital: ${group.capital} (${ethers.formatUnits(group.capital, 6)} USDC)`);
      console.log(`   Started: ${group.started}`);
      
      const groupContract = new ethers.Contract(group.address, ZYBRA_GROUP_ABI, provider);
      
      // Get group status
      const status = await groupContract.getGroupStatus();
      const [started, ended, currentCycle, totalMembers, totalCapital, totalYield, feesAccumulated] = status;
      
      console.log(`\n   On-Chain State:`);
      console.log(`   ├─ Started: ${started}`);
      console.log(`   ├─ Ended: ${ended}`);
      console.log(`   ├─ Current Cycle: ${currentCycle.toString()}`);
      console.log(`   ├─ Total Members: ${totalMembers.toString()}`);
      console.log(`   ├─ Total Capital: ${totalCapital.toString()} (${ethers.formatUnits(totalCapital, 6)} USDC)`);
      console.log(`   ├─ Total Yield: ${totalYield.toString()} (${ethers.formatUnits(totalYield, 6)} USDC)`);
      console.log(`   └─ Fees Accumulated: ${feesAccumulated.toString()} (${ethers.formatUnits(feesAccumulated, 6)} USDC)`);
      
      // Get vault info
      const vaultAddress = await groupContract.vault();
      const groupStartTime = await groupContract.groupStartTime();
      
      console.log(`\n   Vault Info:`);
      console.log(`   ├─ Vault Address: ${vaultAddress}`);
      console.log(`   └─ Group Start Time: ${groupStartTime.toString()} (${new Date(Number(groupStartTime) * 1000).toISOString()})`);
      
      const vaultContract = new ethers.Contract(vaultAddress, VAULT_ABI, provider);
      
      // Check vault state
      const vaultShares = await vaultContract.balanceOf(group.address);
      const vaultValue = vaultShares > 0n ? await vaultContract.convertToAssets(vaultShares) : 0n;
      const vaultTotalAssets = await vaultContract.totalAssets();
      const underlyingAsset = await vaultContract.asset();
      
      console.log(`\n   Vault State:`);
      console.log(`   ├─ Group's Shares: ${vaultShares.toString()}`);
      console.log(`   ├─ Group's Asset Value: ${vaultValue.toString()} (${ethers.formatUnits(vaultValue, 6)} USDC)`);
      console.log(`   ├─ Vault Total Assets: ${vaultTotalAssets.toString()} (${ethers.formatUnits(vaultTotalAssets, 6)} USDC)`);
      console.log(`   └─ Underlying Asset: ${underlyingAsset}`);
      
      // Yield analysis
      const expectedYield = vaultValue > totalCapital ? vaultValue - totalCapital : 0n;
      
      console.log(`\n   Yield Analysis:`);
      console.log(`   ├─ Expected Yield (vaultValue - capital): ${expectedYield.toString()} (${ethers.formatUnits(expectedYield, 6)} USDC)`);
      console.log(`   ├─ Reported Yield: ${totalYield.toString()} (${ethers.formatUnits(totalYield, 6)} USDC)`);
      console.log(`   ├─ Match: ${expectedYield === totalYield ? '✅' : '❌'}`);
      
      // Time since start
      const now = Math.floor(Date.now() / 1000);
      const timeSinceStart = groupStartTime > 0n ? now - Number(groupStartTime) : 0;
      const daysSinceStart = timeSinceStart / 86400;
      
      console.log(`\n   Time Info:`);
      console.log(`   ├─ Time Since Start: ${timeSinceStart}s (${daysSinceStart.toFixed(2)} days)`);
      console.log(`   └─ Expected Yield per Day (rough): ${(Number(totalCapital) * 0.05 / 365).toFixed(2)} USDC (assuming 5% APY)`);
      
      // Diagnosis
      console.log(`\n   🔍 Diagnosis:`);
      if (totalYield === 0n) {
        if (!started) {
          console.log(`   ❌ Group not started yet - no yield expected`);
        } else if (vaultShares === 0n) {
          console.log(`   ❌ No vault shares - capital not deposited to vault`);
        } else if (vaultValue === totalCapital) {
          console.log(`   ⚠️  Vault value equals capital - no yield generated yet`);
          console.log(`      This is NORMAL for:`);
          console.log(`      - Recently started groups (< 1 day)`);
          console.log(`      - Low capital amounts`);
          console.log(`      - Mock vaults with manual yield generation`);
        } else {
          console.log(`   ❓ Unknown issue - vault has value but yield is 0`);
        }
      } else {
        console.log(`   ✅ Yield is being generated`);
      }
      
    } catch (error) {
      console.error(`\n   ❌ Error checking group ${group.address}:`, error.message);
    }
    
    console.log('\n' + '─'.repeat(80));
  }
  
  // Summary and recommendations
  console.log(`\n\n📋 SUMMARY & RECOMMENDATIONS`);
  console.log('═'.repeat(80));
  console.log(`\nPossible reasons for 0 yield:`);
  console.log(`\n1. ⏱️  TIME: Groups recently started - yield accumulates over time`);
  console.log(`   - Check: How long has each group been active?`);
  console.log(`   - Action: Wait 24-48 hours for yield to accumulate`);
  console.log(`\n2. 🏦 VAULT TYPE: Using MockMorphVault that requires manual yield generation`);
  console.log(`   - Check: Is this a mock vault?`);
  console.log(`   - Action: Call generateYield() on MockMorphVault if needed`);
  console.log(`\n3. 💰 CAPITAL: Small amounts may generate negligible yield`);
  console.log(`   - Check: Capital amounts (24 USDC won't generate much yield in days)`);
  console.log(`   - Action: Use larger test amounts (1000+ USDC)`);
  console.log(`\n4. 📊 SUBGRAPH: Subgraph updates only on events (not continuous)`);
  console.log(`   - Check: Has any yield claim/withdrawal event occurred?`);
  console.log(`   - Action: Trigger an event (contribute, claim) to refresh subgraph`);
  console.log(`\n5. 🔧 INTEGRATION: Real Morpho vault may have delays or requirements`);
  console.log(`   - Check: Is this a real Morpho vault or mock?`);
  console.log(`   - Action: Verify vault is functioning correctly`);
  
  console.log(`\n\n🔬 NEXT STEPS:`);
  console.log(`1. Check if vault is MockMorphVault - if so, call generateYield()`);
  console.log(`2. Wait 24 hours and check again`);
  console.log(`3. Trigger a contribution or other event to refresh subgraph`);
  console.log(`4. Check vault's totalAssets() growth over time`);
  console.log('═'.repeat(80));
}

checkGroupYield().catch(error => {
  console.error('\n❌ Fatal error:', error);
  process.exit(1);
});
