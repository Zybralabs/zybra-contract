
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract ZrUSD is ERC4626 {
    constructor(address usdc) ERC20("Zybra Reserve Dollar", "ZrUSD") ERC4626(IERC20(usdc)) {}

    function mint(address to, uint256 assets) external {
        _mint(to, assets);
    }

    function burn(address from, uint256 assets) external {
        _burn(from, assets);
    }
}
