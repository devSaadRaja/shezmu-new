// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC20Vault {
    // ============ Structs ============ //
    struct Position {
        address owner;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 lastInterestCollectionBlock;
    }

    // ============ State Variables ============ //

    function collateralToken() external view returns (address);

    function loanToken() external view returns (address);

    function ltvRatio() external view returns (uint256);

    function liquidationThreshold() external view returns (uint256);

    function liquidatorReward() external view returns (uint256);

    function penaltyRate() external view returns (uint256);

    function PRECISION() external pure returns (uint256);

    function collateralPriceFeed() external view returns (address);

    function loanPriceFeed() external view returns (address);

    function nextPositionId() external view returns (uint256);

    function totalDebt() external view returns (uint256);

    function interestCollectionEnabled() external view returns (bool);

    function interestCollector() external view returns (address);

    function treasury() external view returns (address);

    // ============ Read Functions ============ //

    function getPosition(
        uint256 positionId
    )
        external
        view
        returns (
            address owner,
            uint256 collateralAmount,
            uint256 debtAmount,
            uint256 lastInterestCollectionBlock
        );

    function getCollateralBalance(address user) external view returns (uint256);

    function getLoanBalance(address user) external view returns (uint256);

    function getPositionHealth(
        uint256 positionId
    ) external view returns (uint256);

    function getMaxBorrowable(
        uint256 positionId
    ) external view returns (uint256);

    function getTotalMaxBorrowable(
        address user
    ) external view returns (uint256);

    function getUserPositionIds(
        address user
    ) external view returns (uint256[] memory);

    function getCollateralValue(
        uint256 collateralAmount
    ) external view returns (uint256);

    function getLoanValue(uint256 loanAmount) external view returns (uint256);

    function isLiquidatable(uint256 positionId) external view returns (bool);

    // ============ Write Functions ============ //

    function openPosition(
        address owner,
        address collateral,
        uint256 collateralAmount,
        uint256 debtAmount
    ) external;

    function addCollateral(uint256 positionId, uint256 amount) external;

    function repayDebt(uint256 positionId, uint256 debtAmount) external;

    function borrow(uint256 positionId, uint256 amount) external;

    function borrowFor(
        uint256 positionId,
        address onBehalfOf,
        uint256 amount
    ) external;

    function withdrawCollateral(uint256 positionId, uint256 amount) external;

    function liquidatePosition(uint256 positionId) external;

    function collectInterest(
        uint256 positionId,
        uint256 interestAmount
    ) external;

    // ============ Owner Functions ============ //

    function updatePriceFeeds(
        address _collateralFeed,
        address _loanFeed
    ) external;

    function updateLtvRatio(uint256 newLtvRatio) external;

    function emergencyWithdraw(address token, uint256 amount) external;

    function setInterestCollector(address _interestCollector) external;

    function toggleInterestCollection(bool _enabled) external;
}
