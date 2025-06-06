// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Auth} from "../../contracts/Zybra/Auth.sol";
import {EIP712Lib} from "../../contracts/Zybra/libraries/EIP712Lib.sol";
import {SignatureLib} from "../../contracts/Zybra/libraries/SignatureLib.sol";
import {IERC20, IERC20Metadata} from "../../contracts/Zybra/interfaces/IERC20.sol";

/// @title  ERC20
/// @notice Standard ERC-20 implementation, with mint/burn functionality.
/// @dev    Requires allowance even when from == msg.sender, to mimic
///         USDC and the OpenZeppelin ERC20 implementation.
contract MockUSDC is Auth, IERC20Metadata {
    /// @inheritdoc IERC20Metadata
    string public name;
    /// @inheritdoc IERC20Metadata
    string public symbol;
    /// @inheritdoc IERC20Metadata
    uint8 public immutable decimals;
    /// @inheritdoc IERC20
    uint256 public totalSupply;

    mapping(address => uint256) private balances;
    /// @inheritdoc IERC20
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 decimals_) Auth(msg.sender) {
        decimals = decimals_;
    }

    function _balanceOf(address user) internal view virtual returns (uint256) {
        return balances[user];
    }

    /// @inheritdoc IERC20
    function balanceOf(address user) public view virtual returns (uint256) {
        return _balanceOf(user);
    }

    function _setBalance(address user, uint256 value) internal virtual {
        balances[user] = value;
    }

    // --- ERC20 Mutations ---
    /// @inheritdoc IERC20
    function transfer(address to, uint256 value) public virtual returns (bool) {
        require(to != address(0) && to != address(this), "ERC20/invalid-address");
        uint256 balance = balanceOf(msg.sender);
        require(balance >= value, "ERC20/insufficient-balance");

        unchecked {
            _setBalance(msg.sender, _balanceOf(msg.sender) - value);
            // note: we don't need an overflow check here b/c sum of all balances == totalSupply
            _setBalance(to, _balanceOf(to) + value);
        }

        emit Transfer(msg.sender, to, value);

        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        return _transferFrom(msg.sender, from, to, value);
    }

    function _transferFrom(address sender, address from, address to, uint256 value) internal virtual returns (bool) {
        require(to != address(0) && to != address(this), "ERC20/invalid-address");
        uint256 balance = balanceOf(from);
        require(balance >= value, "ERC20/insufficient-balance");

        uint256 allowed = allowance[from][sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "ERC20/insufficient-allowance");
            unchecked {
                allowance[from][sender] = allowed - value;
            }
        }

        unchecked {
            _setBalance(from, _balanceOf(from) - value);
            // note: we don't need an overflow check here b/c sum of all balances == totalSupply
            _setBalance(to, _balanceOf(to) + value);
        }

        emit Transfer(from, to, value);

        return true;
    }

    /// @inheritdoc IERC20
    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;

        emit Approval(msg.sender, spender, value);

        return true;
    }

    // --- Mint/Burn ---
    function mint(address to, uint256 value) public virtual auth {
        require(to != address(0) && to != address(this), "ERC20/invalid-address");
        unchecked {
            // We don't need an overflow check here b/c balances[to] <= totalSupply
            // and there is an overflow check below
            _setBalance(to, _balanceOf(to) + value);
        }
        totalSupply = totalSupply + value;

        emit Transfer(address(0), to, value);
    }

    function burn(address from, uint256 value) public virtual auth {
        uint256 balance = balanceOf(from);
        require(balance >= value, "ERC20/insufficient-balance");

        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= value, "ERC20/insufficient-allowance");

                unchecked {
                    allowance[from][msg.sender] = allowed - value;
                }
            }
        }

        unchecked {
            // We don't need overflow checks b/c require(balance >= value) and balance <= totalSupply
            _setBalance(from, _balanceOf(from) - value);
            totalSupply = totalSupply - value;
        }

        emit Transfer(from, address(0), value);
    }
}
