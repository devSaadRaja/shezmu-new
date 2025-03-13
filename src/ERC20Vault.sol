// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

interface EERC20 is IERC20 {
    function mint(address account, uint256 value) external;

    function burn(address account, uint256 value) external;
}

contract ERC20Vault is ReentrancyGuard, Ownable {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    struct Position {
        address owner;
        uint256 collateralAmount;
        uint256 debtAmount;
    }

    IERC20 public collateralToken;
    EERC20 public loanToken;
    uint256 public ltvRatio; // Loan-to-Value ratio in percentage (e.g., 50 for 50%)
    uint256 public constant PRECISION = 1e18; // For precise calculations

    IPriceFeed public collateralPriceFeed;
    IPriceFeed public loanPriceFeed;

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) positions;
    mapping(address => uint256[]) userPositionIds;

    mapping(address => uint256) collateralBalances;
    mapping(address => uint256) loanBalances;

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

    event PositionOpened(
        uint256 indexed positionId,
        address indexed user,
        uint256 collateralAmount,
        uint256 debtAmount
    );
    event CollateralAdded(uint256 indexed positionId, uint256 amount);
    event DebtRepaid(uint256 indexed positionId, uint256 amount);
    event WithdrawnCollateral(uint256 indexed positionId, uint256 amount);

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error InvalidCollateralToken();
    error InvalidLoanToken();
    error InvalidLTVRatio();
    error InvalidCollateralPriceFeed();
    error InvalidLoanPriceFeed();
    error ZeroCollateralAmount();
    error ZeroLoanAmount();
    error LoanExceedsLTVLimit();
    error CollateralTransferFailed();
    error NotPositionOwner();
    error AmountExceedsLoan();
    error InsufficientCollateral();
    error InsufficientCollateralAfterWithdrawal();
    error CollateralWithdrawalFailed();
    error InvalidPrice();
    error EmergencyWithdrawFailed();

    // ================================================= //
    // ================== CONSTRUCTOR ================== //
    // ================================================= //
    constructor(
        address _collateralToken,
        address _loanToken,
        uint256 _ltvRatio,
        address _collateralPriceFeed,
        address _loanPriceFeed
    ) Ownable(msg.sender) {
        if (_collateralToken == address(0)) revert InvalidCollateralToken();
        if (_loanToken == address(0)) revert InvalidLoanToken();
        if (_ltvRatio == 0 || _ltvRatio > 100) revert InvalidLTVRatio();
        if (_collateralPriceFeed == address(0))
            revert InvalidCollateralPriceFeed();
        if (_loanPriceFeed == address(0)) revert InvalidLoanPriceFeed();

        collateralToken = IERC20(_collateralToken);
        loanToken = EERC20(_loanToken);
        ltvRatio = _ltvRatio;
        collateralPriceFeed = IPriceFeed(_collateralPriceFeed);
        loanPriceFeed = IPriceFeed(_loanPriceFeed);
    }

    // ==================================================== //
    // ================== READ FUNCTIONS ================== //
    // ==================================================== //

    /// @notice Returns the position details for a given position ID
    /// @param positionId The ID of the position to query
    /// @return owner The address of the position owner
    /// @return collateralAmount The amount of collateral in the position
    /// @return debtAmount The amount of debt in the position
    function getPosition(
        uint256 positionId
    ) external view returns (address, uint256, uint256) {
        Position memory position = positions[positionId];
        return (position.owner, position.collateralAmount, position.debtAmount);
    }

    /// @notice Gets the total collateral balance for a user across all positions
    /// @param user The address of the user to query
    /// @return The total collateral balance
    function getCollateralBalance(
        address user
    ) external view returns (uint256) {
        return collateralBalances[user];
    }

    /// @notice Gets the total loan balance for a user across all positions
    /// @param user The address of the user to query
    /// @return The total loan balance
    function getLoanBalance(address user) external view returns (uint256) {
        return loanBalances[user];
    }

    /// @notice Calculates the health factor of a position
    /// @param positionId The ID of the position to check
    /// @return The health factor (collateral value / debt value) * PRECISION
    function getPositionHealth(
        uint256 positionId
    ) external view returns (uint256) {
        Position memory pos = positions[positionId];
        if (pos.debtAmount == 0) return type(uint256).max;

        uint256 collateralValue = getCollateralValue(pos.collateralAmount);
        uint256 debtValue = getLoanValue(pos.debtAmount);
        return (collateralValue * PRECISION) / debtValue;
    }

    /// @notice Calculates the maximum amount a user can borrow based on their total collateral
    /// @param user The address of the user to check
    /// @return The maximum borrowable amount in loan tokens
    function getMaxBorrowable(address user) external view returns (uint256) {
        uint256 totalCollateral;
        uint256[] memory posIds = userPositionIds[user];
        for (uint256 i = 0; i < posIds.length; i++) {
            totalCollateral += positions[posIds[i]].collateralAmount;
        }

        uint256 collateralValue = getCollateralValue(totalCollateral);
        uint256 maxLoanValue = (collateralValue * ltvRatio) / 100;
        uint256 loanPrice = _getPrice(loanPriceFeed);
        return (maxLoanValue * PRECISION) / loanPrice;
    }

    /// @notice Gets all position IDs owned by a user
    /// @param user The address of the user to query
    /// @return An array of position IDs
    function getUserPositionIds(
        address user
    ) external view returns (uint256[] memory) {
        return userPositionIds[user];
    }

    /// @notice Calculates the USD value of a given amount of collateral
    /// @param collateralAmount The amount of collateral tokens
    /// @return The USD value of the collateral
    function getCollateralValue(
        uint256 collateralAmount
    ) public view returns (uint256) {
        uint256 collateralPrice = _getPrice(collateralPriceFeed);
        return (collateralAmount * collateralPrice) / PRECISION;
    }

    /// @notice Calculates the USD value of a given loan amount
    /// @param loanAmount The amount of loan tokens
    /// @return The USD value of the loan
    function getLoanValue(uint256 loanAmount) public view returns (uint256) {
        uint256 loanPrice = _getPrice(loanPriceFeed);
        return (loanAmount * loanPrice) / PRECISION;
    }

    // ===================================================== //
    // ================== WRITE FUNCTIONS ================== //
    // ===================================================== //

    /// @notice Opens a new lending position
    /// @param collateral The address of the collateral token
    /// @param collateralAmount The amount of collateral to deposit
    /// @param debtAmount The amount of tokens to borrow
    function openPosition(
        address collateral,
        uint256 collateralAmount,
        uint256 debtAmount
    ) external nonReentrant {
        if (collateral != address(collateralToken)) {
            revert InvalidCollateralToken();
        }
        if (collateralAmount == 0) revert ZeroCollateralAmount();
        if (debtAmount == 0) revert ZeroLoanAmount();

        uint256 collateralValue = getCollateralValue(collateralAmount);
        uint256 loanValue = getLoanValue(debtAmount);
        uint256 maxLoanValue = (collateralValue * ltvRatio) / 100;

        if (loanValue > maxLoanValue) revert LoanExceedsLTVLimit();

        if (
            !collateralToken.transferFrom(
                msg.sender,
                address(this),
                collateralAmount
            )
        ) {
            revert CollateralTransferFailed();
        }

        uint256 positionId = nextPositionId++;
        positions[positionId] = Position(
            msg.sender,
            collateralAmount,
            debtAmount
        );
        userPositionIds[msg.sender].push(positionId);

        collateralBalances[msg.sender] += collateralAmount;
        loanBalances[msg.sender] += debtAmount;

        loanToken.mint(msg.sender, debtAmount);

        emit PositionOpened(
            positionId,
            msg.sender,
            collateralAmount,
            debtAmount
        );
    }

    /// @notice Adds additional collateral to an existing position
    /// @param positionId The ID of the position to modify
    /// @param amount The amount of collateral to add
    function addCollateral(
        uint256 positionId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroCollateralAmount();
        if (positions[positionId].owner != msg.sender) {
            revert NotPositionOwner();
        }
        if (!collateralToken.transferFrom(msg.sender, address(this), amount)) {
            revert CollateralTransferFailed();
        }

        positions[positionId].collateralAmount += amount;
        collateralBalances[msg.sender] += amount;

        emit CollateralAdded(positionId, amount);
    }

    /// @notice Repays debt for an existing position
    /// @param positionId The ID of the position to modify
    /// @param debtAmount The amount of debt to repay
    function repayDebt(
        uint256 positionId,
        uint256 debtAmount
    ) external nonReentrant {
        if (debtAmount == 0) revert ZeroLoanAmount();
        if (positions[positionId].owner != msg.sender) {
            revert NotPositionOwner();
        }
        if (positions[positionId].debtAmount < debtAmount) {
            revert AmountExceedsLoan();
        }

        loanToken.burn(msg.sender, debtAmount);

        positions[positionId].debtAmount -= debtAmount;
        loanBalances[msg.sender] -= debtAmount;

        emit DebtRepaid(positionId, debtAmount);
    }

    /// @notice Withdraws collateral from an existing position
    /// @param positionId The ID of the position to withdraw from
    /// @param amount The amount of collateral to withdraw
    function withdrawCollateral(
        uint256 positionId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroCollateralAmount();
        if (positions[positionId].owner != msg.sender) {
            revert NotPositionOwner();
        }
        if (positions[positionId].collateralAmount < amount) {
            revert InsufficientCollateral();
        }

        uint256 newCollateralAmount = positions[positionId].collateralAmount -
            amount;
        uint256 currentDebt = positions[positionId].debtAmount;

        if (currentDebt > 0) {
            uint256 remainingCollateralValue = getCollateralValue(
                newCollateralAmount
            );
            uint256 loanValue = getLoanValue(currentDebt);
            uint256 minCollateralValue = (loanValue * 100) / ltvRatio;
            if (remainingCollateralValue < minCollateralValue) {
                revert InsufficientCollateralAfterWithdrawal();
            }
        }

        positions[positionId].collateralAmount = newCollateralAmount;
        collateralBalances[msg.sender] -= amount;

        if (!collateralToken.transfer(msg.sender, amount)) {
            revert CollateralWithdrawalFailed();
        }

        emit WithdrawnCollateral(positionId, amount);
    }

    // ===================================================== //
    // ================== OWNER FUNCTIONS ================== //
    // ===================================================== //

    /// @notice Updates the price feed addresses for both collateral and loan tokens
    /// @param _collateralFeed The new collateral price feed address
    /// @param _loanFeed The new loan price feed address
    function updatePriceFeeds(
        address _collateralFeed,
        address _loanFeed
    ) external onlyOwner {
        if (_collateralFeed == address(0)) revert InvalidCollateralPriceFeed();
        if (_loanFeed == address(0)) revert InvalidLoanPriceFeed();
        collateralPriceFeed = IPriceFeed(_collateralFeed);
        loanPriceFeed = IPriceFeed(_loanFeed);
    }

    /// @notice Updates the loan-to-value ratio
    /// @param newLtvRatio The new LTV ratio (between 0 and 100)
    function updateLtvRatio(uint256 newLtvRatio) external onlyOwner {
        if (newLtvRatio == 0 || newLtvRatio > 100) revert InvalidLTVRatio();
        ltvRatio = newLtvRatio;
    }

    /// @notice Emergency function to withdraw tokens from the contract
    /// @param token The address of the token to withdraw
    /// @param amount The amount of tokens to withdraw
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyOwner {
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert EmergencyWithdrawFailed();
    }

    // ======================================================== //
    // ================== INTERNAL FUNCTIONS ================== //
    // ======================================================== //

    /// @notice Internal function to get the latest price from a price feed
    /// @param priceFeed The price feed to query
    /// @return The normalized price with 18 decimals
    function _getPrice(IPriceFeed priceFeed) internal view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        return uint256(price) * 10 ** (18 - priceFeed.decimals());
    }
}
