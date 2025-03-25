// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IVault {
    function collectInterest(
        uint256 positionId,
        uint256 interestAmount
    ) external;
}
