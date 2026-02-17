/**
 * Diagnose contribute() revert issues
 * Checks all preconditions for a successful contribution
 */

const { ethers } = require('ethers');

// Configuration
const RPC_URL = 'https://ethereum-sepolia-rpc.publicnode.com';
const GROUP_CONTRACT = '0x4552A6448Ba6Da96fe509236a9fb674f761689a9';
const USER_ADDRESS = '0x302A51a6899B67e78b9Ede846278DD25AF7c3019';

// Minimal ABIs
const GROUP_ABI = [
  'function asset() view returns (address)',
  'function vault() view returns (address)',
  'function contributionAmount() view returns (uint256)',
  'function groupStarted() view returns (bool)',
  'function groupEnded() view returns (bool)',
  'function paused() view returns (bool)',
  'function isMember(address) view returns (bool)',
  'function getCurrentCycle() view returns (uint256)',
  'function contributedInCycle(address, uint256) view returns (bool)',
  'function members(address) view returns (uint128 capitalInGroup, uint128 pendingYield, uint64 lastContributedCycle, uint64 joinedAt, bool isActive)',
  'function getGroupStatus() view returns (bool started, bool ended, uint256 currentCycle, uint256 totalMembers, uint256 totalCapital, uint256 totalYield, uint256 protocolFees)',
  'function admin() view returns (address)',
];

const ERC20_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
];

