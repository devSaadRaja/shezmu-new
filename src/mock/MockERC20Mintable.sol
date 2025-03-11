// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20Mintable is ERC20, Ownable {
    address public vault;

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) Ownable(msg.sender) {}

    function mint(address account, uint256 value) external {
        require(msg.sender == vault);
        _mint(account, value);
    }

    function burn(address account, uint256 value) external {
        require(msg.sender == vault);
        _burn(account, value);
    }

    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }
}
