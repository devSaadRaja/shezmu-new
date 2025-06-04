// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC20Vault} from "../src/interfaces/IERC20Vault.sol";

/// @title IncentiveGauge
/// @notice A contract to manage protocol-funded incentives
/// @dev Manages incentive deposits, distributes rewards to eligible borrowers, and calculates reward rates.
contract IncentiveGauge is ReentrancyGuard, AccessControl {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    struct IncentivePool {
        address token; // The incentive token (e.g. FXS)
        uint256 totalDeposited; // Total amount of tokens deposited
        uint256 rewardRate; // Tokens distributed per second
        uint256 periodFinish; // Timestamp when the reward period ends
        uint256 lastUpdateTime; // Last time the pool was updated
        uint256 rewardPerTokenStored; // Accumulated reward per token
        mapping(address => uint256) userRewardPerTokenPaid; // Tracks user reward progress
        mapping(address => uint256) rewards; // Claimable rewards per user
    }

    bytes32 public constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");

    uint256 public constant REWARD_DURATION = 30 days; // Linear vesting period
    uint256 public constant PRECISION = 1e18; // For precise calculations
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    address public treasury;
    uint256 public protocolFee; // percentage in bips (2500 = 25%)

    IERC20Vault public immutable vault; // Reference to the ERC20Vault contract
    mapping(address => IncentivePool) pools; // Pools per collateral token
    mapping(address => address) collateralToIncentiveToken; // Maps collateral to incentive token

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

    event IncentivesDeposited(
        address indexed collateralToken,
        address indexed token,
        uint256 amount,
        address indexed depositor
    );
    event RewardRateUpdated(
        address indexed collateralToken,
        uint256 rewardRate,
        uint256 periodFinish
    );

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error InvalidCollateralType();
    error InvalidToken();
    error ZeroAmount();
    error TransferFailed();

    // ================================================= //
    // ================== CONSTRUCTOR ================== //
    // ================================================= //

    /// @notice Initializes the IncentiveGauge contract
    /// @param _vault The address of the IERC20Vault contract
    constructor(address _vault, address _treasury, uint256 _protocolFee) {
        if (_vault == address(0)) revert InvalidCollateralType();
        vault = IERC20Vault(_vault);
        treasury = _treasury;
        protocolFee = _protocolFee;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ======================================================== //
    // ================== EXTERNAL FUNCTIONS ================== //
    // ======================================================== //

    /// @notice Allows protocols to deposit incentive tokens for a specific collateral token
    /// @param token The address of the incentive token
    /// @param amount The amount of tokens to deposit
    /// @param collateralToken The collateral token (address of collateral token)
    function depositIncentives(
        address token,
        uint256 amount,
        address collateralToken
    ) external nonReentrant onlyRole(PROTOCOL_ROLE) {
        if (token == address(0)) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();
        if (collateralToken != address(vault.collateralToken())) {
            revert InvalidCollateralType();
        }

        // Initialize pool if it doesn't exist
        if (pools[collateralToken].token == address(0)) {
            pools[collateralToken].token = token;
            collateralToIncentiveToken[collateralToken] = token;
        } else if (pools[collateralToken].token != token) {
            revert InvalidToken();
        }

        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed();
        }

        uint256 protocolAmount = (amount * protocolFee) / 10000;
        uint256 depositAmount = amount - protocolAmount;

        if (!IERC20(token).transfer(treasury, protocolAmount)) {
            revert TransferFailed();
        }

        _updateReward(collateralToken, address(0));

        IncentivePool storage pool = pools[collateralToken];
        pool.totalDeposited += depositAmount;

        uint256 newRewardRate = depositAmount / REWARD_DURATION;
        pool.rewardRate = newRewardRate;
        pool.periodFinish = block.timestamp + REWARD_DURATION;
        pool.lastUpdateTime = block.timestamp;

        emit IncentivesDeposited(
            collateralToken,
            token,
            depositAmount,
            msg.sender
        );
        emit RewardRateUpdated(
            collateralToken,
            newRewardRate,
            pool.periodFinish
        );
    }

    /// @notice Returns the pool data for a given collateral token
    /// @param collateralToken The address of the collateral token
    /// @return token The address of the token in the pool
    /// @return totalDeposited The total amount deposited in the pool
    /// @return rewardRate The current reward rate of the pool
    /// @return periodFinish The timestamp when the reward period will finish
    /// @return lastUpdateTime The last time the pool's reward rate was updated
    function getPoolData(
        address collateralToken
    )
        external
        view
        returns (
            address token,
            uint256 totalDeposited,
            uint256 rewardRate,
            uint256 periodFinish,
            uint256 lastUpdateTime,
            uint256 rewardPerTokenStored
        )
    {
        IncentivePool storage pool = pools[collateralToken];
        token = pool.token;
        totalDeposited = pool.totalDeposited;
        rewardRate = pool.rewardRate;
        periodFinish = pool.periodFinish;
        lastUpdateTime = pool.lastUpdateTime;
        rewardPerTokenStored = pool.rewardPerTokenStored;
    }

    // ====================================================== //
    // ================== PUBLIC FUNCTIONS ================== //
    // ====================================================== //

    /// @notice Gets the claimable rewards for a user
    /// @param collateralToken The address of the collateral token
    /// @param user The address of the user
    /// @return The amount of claimable rewards
    function getClaimableRewards(
        address collateralToken,
        address user
    ) public view returns (uint256) {
        IncentivePool storage pool = pools[collateralToken];
        if (pool.token == address(0)) return 0;

        uint256 rewardPerToken = _rewardPerToken(collateralToken);
        uint256 userCollateral = vault.getCollateralBalance(user);

        return
            pool.rewards[user] +
            ((userCollateral *
                (rewardPerToken - pool.userRewardPerTokenPaid[user])) /
                PRECISION);
    }

    // ======================================================== //
    // ================== INTERNAL FUNCTIONS ================== //
    // ======================================================== //

    /// @notice Updates the reward state for a collateral pool
    /// @param collateralToken The address of the collateral token
    /// @param user The address of the user to update rewards for (address(0) for pool-only update)
    function _updateReward(address collateralToken, address user) internal {
        IncentivePool storage pool = pools[collateralToken];
        if (pool.token == address(0)) return;

        pool.rewardPerTokenStored = _rewardPerToken(collateralToken);
        pool.lastUpdateTime = _lastTimeRewardApplicable(collateralToken);

        if (user != address(0)) {
            pool.rewards[user] = getClaimableRewards(collateralToken, user);
            pool.userRewardPerTokenPaid[user] = pool.rewardPerTokenStored;
        }
    }

    /// @notice Calculates the reward per token for a collateral pool
    /// @param collateralToken The address of the collateral token
    /// @return The reward per token
    function _rewardPerToken(
        address collateralToken
    ) internal view returns (uint256) {
        IncentivePool storage pool = pools[collateralToken];
        if (vault.totalDebt() == 0) return pool.rewardPerTokenStored;

        uint256 timeDelta = _lastTimeRewardApplicable(collateralToken) -
            pool.lastUpdateTime;
        return
            pool.rewardPerTokenStored +
            ((timeDelta * pool.rewardRate * PRECISION) / vault.totalDebt());
    }

    /// @notice Gets the last timestamp when rewards are applicable
    /// @param collateralToken The address of the collateral token
    /// @return The last applicable timestamp
    function _lastTimeRewardApplicable(
        address collateralToken
    ) internal view returns (uint256) {
        IncentivePool storage pool = pools[collateralToken];
        return
            block.timestamp < pool.periodFinish
                ? block.timestamp
                : pool.periodFinish;
    }
}
