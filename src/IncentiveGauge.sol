// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

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
        uint256 totalDeposited; // Total amount of tokens deposited
        uint256 rewardRate; // Tokens distributed per second
        uint256 periodStart; // Timestamp when the reward period ends
        uint256 periodFinish; // Timestamp when the reward period ends
        uint256 lastUpdateTime; // Last time the pool was updated
        uint256 cumulativeAmountPerToken;
    }

    bytes32 public constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");
    bytes32 public constant BALANCE_UPDATER_ROLE =
        keccak256("BALANCE_UPDATER_ROLE");

    uint256 public constant VESTING_DURATION = 30 days; // Linear vesting period
    uint256 public constant PRECISION = 1e18; // For precise calculations

    address public treasury;
    uint256 public protocolFee; // percentage in bips (2500 = 25%)

    IERC20Vault public immutable vault; // Reference to the ERC20Vault contract
    mapping(address => bool) allowedTokens; // Incentive tokens allowed
    mapping(address => IncentivePool) pools; // Pools per collateral token
    mapping(address => mapping(address => uint256)) unclaimedIncentives; // User address => (Token address => Unclaimed Incentive)
    mapping(address => mapping(address => uint256)) lastCumulativeAmountPerToken; // User address => (Token address => Last cumulative amount per token)
    mapping(address => mapping(address => uint256)) lastClaimTimestamp; // User address => (Token address => Last claim timestamp)

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

    event IncentivesDeposited(
        address indexed token,
        uint256 amount,
        address indexed depositor
    );
    event RewardRateUpdated(
        address indexed token,
        uint256 rewardRate,
        uint256 periodFinish
    );
    event AllowedTokenSet(address indexed token, bool allowed);

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
        _grantRole(BALANCE_UPDATER_ROLE, _vault);
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
        if (token == address(0) || !allowedTokens[token]) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();
        if (collateralToken != address(vault.collateralToken())) {
            revert InvalidCollateralType();
        }

        uint256 totalSupply = vault.totalCollateral();
        if (totalSupply == 0) return;

        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed();
        }

        uint256 protocolAmount = (amount * protocolFee) / 10000;
        uint256 depositAmount = amount - protocolAmount;

        if (!IERC20(token).transfer(treasury, protocolAmount)) {
            revert TransferFailed();
        }

        IncentivePool storage pool = pools[token];

        // _updatePool(token);

        uint256 amountPerToken = (depositAmount * PRECISION) / totalSupply;

        pool.totalDeposited += depositAmount;
        pool.rewardRate = depositAmount / VESTING_DURATION;
        pool.periodStart = block.timestamp;
        pool.periodFinish = block.timestamp + VESTING_DURATION;
        pool.lastUpdateTime = block.timestamp;
        pool.cumulativeAmountPerToken += amountPerToken;

        emit IncentivesDeposited(token, depositAmount, msg.sender);
        emit RewardRateUpdated(token, pool.rewardRate, pool.periodFinish);
    }

    /// @notice Updates a user's incentives when their collateral balance changes
    /// @param holder The address of the user whose balance is updated
    /// @param token The address of the incentive token
    function onCollateralBalanceChange(
        address holder,
        address token
    ) external onlyRole(BALANCE_UPDATER_ROLE) {
        if (token == address(0) || !allowedTokens[token]) revert InvalidToken();

        // _updatePool(token);
        _updateIncentives(holder, token);
        // emit BalanceUpdated(
        //     holder,
        //     token,
        //     vault.getCollateralBalance(holder)
        // );
    }

    /// @notice Sets the allowed incentive tokens for deposits
    /// @dev Only callable by an account with the PROTOCOL_ROLE
    /// @param token The token address to allow or disallow
    /// @param allowed boolean indicating if the token is allowed (true) or not (false)
    function setAllowedToken(
        address token,
        bool allowed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowedTokens[token] = allowed;
        emit AllowedTokenSet(token, allowed);
    }

    /// @notice Returns the pool data for a given collateral token
    /// @param token The address of the incentive token
    /// @return totalDeposited The total amount deposited in the pool
    /// @return rewardRate The current reward rate of the pool
    /// @return periodStart The timestamp when the reward period starts
    /// @return periodFinish The timestamp when the reward period will finish
    /// @return lastUpdateTime The last time the pool's reward rate was updated
    function getPoolData(
        address token
    )
        external
        view
        returns (
            uint256 totalDeposited,
            uint256 rewardRate,
            uint256 periodStart,
            uint256 periodFinish,
            uint256 lastUpdateTime
        )
    {
        IncentivePool storage pool = pools[token];
        totalDeposited = pool.totalDeposited;
        rewardRate = pool.rewardRate;
        periodStart = pool.periodStart;
        periodFinish = pool.periodFinish;
        lastUpdateTime = pool.lastUpdateTime;
    }

    /// @notice Returns true if the token is allowed for incentives
    /// @param token The address of the incentive token to check
    /// @return True if the token is allowed, false otherwise
    function isTokenAllowed(address token) external view returns (bool) {
        return allowedTokens[token];
    }

    /// @notice Gets the claimable rewards for a user
    /// @param token The address of the incentive token
    /// @param user The address of the user
    /// @return The amount of claimable rewards
    function getClaimableIncentives(
        address token,
        address user
    ) external view returns (uint256) {
        return _getUnclaimedIncentives(token, user);
    }

    // ======================================================== //
    // ================== INTERNAL FUNCTIONS ================== //
    // ======================================================== //

    function _getUnclaimedIncentives(
        address token,
        address user
    ) internal view returns (uint256) {
        uint256 cumulativeAmount = pools[token].cumulativeAmountPerToken;
        uint256 lastCumulativeAmount = lastCumulativeAmountPerToken[user][
            token
        ];
        uint256 balance = vault.getCollateralBalance(user);
        uint256 amountPerTokenSinceClaim = cumulativeAmount -
            lastCumulativeAmount;
        uint256 totalAccruedIncentives = (balance * amountPerTokenSinceClaim) /
            PRECISION;
        uint256 unclaimed = unclaimedIncentives[user][token];
        uint256 lastClaimTime = lastClaimTimestamp[user][token];

        // If no previous claim, use pool's last update time as the start of vesting
        if (lastClaimTime == 0) lastClaimTime = pools[token].lastUpdateTime;

        console.log();
        console.log(cumulativeAmount, "<<< cumulativeAmount");
        console.log(lastCumulativeAmount, "<<< lastCumulativeAmount");
        console.log(balance, "<<< balance");
        console.log(amountPerTokenSinceClaim, "<<< amountPerTokenSinceClaim");
        console.log(totalAccruedIncentives, "<<< totalAccruedIncentives");
        console.log(unclaimed, "<<< unclaimed");
        console.log(lastClaimTime, "<<< lastClaimTime");

        // Calculate vested amount based on time elapsed
        uint256 timeElapsed = block.timestamp - lastClaimTime;
        if (timeElapsed >= VESTING_DURATION) {
            return unclaimed + totalAccruedIncentives;
        }

        // Linear vesting: vested amount = total * (timeElapsed / VESTING_DURATION)
        uint256 vestedAmount = (totalAccruedIncentives * timeElapsed) /
            VESTING_DURATION;
        return unclaimed + vestedAmount;
    }

    /// @notice Updates the user's unclaimed incentives and resets their cumulative amount per token
    /// @param holder The address of the user
    /// @param token The address of the incentive token
    function _updateIncentives(address holder, address token) internal {
        // _updatePool(token);
        unclaimedIncentives[holder][token] = _getUnclaimedIncentives(
            holder,
            token
        );
        lastCumulativeAmountPerToken[holder][token] = pools[token]
            .cumulativeAmountPerToken;
        lastClaimTimestamp[holder][token] = block.timestamp;
    }

    // function _updatePool(address token) internal {
    //     IncentivePool storage pool = pools[token];
    //     uint256 supply = vault.totalCollateral();
    //     if (supply == 0) return;

    //     uint256 lastTime = block.timestamp < pool.periodFinish
    //         ? block.timestamp
    //         : pool.periodFinish;

    //     uint256 delta = lastTime - pool.lastUpdateTime;
    //     if (delta > 0) {
    //         uint256 perToken = (delta * pool.rewardRate * PRECISION) / supply;
    //         pool.cumulativeAmountPerToken += perToken;
    //         pool.lastUpdateTime = lastTime;
    //     }
    // }
}
