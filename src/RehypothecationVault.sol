// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IPool} from "./interfaces/aave-v3/IPool.sol";
import {IRewardsController} from "./interfaces/aave-v3/IRewardsController.sol";

contract RehypothecationVault is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    struct Position {
        address owner;
        uint256 principal; // uint256 collateralAmount;
        // uint256 aTokenAmount;
        uint256 initialLiquidityIndex;
        uint256 supplyTime;
    }

    uint256 public constant BORROWER_YIELD_SHARE = 7500; // 75% yield to borrower (bips)
    uint256 public constant PROTOCOL_YIELD_SHARE = 2500; // 25% yield to protocol (bips)
    uint256 public constant DENOMINATOR = 10000; // For percentage calculations (bips)

    address public vault;
    address public treasury;
    IERC20 public collateralToken;
    IERC20 public aToken;
    IERC20 public rewardToken;
    IPool public pool;
    IRewardsController public rewardsController;

    mapping(uint256 => uint256) public amounts; // Tracks collateral amount per position
    mapping(uint256 => Position) positions;

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

    event Deposit(uint256 indexed positionId, uint256 amount);
    event RewardClaimed(uint256 borrowerAmount, uint256 protocolAmount);
    event Withdraw(uint256 indexed positionId);
    event PoolUpdated(address indexed newProxy);
    event RewardsControllerUpdated(address indexed newController);

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error InvalidAddress();
    error Unauthorized();
    error ZeroAmount();
    error ZeroReward();
    error AlreadyActive();

    // =============================================== //
    // ================== MODIFIERS ================== //
    // =============================================== //

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    modifier onlyValidAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }

    // =============================================== //
    // ================== INITIALIZE ================= //
    // =============================================== //

    /// @notice Initializes the vault with required addresses and parameters
    /// @param _treasury Address of the treasury
    /// @param _collateralToken Address of the collateral token
    /// @param _rewardToken Address of the reward token
    /// @param _pool Address of the yield proxy contract
    /// @param _rewardController Address of the reward controller contract
    function initialize(
        address _treasury,
        address _collateralToken,
        address _aToken,
        address _rewardToken,
        address _pool,
        address _rewardController
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        treasury = _treasury;
        collateralToken = IERC20(_collateralToken);
        aToken = IERC20(_aToken);
        rewardToken = IERC20(_rewardToken);
        pool = IPool(_pool);
        rewardsController = IRewardsController(_rewardController);
    }

    // ==================================================== //
    // ================== VIEW FUNCTIONS ================== //
    // ==================================================== //

    // /// @notice Returns the position details for a given position ID
    // /// @param positionId The ID of the position to query
    // /// @return owner The address of the position owner
    // /// @return collateralAmount The amount of collateral in the position
    // /// @return aTokenAmount The amount of aTokens for this position
    // function getPosition(
    //     uint256 positionId
    // ) external view returns (address, uint256, uint256) {
    //     Position memory position = positions[positionId];
    //     return (
    //         position.owner,
    //         position.collateralAmount,
    //         position.aTokenAmount
    //     );
    // }

    /// @notice Retrieves the accumulated rewards for a specific user
    /// @param user Address of the user to check rewards for
    /// @return uint256 Amount of accumulated rewards
    function getAccumulatedRewards(address user) public view returns (uint256) {
        return (
            rewardsController.getUserAccruedRewards(user, address(rewardToken))
        );
    }

    /// @notice Gets the current rewards balance for a specific user
    /// @param user Address of the user to check rewards for
    /// @return uint256 Amount of current rewards
    function getUserRewards(address user) public view returns (uint256) {
        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        return (
            rewardsController.getUserRewards(assets, user, address(rewardToken))
        );
    }

    // ===================================================== //
    // ================== WRITE FUNCTIONS ================== //
    // ===================================================== //

    /// @notice Deposits collateral into the vault and forwards it to the specified protocol
    /// @param positionId Unique identifier for the position
    /// @param amount Amount of collateral to deposit
    function deposit(
        uint256 positionId,
        address user,
        uint256 amount
    ) external nonReentrant onlyVault {
        if (amount == 0) revert ZeroAmount();
        if (amounts[positionId] > 0) revert AlreadyActive();
        // if (positions[positionId].collateralAmount > 0) revert AlreadyActive();

        collateralToken.transferFrom(user, address(this), amount);

        amounts[positionId] = amount;
        // positions[positionId].owner = user;
        // positions[positionId].collateralAmount = amount;

        // uint256 balanceBefore = aToken.balanceOf(address(this));

        collateralToken.approve(address(pool), amount);
        pool.supply(address(collateralToken), amount, address(this), 0);

        // positions[positionId].aTokenAmount =
        //     aToken.balanceOf(address(this)) -
        //     balanceBefore;

        emit Deposit(positionId, amount);
    }

    /// @notice Withdraws collateral from a position
    /// @param positionId Unique identifier for the position
    function withdraw(
        uint256 positionId,
        address user
    ) external nonReentrant onlyVault {
        uint256 balanceBefore = aToken.balanceOf(address(this));

        pool.withdraw(
            address(collateralToken),
            amounts[positionId],
            address(this)
        );

        uint256 newBalance = aToken.balanceOf(address(this));
        uint256 interestATokens = balanceBefore - newBalance;
        uint256 interest = pool.withdraw(
            address(collateralToken),
            interestATokens,
            address(this)
        );

        // uint256 interest = withdrawnAmount - amounts[positionId];
        // uint256 interest = withdrawnAmount -
        //     positions[positionId].collateralAmount;

        uint256 borrowerAmount = (interest * BORROWER_YIELD_SHARE) /
            DENOMINATOR;
        uint256 protocolAmount = (interest * PROTOCOL_YIELD_SHARE) /
            DENOMINATOR;

        collateralToken.transfer(treasury, protocolAmount);
        collateralToken.transfer(user, borrowerAmount + amounts[positionId]);

        amounts[positionId] = 0;

        emit Withdraw(positionId);
    }

    /// @notice Claims accumulated reward for a user and splits it between borrower and protocol
    /// @dev Splits yield according to BORROWER_YIELD_SHARE and PROTOCOL_YIELD_SHARE
    function claimReward(address user) external nonReentrant onlyVault {
        uint256 totalReward = this.getUserRewards(address(this));
        if (totalReward == 0) revert ZeroReward();

        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        rewardsController.claimRewards(
            assets,
            type(uint256).max,
            address(this),
            address(rewardToken)
        );

        uint256 borrowerAmount = (totalReward * BORROWER_YIELD_SHARE) /
            DENOMINATOR;
        uint256 protocolAmount = (totalReward * PROTOCOL_YIELD_SHARE) /
            DENOMINATOR;

        rewardToken.transfer(user, borrowerAmount);
        rewardToken.transfer(treasury, protocolAmount);

        emit RewardClaimed(borrowerAmount, protocolAmount);
    }

    // ===================================================== //
    // ================== OWNER FUNCTIONS ================== //
    // ===================================================== //

    /// @notice Sets the vault address
    /// @param _vault Address of Vault contract
    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    /// @notice Updates the pool proxy contract address
    /// @param newProxy Address of the new yield proxy contract
    function updatePoolProxy(
        address newProxy
    ) external onlyOwner onlyValidAddress(newProxy) {
        pool = IPool(newProxy);
        emit PoolUpdated(newProxy);
    }

    /// @notice Updates the reward controller contract address
    /// @param newController Address of the new reward controller contract
    function updateRewardsController(
        address newController
    ) external onlyOwner onlyValidAddress(newController) {
        rewardsController = IRewardsController(newController);
        emit RewardsControllerUpdated(newController);
    }
}
