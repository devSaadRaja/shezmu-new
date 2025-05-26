// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IInterestCollector {
    function collectInterest(
        address vault,
        address token,
        uint256 positionId,
        uint256 debtAmount
    ) external returns (uint256);

    function calculateInterestDue(
        address vault,
        uint256 positionId,
        uint256 debtAmount
    ) external view returns (uint256);

    function isCollectionReady(
        address vault,
        uint256 positionId
    ) external view returns (bool);

    function setLastCollectionBlock(address vault, uint256 positionId) external;

    function getVaultInterestRate(
        address vault
    ) external view returns (uint256);
}
