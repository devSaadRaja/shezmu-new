// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

contract ERC20Vault is ReentrancyGuard, Ownable {
    // State variables
    IERC20 public collateralToken; // ERC20 token used as collateral
    IERC20 public loanToken; // ERC20 token used for loans
    uint256 public ltvRatio; // Loan-to-Value ratio in percentage (e.g., 50 for 50%)
    uint256 public constant PRECISION = 1e18; // For precise calculations

    // Price feed oracles
    IPriceFeed public collateralPriceFeed;
    IPriceFeed public loanPriceFeed;

    // User balances and loans
    mapping(address => uint256) public collateralBalances;
    mapping(address => uint256) public loanBalances;

    // Events
    event DepositedCollateral(address indexed user, uint256 amount);
    event WithdrawnCollateral(address indexed user, uint256 amount);
    event LoanTaken(
        address indexed user,
        uint256 collateralAmount,
        uint256 loanAmount
    );
    event LoanRepaid(address indexed user, uint256 amount);

    constructor(
        address _collateralToken,
        address _loanToken,
        uint256 _ltvRatio,
        address _collateralPriceFeed,
        address _loanPriceFeed
    ) Ownable(msg.sender) {
        require(_collateralToken != address(0), "Invalid collateral token");
        require(_loanToken != address(0), "Invalid loan token");
        require(_ltvRatio > 0 && _ltvRatio <= 100, "Invalid LTV ratio");
        require(
            _collateralPriceFeed != address(0),
            "Invalid collateral price feed"
        );
        require(_loanPriceFeed != address(0), "Invalid loan price feed");

        collateralToken = IERC20(_collateralToken);
        loanToken = IERC20(_loanToken);
        ltvRatio = _ltvRatio;
        collateralPriceFeed = IPriceFeed(_collateralPriceFeed);
        loanPriceFeed = IPriceFeed(_loanPriceFeed);
    }

    function getPrice(IPriceFeed priceFeed) internal view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        require(updatedAt > block.timestamp - 1 hours, "Price too old");
        return uint256(price) * 10 ** (18 - priceFeed.decimals());
    }

    function getCollateralValue(
        uint256 collateralAmount
    ) public view returns (uint256) {
        uint256 collateralPrice = getPrice(collateralPriceFeed);
        return (collateralAmount * collateralPrice) / PRECISION;
    }

    function getLoanValue(uint256 loanAmount) public view returns (uint256) {
        uint256 loanPrice = getPrice(loanPriceFeed);
        return (loanAmount * loanPrice) / PRECISION;
    }

    function depositCollateralAndBorrow(
        uint256 collateralAmount,
        uint256 loanAmount
    ) external nonReentrant {
        require(
            collateralAmount > 0,
            "Collateral amount must be greater than 0"
        );
        require(loanAmount > 0, "Loan amount must be greater than 0");

        uint256 collateralValue = getCollateralValue(collateralAmount);
        uint256 loanValue = getLoanValue(loanAmount);
        uint256 maxLoanValue = (collateralValue * ltvRatio) / 100;

        require(loanValue <= maxLoanValue, "Loan amount exceeds LTV limit");

        require(
            collateralToken.transferFrom(
                msg.sender,
                address(this),
                collateralAmount
            ),
            "Collateral transfer failed"
        );

        collateralBalances[msg.sender] += collateralAmount;
        loanBalances[msg.sender] += loanAmount;

        require(
            loanToken.transfer(msg.sender, loanAmount),
            "Loan transfer failed"
        );

        emit DepositedCollateral(msg.sender, collateralAmount);
        emit LoanTaken(msg.sender, collateralAmount, loanAmount);
    }

    function removeCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(
            collateralBalances[msg.sender] >= amount,
            "Insufficient collateral"
        );

        uint256 newCollateralBalance = collateralBalances[msg.sender] - amount;
        uint256 currentLoan = loanBalances[msg.sender];

        if (currentLoan > 0) {
            uint256 remainingCollateralValue = getCollateralValue(
                newCollateralBalance
            );
            uint256 loanValue = getLoanValue(currentLoan);
            uint256 minCollateralValue = (loanValue * 100) / ltvRatio;
            require(
                remainingCollateralValue >= minCollateralValue,
                "Insufficient collateral after withdrawal"
            );
        }

        collateralBalances[msg.sender] = newCollateralBalance;

        require(
            collateralToken.transfer(msg.sender, amount),
            "Collateral withdrawal failed"
        );

        emit WithdrawnCollateral(msg.sender, amount);
    }

    function repayLoan(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(loanBalances[msg.sender] >= amount, "Amount exceeds loan");

        require(
            loanToken.transferFrom(msg.sender, address(this), amount),
            "Repayment failed"
        );

        loanBalances[msg.sender] -= amount;

        emit LoanRepaid(msg.sender, amount);
    }

    function getMaxBorrowable(address user) public view returns (uint256) {
        uint256 collateralValue = getCollateralValue(collateralBalances[user]);
        uint256 maxLoanValue = (collateralValue * ltvRatio) / 100;
        uint256 loanPrice = getPrice(loanPriceFeed);
        return (maxLoanValue * PRECISION) / loanPrice;
    }

    // Owner functions
    function updatePriceFeeds(
        address _collateralFeed,
        address _loanFeed
    ) external onlyOwner {
        require(_collateralFeed != address(0), "Invalid collateral feed");
        require(_loanFeed != address(0), "Invalid loan feed");
        collateralPriceFeed = IPriceFeed(_collateralFeed);
        loanPriceFeed = IPriceFeed(_loanFeed);
    }

    // Emergency functions for owner
    function updateLtvRatio(uint256 newLtvRatio) external onlyOwner {
        require(
            newLtvRatio > 0 && newLtvRatio <= 100,
            "LTV must be between 0 and 100"
        );
        ltvRatio = newLtvRatio;
    }

    // Emergency withdrawal of tokens (owner only)
    function emergencyWithdraw(
        address token,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).transfer(msg.sender, amount);
    }
}
