// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SoulBound} from "./SoulBound.sol";

import {EERC20} from "./interfaces/EERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IInterestCollector} from "./interfaces/IInterestCollector.sol";

/// @title ERC20Vault
/// @notice A lending vault contract for ERC20 tokens with support for leverage, interest collection, and soul-bound tokens.
/// @dev Inherits from ReentrancyGuard and AccessControl. Manages positions, collateral, debt, and integrates with external strategies and price feeds.
contract ERC20Vault is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    struct Position {
        address owner;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 lastInterestCollectionBlock;
        uint256 effectiveLtvRatio;
        bool interestOptOut;
        uint256 leverage;
    }

    bytes32 public constant LEVERAGE_ROLE = keccak256("LEVERAGE_ROLE");
    uint256 public constant PRECISION = 1e18; // For precise calculations
    uint256 public constant MAX_LEVERAGE = 10; // 10x
    uint256 public constant BIPS_HUNDRED = 10000;

    SoulBound public soulBoundToken;
    uint256 public soulBoundFeePercent = 200; // bips
    mapping(uint256 => bool) hasSoulBound; // Tracks if a position has a soul-bound token
    mapping(address => bool) doNotMint; // check if user has not allowed soulbound (deducting fee)

    IStrategy public strategy;
    mapping(address => bool) interestOptOut; // default interest accrual

    IERC20 public immutable collateralToken;
    EERC20 public immutable loanToken;
    uint256 public immutable liquidationThreshold; // % of LTV ratio as liquidation threshold
    uint256 public immutable liquidatorReward; // 50 for 50%
    uint256 public immutable penaltyRate; // 10 for 10%
    uint256 public ltvRatio; // Loan-to-Value ratio in bips (e.g., 5000 for 50%)

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
    event BatchPositionsLiquidated(
        uint256[] positionIds,
        address liquidator,
        uint256 totalReward
    );

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
    error NotPositionOwner();
    error AmountExceedsLoan();
    error InsufficientCollateral();
    error InsufficientCollateralAfterWithdrawal();
    error InvalidPrice();
    error PositionNotLiquidatable();
    error NoPositionsToLiquidate();
    error InvalidLeverage();
    error MaxDebtReached();

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
        address _treasury,
        address _strategy,
        uint256 _penalty
    ) {
        if (_collateralToken == address(0)) revert InvalidCollateralToken();
        if (_loanToken == address(0)) revert InvalidLoanToken();
        if (_ltvRatio == 0 || _ltvRatio > BIPS_HUNDRED)
            revert InvalidLTVRatio();
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
        strategy = IStrategy(_strategy);
        penaltyRate = _penalty;

        soulBoundToken = new SoulBound(address(this));

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ======================================================== //
    // ================== EXTERNAL FUNCTIONS ================== //
    // ======================================================== //

    /// @notice Allows users to opt out of soul-bound token minting
    /// @param status The status to set for doNotMint (true = opt out, false = opt in)
    function setDoNotMint(bool status) external {
        doNotMint[msg.sender] = status;
    }

    /// @notice Sets if user want to opt in or out of interest deduction
    function setInterestOptOut(bool val) external {
        interestOptOut[msg.sender] = val;
    }

    /// @notice Opens a new lending position
    /// @param collateral The address of the collateral token
    /// @param collateralAmount The amount of collateral to deposit
    /// @param debtAmount The amount of tokens to borrow
    function openPosition(
        address owner,
        address collateral,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 leverage
    ) external nonReentrant {
        if (collateral != address(collateralToken)) {
            revert InvalidCollateralToken();
        }
        if (collateralAmount == 0) revert ZeroCollateralAmount();
        if (leverage < 1 || leverage > MAX_LEVERAGE) revert InvalidLeverage();

        collateralToken.safeTransferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );

        (
            uint256 fee,
            uint256 adjustedCollateral,
            uint256 maxDebt,
            uint256 effectiveLtvRatio
        ) = _estimateTotalDebt(
                owner,
                collateralAmount,
                leverage,
                ltvRatio,
                true
            );
        if (debtAmount > maxDebt) revert MaxDebtReached();

        uint256 positionId = nextPositionId++;
        positions[positionId] = Position(
            owner,
            adjustedCollateral,
            debtAmount,
            block.number,
            effectiveLtvRatio,
            interestOptOut[owner],
            leverage
        );
        userPositionIds[owner].push(positionId);

        collateralBalances[owner] += adjustedCollateral;
        loanBalances[owner] += debtAmount;
        totalDebt += debtAmount;

        loanToken.mint(owner, debtAmount);

        interestCollector.setLastCollectionBlock(address(this), positionId);

        Position storage pos = positions[positionId];

        if (!doNotMint[owner]) {
            soulBoundToken.mint(msg.sender, positionId);
            hasSoulBound[positionId] = true;

            if (fee > 0) collateralToken.safeTransfer(treasury, fee);
        }

        if (address(strategy) != address(0) && pos.interestOptOut) {
            collateralToken.safeIncreaseAllowance(
                address(strategy),
                pos.collateralAmount
            );
            strategy.deposit(positionId, pos.collateralAmount);
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
            uint256 minCollateralValue = (loanValue * BIPS_HUNDRED) /
                effectiveLtv;
            if (remainingCollateralValue < minCollateralValue) {
                revert InsufficientCollateralAfterWithdrawal();
            }
        }

        positions[positionId].collateralAmount = newCollateralAmount;
        collateralBalances[msg.sender] -= amount;

        if (
            address(strategy) != address(0) &&
            positions[positionId].interestOptOut
        ) {
            strategy.withdraw(positionId, amount);
        }

        collateralToken.safeTransfer(msg.sender, amount);

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
        bool posInterestOptOut = position.interestOptOut;

        if (positionOwner == address(0)) revert InvalidPosition();
        if (!isLiquidatable(positionId)) revert PositionNotLiquidatable();

        _collectInterestIfAvailable(positionId);

        uint256 reward = (collateralAmount * liquidatorReward) / 100;
        uint256 penalty = (collateralAmount * penaltyRate) / 100;
        uint256 remainingCollateral = collateralAmount - reward - penalty;

        if (address(strategy) != address(0) && posInterestOptOut) {
            strategy.withdraw(positionId, collateralAmount);
        }

        collateralToken.safeTransfer(treasury, penalty);
        collateralToken.safeTransfer(msg.sender, reward);
        if (remainingCollateral > 0) {
            collateralToken.safeTransfer(positionOwner, remainingCollateral);
        }

        collateralBalances[positionOwner] -= collateralAmount;
        loanBalances[positionOwner] -= debtAmount;

        totalDebt -= debtAmount;

        _deletePosition(positionId, positionOwner);

        loanToken.burn(positionOwner, debtAmount);

        emit PositionLiquidated(positionId, msg.sender, reward, debtAmount);
    }

    function batchLiquidate(
        uint256[] calldata positionIds
    ) external nonReentrant {
        if (positionIds.length == 0) revert NoPositionsToLiquidate();

        uint256 totalPenalty = 0;
        uint256 totalReward = 0;

        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            Position storage position = positions[positionId];
            address positionOwner = position.owner;

            if (positionOwner == address(0)) continue;
            if (!isLiquidatable(positionId)) continue;

            _collectInterestIfAvailable(positionId);

            uint256 collateralAmount = position.collateralAmount;
            uint256 debtAmount = position.debtAmount;

            uint256 reward = (collateralAmount * liquidatorReward) / 100;
            uint256 penalty = (collateralAmount * penaltyRate) / 100;
            uint256 remainingCollateral = collateralAmount - reward - penalty;

            totalPenalty += penalty;
            totalReward += reward;

            // Update balances
            collateralBalances[positionOwner] -= collateralAmount;
            loanBalances[positionOwner] -= debtAmount;
            totalDebt -= debtAmount;

            if (
                address(strategy) != address(0) &&
                positions[positionId].interestOptOut
            ) {
                strategy.withdraw(positionId, collateralAmount);
            }

            if (remainingCollateral > 0) {
                collateralToken.safeTransfer(
                    positionOwner,
                    remainingCollateral
                );
            }

            loanToken.burn(positionOwner, debtAmount);

            _deletePosition(positionId, positionOwner);
        }

        if (totalPenalty > 0)
            collateralToken.safeTransfer(treasury, totalPenalty);
        if (totalReward > 0)
            collateralToken.safeTransfer(msg.sender, totalReward);

        emit BatchPositionsLiquidated(positionIds, msg.sender, totalReward);
    }

    /// @notice Mint interest amount to InterestCollector
    /// @dev Can only be called by InterestCollector
    /// @param positionId The ID of the position to collect interest from
    function collectInterest(
        uint256 positionId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 interestAmount = _collectInterestIfAvailable(positionId);
        emit InterestCollected(interestAmount);
    }

    /// @notice Sets strategy
    /// @param _strategy address of new strategy
    function setStrategy(
        address _strategy
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        strategy = IStrategy(_strategy);
    }

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
        if (newLtvRatio == 0 || newLtvRatio > BIPS_HUNDRED) {
            revert InvalidLTVRatio();
        }
        ltvRatio = newLtvRatio;
    }

    /// @notice Emergency function to withdraw tokens from the contract
    /// @param token The address of the token to withdraw
    /// @param amount The amount of tokens to withdraw
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
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

    /// @notice Returns the position details for a given position ID
    /// @param positionId The ID of the position to query
    /// @return owner The address of the position owner
    /// @return collateralAmount The amount of collateral in the position
    /// @return debtAmount The amount of debt in the position
    /// @return the block number for last interest collected
    function getPosition(
        uint256 positionId
    )
        external
        view
        returns (address, uint256, uint256, uint256, uint256, bool, uint256)
    {
        Position memory position = positions[positionId];
        return (
            position.owner,
            position.collateralAmount,
            position.debtAmount,
            position.lastInterestCollectionBlock,
            position.effectiveLtvRatio,
            position.interestOptOut,
            position.leverage
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

    /// @notice Calculates the maximum amount a user can borrow based on their total collateral
    /// @param positionId The positionId to check max loan amount
    /// @return The maximum borrowable amount in loan tokens
    function getMaxBorrowable(
        uint256 positionId
    ) external view returns (uint256) {
        (, , uint256 maxLoan, ) = _estimateTotalDebt(
            positions[positionId].owner,
            positions[positionId].collateralAmount,
            positions[positionId].leverage,
            positions[positionId].effectiveLtvRatio,
            false
        );

        return maxLoan;
    }

    /// @notice Gets all position IDs owned by a user
    /// @param user The address of the user to query
    /// @return An array of position IDs
    function getUserPositionIds(
        address user
    ) external view returns (uint256[] memory) {
        return userPositionIds[user];
    }

    /// @notice Checks if a position has a soul-bound token
    /// @param positionId The ID of the position to check
    /// @return True if the position has a soul-bound token, false otherwise
    function getHasSoulBound(uint256 positionId) external view returns (bool) {
        return hasSoulBound[positionId];
    }

    /// @notice Checks if a user has opted out of soul-bound token minting
    /// @param user The address of the user to check
    /// @return True if the user has opted out, false otherwise
    function getDoNotMint(address user) external view returns (bool) {
        return doNotMint[user];
    }

    // ====================================================== //
    // ================== PUBLIC FUNCTIONS ================== //
    // ====================================================== //

    /// @notice Calculates the health factor of a position
    /// @param positionId The ID of the position to check
    /// @return The health factor
    function getPositionHealth(
        uint256 positionId
    ) public view returns (uint256) {
        Position memory pos = positions[positionId];
        if (pos.debtAmount == 0) return type(uint256).max;

        uint256 collateralValue = getCollateralValue(pos.collateralAmount);
        uint256 debtValue = getLoanValue(pos.debtAmount);

        uint256 x = (collateralValue * pos.leverage * pos.effectiveLtvRatio) /
            BIPS_HUNDRED;
        uint256 y = (debtValue * (1000 - (1000 / (pos.leverage + 1)))) / 1000;

        return (x * PRECISION) / y;
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
        uint256 threshold = (PRECISION * liquidationThreshold) / 100;

        return health < threshold;
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
        if (positions[positionId].owner != onBehalfOf) {
            revert NotPositionOwner();
        }

        collateralToken.safeTransferFrom(account, address(this), amount);

        if (
            address(strategy) != address(0) &&
            positions[positionId].interestOptOut
        ) {
            collateralToken.safeIncreaseAllowance(address(strategy), amount);
            strategy.deposit(positionId, amount);
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

        if (position.owner != onBehalfOf) revert NotPositionOwner();

        _collectInterestIfAvailable(positionId);

        (, , uint256 maxLoan, ) = _estimateTotalDebt(
            onBehalfOf,
            position.collateralAmount,
            position.leverage,
            position.effectiveLtvRatio,
            false
        );

        uint256 newDebtAmount = position.debtAmount + amount;
        uint256 newLoanValue = getLoanValue(newDebtAmount);
        uint256 maxLoanValue = getLoanValue(maxLoan);

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

    /// @notice Internal function to collect interest if conditions are met
    /// @param positionId The ID of the position to collect interest
    function _collectInterestIfAvailable(
        uint256 positionId
    ) internal returns (uint256) {
        if (
            address(interestCollector) == address(0) ||
            !interestCollectionEnabled
        ) return 0;

        Position memory pos = positions[positionId];
        if (pos.debtAmount == 0) return 0;

        try
            interestCollector.collectInterest(
                address(this),
                address(loanToken),
                positionId,
                pos.debtAmount
            )
        returns (uint256 interestAmount) {
            loanToken.mint(address(interestCollector), interestAmount);

            totalDebt += interestAmount;

            positions[positionId].debtAmount += interestAmount;
            loanBalances[pos.owner] += interestAmount;

            return interestAmount;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Estimates the total debt a user can take based on collateral and leverage.
     * @dev Calculates the fee, adjusted collateral, maximum debt, and effective LTV ratio.
     *      Applies soul-bound fee and adjusts LTV if the user has not opted out of soul-bound minting.
     * @param user The address of the user opening the position.
     * @param collateralAmount The amount of collateral being deposited.
     * @param leverage The leverage multiplier requested.
     * @return fee The fee deducted for soul-bound token minting (if applicable).
     * @return adjustedCollateral The collateral amount after deducting the fee.
     * @return debtAmount The maximum debt amount the user can borrow.
     * @return effectiveLtvRatio The effective loan-to-value ratio for this position.
     */
    function _estimateTotalDebt(
        address user,
        uint256 collateralAmount,
        uint256 leverage,
        uint256 posLtvRatio,
        bool open
    )
        internal
        view
        returns (
            uint256 fee,
            uint256 adjustedCollateral,
            uint256 debtAmount,
            uint256 effectiveLtvRatio
        )
    {
        uint256 baseLtvRatio = posLtvRatio;
        effectiveLtvRatio = baseLtvRatio;
        adjustedCollateral = collateralAmount;

        if (open && !doNotMint[user]) {
            fee = (collateralAmount * soulBoundFeePercent) / BIPS_HUNDRED;
            adjustedCollateral = collateralAmount - fee;

            uint256 differenceTo100 = BIPS_HUNDRED - baseLtvRatio;
            uint256 halfDifference = differenceTo100 / 2;
            uint256 newLtvBeforeFee = BIPS_HUNDRED - halfDifference;
            effectiveLtvRatio = newLtvBeforeFee - soulBoundFeePercent;
        }

        uint256 collateralValue = getCollateralValue(adjustedCollateral);
        uint256 loanValueNeeded = collateralValue * leverage;

        uint256 loanValue = (loanValueNeeded * effectiveLtvRatio) /
            BIPS_HUNDRED;
        uint256 loanPrice = getLoanValue(1 ether);

        debtAmount = (loanValue * PRECISION) / loanPrice;
    }

    /// @notice Internal function to get the latest price from a price feed
    /// @param priceFeed The price feed to query
    /// @return The normalized price with 18 decimals
    function _getPrice(IPriceFeed priceFeed) internal view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        if (price <= 0) revert InvalidPrice();
        return uint256(price) * 10 ** (18 - priceFeed.decimals());
    }
}
