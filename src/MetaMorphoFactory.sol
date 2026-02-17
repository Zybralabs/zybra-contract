// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "./mocks/MockMetaMorpho.sol";
import {IMorpho} from "./interfaces/IMorpho.sol";

/**
 * @title MetaMorphoFactory
 * @dev Factory contract for deploying MockMetaMorpho vaults
 * @author Zybra Protocol
 * @notice This factory simplifies the deployment of MetaMorpho vaults with standardized parameters
 */
contract MetaMorphoFactory {
    /* EVENTS */
    event VaultDeployed(
        address indexed vaultAddress,
        address indexed owner,
        address indexed asset,
        string name,
        string symbol,
        address morpho
    );
    event FactoryOwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /* ERRORS */
    error OnlyOwner();
    error ZeroAddress();
    error InvalidName();
    error InvalidSymbol();
    error DeploymentFailed();

    /* STATE */
    address public owner;
    address public immutable DEFAULT_MORPHO;

    // Deployment tracking
    mapping(address => bool) public isDeployedVault;
    address[] public deployedVaults;
    mapping(address => address[]) public ownerToVaults; // Track vaults by owner

    /* MODIFIERS */
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    /* CONSTRUCTOR */
    constructor(address defaultMorpho) validAddress(defaultMorpho) {
        owner = msg.sender;
        DEFAULT_MORPHO = defaultMorpho;
    }

    /* DEPLOYMENT FUNCTIONS */

    /**
     * @notice Deploy a new MockMetaMorpho vault with custom Morpho instance
     * @param morpho The Morpho protocol instance address
     * @param asset The underlying asset address
     * @param name The vault token name
     * @param symbol The vault token symbol
     * @param vaultOwner The owner of the new vault
     * @return vaultAddress The address of the deployed vault
     */
    function deployVault(
        address morpho,
        address asset,
        string memory name,
        string memory symbol,
        address vaultOwner
    ) external validAddress(morpho) validAddress(asset) validAddress(vaultOwner) returns (address vaultAddress) {
        return _deployVault(morpho, asset, name, symbol, vaultOwner);
    }

    /**
     * @notice Deploy a new MockMetaMorpho vault with default Morpho instance
     * @param asset The underlying asset address
     * @param name The vault token name
     * @param symbol The vault token symbol
     * @param vaultOwner The owner of the new vault
     * @return vaultAddress The address of the deployed vault
     */
    function deployVaultWithDefaultMorpho(
        address asset,
        string memory name,
        string memory symbol,
        address vaultOwner
    ) external validAddress(asset) validAddress(vaultOwner) returns (address vaultAddress) {
        return _deployVault(DEFAULT_MORPHO, asset, name, symbol, vaultOwner);
    }

    /**
     * @dev Internal function to deploy vault with validation
     */
    function _deployVault(
        address morpho,
        address asset,
        string memory name,
        string memory symbol,
        address vaultOwner
    ) internal returns (address) {
        // Validate parameters
        if (bytes(name).length == 0) revert InvalidName();
        if (bytes(symbol).length == 0) revert InvalidSymbol();

        // Deploy new MockMetaMorpho vault
        try new MockMetaMorpho(morpho, asset, name, symbol, vaultOwner) returns (MockMetaMorpho newVault) {
            address vaultAddress = address(newVault);

            // Track deployment
            isDeployedVault[vaultAddress] = true;
            deployedVaults.push(vaultAddress);
            ownerToVaults[vaultOwner].push(vaultAddress);

            emit VaultDeployed(vaultAddress, vaultOwner, asset, name, symbol, morpho);

            return vaultAddress;
        } catch {
            revert DeploymentFailed();
        }
    }

    /* VIEW FUNCTIONS */

    /**
     * @notice Get all deployed vaults
     * @return Array of deployed vault addresses
     */
    function getAllDeployedVaults() external view returns (address[] memory) {
        return deployedVaults;
    }

    /**
     * @notice Get vaults owned by a specific address
     * @param vaultOwner The owner address to query
     * @return Array of vault addresses owned by the owner
     */
    function getVaultsByOwner(address vaultOwner) external view returns (address[] memory) {
        return ownerToVaults[vaultOwner];
    }

    /**
     * @notice Get the number of deployed vaults
     * @return The total count of deployed vaults
     */
    function getDeployedVaultsCount() external view returns (uint256) {
        return deployedVaults.length;
    }

    /**
     * @notice Get vault info for multiple vaults at once
     * @param vaults Array of vault addresses to query
     * @return infos Array of vault information structs
     */
    function getVaultsInfo(address[] calldata vaults) external view returns (VaultInfo[] memory infos) {
        infos = new VaultInfo[](vaults.length);

        for (uint256 i = 0; i < vaults.length; i++) {
            if (isDeployedVault[vaults[i]]) {
                MockMetaMorpho vault = MockMetaMorpho(vaults[i]);
                infos[i] = VaultInfo({
                    vaultAddress: vaults[i],
                    owner: vault.owner(),
                    asset: vault.asset(),
                    name: vault.name(),
                    symbol: vault.symbol(),
                    totalAssets: vault.totalAssets(),
                    totalSupply: vault.totalSupply(),
                    fee: vault.fee(),
                    feeRecipient: vault.feeRecipient()
                });
            }
        }
    }

    /**
     * @dev Struct to hold vault information
     */
    struct VaultInfo {
        address vaultAddress;
        address owner;
        address asset;
        string name;
        string symbol;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 fee;
        address feeRecipient;
    }

    /* OWNER FUNCTIONS */

    /**
     * @notice Transfer ownership of the factory
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner validAddress(newOwner) {
        address oldOwner = owner;
        owner = newOwner;
        emit FactoryOwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @notice Preview deployment parameters without actually deploying
     * @param morpho The Morpho protocol instance address
     * @param asset The underlying asset address
     * @param name The vault token name
     * @param symbol The vault token symbol
     * @param vaultOwner The owner of the new vault
     * @return isValid Validation status
     * @return errorReason Error reason if validation fails
     */
    function previewDeployment(
        address morpho,
        address asset,
        string memory name,
        string memory symbol,
        address vaultOwner
    ) external pure returns (bool isValid, string memory errorReason) {
        // Validate parameters
        if (morpho == address(0) || asset == address(0) || vaultOwner == address(0)) {
            return (false, "Zero address provided");
        }
        if (bytes(name).length == 0) {
            return (false, "Invalid name");
        }
        if (bytes(symbol).length == 0) {
            return (false, "Invalid symbol");
        }

        return (true, "");
    }
}
