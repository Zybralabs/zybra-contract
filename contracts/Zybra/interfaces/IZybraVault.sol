// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

interface IZybraVaultBase {
    function requestDeposit(uint256 assetAmount, address _vault) external;
    function deposit(uint256 assetAmount, address _vault, uint256 mintAmount) external;
    function withdraw(address _vault, uint256 tranche_amount) external;
    function requestWithdraw(uint256 tranche_amount, address onBehalfOf, address _vault) external;
    function cancelWithdrawRequest(address _vault) external;
    function cancelDepositRequest(address _vault) external;
    function ClaimcancelDepositRequest(address _vault) external;
    function addVault(address _vault) external;
    function removeVault(address _vault) external;
    function liquidation(address provider, address _vault, address onBehalfOf, uint256 assetAmount) external;
    function rigidRedemption(address provider, address _vault, uint256 lzybra_amount) external;
    function getBorrowed(address _vault, address user) external view returns (uint256);
    function getPoolTotalCirculation() external view returns (uint256);
    function isVault(address _vault) external view returns (bool);
    function getAsset(address _vault) external view returns (address);
    function getUserTrancheAsset(address vault, address user) external view returns (uint256);
    function getVaultType() external pure returns (uint8);
    function calc_share(uint256 amount, address _vault) external view returns (uint256);
    function getCollateralAssetPrice() external view returns (uint256);
    function getTrancheAssetPrice(address _vault) external view returns (uint256);
}
