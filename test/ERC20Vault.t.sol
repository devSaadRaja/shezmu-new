// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import "../src/ERC20Vault.sol";
import "../src/mock/MockERC20.sol";
import "../src/mock/MockERC20Mintable.sol";
import "../src/mock/MockPriceFeed.sol";

import "../src/interfaces/IPriceFeed.sol";

contract ERC20VaultTest is Test {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    ERC20Vault vault;
    MockERC20 WETH;
    MockERC20Mintable shezUSD;

    // IPriceFeed wethPriceFeed;
    MockPriceFeed wethPriceFeed;
    MockPriceFeed shezUSDPriceFeed;

    address deployer = vm.addr(1);
    address user1 = vm.addr(2);
    address user2 = vm.addr(3);

    uint256 constant INITIAL_LTV = 50;

    // =========================================== //
    // ================== SETUP ================== //
    // =========================================== //

    function setUp() public {
        vm.startPrank(deployer);

        WETH = new MockERC20("Collateral Token", "COL");
        shezUSD = new MockERC20Mintable("Shez USD", "shezUSD");

        // wethPriceFeed = IPriceFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        wethPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8); // $200
        shezUSDPriceFeed = new MockPriceFeed(100 * 10 ** 8, 8); // $100

        vault = new ERC20Vault(
            address(WETH),
            address(shezUSD),
            INITIAL_LTV,
            address(wethPriceFeed),
            address(shezUSDPriceFeed)
        );

        WETH.transfer(user1, 2_000_000 ether);
        WETH.transfer(user2, 2_000_000 ether);

        shezUSD.grantRole(keccak256("MINTER_ROLE"), address(vault));
        shezUSD.grantRole(keccak256("BURNER_ROLE"), address(vault));

        vm.stopPrank();
    }

    // ================================================ //
    // ================== TEST CASES ================== //
    // ================================================ //

    function test_InitialDeployment() public view {
        assertEq(address(vault.collateralToken()), address(WETH));
        assertEq(address(vault.loanToken()), address(shezUSD));
        assertEq(vault.ltvRatio(), INITIAL_LTV);
    }

    function test_OpenPosition() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether; // $200,000 worth
        uint256 debtAmount = 1000 ether; // $100,000 worth (50% LTV)

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);

        assertEq(vault.getCollateralBalance(user1), collateralAmount);
        assertEq(vault.getLoanBalance(user1), debtAmount);
        (, uint256 posCollateral, uint256 posDebt) = vault.getPosition(1);
        assertEq(posCollateral, collateralAmount);
        assertEq(posDebt, debtAmount);
        assertEq(shezUSD.balanceOf(user1), debtAmount);

        vm.stopPrank();
    }

    function test_BorrowExceedsLTV() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether; // $200,000 worth
        uint256 debtAmount = 2000 ether; // $200,000 worth (100% LTV)

        WETH.approve(address(vault), collateralAmount);
        vm.expectRevert(ERC20Vault.LoanExceedsLTVLimit.selector);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);

        vm.stopPrank();
    }

    function test_AddCollateral() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 additionalAmount = 200 ether;

        WETH.approve(address(vault), collateralAmount + additionalAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);
        vault.addCollateral(1, additionalAmount);

        (, uint256 posCollateral, ) = vault.getPosition(1);
        assertEq(posCollateral, collateralAmount + additionalAmount);
        assertEq(
            vault.getCollateralBalance(user1),
            collateralAmount + additionalAmount
        );

        vm.stopPrank();
    }

    function test_WithdrawCollateralSuccess() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 withdrawAmount = 200 ether;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);
        vault.withdrawCollateral(1, withdrawAmount);

        (, uint256 posCollateral, ) = vault.getPosition(1);
        assertEq(posCollateral, collateralAmount - withdrawAmount);
        assertEq(
            WETH.balanceOf(user1),
            2_000_000 ether - collateralAmount + withdrawAmount
        );

        vm.stopPrank();
    }

    function test_WithdrawCollateralFailInsufficient() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 1000 ether; // Max LTV

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);

        vm.expectRevert(
            ERC20Vault.InsufficientCollateralAfterWithdrawal.selector
        );
        vault.withdrawCollateral(1, 200 ether);

        vm.stopPrank();
    }

    function test_RepayDebt() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 1000 ether;
        uint256 repayAmount = 300 ether;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);
        shezUSD.approve(address(vault), repayAmount);
        vault.repayDebt(1, repayAmount);

        (, , uint256 posDebt) = vault.getPosition(1);
        assertEq(posDebt, debtAmount - repayAmount);
        assertEq(vault.getLoanBalance(user1), debtAmount - repayAmount);

        vm.stopPrank();
    }

    function test_GetPositionHealth() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether; // $200,000
        uint256 debtAmount = 1000 ether; // $100,000

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);

        uint256 health = vault.getPositionHealth(1);
        assertEq(health, 2 ether); // 200,000 / 100,000 = 2

        uint256 healthInfinite = vault.getPositionHealth(2);
        assertEq(healthInfinite, type(uint256).max); // ~ / 0 = infinity

        vm.stopPrank();
    }

    function test_GetMaxBorrowable() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, 100 ether);

        uint256 maxBorrowable = vault.getMaxBorrowable(user1);
        assertEq(maxBorrowable, 1000 ether); // $100,000 worth at 50% LTV

        vm.stopPrank();
    }

    function test_MultiplePositions() public {
        vm.startPrank(user1);

        uint256 collateral1 = 1000 ether;
        uint256 debt1 = 500 ether;
        uint256 collateral2 = 500 ether;
        uint256 debt2 = 250 ether;

        WETH.approve(address(vault), collateral1 + collateral2);
        vault.openPosition(address(WETH), collateral1, debt1);
        vault.openPosition(address(WETH), collateral2, debt2);

        (, uint256 posCollateral1, ) = vault.getPosition(1);
        (, uint256 posCollateral2, ) = vault.getPosition(2);
        assertEq(posCollateral1, collateral1);
        assertEq(posCollateral2, collateral2);
        assertEq(vault.getCollateralBalance(user1), collateral1 + collateral2);

        vm.stopPrank();
    }

    function test_VerySmallAmount() public {
        vm.startPrank(user1);

        uint256 tinyCollateral = 10;
        uint256 tinyDebt = 5;

        WETH.approve(address(vault), tinyCollateral);
        vault.openPosition(address(WETH), tinyCollateral, tinyDebt);

        (, uint256 posCollateral, uint256 posDebt) = vault.getPosition(1);
        assertEq(posCollateral, tinyCollateral);
        assertEq(posDebt, tinyDebt);

        vm.stopPrank();
    }

    function test_ZeroAmounts() public {
        vm.startPrank(user1);

        WETH.approve(address(vault), 1000 ether);

        vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
        vault.openPosition(address(WETH), 0, 500 ether);

        vm.expectRevert(ERC20Vault.ZeroLoanAmount.selector);
        vault.openPosition(address(WETH), 1000 ether, 0);

        vault.openPosition(address(WETH), 1000 ether, 500 ether);
        vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
        vault.withdrawCollateral(1, 0);

        vm.stopPrank();
    }

    function test_PriceChangeAffectsHealth() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, 1000 ether);

        wethPriceFeed.setPrice(100 * 10 ** 8); // Drop to $100
        uint256 health = vault.getPositionHealth(1);
        assertEq(health, 1 ether); // 100,000 / 100,000 = 1

        vm.expectRevert(
            ERC20Vault.InsufficientCollateralAfterWithdrawal.selector
        );
        vault.withdrawCollateral(1, 100 ether);

        vm.stopPrank();
    }

    function test_InvalidPrice() public {
        vm.startPrank(user1);

        wethPriceFeed.setPrice(0);
        WETH.approve(address(vault), 1000 ether);
        vm.expectRevert(ERC20Vault.InvalidPrice.selector);
        vault.openPosition(address(WETH), 1000 ether, 500 ether);

        vm.stopPrank();
    }

    function test_MultipleUsersMultiplePositions() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 2000 ether);
        vault.openPosition(address(WETH), 1000 ether, 500 ether);
        vault.openPosition(address(WETH), 500 ether, 250 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        WETH.approve(address(vault), 3000 ether);
        vault.openPosition(address(WETH), 1500 ether, 750 ether);
        vault.openPosition(address(WETH), 750 ether, 375 ether);
        vm.stopPrank();

        (address pos1Owner, , ) = vault.getPosition(1);
        (address pos2Owner, , ) = vault.getPosition(2);
        (address pos3Owner, , ) = vault.getPosition(3);
        (address pos4Owner, , ) = vault.getPosition(4);
        assertEq(pos1Owner, user1);
        assertEq(pos2Owner, user1);
        assertEq(pos3Owner, user2);
        assertEq(pos4Owner, user2);
        assertEq(vault.getCollateralBalance(user1), 1500 ether);
        assertEq(vault.getCollateralBalance(user2), 2250 ether);
    }

    function test_FullDebtRepayment() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);

        shezUSD.approve(address(vault), debtAmount);
        vault.repayDebt(1, debtAmount);

        (, , uint256 posDebt) = vault.getPosition(1);
        assertEq(posDebt, 0);
        assertEq(vault.getLoanBalance(user1), 0);
        assertEq(vault.getPositionHealth(1), type(uint256).max);

        vault.withdrawCollateral(1, collateralAmount);
        (, uint256 posCollateral, ) = vault.getPosition(1);
        assertEq(posCollateral, 0);

        vm.stopPrank();
    }

    function test_UnauthorizedPositionAccess() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(ERC20Vault.NotPositionOwner.selector);
        vault.addCollateral(1, 100 ether);

        vm.expectRevert(ERC20Vault.NotPositionOwner.selector);
        vault.withdrawCollateral(1, 100 ether);

        vm.expectRevert(ERC20Vault.NotPositionOwner.selector);
        vault.repayDebt(1, 100 ether);
        vm.stopPrank();
    }

    function test_InvalidCollateralToken() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);

        vm.expectRevert(ERC20Vault.InvalidCollateralToken.selector);
        vault.openPosition(address(shezUSD), 1000 ether, 500 ether);

        vm.stopPrank();
    }

    function test_PositionHealthEdgeCases() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 2000 ether);

        vault.openPosition(address(WETH), 1000 ether, 1);
        uint256 healthSmallDebt = vault.getPositionHealth(1);
        assertGt(healthSmallDebt, 1000 ether);

        vault.openPosition(address(WETH), 1000 ether, 1000 ether);
        assertEq(vault.getPositionHealth(2), 2 ether);

        vm.stopPrank();
    }

    function test_MaxBorrowableWithMultiplePositions() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1500 ether);

        vault.openPosition(address(WETH), 1000 ether, 500 ether);
        vault.openPosition(address(WETH), 500 ether, 250 ether);

        uint256 maxBorrowable = vault.getMaxBorrowable(user1);
        assertEq(maxBorrowable, 1500 ether);

        vm.stopPrank();
    }

    function test_AddCollateralImprovesHealth() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1200 ether);

        vault.openPosition(address(WETH), 1000 ether, 1000 ether);
        uint256 initialHealth = vault.getPositionHealth(1);
        assertEq(initialHealth, 2 ether);

        vault.addCollateral(1, 200 ether);
        uint256 newHealth = vault.getPositionHealth(1);
        assertEq(newHealth, 2.4 ether);

        vm.stopPrank();
    }

    function test_PriceDropLiquidationThreshold() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(address(WETH), 1000 ether, 1000 ether);

        assertEq(vault.getPositionHealth(1), 2 ether);

        wethPriceFeed.setPrice(150 * 10 ** 8);
        assertEq(vault.getPositionHealth(1), 1.5 ether);

        vm.expectRevert(
            ERC20Vault.InsufficientCollateralAfterWithdrawal.selector
        );
        vault.withdrawCollateral(1, 1 ether);

        vm.stopPrank();
    }

    function test_UserPositionIdsTracking() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 2000 ether);

        vault.openPosition(address(WETH), 1000 ether, 500 ether);
        vault.openPosition(address(WETH), 500 ether, 250 ether);

        uint256[] memory positionIds = vault.getUserPositionIds(user1);
        assertEq(positionIds.length, 2);
        assertEq(positionIds[0], 1);
        assertEq(positionIds[1], 2);

        vm.stopPrank();
    }

    function test_EmergencyWithdraw() public {
        vm.startPrank(deployer);
        uint256 collateralAmount = 1000 ether;

        // Store deployer's balance before the emergency transfer
        uint256 balanceBefore = WETH.balanceOf(deployer);

        // Transfer to vault and withdraw
        WETH.transfer(address(vault), collateralAmount);
        vault.emergencyWithdraw(address(WETH), collateralAmount);

        // Verify exact balance after withdrawal
        assertEq(WETH.balanceOf(deployer), balanceBefore);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert();
        vault.emergencyWithdraw(address(WETH), 1 ether);
        vm.stopPrank();
    }

    function test_UpdatePriceFeeds() public {
        vm.startPrank(deployer);
        MockPriceFeed newWETHPriceFeed = new MockPriceFeed(250 ether, 8);
        MockPriceFeed newShezUSDPriceFeed = new MockPriceFeed(120 ether, 8);
        vault.updatePriceFeeds(
            address(newWETHPriceFeed),
            address(newShezUSDPriceFeed)
        );
        assertEq(
            address(vault.collateralPriceFeed()),
            address(newWETHPriceFeed)
        );
        assertEq(address(vault.loanPriceFeed()), address(newShezUSDPriceFeed));
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert();
        vault.updatePriceFeeds(
            address(newWETHPriceFeed),
            address(newShezUSDPriceFeed)
        );
        vm.stopPrank();
    }

    function test_UpdateLtvRatio() public {
        vm.startPrank(deployer);
        vault.updateLtvRatio(60);
        assertEq(vault.ltvRatio(), 60);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert();
        vault.updateLtvRatio(60);
        vm.stopPrank();
    }

    function test_WithdrawCollateralTransferFail() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);
        vm.mockCall(
            address(WETH),
            abi.encodeWithSelector(WETH.transfer.selector),
            abi.encode(false)
        );
        vm.expectRevert(ERC20Vault.CollateralWithdrawalFailed.selector);
        vault.withdrawCollateral(1, 200 ether);
        vm.stopPrank();
    }

    function test_AddCollateralZeroAmount() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);
        vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
        vault.addCollateral(1, 0);
        vm.stopPrank();
    }

    function test_ConstructorInvalidInputs() public {
        vm.startPrank(deployer);
        vm.expectRevert(ERC20Vault.InvalidCollateralToken.selector);
        new ERC20Vault(
            address(0),
            address(shezUSD),
            INITIAL_LTV,
            address(wethPriceFeed),
            address(shezUSDPriceFeed)
        );

        vm.expectRevert(ERC20Vault.InvalidLoanToken.selector);
        new ERC20Vault(
            address(WETH),
            address(0),
            INITIAL_LTV,
            address(wethPriceFeed),
            address(shezUSDPriceFeed)
        );

        vm.expectRevert(ERC20Vault.InvalidCollateralPriceFeed.selector);
        new ERC20Vault(
            address(WETH),
            address(shezUSD),
            INITIAL_LTV,
            address(0),
            address(shezUSDPriceFeed)
        );

        vm.expectRevert(ERC20Vault.InvalidLoanPriceFeed.selector);
        new ERC20Vault(
            address(WETH),
            address(shezUSD),
            INITIAL_LTV,
            address(wethPriceFeed),
            address(0)
        );
        vm.stopPrank();
    }

    function test_GetCollateralValue() public view {
        uint256 collateralAmount = 1000 ether; // $200,000 at $200 per token
        uint256 collateralValue = vault.getCollateralValue(collateralAmount);
        assertEq(collateralValue, 200_000 ether); // 1000 * 200
    }

    function test_GetLoanValue() public view {
        uint256 loanAmount = 1000 ether; // $100,000 at $100 per token
        uint256 loanValue = vault.getLoanValue(loanAmount);
        assertEq(loanValue, 100_000 ether); // 1000 * 100
    }

    function test_WithdrawCollateralFailInsufficientCollateral() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 withdrawAmount = 2000 ether; // More than deposited

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);
        vm.expectRevert(ERC20Vault.InsufficientCollateral.selector);
        vault.withdrawCollateral(1, withdrawAmount);
        vm.stopPrank();
    }

    function test_RepayDebtBurnFailNoPermission() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 repayAmount = 300 ether;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(address(WETH), collateralAmount, debtAmount);
        vm.stopPrank();

        vm.startPrank(deployer);
        shezUSD.revokeRole(keccak256("BURNER_ROLE"), address(vault));
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(vault),
                keccak256("BURNER_ROLE")
            )
        );
        vault.repayDebt(1, repayAmount);
        vm.stopPrank();
    }

    function test_UpdateLtvRatioInvalid() public {
        vm.startPrank(deployer);
        vm.expectRevert(ERC20Vault.InvalidLTVRatio.selector);
        vault.updateLtvRatio(0);

        vm.expectRevert(ERC20Vault.InvalidLTVRatio.selector);
        vault.updateLtvRatio(101);
        vm.stopPrank();
    }

    function test_EmergencyWithdrawTransferFail() public {
        vm.startPrank(deployer);
        uint256 collateralAmount = 1000 ether;
        WETH.transfer(address(vault), collateralAmount);
        vm.mockCall(
            address(WETH),
            abi.encodeWithSelector(WETH.transfer.selector),
            abi.encode(false)
        );
        vm.expectRevert(ERC20Vault.EmergencyWithdrawFailed.selector);
        vault.emergencyWithdraw(address(WETH), collateralAmount);
        vm.stopPrank();
    }
}
