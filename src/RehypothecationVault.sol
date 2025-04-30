// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

interface IPoolProxy {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

interface IRewardsController {
    function claimRewards(
        address[] calldata assets,
        uint256 amount,
        address to,
        address reward
    ) external returns (uint256);

    function getUserAccruedRewards(
        address user,
        address reward
    ) external returns (uint256);
}

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
    mapping(address => bool) public whitelistedProtocols; // Whitelist of low-risk protocols
    mapping(uint256 => address) public positionProtocols; // Maps position to its yield protocol

    uint256 public constant BORROWER_YIELD_SHARE = 7500; // 75% yield to borrower (bips)
    uint256 public constant PROTOCOL_YIELD_SHARE = 2500; // 25% yield to protocol (bips)
    uint256 public constant DENOMINATOR = 10000; // For percentage calculations (bips)

    address public vault;
    address public treasury;
    IERC20 public collateralToken;
    IERC20 public rewardToken;
    IPoolProxy public poolProxy;
    IRewardsController public rewardsController;

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

    event DepositedToVault(
        uint256 indexed positionId,
        uint256 amount,
        address protocol
    );
    event YieldClaimed(
        uint256 indexed positionId,
        uint256 borrowerAmount,
        uint256 protocolAmount
    );
    event WithdrawnFromVault(uint256 indexed positionId, uint256 amount);
    event ProtocolWhitelisted(address indexed protocol, bool status);
    event YieldProxyUpdated(address indexed newProxy);

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error Unauthorized();
    error ProtocolNotWhitelisted();

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
    /// @param _yieldProxy Address of the yield proxy contract
    /// @param _rewardController Address of the reward controller contract
    function initialize(
        address _treasury,
        address _collateralToken,
        address _rewardToken,
        address _yieldProxy,
        address _rewardController
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        treasury = _treasury;
        collateralToken = IERC20(_collateralToken);
        rewardToken = IERC20(_rewardToken);
        poolProxy = IPoolProxy(_yieldProxy);
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
    //         poolProxy.getProtocolYield(protocol) - yieldData.accumulatedYield;
    // }

    // ===================================================== //
    // ================== WRITE FUNCTIONS ================== //
    // ===================================================== //

    /// @notice Deposits collateral into the vault and forwards it to the specified yield protocol
    /// @param positionId Unique identifier for the position
    /// @param amount Amount of collateral to deposit
    /// @param protocol Address of the whitelisted yield protocol
    function deposit(
        uint256 positionId,
        uint256 amount,
        address protocol
    ) external nonReentrant onlyVault {
        // onlyWhitelisted(protocol)
        require(amount > 0, "Amount must be greater than 0");
        require(yields[positionId].amount == 0, "Position already active");

        yields[positionId] = YieldData({amount: amount, accumulatedYield: 0});
        positionProtocols[positionId] = protocol;

        // Forward collateral to yield protocol
        poolProxy.supply(address(collateralToken), amount, address(this), 0);

        emit DepositedToVault(positionId, amount, protocol);
    }

    /// @notice Claims accumulated yield for a position and splits it between borrower and protocol
    /// @param positionId Unique identifier for the position
    /// @dev Splits yield according to BORROWER_YIELD_SHARE and PROTOCOL_YIELD_SHARE
    function claimYield(uint256 positionId) external nonReentrant onlyVault {
        YieldData storage yieldData = yields[positionId];
        require(yieldData.amount > 0, "No active position");

        address protocol = positionProtocols[positionId];
        require(protocol != address(0), "Invalid protocol");

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
    /// @param amount Amount of collateral to withdraw
    /// @dev Deletes position data if amount withdrawn equals total position amount
    function withdraw(
        uint256 positionId,
        uint256 amount
    ) external nonReentrant onlyVault {
        YieldData storage yieldData = yields[positionId];
        require(yieldData.amount >= amount, "Insufficient collateral");
        require(amount > 0, "Amount must be greater than 0");

        address protocol = positionProtocols[positionId];
        require(protocol != address(0), "Invalid protocol");

        // // Update yield before withdrawal
        // uint256 totalYield = poolProxy.getProtocolYield(protocol) -
        //     yieldData.accumulatedYield;
        // yieldData.accumulatedYield += totalYield;

        // Withdraw collateral via proxy
        uint256 withdrawnAmount = poolProxy.withdraw(
            address(collateralToken),
            amount, // type(uint256).max
            msg.sender
        );
        require(withdrawnAmount == amount, "Withdrawal amount mismatch");

        // Update position
        yieldData.amount -= amount;
        if (yieldData.amount == 0) {
            delete yields[positionId];
            delete positionProtocols[positionId];
        }

        emit WithdrawnFromVault(positionId, amount);
    }

    // ===================================================== //
    // ================== OWNER FUNCTIONS ================== //
    // ===================================================== //

    /// @notice Sets the vault address
    /// @param _vault Address of Vault contract
    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    /// @notice Updates the whitelist status of a yield protocol
    /// @param protocol Address of the protocol to whitelist/blacklist
    /// @param status Boolean indicating whether the protocol should be whitelisted
    function setProtocolWhitelist(
        address protocol,
        bool status
    ) external onlyOwner {
        whitelistedProtocols[protocol] = status;
        emit ProtocolWhitelisted(protocol, status);
    }

    /// @notice Updates the yield proxy contract address
    /// @param newProxy Address of the new yield proxy contract
    function updateYieldProxy(address newProxy) external onlyOwner {
        require(newProxy != address(0), "Invalid proxy address");
        poolProxy = IPoolProxy(newProxy);
        emit YieldProxyUpdated(newProxy);
    }
}
