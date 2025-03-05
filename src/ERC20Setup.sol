// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {ERC20} from "../contracts/Zybra/token/ERC20.sol";

contract ERC20Setup {
    ERC20 public erc20;

    function setupERC20() external returns (address) {
        erc20 = new ERC20(6);
        erc20.file("name", "X's Dollar");
        erc20.file("symbol", "USDX");

        return address(erc20);
    }
}
