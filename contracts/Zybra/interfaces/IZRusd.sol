// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface ILZYBRA {

    // ================================================================
    // |                       ERC20 Functions                        |
    // ================================================================

    /// @notice Returns the number of decimals used in the user representation.
    function decimals() external view returns (uint8);

    /// @notice Returns the maximum supply of the token, 0 if unlimited.
    function maxSupply() external view returns (uint256);

    /// @notice Moves `amount` tokens from the caller's account to `recipient`.
    /// @dev Returns a boolean value indicating whether the operation succeeded.
    function transfer(address recipient, uint256 amount) external returns (bool);

    /// @notice Returns the remaining number of tokens that `spender` will be allowed to spend on behalf of `owner` through `transferFrom`.
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Sets `amount` as the allowance of `spender` over the caller's tokens.
    /// @dev Returns a boolean value indicating whether the operation succeeded.
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Moves `amount` tokens from `sender` to `recipient` using the allowance mechanism.
    /// @dev `amount` is then deducted from the caller's allowance.
    /// @dev Returns a boolean value indicating whether the operation succeeded.
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    // ================================================================
    // |                      Burning & Minting                       |
    // ================================================================

    /// @notice Burns `amount` tokens from the caller.
    /// @dev Only accounts with the burner role can burn tokens.
    function burn(uint256 amount) external;

    /// @notice Burns `amount` tokens from `account`.
    /// @dev Only accounts with the burner role can burn tokens from a given account.
    ///      Reverts if the account does not have enough balance.
    function burn(address account, uint256 amount) external;

    /// @notice Burns `amount` tokens from `account`, reducing the total supply.
    /// @dev Only accounts with the burner role can burn tokens.
    function burnFrom(address account, uint256 amount) external;

    /// @notice Mints `amount` tokens to the `account`, increasing the total supply.
    /// @dev Only accounts with the minter role can mint tokens.
    function mint(address account, uint256 amount) external;

    // ================================================================
    // |                         Role Management                      |
    // ================================================================

    /// @notice Grants both mint and burn roles to `burnAndMinter`.
    /// @dev Only the owner can call this function.
    function grantMintAndBurnRoles(address burnAndMinter) external;

    /// @notice Grants the mint role to `minter`.
    /// @dev Only the owner can call this function.
    function grantMintRole(address minter) external;

    /// @notice Grants the burn role to `burner`.
    /// @dev Only the owner can call this function.
    function grantBurnRole(address burner) external;

    /// @notice Revokes the mint role from `minter`.
    /// @dev Only the owner can call this function.
    function revokeMintRole(address minter) external;

    /// @notice Revokes the burn role from `burner`.
    /// @dev Only the owner can call this function.
    function revokeBurnRole(address burner) external;

    /// @notice Returns a list of all addresses that have the mint role.
    function getMinters() external view returns (address[] memory);

    /// @notice Returns a list of all addresses that have the burn role.
    function getBurners() external view returns (address[] memory);

    /// @notice Checks if `minter` is a permissioned minter.
    function isMinter(address minter) external view returns (bool);

    /// @notice Checks if `burner` is a permissioned burner.
    function isBurner(address burner) external view returns (bool);

    // ================================================================
    // |                         ERC165 Support                       |
    // ================================================================

    /// @notice Checks whether the contract implements a given interface.
    /// @param interfaceId The interface identifier, as specified in ERC165.
    /// @return `true` if the contract implements `interfaceId`, `false` otherwise.
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
