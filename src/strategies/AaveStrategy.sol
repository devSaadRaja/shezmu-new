// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IPool} from "../interfaces/aave-v3/IPool.sol";
import {IRewardsController} from "../interfaces/aave-v3/IRewardsController.sol";

/// @title AaveStrategy
/// @notice Strategy contract for depositing collateral into Aave and managing rewards for a vault.
/// @dev Only the vault can deposit/withdraw. Owner can claim rewards and manage protocol addresses.
contract AaveStrategy is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    address public vault;
    address public treasury;
    IERC20 public collateralToken;
    IERC20 public aToken;
    IERC20 public rewardToken;
    IPool public pool;
    IRewardsController public rewardsController;

    uint256 public totalCollateral;
    mapping(uint256 => uint256) public amounts; // collateral amounts per position

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

    event PoolUpdated(address indexed newProxy);
    event RewardsControllerUpdated(address indexed newController);
    event Deposit(uint256 indexed positionId, uint256 amount);
    event RewardClaimed(uint256 amount);
    event Withdraw(uint256 indexed positionId, uint256 amount);
    event Withdrawal(address indexed token, uint256 amount);
    event InterestCollected(uint256 amount);
    event SetUserUseReserveAsCollateral(address collateralToken, bool val);
    event SetVault(address vault);

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error InvalidAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error Unauthorized();
    error NoPositionBalance();
    error ZeroReward();

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

    // ======================================================== //
    // ================== EXTERNAL FUNCTIONS ================== //
    // ======================================================== //

    /// @notice Deposits collateral into the vault and forwards it to the specified protocol
    /// @param positionId Unique identifier for the position
    /// @param amount Amount of collateral to deposit
    function deposit(
        uint256 positionId,
        uint256 amount
    ) external nonReentrant onlyVault {
        if (amount == 0) revert ZeroAmount();

        totalCollateral += amount;
        amounts[positionId] += amount;

        collateralToken.transferFrom(msg.sender, address(this), amount);

        collateralToken.approve(address(pool), amount);
        pool.supply(address(collateralToken), amount, address(this), 0);

        emit Deposit(positionId, amount);
    }

    /// @notice Withdraws collateral from a position
    /// @param positionId Unique identifier for the position
    function withdraw(
        uint256 positionId,
        uint256 amount
    ) external nonReentrant onlyVault {
        if (amount == 0) revert ZeroAmount();
        if (amounts[positionId] == 0) revert InsufficientBalance();
        if (amount > amounts[positionId]) revert InsufficientBalance();

        totalCollateral -= amount;
        amounts[positionId] -= amount;

        pool.withdraw(address(collateralToken), amount, address(this));
        collateralToken.transfer(msg.sender, amount);

        emit Withdraw(positionId, amount);
    }

    /// @notice Claims all interest accrued and redeposit collateral to aave
    function claimAndRedeposit() external onlyOwner {
        uint256 amountWithdrawn = pool.withdraw(
            address(collateralToken),
            type(uint256).max,
            address(this)
        );

        collateralToken.approve(address(pool), totalCollateral);
        pool.supply(
            address(collateralToken),
            totalCollateral,
            address(this),
            0
        );

        emit InterestCollected(amountWithdrawn - totalCollateral);
    }

    /// @notice Withdraws an ERC20 token from this contract
    /// @param token Address of the ERC20 token to withdraw
    /// @param amount Amount of the token to withdraw
    function withdrawToken(
        address token,
        uint256 amount
    ) external onlyOwner onlyValidAddress(token) {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).transfer(treasury, amount);

        emit Withdrawal(token, amount);
    }

    /// @notice Claims accumulated reward
    function claimReward() external nonReentrant onlyOwner {
        uint256 totalReward = this.getUserRewards();
        if (totalReward == 0) revert ZeroReward();

        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        rewardsController.claimRewards(
            assets,
            type(uint256).max,
            address(this),
            address(rewardToken)
        );

        emit RewardClaimed(totalReward);
    }

    /// @notice Sets the vault address
    /// @param _vault Address of Vault contract
    function setVault(
        address _vault
    ) external onlyOwner onlyValidAddress(_vault) {
        vault = _vault;
        emit SetVault(_vault);
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

    /// @dev should call once after first collateral deposit
    /// @notice Sets no use for reserves as collateral
    function setUserUseReserveAsCollateral() external onlyOwner {
        pool.setUserUseReserveAsCollateral(address(collateralToken), false);
        emit SetUserUseReserveAsCollateral(address(collateralToken), false);
    }

    // ====================================================== //
    // ================== PUBLIC FUNCTIONS ================== //
    // ====================================================== //

    /// @notice Retrieves the accumulated rewards
    /// @return uint256 Amount of accumulated rewards
    function getAccumulatedRewards() public view returns (uint256) {
        return (
            rewardsController.getUserAccruedRewards(
                address(this),
                address(rewardToken)
            )
        );
    }

    /// @notice Gets the current rewards balance
    /// @return uint256 Amount of current rewards
    function getUserRewards() public view returns (uint256) {
        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        return (
            rewardsController.getUserRewards(
                assets,
                address(this),
                address(rewardToken)
            )
        );
    }
}
