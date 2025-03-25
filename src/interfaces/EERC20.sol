// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface EERC20 is IERC20 {
    function mint(address account, uint256 value) external;

    function burn(address account, uint256 value) external;
}
