// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IStrategy {
    function deposit(uint256 positionId, uint256 amount) external;

    function withdraw(uint256 positionId, uint256 amount) external;
}
