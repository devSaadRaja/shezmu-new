// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title SoulBound
/// @notice ERC721 implementation for non-transferable (soul-bound) tokens representing vault positions.
/// @dev Only the associated vault contract can mint or burn these tokens. Transfers are disabled.
contract SoulBound is ERC721 {
    address public vault;

    // ================================================= //
    // ================== CONSTRUCTOR ================== //
    // ================================================= //

    /// @notice Constructor sets the vault address and initializes the ERC721 token with name and symbol.
    /// @param _vault The address of the vault contract allowed to mint and burn tokens.
    constructor(address _vault) ERC721("Shezmu SoulBound", "ShezSBT") {
        vault = _vault;
    }

    // ======================================================== //
    // ================== EXTERNAL FUNCTIONS ================== //
    // ======================================================== //

    /// @notice Mints a new soul-bound token to the specified address.
    /// @dev Only callable by the vault contract.
    /// @param to The address to receive the soul-bound token.
    /// @param positionId The unique identifier for the token to be minted.
    function mint(address to, uint256 positionId) external {
        require(msg.sender == vault, "Only vault can mint");
        _mint(to, positionId);
    }

    /// @notice Burns a soul-bound token with the given tokenId.
    /// @dev Only callable by the vault contract.
    /// @param tokenId The unique identifier for the token to be burned.
    function burn(uint256 tokenId) external {
        require(msg.sender == vault, "Only vault can burn");
        _burn(tokenId);
    }

    // ====================================================== //
    // ================== PUBLIC FUNCTIONS ================== //
    // ====================================================== //

    /// @notice Prevents approving of soul-bound tokens.
    /// @dev Always reverts to enforce soulbound functionalities.
    function approve(address, uint256) public pure override {
        revert("Soul-bound tokens cannot be approved");
    }

    /// @notice Prevents approving of soul-bound tokens.
    /// @dev Always reverts to enforce soulbound functionalities.
    function setApprovalForAll(address, bool) public pure override {
        revert("Soul-bound tokens cannot be approved");
    }

    /// @notice Prevents transfer of soul-bound tokens.
    /// @dev Always reverts to enforce non-transferability.
    function transferFrom(address, address, uint256) public pure override {
        revert("Soul-bound tokens cannot be transferred");
    }

    /// @notice Prevents safe transfer of soul-bound tokens.
    /// @dev Always reverts to enforce non-transferability.
    function safeTransferFrom(
        address,
        address,
        uint256,
        bytes memory
    ) public pure override {
        revert("Soul-bound tokens cannot be transferred");
    }
}
