// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC20Vault} from "./interfaces/IERC20Vault.sol";

/**
 * @title InterestCollector
 * @notice Collects interest from lending vaults using a perpetual decay model
 * @dev Interest is collected periodically (every 300 blocks, ~60 min)
 */
contract InterestCollector is ReentrancyGuard, Ownable {
    // =============================================== //
    // ================== CONSTANTS ================== //
    // =============================================== //

    uint256 public constant PRECISION = 1e18;
    uint256 public blocksPerYear = 7160 * 365; // Estimated blocks per year
    uint256 public periodBlocks = 300; // ~60 minutes at 7160 blocks per day
    uint256 public periodShare = (periodBlocks * 1e18) / blocksPerYear; // Scaled by 1e18

    // =============================================== //
    // ================== STORAGE ================== //
    // =============================================== //

    // Lending vault => interest rate (annual rate in basis points 500 = 5.00%)
    mapping(address => uint256) vaultInterestRates;

    // Vault => Position ID => last interest collection block
    mapping(address => mapping(uint256 => uint256)) lastCollectionBlock;

    // Token => collected interest amount
    mapping(address => uint256) collectedInterest;

    // List of registered vaults
    address[] public registeredVaults;

    // Treasury address to receive collected interest
    address public treasury;

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

    event VaultRegistered(address indexed vault, uint256 interestRate);
    event InterestRateUpdated(address indexed vault, uint256 newInterestRate);
    event InterestCollected(
        address indexed vault,
        address indexed token,
        uint256 amount
    );
    event InterestWithdrawn(
        address indexed token,
        uint256 amount,
        address indexed recipient
    );
    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error ZeroAddress();
    error VaultAlreadyRegistered();
    error VaultNotRegistered();
    error VaultNotCaller();
    error InvalidInterestRate();
    error NoInterestToCollect();
    error TransferFailed();

    // ================================================= //
    // ================== CONSTRUCTOR ================== //
    // ================================================= //

    constructor(address _treasury) Ownable(msg.sender) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    // ==================================================== //
    // ================== VIEW FUNCTIONS ================== //
    // ==================================================== //

    /**
     * @notice Get the number of registered vaults
     * @return The number of registered vaults
     */
    function getRegisteredVaultsCount() external view returns (uint256) {
        return registeredVaults.length;
    }

    /**
     * @notice Retrieve the interest rate for a specific vault
     * @param vault The address of the vault
     * @return The annual interest rate for the vault (scaled by 1e18)
     */
    function getVaultInterestRate(
        address vault
    ) external view returns (uint256) {
        return vaultInterestRates[vault];
    }

    /**
     * @notice Retrieve the last block number when interest was collected for a specific vault
     * @param vault The address of the vault
     * @return The block number of the last interest collection
     */
    function getLastCollectionBlock(
        address vault,
        uint256 positionId
    ) external view returns (uint256) {
        // return lastCollectionBlock[vault];
        return lastCollectionBlock[vault][positionId];
    }

    /**
     * @notice Retrieve the total amount of interest collected for a specific token
     * @param token The address of the token
     * @return The total collected interest amount for the token
     */
    function getCollectedInterest(
        address token
    ) external view returns (uint256) {
        return collectedInterest[token];
    }

    /**
     * @notice Calculate the interest due for a specific vault
     * @param vault The address of the vault
     * @param positionId The positionId to calculate interest
     * @param debtAmount The current debt amount in the vault
     * @return interestDue The amount of interest due
     */
    function calculateInterestDue(
        address vault,
        uint256 positionId,
        uint256 debtAmount
    ) public view returns (uint256) {
        if (vaultInterestRates[vault] == 0) return 0;
        if (lastCollectionBlock[vault][positionId] == 0) return 0;
        if (debtAmount == 0) return 0;

        uint256 currentBlock = block.number;
        if (currentBlock <= lastCollectionBlock[vault][positionId]) return 0;

        uint256 blocksPassed = currentBlock -
            lastCollectionBlock[vault][positionId];
        uint256 periodsPassed = blocksPassed / periodBlocks;

        if (periodsPassed == 0) return 0;

        uint256 annualInterest = debtAmount * vaultInterestRates[vault];
        uint256 periodInterest = (annualInterest * periodShare) /
            (10000 * PRECISION);

        return periodInterest * periodsPassed;
    }

    /**
     * @notice Check if a vault is ready for interest collection
     * @param vault The address of the vault to check
     * @return True if at least one period has passed since last collection
     */
    function isCollectionReady(
        address vault,
        uint256 positionId
    ) public view returns (bool) {
        if (lastCollectionBlock[vault][positionId] == 0) return false;

        uint256 blocksPassed = block.number -
            lastCollectionBlock[vault][positionId];
        return blocksPassed >= periodBlocks;
    }

    // ===================================================== //
    // ================== WRITE FUNCTIONS ================== //
    // ===================================================== //

    /**
     * @notice Update the lastCollectionBlock for a positionId
     * @param vault The vault address
     * @param positionId The positionId to update to the latest block.number
     */
    function setLastCollectionBlock(
        address vault,
        uint256 positionId
    ) external {
        if (msg.sender != vault) revert VaultNotCaller();
        lastCollectionBlock[vault][positionId] = block.number;
    }

    /**
     * @notice Update the period blocks and share
     * @param newPeriodBlocks The new period blocks value
     */
    function setPeriodBlocks(uint256 newPeriodBlocks) external onlyOwner {
        periodBlocks = newPeriodBlocks;
        periodShare = (periodBlocks * 1e18) / blocksPerYear; // Recalculate periodShare
    }

    /**
     * @notice Register a new vault with an interest rate
     * @param vault The address of the vault to register
     * @param interestRate Annual interest rate (5% = 500)
     */
    function registerVault(
        address vault,
        uint256 interestRate
    ) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        if (vaultInterestRates[vault] != 0) revert VaultAlreadyRegistered();
        if (interestRate == 0) revert InvalidInterestRate();

        vaultInterestRates[vault] = interestRate;
        registeredVaults.push(vault);

        emit VaultRegistered(vault, interestRate);
    }

    /**
     * @notice Update the interest rate for a vault
     * @param vault The address of the vault
     * @param newInterestRate The new annual interest rate (scaled by 1e18)
     */
    function updateInterestRate(
        address vault,
        uint256 newInterestRate
    ) external onlyOwner {
        if (vaultInterestRates[vault] == 0) revert VaultNotRegistered();
        if (newInterestRate == 0) revert InvalidInterestRate();

        vaultInterestRates[vault] = newInterestRate;
        emit InterestRateUpdated(vault, newInterestRate);
    }

    /**
     * @notice Collect interest from a vault
     * @param vault The address of the vault
     * @param token The loan token address
     * @param positionId The positionId to collect interest from
     * @param debtAmount The current total debt amount in the vault
     * @dev This function should be called by the vault during suitable operations
     */
    function collectInterest(
        address vault,
        address token,
        uint256 positionId,
        uint256 debtAmount
    ) external nonReentrant {
        if (vaultInterestRates[vault] == 0) revert VaultNotRegistered();
        if (msg.sender != vault) revert VaultNotCaller();
        if (!isCollectionReady(vault, positionId)) return;

        uint256 interestDue = calculateInterestDue(
            vault,
            positionId,
            debtAmount
        );

        if (interestDue == 0) revert NoInterestToCollect();

        IERC20Vault(vault).collectInterest(positionId, interestDue);

        lastCollectionBlock[vault][positionId] = block.number;
        collectedInterest[token] += interestDue;

        emit InterestCollected(vault, token, interestDue);
    }

    /**
     * @notice Withdraw collected interest to the treasury
     * @param token The token to withdraw
     */
    function withdrawInterest(address token) external onlyOwner nonReentrant {
        uint256 amount = collectedInterest[token];
        if (amount == 0) revert NoInterestToCollect();

        bool success = IERC20(token).transfer(treasury, amount);
        if (!success) revert TransferFailed();

        collectedInterest[token] = 0;

        emit InterestWithdrawn(token, amount, treasury);
    }

    /**
     * @notice Update the treasury address
     * @param newTreasury The new treasury address
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
}
