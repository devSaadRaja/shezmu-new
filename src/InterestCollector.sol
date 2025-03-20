// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title InterestCollector
 * @notice Collects interest from lending vaults using a perpetual decay model
 * @dev Interest is collected periodically (every 300 blocks, ~60 min)
 */
contract InterestCollector is ReentrancyGuard, Ownable {
    // =============================================== //
    // ================== CONSTANTS ================== //
    // =============================================== //

    uint256 public constant PERIOD_BLOCKS = 300; // ~60 minutes at 7160 blocks per day
    uint256 public constant BLOCKS_PER_YEAR = 7160 * 365; // Estimated blocks per year
    uint256 public constant PERIOD_SHARE =
        (PERIOD_BLOCKS * 1e18) / BLOCKS_PER_YEAR; // Scaled by 1e18
    uint256 public constant PRECISION = 1e18;

    // =============================================== //
    // ================== STORAGE ================== //
    // =============================================== //

    // Lending vault => interest rate (annual rate in basis points 500 = 5.00%)
    mapping(address => uint256) public vaultInterestRates;

    // Vault => last interest collection block
    mapping(address => uint256) public lastCollectionBlock;

    // Token => collected interest amount
    mapping(address => uint256) public collectedInterest;

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
    error InvalidInterestRate();
    error NoInterestToCollect();
    error CollectionTooEarly();
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
     * @notice Calculate the interest due for a specific vault
     * @param vault The address of the vault
     * @param debtAmount The current debt amount in the vault
     * @return interestDue The amount of interest due
     */
    function calculateInterestDue(
        address vault,
        uint256 debtAmount
    ) public view returns (uint256) {
        if (vaultInterestRates[vault] == 0) return 0;
        if (lastCollectionBlock[vault] == 0) return 0;
        if (debtAmount == 0) return 0;

        uint256 currentBlock = block.number;
        if (currentBlock <= lastCollectionBlock[vault]) return 0;

        uint256 blocksPassed = currentBlock - lastCollectionBlock[vault];
        uint256 periodsPassed = blocksPassed / PERIOD_BLOCKS;

        if (periodsPassed == 0) return 0;

        // Interest calculation: Debt * (Rate * Periods * PeriodShare / PRECISION)
        uint256 annualInterest = debtAmount * vaultInterestRates[vault];
        uint256 periodInterest = (annualInterest * PERIOD_SHARE) /
            (10000 * PRECISION);

        return periodInterest * periodsPassed;
    }

    /**
     * @notice Check if a vault is ready for interest collection
     * @param vault The address of the vault to check
     * @return True if at least one period has passed since last collection
     */
    function isCollectionReady(address vault) public view returns (bool) {
        if (lastCollectionBlock[vault] == 0) return false;

        uint256 blocksPassed = block.number - lastCollectionBlock[vault];
        return blocksPassed >= PERIOD_BLOCKS;
    }

    // ===================================================== //
    // ================== WRITE FUNCTIONS ================== //
    // ===================================================== //

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
        lastCollectionBlock[vault] = block.number;
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
     * @param debtAmount The current total debt amount in the vault
     * @dev This function should be called by the vault during suitable operations
     */
    function collectInterest(
        address vault,
        address token,
        uint256 debtAmount
    ) external nonReentrant {
        if (vaultInterestRates[vault] == 0) revert VaultNotRegistered();
        if (msg.sender != vault) revert VaultNotRegistered();
        if (!isCollectionReady(vault)) revert CollectionTooEarly();

        uint256 interestDue = calculateInterestDue(vault, debtAmount);
        if (interestDue == 0) revert NoInterestToCollect();

        lastCollectionBlock[vault] = block.number;
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
