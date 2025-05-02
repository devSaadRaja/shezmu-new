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

    struct YieldData {
        uint256 amount; // Collateral amount deposited
        uint256 accumulatedYield; // Yield accrued
    }

    mapping(uint256 => YieldData) public yields; // Tracks yield data per position

    uint256 public constant BORROWER_YIELD_SHARE = 7500; // 75% yield to borrower (bips)
    uint256 public constant PROTOCOL_YIELD_SHARE = 2500; // 25% yield to protocol (bips)
    uint256 public constant DENOMINATOR = 10000; // For percentage calculations (bips)

    address public vault;
    address public treasury;
    IERC20 public collateralToken;
    IERC20 public rewardToken;
    IPool public pool;
    IRewardsController public rewardsController;

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

    event Deposit(uint256 indexed positionId, uint256 amount);
    event YieldClaimed(
        uint256 indexed positionId,
        uint256 borrowerAmount,
        uint256 protocolAmount
    );
    event Withdraw(uint256 indexed positionId);
    event PoolUpdated(address indexed newProxy);
    event RewardsControllerUpdated(address indexed newController);

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error Unauthorized();

    // =============================================== //
    // ================== MODIFIERS ================== //
    // =============================================== //

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    // modifier onlyWhitelisted(address protocol) {
    //     if (!whitelistedProtocols[protocol]) revert ProtocolNotWhitelisted();
    //     _;
    // }

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
        address _rewardToken,
        address _pool,
        address _rewardController
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        treasury = _treasury;
        collateralToken = IERC20(_collateralToken);
        rewardToken = IERC20(_rewardToken);
        pool = IPool(_pool);
        rewardsController = IRewardsController(_rewardController);
    }

    // ==================================================== //
    // ================== VIEW FUNCTIONS ================== //
    // ==================================================== //

    // // Get current yield for a position
    // function getCurrentYield(
    //     uint256 positionId
    // ) external view returns (uint256) {
    //     YieldData storage yieldData = yields[positionId];
    //     address protocol = positionProtocols[positionId];
    //     if (yieldData.amount == 0 || protocol == address(0)) {
    //         return 0;
    //     }
    //     return
    //         pool.getProtocolYield(protocol) - yieldData.accumulatedYield;
    // }

    // ===================================================== //
    // ================== WRITE FUNCTIONS ================== //
    // ===================================================== //

    /// @notice Deposits collateral into the vault and forwards it to the specified yield protocol
    /// @param positionId Unique identifier for the position
    /// @param amount Amount of collateral to deposit
    function deposit(
        uint256 positionId,
        uint256 amount
    ) external nonReentrant onlyVault {
        require(amount > 0, "Amount must be greater than 0");
        require(yields[positionId].amount == 0, "Position already active");

        collateralToken.transferFrom(msg.sender, address(this), amount);

        yields[positionId] = YieldData({amount: amount, accumulatedYield: 0});

        collateralToken.approve(address(pool), amount);
        pool.supply(address(collateralToken), amount, address(this), 0);

        emit Deposit(positionId, amount);
    }

    /// @notice Claims accumulated yield for a position and splits it between borrower and protocol
    /// @param positionId Unique identifier for the position
    /// @dev Splits yield according to BORROWER_YIELD_SHARE and PROTOCOL_YIELD_SHARE
    function claimYield(uint256 positionId) external nonReentrant onlyVault {
        YieldData storage yieldData = yields[positionId];
        require(yieldData.amount > 0, "No active position");

        uint256 totalYield = rewardsController.getUserAccruedRewards(
            msg.sender,
            address(rewardToken)
        ) - yieldData.accumulatedYield;
        require(totalYield > 0, "No yield to claim");

        uint256 borrowerYield = (totalYield * BORROWER_YIELD_SHARE) /
            DENOMINATOR;
        uint256 protocolYield = (totalYield * PROTOCOL_YIELD_SHARE) /
            DENOMINATOR;

        yieldData.accumulatedYield += totalYield;

        address[] memory assets = new address[](1);
        assets[0] = address(rewardToken); // Or the aToken if required
        rewardsController.claimRewards(
            assets,
            type(uint256).max,
            address(this),
            address(rewardToken)
        );

        rewardToken.transfer(msg.sender, borrowerYield);
        rewardToken.transfer(owner(), protocolYield);

        emit YieldClaimed(positionId, borrowerYield, protocolYield);
    }

    /// @notice Withdraws collateral from a position
    /// @param positionId Unique identifier for the position
    /// @dev Deletes position data
    function withdraw(uint256 positionId) external nonReentrant onlyVault {
        // // Update yield before withdrawal
        // uint256 totalYield = pool.getProtocolYield(protocol) -
        //     yieldData.accumulatedYield;
        // yieldData.accumulatedYield += totalYield;

        uint256 withdrawnAmount = pool.withdraw(
            address(collateralToken),
            type(uint256).max,
            msg.sender
        );

        delete yields[positionId];

        emit Withdraw(positionId);
    }

    // ===================================================== //
    // ================== OWNER FUNCTIONS ================== //
    // ===================================================== //

    /// @notice Sets the vault address
    /// @param _vault Address of Vault contract
    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    /// @notice Updates the yield proxy contract address
    /// @param newProxy Address of the new yield proxy contract
    function updateYieldProxy(address newProxy) external onlyOwner {
        require(newProxy != address(0), "Invalid address");
        pool = IPool(newProxy);
        emit PoolUpdated(newProxy);
    }

    /// @notice Updates the reward controller contract address
    /// @param newController Address of the new reward controller contract
    function updateRewardsController(address newController) external onlyOwner {
        require(newController != address(0), "Invalid address");
        rewardsController = IRewardsController(newController);
        emit RewardsControllerUpdated(newController);
    }
}
