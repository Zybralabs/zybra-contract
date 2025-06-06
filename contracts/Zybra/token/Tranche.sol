// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {ERC20} from "contracts/Zybra/token/ERC20.sol";
import {IERC20, IERC20Metadata} from "contracts/Zybra/interfaces/IERC20.sol";
import {
    IHook,
    HookData,
    SUCCESS_CODE_ID,
    SUCCESS_MESSAGE,
    ERROR_CODE_ID,
    ERROR_MESSAGE
} from "contracts/Zybra/interfaces/token/IHook.sol";
import {IERC7575Share, IERC165} from "contracts/Zybra/interfaces/IERC7575.sol";
import {ITranche, IERC1404} from "contracts/Zybra/interfaces/token/ITranche.sol";
import {MathLib} from "contracts/Zybra/libraries/MathLib.sol";

/// @title  Tranche Token
/// @notice Extension of ERC20 + ERC1404 for tranche tokens,
///         integrating an external hook optionally for ERC20 callbacks and ERC1404 checks.
contract Tranche is ERC20, ITranche {
    using MathLib for uint256;

    mapping(address => Balance) private balances;

    /// @inheritdoc ITranche
    address public hook;

    /// @inheritdoc IERC7575Share
    mapping(address asset => address) public vault;

    constructor(uint8 decimals_) ERC20(decimals_) {}

    modifier authOrHook() {
        require(wards[msg.sender] == 1 || msg.sender == hook, "Tranche/not-authorized");
        _;
    }

    // --- Administration ---
    /// @inheritdoc ITranche
    function file(bytes32 what, address data) external authOrHook {
        if (what == "hook") hook = data;
        else revert("Tranche/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc ITranche
    function file(bytes32 what, string memory data) public override(ERC20, ITranche) auth {
        super.file(what, data);
    }

    /// @inheritdoc ITranche
    function updateVault(address asset, address vault_) external auth {
        vault[asset] = vault_;
        emit VaultUpdate(asset, vault_);
    }

    // --- ERC20 overrides ---
    function _balanceOf(address user) internal view override returns (uint256) {
        return balances[user].amount;
    }

    function _setBalance(address user, uint256 value) internal override {
        balances[user].amount = value.toUint128();
    }

    /// @inheritdoc ITranche
    function hookDataOf(address user) public view returns (bytes16) {
        return balances[user].hookData;
    }

    /// @inheritdoc ITranche
    function setHookData(address user, bytes16 hookData) public authOrHook {
        balances[user].hookData = hookData;
        emit SetHookData(user, hookData);
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 value) public override(ERC20, IERC20) returns (bool success) {
        success = super.transfer(to, value);
        _onTransfer(msg.sender, to, value);
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20, IERC20)
        returns (bool success)
    {
        success = super.transferFrom(from, to, value);
        _onTransfer(from, to, value);
    }

    /// @inheritdoc ITranche
    function mint(address to, uint256 value) public override(ERC20, ITranche) {
        super.mint(to, value);
        require(totalSupply <= type(uint128).max, "Tranche/exceeds-max-supply");
        _onTransfer(address(0), to, value);
    }

    /// @inheritdoc ITranche
    function burn(address from, uint256 value) public override(ERC20, ITranche) {
        super.burn(from, value);
        _onTransfer(from, address(0), value);
    }

    function _onTransfer(address from, address to, uint256 value) internal {
        require(
            hook == address(0)
                || IHook(hook).onERC20Transfer(from, to, value, HookData(hookDataOf(from), hookDataOf(to)))
                    == IHook.onERC20Transfer.selector,
            "Tranche/restrictions-failed"
        );
    }

    /// @inheritdoc ITranche
    function authTransferFrom(address sender, address from, address to, uint256 value)
        public
        auth
        returns (bool success)
    {
        success = _transferFrom(sender, from, to, value);
        require(
            hook == address(0)
                || IHook(hook).onERC20AuthTransfer(sender, from, to, value, HookData(hookDataOf(from), hookDataOf(to)))
                    == IHook.onERC20AuthTransfer.selector,
            "Tranche/restrictions-failed"
        );
    }

    // --- ERC1404 implementation ---
    /// @inheritdoc ITranche
    function checkTransferRestriction(address from, address to, uint256 value) public view returns (bool) {
        return detectTransferRestriction(from, to, value) == SUCCESS_CODE_ID;
    }

    /// @inheritdoc IERC1404
    function detectTransferRestriction(address from, address to, uint256 value) public view returns (uint8) {
        if (hook == address(0)) return SUCCESS_CODE_ID;
        return IHook(hook).checkERC20Transfer(from, to, value, HookData(hookDataOf(from), hookDataOf(to)))
            ? SUCCESS_CODE_ID
            : ERROR_CODE_ID;
    }

    /// @inheritdoc IERC1404
    function messageForTransferRestriction(uint8 restrictionCode) external pure returns (string memory) {
        return restrictionCode == SUCCESS_CODE_ID ? SUCCESS_MESSAGE : ERROR_MESSAGE;
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC7575Share).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
