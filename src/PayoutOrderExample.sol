// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title ZybraGroup Payout Order Example
 * @dev This contract demonstrates how the sequential payout system works
 */

/*
PAYOUT ORDER SYSTEM EXPLANATION:

1. Group Setup:
   - Admin creates group with 4 members for 4-week cycle
   - Member1 gets payoutWeek = 1 (first to receive)
   - Member2 gets payoutWeek = 2 (second to receive)
   - Member3 gets payoutWeek = 3 (third to receive)
   - Member4 gets payoutWeek = 4 (last to receive)

2. Merkle Tree Structure:
   Each leaf = keccak256(abi.encodePacked(memberAddress, payoutNumber))
   
   Example leaves:
   - Leaf1 = keccak256(abi.encodePacked(member1Address, 1))
   - Leaf2 = keccak256(abi.encodePacked(member2Address, 2))
   - Leaf3 = keccak256(abi.encodePacked(member3Address, 3))
   - Leaf4 = keccak256(abi.encodePacked(member4Address, 4))

3. Sequential Payout Rules:
   Week 1: Only Member1 can claim (designated for week 1)
   Week 2: Only Member2 can claim (requires week 1 completed)
   Week 3: Only Member3 can claim (requires week 2 completed)
   Week 4: Only Member4 can claim (requires week 3 completed)

4. Security Validations:
   ✅ Member2 CANNOT claim in week 1 (wrong week)
   ✅ Member1 CANNOT claim in week 2 (already claimed)
   ✅ Member3 CANNOT claim in week 2 (not their turn)
   ✅ Member3 CANNOT skip to week 3 if week 2 not completed

5. Merkle Proof Generation (Off-chain):
   ```javascript
   function generateMerkleProof(members, targetMember, targetWeek) {
     const leaves = members.map((member, index) => 
       ethers.utils.solidityKeccak256(
         ["address", "uint256"], 
         [member.address, index + 1]
       )
     );
     
     const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });
     const leaf = ethers.utils.solidityKeccak256(
       ["address", "uint256"], 
       [targetMember, targetWeek]
     );
     
     return tree.getHexProof(leaf);
   }
   ```

6. Example Usage Flow:

   Deploy Contract:
   ```solidity
   // Generate merkle root off-chain from member list
   bytes32 merkleRoot = 0x1234...;
   
   ZybraGroup group = new ZybraGroup(
     usdcAddress,
     100e6, // 100 USDC per contribution
     4,     // 4 week cycle
     admin,
     morphoAddress,
     marketParams,
     merkleRoot
   );
   ```

   Add Members:
   ```solidity
   group.joinGroup(member1, 1); // Gets week 1 payout
   group.joinGroup(member2, 2); // Gets week 2 payout
   group.joinGroup(member3, 3); // Gets week 3 payout
   group.joinGroup(member4, 4); // Gets week 4 payout
   ```

   Weekly Payout Process:
   ```solidity
   // Week 1: Only member1 can claim
   currentWeek = 1;
   member1.redeemReward(1, 105e6, merkleProof1); // ✅ Success
   member2.redeemReward(2, 105e6, merkleProof2); // ❌ Fails: wrong week
   
   // Advance to week 2
   admin.advanceWeek(); // currentWeek = 2
   
   // Week 2: Only member2 can claim
   member2.redeemReward(2, 105e6, merkleProof2); // ✅ Success
   member1.redeemReward(1, 105e6, merkleProof1); // ❌ Fails: already claimed
   member3.redeemReward(3, 105e6, merkleProof3); // ❌ Fails: wrong week
   ```

7. Yield Distribution:
   - Each week, designated member receives: base contribution + yield share
   - Yield comes from Morpho vault earnings
   - getCurrentReward() shows total available yield
   - getPayoutAmount(week) shows expected payout for specific week

This system ensures:
- Fair, sequential payout order
- No member can claim out of turn
- No double claiming
- Transparent yield distribution
- Cryptographic proof of eligibility
*/

contract PayoutOrderExample {
    // This is just documentation - see ZybraGroup.sol for actual implementation
}