// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract SoulBound is ERC721 {
    address public vault;

    constructor(address _vault) ERC721("Shezmu SoulBound", "ShezSBT") {
        vault = _vault;
    }

    function mint(address to, uint256 positionId) external {
        require(msg.sender == vault, "Only vault can mint");
        _mint(to, positionId);
    }

    function burn(uint256 tokenId) external {
        require(msg.sender == vault, "Only vault can burn");
        _burn(tokenId);
    }

    // Override functions to make tokens non-transferable
    function transferFrom(address, address, uint256) public pure override {
        revert("Soul-bound tokens cannot be transferred");
    }

    function safeTransferFrom(
        address,
        address,
        uint256,
        bytes memory
    ) public pure override {
        revert("Soul-bound tokens cannot be transferred");
    }
}