async function diagnose() {
  console.log('='.repeat(60));
  console.log('CONTRIBUTE FUNCTION DIAGNOSTIC');
  console.log('='.repeat(60));
  console.log(`\nGroup Contract: ${GROUP_CONTRACT}`);
  console.log(`User Address: ${USER_ADDRESS}`);
  console.log('');

  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const group = new ethers.Contract(GROUP_CONTRACT, GROUP_ABI, provider);

  try {
    // 1. Check if contract exists
    const code = await provider.getCode(GROUP_CONTRACT);
    if (code === '0x') {
      console.log('❌ ERROR: No contract deployed at this address!');
      return;
    }
    console.log('✅ Contract exists at address');

    // 2. Get asset address
    const assetAddress = await group.asset();
    console.log(`\n📍 Asset (ERC20) Address: ${assetAddress}`);
    
    const asset = new ethers.Contract(assetAddress, ERC20_ABI, provider);
    
    let symbol = 'UNKNOWN';
    let decimals = 6;
    try {
      symbol = await asset.symbol();
      decimals = await asset.decimals();
    } catch (e) {
      console.log('⚠️  Could not fetch token symbol/decimals');
    }
    console.log(`   Token: ${symbol} (${decimals} decimals)`);

    // 3. Get contribution amount
    const contributionAmount = await group.contributionAmount();
    console.log(`\n💰 Contribution Amount: ${ethers.formatUnits(contributionAmount, decimals)} ${symbol}`);

    // 4. Check group state
    console.log('\n--- GROUP STATE ---');
    const [started, ended, currentCycle, totalMembers, totalCapital] = await group.getGroupStatus();
    const paused = await group.paused();
    const admin = await group.admin();
    
    console.log(`   Admin: ${admin}`);
    console.log(`   Started: ${started} ${started ? '✅' : '❌ Group must be started first!'}`);
    console.log(`   Ended: ${ended} ${!ended ? '✅' : '❌ Group has ended!'}`);
    console.log(`   Paused: ${paused} ${!paused ? '✅' : '❌ Contract is paused!'}`);
    console.log(`   Current Cycle: ${currentCycle}`);
    console.log(`   Total Members: ${totalMembers}`);
    console.log(`   Total Capital: ${ethers.formatUnits(totalCapital, decimals)} ${symbol}`);

    // 5. Check member status
    console.log('\n--- MEMBER STATUS ---');
    const isMember = await group.isMember(USER_ADDRESS);
    console.log(`   Is Member: ${isMember} ${isMember ? '✅' : '❌ User must join group first!'}`);

    if (isMember) {
      const memberInfo = await group.members(USER_ADDRESS);
      console.log(`   Capital In Group: ${ethers.formatUnits(memberInfo.capitalInGroup, decimals)} ${symbol}`);
      console.log(`   Pending Yield: ${ethers.formatUnits(memberInfo.pendingYield, decimals)} ${symbol}`);
      console.log(`   Last Contributed Cycle: ${memberInfo.lastContributedCycle}`);
      console.log(`   Is Active: ${memberInfo.isActive}`);
      
      // Check if already contributed this cycle
      const alreadyContributed = await group.contributedInCycle(USER_ADDRESS, currentCycle);
      console.log(`   Already Contributed This Cycle: ${alreadyContributed} ${!alreadyContributed ? '✅' : '❌ Already contributed!'}`);
    }

    // 6. Check ERC20 balance and allowance
    console.log('\n--- TOKEN BALANCES & ALLOWANCES ---');
    const userBalance = await asset.balanceOf(USER_ADDRESS);
    const userAllowance = await asset.allowance(USER_ADDRESS, GROUP_CONTRACT);
    
    console.log(`   User ${symbol} Balance: ${ethers.formatUnits(userBalance, decimals)}`);
    console.log(`   User Allowance to Group: ${ethers.formatUnits(userAllowance, decimals)}`);
    
    const hasEnoughBalance = userBalance >= contributionAmount;
    const hasEnoughAllowance = userAllowance >= contributionAmount;
    
    console.log(`   Has Enough Balance: ${hasEnoughBalance ? '✅' : '❌ INSUFFICIENT BALANCE!'}`);
    console.log(`   Has Enough Allowance: ${hasEnoughAllowance ? '✅' : '❌ INSUFFICIENT ALLOWANCE!'}`);

    if (!hasEnoughBalance) {
      const needed = contributionAmount - userBalance;
      console.log(`\n   ⚠️  Need ${ethers.formatUnits(needed, decimals)} more ${symbol}`);
    }

    if (!hasEnoughAllowance) {
      console.log(`\n   ⚠️  User must approve ${ethers.formatUnits(contributionAmount, decimals)} ${symbol} to ${GROUP_CONTRACT}`);
    }

    // 7. Check vault
    console.log('\n--- VAULT STATUS ---');
    const vaultAddress = await group.vault();
    console.log(`   Vault Address: ${vaultAddress}`);
    
    const vaultCode = await provider.getCode(vaultAddress);
    if (vaultCode === '0x') {
      console.log('   ❌ No contract at vault address!');
    } else {
      console.log('   ✅ Vault contract exists');
      
      // Check group's allowance to vault
      const groupAllowanceToVault = await asset.allowance(GROUP_CONTRACT, vaultAddress);
      console.log(`   Group's Allowance to Vault: ${ethers.formatUnits(groupAllowanceToVault, decimals)} ${symbol}`);
    }

    // Summary
    console.log('\n' + '='.repeat(60));
    console.log('DIAGNOSIS SUMMARY');
    console.log('='.repeat(60));
    
    const issues = [];
    if (!started) issues.push('Group not started - admin must call startGroup()');
    if (ended) issues.push('Group has ended');
    if (paused) issues.push('Contract is paused');
    if (!isMember) issues.push('User is not a member - must call joinGroup() first');
    if (isMember) {
      const alreadyContributed = await group.contributedInCycle(USER_ADDRESS, currentCycle);
      if (alreadyContributed) issues.push('User already contributed this cycle');
    }
    if (!hasEnoughBalance) issues.push(`Insufficient ${symbol} balance`);
    if (!hasEnoughAllowance) issues.push(`Insufficient ${symbol} allowance - user must approve tokens`);

    if (issues.length === 0) {
      console.log('\n✅ All checks passed! The transaction should succeed.');
      console.log('   If still failing, check:');
      console.log('   1. The vault deposit function');
      console.log('   2. Network/gas issues');
    } else {
      console.log('\n❌ Found issues:\n');
      issues.forEach((issue, i) => {
        console.log(`   ${i + 1}. ${issue}`);
      });
    }

  } catch (error) {
    console.error('\n❌ Error during diagnosis:', error.message);
  }
}

diagnose().catch(console.error);
