// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract MockPriceFeed {
    int256 public price;
    uint8 public decimalsVal;
    uint256 public lastUpdate;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimalsVal = _decimals;
        lastUpdate = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, price, 0, lastUpdate, 0);
    }

    function decimals() external view returns (uint8) {
        return decimalsVal;
    }

    function setPrice(int256 _price) external {
        price = _price;
        lastUpdate = block.timestamp;
    }
}
