// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "../interfaces/aave-v3/IPool.sol";
import "../interfaces/aave-v3/IRewardsController.sol";

import "../libraries/WadRayMath.sol";
import "../libraries/MathUtils.sol";

contract AaveStrategy is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using WadRayMath for uint128;
    using WadRayMath for uint256;
    using MathUtils for uint256;

    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    struct Position {
        address owner;
        uint256 collateralAmount;
        uint256 liquidityIndex;
        uint256 lastUpdateTimestamp;
    }

    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_IN_A_YEAR = 365 days;
    uint256 public constant BORROWER_SHARE = 7500; // 75% yield to borrower (bips)
    uint256 public constant PROTOCOL_SHARE = 2500; // 25% yield to protocol (bips)
    uint256 public constant DENOMINATOR = 10000; // For percentage calculations (bips)

    address public vault;
    address public treasury;
    IERC20 public collateralToken;
    IERC20 public aToken;
    IERC20 public rewardToken;
    uint256 public totalDeposited; // Total collateral deposited

    IPool public pool;
    IRewardsController public rewardsController;

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

    /// @notice Returns the position details for a given position ID
    /// @param positionId The ID of the position to query
    /// @return owner The address of the position owner
    /// @return collateralAmount The amount of collateral in the position
    function getPosition(
        uint256 positionId
    ) external view returns (address, uint256, uint256) {
        Position memory position = positions[positionId];
        return (
            position.owner,
            position.collateralAmount,
            position.lastUpdateTimestamp
        );
    }

    // /// @notice Retrieves the accrued rewards for a specific user
    // /// @param user Address of the user to check rewards for
    // /// @return uint256 Amount of accrued rewards
    // function getAccruedRewards(address user) public view returns (uint256) {
    //     return (
    //         rewardsController.getUserAccruedRewards(user, address(rewardToken))
    //     );
    // }

    // /// @notice Gets the current rewards balance for a specific user
    // /// @param user Address of the user to check rewards for
    // /// @return uint256 Amount of current rewards
    // function getUserRewards(address user) public view returns (uint256) {
    //     address[] memory assets = new address[](1);
    //     assets[0] = address(aToken);
    //     return (
    //         rewardsController.getUserRewards(assets, user, address(rewardToken))
    //     );
    // }

    /// @notice Gets the current rewards balance for a specific user
    /// @param positionId The ID of the position to query
    /// @return uint256 current interest amount of position
    function getAccumulatedInterest(
        uint256 positionId
    ) external view returns (uint256) {
        return _getAccumulatedInterest(positionId);
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
        // if (positions[positionId].collateralAmount > 0) revert AlreadyActive();

        DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(
            address(collateralToken)
        );

        collateralToken.transferFrom(msg.sender, address(this), amount);

        positions[positionId].collateralAmount += amount;

        if (positions[positionId].owner == address(0)) {
            positions[positionId].owner = user;
            positions[positionId].lastUpdateTimestamp = block.timestamp;
            positions[positionId].liquidityIndex = reserveData.liquidityIndex;
        }

        totalDeposited += amount;

        collateralToken.approve(address(pool), amount);
        pool.supply(address(collateralToken), amount, address(this), 0);

        emit Deposit(positionId, amount);
    }

    /// @notice Withdraws collateral from a position and divides interest
    /// @param positionId Unique identifier for the position
    function withdraw(uint256 positionId) external nonReentrant onlyVault {
        Position storage pos = positions[positionId];

        uint256 interest = _getAccumulatedInterest(positionId);
        pool.withdraw(
            address(collateralToken),
            pos.collateralAmount + interest,
            address(this)
        );

        uint256 borrowerAmount = (interest * BORROWER_SHARE) / DENOMINATOR;
        uint256 protocolAmount = (interest * PROTOCOL_SHARE) / DENOMINATOR;

        collateralToken.transfer(treasury, protocolAmount);
        collateralToken.transfer(
            pos.owner,
            borrowerAmount + pos.collateralAmount
        );

        totalDeposited -= pos.collateralAmount;
        pos.collateralAmount = 0;

        emit Withdraw(positionId);
    }

    // /// @notice Claims accumulated reward for a user and splits it between borrower and protocol
    // /// @param positionId Unique identifier for the position
    // /// @dev Splits yield according to BORROWER_SHARE and PROTOCOL_SHARE
    // function claimReward(uint256 positionId) external nonReentrant onlyVault {
    //     uint256 totalReward = this.getUserRewards(address(this));
    //     if (totalReward == 0) revert ZeroReward();

    //     Position memory pos = positions[positionId];

    //     address[] memory assets = new address[](1);
    //     assets[0] = address(aToken);
    //     rewardsController.claimRewards(
    //         assets,
    //         borrowerAmount + pos.collateralAmount, // type(uint256).max,
    //         address(this),
    //         address(rewardToken)
    //     );

    //     uint256 borrowerAmount = (totalReward * BORROWER_SHARE) / DENOMINATOR;
    //     uint256 protocolAmount = (totalReward * PROTOCOL_SHARE) / DENOMINATOR;

    //     rewardToken.transfer(pos.owner, borrowerAmount);
    //     rewardToken.transfer(treasury, protocolAmount);

    //     emit RewardClaimed(borrowerAmount, protocolAmount);
    // }

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

    /// @notice Sets no use for reserves as collateral
    function setUserUseReserveAsCollateral() external onlyOwner {
        pool.setUserUseReserveAsCollateral(address(collateralToken), false);
    }

    // ======================================================== //
    // ================== INTERNAL FUNCTIONS ================== //
    // ======================================================== //

    /// @notice Gets the current rewards balance for a specific user
    /// @param positionId The ID of the position to query
    /// @return uint256 current interest amount of position
    function _getAccumulatedInterest(
        uint256 positionId
    ) internal view returns (uint256) {
        Position memory position = positions[positionId];
        if (position.collateralAmount == 0) return 0;

        DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(
            address(collateralToken)
        );
        uint256 initialLiquidityIndex = position.liquidityIndex;
        uint256 currentLiquidityIndex = reserveData.liquidityIndex;

        console.log(initialLiquidityIndex, "<<< initialLiquidityIndex");
        console.log(currentLiquidityIndex, "<<< currentLiquidityIndex");

        // uint256 scaledBalance = (position.collateralAmount * RAY) /
        //     initialLiquidityIndex;

        uint256 scaledBalance = position.collateralAmount.rayDiv(reserveData.liquidityIndex);

        console.log(scaledBalance, "<<< scaledBalance");

        uint256 updatedBalance = (scaledBalance * currentLiquidityIndex) / RAY;

        uint256 interest = updatedBalance - position.collateralAmount;

        return interest;

        // ! ---

        // Position memory position = positions[positionId];
        // if (position.collateralAmount == 0) return 0;

        // console.log();

        // console.log(position.collateralAmount, "<<< position.collateralAmount");

        // DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(
        //     address(collateralToken)
        // );
        // uint256 totalBalance = position.collateralAmount.rayMul(
        //     reserveData.liquidityIndex.rayDiv(position.liquidityIndex)
        // );

        // console.log(
        //     reserveData.liquidityIndex,
        //     "<<< reserveData.liquidityIndex"
        // );
        // console.log(position.liquidityIndex, "<<< position.liquidityIndex");
        // console.log(
        //     reserveData.liquidityIndex.rayDiv(position.liquidityIndex),
        //     "<<< reserveData.liquidityIndex.rayDiv(position.liquidityIndex)"
        // );

        // console.log(totalBalance, "<<< totalBalance");

        // console.log();

        // return totalBalance - position.collateralAmount;

        // ! ---

        // DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(
        //     address(collateralToken)
        // );
        // uint256 timeElapsed = block.timestamp -
        //     positions[positionId].lastUpdateTimestamp;
        // uint256 currentLiquidityRate = reserveData.currentLiquidityRate;
        // uint256 interest = (positions[positionId].collateralAmount *
        //     currentLiquidityRate *
        //     timeElapsed) / (SECONDS_IN_A_YEAR * RAY);

        // return interest;

        // ! ---

        // Position memory position = positions[positionId];
        // if (position.collateralAmount == 0 || totalDeposited == 0) return 0;

        // uint256 totalBalance = aToken.balanceOf(address(this));
        // uint256 totalInterest = totalBalance > totalDeposited
        //     ? totalBalance - totalDeposited
        //     : 0;
        // uint256 positionShare = (position.collateralAmount * 1e18) /
        //     totalDeposited;

        // return (totalInterest * positionShare) / 1e18;
    }
}
