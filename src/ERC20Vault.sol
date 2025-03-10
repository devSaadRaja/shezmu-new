// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ERC20Vault is ReentrancyGuard, Ownable {
    // State variables
    IERC20 public collateralToken; // ERC20 token used as collateral
    IERC20 public loanToken; // ERC20 token used for loans
    uint256 public ltvRatio; // Loan-to-Value ratio in percentage (e.g., 50 for 50%)
    uint256 public constant PRECISION = 1e18; // For precise calculations

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
        uint256 _ltvRatio
    ) Ownable(msg.sender) {
        require(
            _collateralToken != address(0),
            "Invalid collateral token address"
        );
        require(_loanToken != address(0), "Invalid loan token address");
        require(
            _ltvRatio > 0 && _ltvRatio <= 100,
            "LTV must be between 0 and 100"
        );

        collateralToken = IERC20(_collateralToken);
        loanToken = IERC20(_loanToken);
        ltvRatio = _ltvRatio;
    }

    // Deposit collateral and take a loan
    function depositCollateralAndBorrow(
        uint256 collateralAmount,
        uint256 loanAmount
    ) external nonReentrant {
        require(
            collateralAmount > 0,
            "Collateral amount must be greater than 0"
        );
        require(loanAmount > 0, "Loan amount must be greater than 0");

        // Calculate maximum loan amount based on collateral and LTV
        uint256 maxLoanAmount = (collateralAmount * ltvRatio * PRECISION) /
            (100 * PRECISION);
        require(loanAmount <= maxLoanAmount, "Loan amount exceeds LTV limit");

        // Transfer collateral from user to vault
        require(
            collateralToken.transferFrom(
                msg.sender,
                address(this),
                collateralAmount
            ),
            "Collateral transfer failed"
        );

        // Update user balances
        collateralBalances[msg.sender] += collateralAmount;
        loanBalances[msg.sender] += loanAmount;

        // Transfer loan tokens to user
        require(
            loanToken.transfer(msg.sender, loanAmount),
            "Loan transfer failed"
        );

        emit DepositedCollateral(msg.sender, collateralAmount);
        emit LoanTaken(msg.sender, collateralAmount, loanAmount);
    }

    // Remove collateral (only if loan conditions are still met)
    function removeCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(
            collateralBalances[msg.sender] >= amount,
            "Insufficient collateral balance"
        );

        uint256 newCollateralBalance = collateralBalances[msg.sender] - amount;
        uint256 currentLoan = loanBalances[msg.sender];

        // Check if remaining collateral supports the current loan
        if (currentLoan > 0) {
            uint256 maxLoanAllowed = (newCollateralBalance *
                ltvRatio *
                PRECISION) / (100 * PRECISION);
            require(
                maxLoanAllowed >= currentLoan,
                "Insufficient collateral after withdrawal"
            );
        }

        // Update balance and transfer collateral back
        collateralBalances[msg.sender] = newCollateralBalance;

        require(
            collateralToken.transfer(msg.sender, amount),
            "Collateral withdrawal failed"
        );

        emit WithdrawnCollateral(msg.sender, amount);
    }

    // Repay loan (optional function for completeness)
    function repayLoan(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(
            loanBalances[msg.sender] >= amount,
            "Amount exceeds loan balance"
        );

        // Transfer loan tokens from user to vault
        require(
            loanToken.transferFrom(msg.sender, address(this), amount),
            "Repayment transfer failed"
        );

        // Update loan balance
        loanBalances[msg.sender] -= amount;

        emit LoanRepaid(msg.sender, amount);
    }

    // View function to check maximum borrowable amount
    function getMaxBorrowable(address user) public view returns (uint256) {
        return
            (collateralBalances[user] * ltvRatio * PRECISION) /
            (100 * PRECISION);
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
