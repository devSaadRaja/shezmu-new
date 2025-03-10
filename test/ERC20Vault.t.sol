// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "../src/ERC20Vault.sol";
import "../src/mock/MockERC20.sol";

contract ERC20VaultTest is Test {
    ERC20Vault vault;
    MockERC20 collateralToken;
    MockERC20 loanToken;

    address deployer = vm.addr(1);
    address user1 = vm.addr(2);
    address user2 = vm.addr(3);

    uint256 constant INITIAL_LTV = 50; // 50% LTV

    function setUp() public {
        vm.startPrank(deployer);

        // Deploy mock tokens
        collateralToken = new MockERC20("Collateral Token", "COL");
        loanToken = new MockERC20("Loan Token", "LOAN");

        // Deploy vault
        vault = new ERC20Vault(
            address(collateralToken),
            address(loanToken),
            INITIAL_LTV
        );

        // Transfer some tokens to users
        collateralToken.transfer(user1, 2_000_000 ether);
        collateralToken.transfer(user2, 2_000_000 ether);

        // Transfer loan tokens to vault
        loanToken.transfer(address(vault), 2_000_000 ether);

        vm.stopPrank();
    }

    function test_InitialDeployment() public view {
        assertEq(address(vault.collateralToken()), address(collateralToken));
        assertEq(address(vault.loanToken()), address(loanToken));
        assertEq(vault.ltvRatio(), INITIAL_LTV);
    }

    function test_DepositAndBorrow() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 loanAmount = 500 ether; // 50% of collateral

        // Approve vault to spend collateral
        collateralToken.approve(address(vault), collateralAmount);

        // Deposit and borrow
        vault.depositCollateralAndBorrow(collateralAmount, loanAmount);

        // Check balances
        assertEq(vault.collateralBalances(user1), collateralAmount);
        assertEq(vault.loanBalances(user1), loanAmount);
        assertEq(collateralToken.balanceOf(address(vault)), collateralAmount);
        assertEq(loanToken.balanceOf(user1), loanAmount);

        vm.stopPrank();
    }

    function test_BorrowExceedsLTV() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 loanAmount = 600 ether; // Exceeds 50% LTV

        collateralToken.approve(address(vault), collateralAmount);

        vm.expectRevert("Loan amount exceeds LTV limit");
        vault.depositCollateralAndBorrow(collateralAmount, loanAmount);

        vm.stopPrank();
    }

    function test_RemoveCollateralSuccess() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 loanAmount = 400 ether;
        uint256 withdrawAmount = 200 ether;

        collateralToken.approve(address(vault), collateralAmount);
        vault.depositCollateralAndBorrow(collateralAmount, loanAmount);

        vault.removeCollateral(withdrawAmount);

        assertEq(
            vault.collateralBalances(user1),
            collateralAmount - withdrawAmount
        );
        assertEq(
            collateralToken.balanceOf(user1),
            2_000_000 ether - collateralAmount + withdrawAmount
        );

        vm.stopPrank();
    }

    function test_RemoveCollateralFailInsufficient() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 loanAmount = 500 ether; // Max LTV

        collateralToken.approve(address(vault), collateralAmount);
        vault.depositCollateralAndBorrow(collateralAmount, loanAmount);

        vm.expectRevert("Insufficient collateral after withdrawal");
        vault.removeCollateral(200 ether);

        vm.stopPrank();
    }

    function test_RepayLoan() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 loanAmount = 500 ether;
        uint256 repayAmount = 300 ether;

        collateralToken.approve(address(vault), collateralAmount);
        vault.depositCollateralAndBorrow(collateralAmount, loanAmount);

        loanToken.approve(address(vault), repayAmount);
        vault.repayLoan(repayAmount);

        assertEq(vault.loanBalances(user1), loanAmount - repayAmount);
        assertEq(
            loanToken.balanceOf(address(vault)),
            2_000_000 ether - loanAmount + repayAmount
        );

        vm.stopPrank();
    }

    function test_GetMaxBorrowable() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        collateralToken.approve(address(vault), collateralAmount);
        vault.depositCollateralAndBorrow(collateralAmount, 100 ether);

        uint256 maxBorrowable = vault.getMaxBorrowable(user1);
        assertEq(maxBorrowable, 500 ether); // 50% of 1000

        vm.stopPrank();
    }

    function test_UpdateLtvRatio() public {
        vm.prank(vault.owner());
        vault.updateLtvRatio(75);
        assertEq(vault.ltvRatio(), 75);

        vm.prank(user1);
        vm.expectRevert();
        vault.updateLtvRatio(60);
    }

    function test_EmergencyWithdraw() public {
        uint256 amount = 1000 ether;

        vm.prank(vault.owner());
        vault.emergencyWithdraw(address(loanToken), amount);

        assertEq(
            loanToken.balanceOf(vault.owner()),
            1_000_000_000 ether - 2_000_000 ether + amount
        );

        vm.prank(user1);
        vm.expectRevert();
        vault.emergencyWithdraw(address(loanToken), amount);
    }

    // Edge cases with very small/large amounts
    function test_VerySmallAmount() public {
        vm.startPrank(user1);

        uint256 tinyCollateral = 10; // 10 wei
        uint256 tinyLoan = 5;

        collateralToken.approve(address(vault), tinyCollateral);
        vault.depositCollateralAndBorrow(tinyCollateral, tinyLoan);

        assertEq(vault.collateralBalances(user1), tinyCollateral);
        assertEq(vault.loanBalances(user1), tinyLoan);

        vm.stopPrank();
    }

    function test_VeryLargeAmount() public {
        vm.startPrank(user1);

        uint256 largeCollateral = 1000000 ether; // 1M tokens
        collateralToken.transfer(user1, largeCollateral); // Give user more tokens
        uint256 largeLoan = 500000 ether; // 50% LTV

        collateralToken.approve(address(vault), largeCollateral);
        vault.depositCollateralAndBorrow(largeCollateral, largeLoan);

        assertEq(vault.collateralBalances(user1), largeCollateral);
        assertEq(vault.loanBalances(user1), largeLoan);

        vm.stopPrank();
    }

    // Multiple simultaneous users
    function test_MultipleUsers() public {
        uint256 amount1 = 1000 ether;
        uint256 amount2 = 2000 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(vault), amount1);
        vault.depositCollateralAndBorrow(amount1, 500 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        collateralToken.approve(address(vault), amount2);
        vault.depositCollateralAndBorrow(amount2, 1000 ether);
        vm.stopPrank();

        assertEq(vault.collateralBalances(user1), amount1);
        assertEq(vault.loanBalances(user1), 500 ether);
        assertEq(vault.collateralBalances(user2), amount2);
        assertEq(vault.loanBalances(user2), 1000 ether);
    }

    // Zero amount edge cases
    function test_ZeroCollateralAmount() public {
        vm.startPrank(user1);

        collateralToken.approve(address(vault), 1000 ether);
        vm.expectRevert("Collateral amount must be greater than 0");
        vault.depositCollateralAndBorrow(0, 500 ether);

        vm.stopPrank();
    }

    function test_ZeroLoanAmount() public {
        vm.startPrank(user1);

        collateralToken.approve(address(vault), 1000 ether);
        vm.expectRevert("Loan amount must be greater than 0");
        vault.depositCollateralAndBorrow(1000 ether, 0);

        vm.stopPrank();
    }

    function test_ZeroWithdrawAmount() public {
        vm.startPrank(user1);

        collateralToken.approve(address(vault), 1000 ether);
        vault.depositCollateralAndBorrow(1000 ether, 500 ether);

        vm.expectRevert("Amount must be greater than 0");
        vault.removeCollateral(0);

        vm.stopPrank();
    }

    // Token transfer failures
    function test_CollateralTransferFailure() public {
        vm.startPrank(user1);

        // Don't approve tokens, causing transfer to fail
        vm.expectRevert(); // "ERC20: insufficient allowance"
        vault.depositCollateralAndBorrow(1000 ether, 500 ether);

        vm.stopPrank();
    }

    function test_LoanTransferFailure() public {
        // First, as owner, empty vault's loan token balance
        vm.startPrank(vault.owner());
        vault.emergencyWithdraw(
            address(loanToken),
            loanToken.balanceOf(address(vault))
        );
        vm.stopPrank();

        // Now test as user1
        vm.startPrank(user1);
        collateralToken.approve(address(vault), 1000 ether);
        vm.expectRevert(); // "ERC20: transfer amount exceeds balance"
        vault.depositCollateralAndBorrow(1000 ether, 500 ether);
        vm.stopPrank();
    }

    function test_RepayTransferFailure() public {
        vm.startPrank(user1);

        collateralToken.approve(address(vault), 1000 ether);
        vault.depositCollateralAndBorrow(1000 ether, 500 ether);

        // Don't approve loan tokens for repayment
        vm.expectRevert(); // "ERC20: insufficient allowance"
        vault.repayLoan(300 ether);

        vm.stopPrank();
    }
}
