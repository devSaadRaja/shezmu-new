// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {SoulBound} from "./SoulBound.sol";

import {EERC20} from "./interfaces/EERC20.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IInterestCollector} from "./interfaces/IInterestCollector.sol";

contract ERC20Vault is ReentrancyGuard, AccessControl {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    bytes32 public constant LEVERAGE_ROLE = keccak256("LEVERAGE_ROLE");

    struct Position {
        address owner;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 lastInterestCollectionBlock;
        uint256 effectiveLtvRatio;
    }

    SoulBound public soulBoundToken;
    uint256 public soulBoundFeePercent = 2;
    mapping(uint256 => bool) public hasSoulBound; // Tracks if a position has a soul-bound token
    mapping(address => bool) public doNotMint; // check if user has not allowed soulbound (deducting fee)

    IERC20 public collateralToken;
    EERC20 public loanToken;
    uint256 public ltvRatio; // Loan-to-Value ratio in percentage (e.g., 50 for 50%)
    uint256 public liquidationThreshold; // % of LTV ratio as liquidation threshold
    uint256 public liquidatorReward; // 50 for 50%
    uint256 public penaltyRate = 10; // 10 for 10%

    uint256 public constant PRECISION = 1e18; // For precise calculations

    IPriceFeed public collateralPriceFeed;
    IPriceFeed public loanPriceFeed;

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) positions;
    mapping(address => uint256[]) userPositionIds;

    mapping(address => uint256) collateralBalances;
    mapping(address => uint256) loanBalances;

    uint256 public totalDebt;
    bool public interestCollectionEnabled;
    IInterestCollector public interestCollector;

    address public treasury; // to receive penalty amounts

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
    event Borrowed(uint256 indexed positionId, uint256 amount);
    event DebtRepaid(uint256 indexed positionId, uint256 amount);
    event WithdrawnCollateral(uint256 indexed positionId, uint256 amount);
    event PositionLiquidated(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 collateralSeized,
        uint256 debtRepaid
    );
    event InterestCollectorSet(address indexed interestCollector);
    event InterestCollected(uint256 interestAmount);
    event InterestCollectionToggled(bool enabled);
    event PositionDeleted(uint256 indexed positionId);

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error ZeroAddress();
    error InvalidPosition();
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
    error PositionNotLiquidatable();
    error LiquidationFailed();
    error InterestCollectorNotSet();
    error InterestCollectionFailed();
    error InsufficientFee();

    // ================================================= //
    // ================== CONSTRUCTOR ================== //
    // ================================================= //
    constructor(
        address _collateralToken,
        address _loanToken,
        uint256 _ltvRatio,
        uint256 _liquidationThreshold,
        uint256 _liquidatorReward,
        address _collateralPriceFeed,
        address _loanPriceFeed,
        address _treasury
    ) {
        if (_collateralToken == address(0)) revert InvalidCollateralToken();
        if (_loanToken == address(0)) revert InvalidLoanToken();
        if (_ltvRatio == 0 || _ltvRatio > 100) revert InvalidLTVRatio();
        if (_collateralPriceFeed == address(0))
            revert InvalidCollateralPriceFeed();
        if (_loanPriceFeed == address(0)) revert InvalidLoanPriceFeed();
        if (_treasury == address(0)) revert ZeroAddress();

        collateralToken = IERC20(_collateralToken);
        loanToken = EERC20(_loanToken);
        ltvRatio = _ltvRatio;
        liquidationThreshold = _liquidationThreshold;
        liquidatorReward = _liquidatorReward;
        collateralPriceFeed = IPriceFeed(_collateralPriceFeed);
        loanPriceFeed = IPriceFeed(_loanPriceFeed);
        treasury = _treasury;

        soulBoundToken = new SoulBound(address(this));

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ==================================================== //
    // ================== READ FUNCTIONS ================== //
    // ==================================================== //

    /// @notice Returns the position details for a given position ID
    /// @param positionId The ID of the position to query
    /// @return owner The address of the position owner
    /// @return collateralAmount The amount of collateral in the position
    /// @return debtAmount The amount of debt in the position
    /// @return the block number for last interest collected
    function getPosition(
        uint256 positionId
    ) external view returns (address, uint256, uint256, uint256) {
        Position memory position = positions[positionId];
        return (
            position.owner,
            position.collateralAmount,
            position.debtAmount,
            position.lastInterestCollectionBlock
        );
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
    ) public view returns (uint256) {
        Position memory pos = positions[positionId];
        if (pos.debtAmount == 0) return type(uint256).max;

        uint256 collateralValue = getCollateralValue(pos.collateralAmount);
        uint256 debtValue = getLoanValue(pos.debtAmount);
        return (collateralValue * PRECISION) / debtValue;
    }

    /// @notice Calculates the maximum amount a user can borrow based on their total collateral
    /// @param positionId The positionId to check max loan amount
    /// @return The maximum borrowable amount in loan tokens
    function getMaxBorrowable(
        uint256 positionId
    ) external view returns (uint256) {
        uint256 effectiveLtv = positions[positionId].effectiveLtvRatio;
        uint256 collateralValue = getCollateralValue(
            positions[positionId].collateralAmount
        );
        uint256 maxLoanValue = (collateralValue * effectiveLtv) / 100;
        uint256 loanPrice = _getPrice(loanPriceFeed);
        return (maxLoanValue * PRECISION) / loanPrice;
    }

    // /// @notice Calculates the maximum amount a user can borrow based on their total collateral
    // /// @param user The address of the user to check
    // /// @return The maximum borrowable amount in loan tokens
    // function getTotalMaxBorrowable(
    //     address user
    // ) external view returns (uint256) {
    //     uint256 totalCollateral;
    //     uint256[] memory posIds = userPositionIds[user];
    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         totalCollateral += positions[posIds[i]].collateralAmount;
    //     }

    //     uint256 collateralValue = getCollateralValue(totalCollateral);

    //     // uint256 maxLoanValue = (collateralValue * ltvRatio) / 100;

    //     uint256 maxLoanValue;
    //     if (posIds.length > 0) {
    //         // Use the highest effective LTV among the user's positions
    //         uint256 highestEffectiveLtv = ltvRatio;
    //         for (uint256 i = 0; i < posIds.length; i++) {
    //             uint256 posLtv = positions[posIds[i]].effectiveLtvRatio;
    //             if (posLtv > highestEffectiveLtv) highestEffectiveLtv = posLtv;
    //         }
    //         maxLoanValue = (collateralValue * highestEffectiveLtv) / 100;
    //     } else {
    //         maxLoanValue = (collateralValue * ltvRatio) / 100;
    //     }

    //     uint256 loanPrice = _getPrice(loanPriceFeed);
    //     return (maxLoanValue * PRECISION) / loanPrice;
    // }

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

    /// @notice Checks if a position is liquidatable
    /// @param positionId The ID of the position to check
    /// @return bool True if the position is liquidatable
    function isLiquidatable(uint256 positionId) public view returns (bool) {
        Position memory pos = positions[positionId];
        if (pos.debtAmount == 0 || pos.collateralAmount == 0) return false;

        uint256 health = getPositionHealth(positionId);
        uint256 liquidationThresholdValue = (pos.effectiveLtvRatio *
            liquidationThreshold) / 100;
        return health < ((PRECISION * liquidationThresholdValue) / 100);
    }

    // ===================================================== //
    // ================== WRITE FUNCTIONS ================== //
    // ===================================================== //

    /// @notice Opens a new lending position
    /// @param collateral The address of the collateral token
    /// @param collateralAmount The amount of collateral to deposit
    /// @param debtAmount The amount of tokens to borrow
    function openPosition(
        address owner,
        address collateral,
        uint256 collateralAmount,
        uint256 debtAmount
    ) external nonReentrant {
        if (collateral != address(collateralToken)) {
            revert InvalidCollateralToken();
        }
        if (collateralAmount == 0) revert ZeroCollateralAmount();
        // if (debtAmount == 0) revert ZeroLoanAmount();

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
            owner,
            collateralAmount,
            debtAmount,
            block.number,
            ltvRatio
        );
        userPositionIds[owner].push(positionId);

        collateralBalances[owner] += collateralAmount;
        loanBalances[owner] += debtAmount;

        totalDebt += debtAmount;

        loanToken.mint(owner, debtAmount);

        interestCollector.setLastCollectionBlock(address(this), positionId);

        if (!doNotMint[owner]) {
            // Calculate the fee: 2% of collateral amount
            uint256 fee = (collateralAmount * soulBoundFeePercent) / 100;
            if (fee == 0) revert InsufficientFee();

            // Transfer the fee to the treasury
            if (!collateralToken.transferFrom(msg.sender, treasury, fee)) {
                revert CollateralTransferFailed();
            }

            // Mint the soul-bound token
            soulBoundToken.mint(msg.sender, positionId);
            hasSoulBound[positionId] = true;

            // Adjust the effective LTV or liquidation threshold
            uint256 currentCR = (100 * PRECISION) / ltvRatio; // CR = 1 / LTV
            uint256 targetCR = (100 * PRECISION) / 100; // Target CR = 1 (100% LTV)
            uint256 crDifference = currentCR > targetCR
                ? (currentCR - targetCR) / 2
                : 0;
            uint256 newCR = currentCR - crDifference;
            positions[positionId].effectiveLtvRatio = (100 * PRECISION) / newCR; // New LTV = 1 / newCR
        }

        emit PositionOpened(positionId, owner, collateralAmount, debtAmount);
    }

    /// @notice Adds additional collateral to an existing position
    /// @param positionId The ID of the position to modify
    /// @param amount The amount of collateral to add
    function addCollateral(
        uint256 positionId,
        uint256 amount
    ) external nonReentrant {
        _addCollateral(msg.sender, msg.sender, positionId, amount);
    }

    /// @notice Allows a user to add collateral on behalf of another user
    /// @param positionId The ID of the position to modify
    /// @param onBehalfOf The onBeHalfOf user
    /// @param amount The collateral amount
    function addCollateralFor(
        uint256 positionId,
        address onBehalfOf,
        uint256 amount
    ) external nonReentrant onlyRole(LEVERAGE_ROLE) {
        _addCollateral(msg.sender, onBehalfOf, positionId, amount);
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

        _collectInterestIfAvailable(positionId);

        loanToken.burn(msg.sender, debtAmount);

        positions[positionId].debtAmount -= debtAmount;
        loanBalances[msg.sender] -= debtAmount;

        totalDebt -= debtAmount;

        // If no collateral or debt remains, burn the soul-bound token and clean up
        if (
            positions[positionId].debtAmount == 0 &&
            positions[positionId].collateralAmount == 0
        ) {
            _deletePosition(positionId, positions[positionId].owner);
        }

        emit DebtRepaid(positionId, debtAmount);
    }

    /// @notice Allows users to borrow loanToken
    /// @dev emits a {Borrowed} event
    /// @param positionId The ID of the position to borrow for
    /// @param amount The amount of loanToken to be borrowed
    function borrow(uint256 positionId, uint256 amount) external nonReentrant {
        _borrow(msg.sender, msg.sender, positionId, amount);
    }

    /// @notice Allows users to borrow loanToken
    /// @dev emits a {Borrowed} event
    /// @param positionId The ID of the position to borrow for
    /// @param onBehalfOf The owner of the position
    /// @param amount The amount of loanToken to be borrowed
    function borrowFor(
        uint256 positionId,
        address onBehalfOf,
        uint256 amount
    ) external nonReentrant onlyRole(LEVERAGE_ROLE) {
        _borrow(msg.sender, onBehalfOf, positionId, amount);
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

        _collectInterestIfAvailable(positionId);

        uint256 newCollateralAmount = positions[positionId].collateralAmount -
            amount;
        uint256 currentDebt = positions[positionId].debtAmount;

        if (currentDebt > 0) {
            uint256 remainingCollateralValue = getCollateralValue(
                newCollateralAmount
            );
            uint256 loanValue = getLoanValue(currentDebt);
            uint256 effectiveLtv = positions[positionId].effectiveLtvRatio;
            uint256 minCollateralValue = (loanValue * 100) / effectiveLtv;
            if (remainingCollateralValue < minCollateralValue) {
                revert InsufficientCollateralAfterWithdrawal();
            }
        }

        positions[positionId].collateralAmount = newCollateralAmount;
        collateralBalances[msg.sender] -= amount;

        if (!collateralToken.transfer(msg.sender, amount)) {
            revert CollateralWithdrawalFailed();
        }

        // If no collateral or debt remains, burn the soul-bound token and clean up
        if (
            positions[positionId].collateralAmount == 0 &&
            positions[positionId].debtAmount == 0
        ) {
            _deletePosition(positionId, positions[positionId].owner);
        }

        emit WithdrawnCollateral(positionId, amount);
    }

    /// @notice Liquidates an undercollateralized position
    /// @param positionId The ID of the position to liquidate
    function liquidatePosition(uint256 positionId) external nonReentrant {
        Position storage position = positions[positionId];
        address positionOwner = position.owner;
        uint256 collateralAmount = position.collateralAmount;
        uint256 debtAmount = position.debtAmount;

        if (positionOwner == address(0)) revert InvalidPosition();
        if (!isLiquidatable(positionId)) revert PositionNotLiquidatable();

        _collectInterestIfAvailable(positionId);

        uint256 reward = (collateralAmount * liquidatorReward) / 100;
        uint256 penalty = (collateralAmount * penaltyRate) / 100;
        uint256 remainingCollateral = collateralAmount - reward - penalty;

        if (!collateralToken.transfer(treasury, penalty)) {
            revert LiquidationFailed();
        }
        if (!collateralToken.transfer(msg.sender, reward)) {
            revert LiquidationFailed();
        }
        if (remainingCollateral > 0) {
            if (!collateralToken.transfer(positionOwner, remainingCollateral)) {
                revert LiquidationFailed();
            }
        }

        collateralBalances[positionOwner] -= collateralAmount;
        loanBalances[positionOwner] -= debtAmount;

        totalDebt -= debtAmount;

        _deletePosition(positionId, positionOwner);

        loanToken.burn(positionOwner, debtAmount);

        emit PositionLiquidated(positionId, msg.sender, reward, debtAmount);
    }

    /// @notice Mint interest amount to InterestCollector
    /// @dev Can only be called by InterestCollector
    /// @param positionId The ID of the position to collect interest from
    /// @param interestAmount The interest amount to be collected
    function collectInterest(
        uint256 positionId,
        uint256 interestAmount
    ) external {
        require(msg.sender == address(interestCollector));

        loanToken.mint(address(interestCollector), interestAmount);

        totalDebt += interestAmount;

        Position storage pos = positions[positionId];
        pos.debtAmount += interestAmount;
        loanBalances[pos.owner] += interestAmount;
        pos.lastInterestCollectionBlock = block.number;

        emit InterestCollected(interestAmount);
    }

    /// @notice Allows users to opt out of soul-bound token minting
    /// @param status The status to set for doNotMint (true = opt out, false = opt in)
    function setDoNotMint(bool status) external {
        doNotMint[msg.sender] = status;
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
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_collateralFeed == address(0)) revert InvalidCollateralPriceFeed();
        if (_loanFeed == address(0)) revert InvalidLoanPriceFeed();
        collateralPriceFeed = IPriceFeed(_collateralFeed);
        loanPriceFeed = IPriceFeed(_loanFeed);
    }

    /// @notice Updates the loan-to-value ratio
    /// @param newLtvRatio The new LTV ratio (between 0 and 100)
    function updateLtvRatio(
        uint256 newLtvRatio
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newLtvRatio == 0 || newLtvRatio > 100) revert InvalidLTVRatio();
        ltvRatio = newLtvRatio;
    }

    /// @notice Emergency function to withdraw tokens from the contract
    /// @param token The address of the token to withdraw
    /// @param amount The amount of tokens to withdraw
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert EmergencyWithdrawFailed();
    }

    /// @notice Set the interest collector contract address
    /// @param _interestCollector The address of the interest collector contract
    function setInterestCollector(
        address _interestCollector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        interestCollector = IInterestCollector(_interestCollector);
        emit InterestCollectorSet(_interestCollector);
    }

    /// @notice Enable or disable interest collection
    /// @param _enabled Whether interest collection should be enabled
    function toggleInterestCollection(
        bool _enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        interestCollectionEnabled = _enabled;
        emit InterestCollectionToggled(_enabled);
    }

    // ======================================================== //
    // ================== INTERNAL FUNCTIONS ================== //
    // ======================================================== //

    /// @dev See {addCollateral}
    function _addCollateral(
        address account,
        address onBehalfOf,
        uint256 positionId,
        uint256 amount
    ) internal {
        if (amount == 0) revert ZeroCollateralAmount();
        if (!collateralToken.transferFrom(account, address(this), amount)) {
            revert CollateralTransferFailed();
        }

        positions[positionId].collateralAmount += amount;
        collateralBalances[onBehalfOf] += amount;

        emit CollateralAdded(positionId, amount);
    }

    /// @dev See {borrow}
    function _borrow(
        address account,
        address onBehalfOf,
        uint256 positionId,
        uint256 amount
    ) internal {
        if (amount == 0) revert ZeroLoanAmount();
        Position storage position = positions[positionId];

        _collectInterestIfAvailable(positionId);

        uint256 newDebtAmount = position.debtAmount + amount;

        uint256 collateralValue = getCollateralValue(position.collateralAmount);
        uint256 newLoanValue = getLoanValue(newDebtAmount);
        uint256 effectiveLtv = position.effectiveLtvRatio;
        uint256 maxLoanValue = (collateralValue * effectiveLtv) / 100;

        if (newLoanValue > maxLoanValue) revert LoanExceedsLTVLimit();

        position.debtAmount = newDebtAmount;
        loanBalances[onBehalfOf] += amount;
        totalDebt += amount;

        loanToken.mint(account, amount);

        emit Borrowed(positionId, amount);
    }

    /// @notice Internal function to burn souldbound token if exists
    /// @param positionId The ID of the position to burn token for
    function _deletePosition(uint256 positionId, address owner) internal {
        if (hasSoulBound[positionId]) {
            soulBoundToken.burn(positionId);
            hasSoulBound[positionId] = false;
        }

        delete positions[positionId];
        uint256[] storage userPositions = userPositionIds[owner];
        for (uint256 i = 0; i < userPositions.length; i++) {
            if (userPositions[i] == positionId) {
                userPositions[i] = userPositions[userPositions.length - 1];
                userPositions.pop();
                break;
            }
        }

        emit PositionDeleted(positionId);
    }

    /// @notice Internal function to get the latest price from a price feed
    /// @param priceFeed The price feed to query
    /// @return The normalized price with 18 decimals
    function _getPrice(IPriceFeed priceFeed) internal view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        return uint256(price) * 10 ** (18 - priceFeed.decimals());
    }

    /// @notice Internal function to collect interest if conditions are met
    /// @param positionId The ID of the position to collect interest
    function _collectInterestIfAvailable(uint256 positionId) internal {
        if (
            address(interestCollector) == address(0) ||
            !interestCollectionEnabled
        ) return;

        Position memory pos = positions[positionId];
        if (pos.debtAmount == 0) return;

        try
            interestCollector.collectInterest(
                address(this),
                address(loanToken),
                positionId,
                pos.debtAmount
            )
        {} catch {
            // Continue execution even if interest collection fails
        }
    }
}
