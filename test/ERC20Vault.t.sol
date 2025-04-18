// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import "../src/ERC20Vault.sol";
import "../src/InterestCollector.sol";
import "../src/mock/MockERC20.sol";
import "../src/mock/MockERC20Mintable.sol";
import "../src/mock/MockPriceFeed.sol";

import "../src/interfaces/IPriceFeed.sol";

contract ERC20VaultTest is Test {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    ERC20Vault vault;
    IERC20 WETH;
    // MockERC20 WETH;
    MockERC20Mintable shezUSD;

    // IPriceFeed wethPriceFeed;
    MockPriceFeed wethPriceFeed;
    MockPriceFeed shezUSDPriceFeed;

    address deployer = vm.addr(1);
    address user1 = vm.addr(2);
    address user2 = vm.addr(3);
    address user3 = vm.addr(4);
    address treasury = vm.addr(5);

    InterestCollector interestCollector;

    uint256 constant INITIAL_LTV = 70;
    uint256 constant LIQUIDATION_THRESHOLD = 90; // 90% of LTV
    uint256 constant LIQUIDATOR_REWARD = 50; // 50%
    uint256 constant INTEREST_RATE = 500; // 5% annual interest in basis points
    uint256 constant MINT_FEE = 2; // 2%
    uint256 constant PENALTY_RATE = 10; // 10 for 10%

    // =========================================== //
    // ================== SETUP ================== //
    // =========================================== //

    function setUp() public {
        vm.startPrank(deployer);

        // WETH = new MockERC20("Collateral Token", "COL");
        WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // eth mainnet
        deal(address(WETH), deployer, 1_000_000_000 ether);

        shezUSD = new MockERC20Mintable("Shez USD", "shezUSD");

        // wethPriceFeed = IPriceFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        wethPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8); // $200
        shezUSDPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8); // $200

        vault = new ERC20Vault(
            address(WETH),
            address(shezUSD),
            INITIAL_LTV,
            LIQUIDATION_THRESHOLD,
            LIQUIDATOR_REWARD,
            address(wethPriceFeed),
            address(shezUSDPriceFeed),
            treasury
        );
        interestCollector = new InterestCollector(treasury);

        vault.setInterestCollector(address(interestCollector));
        vault.toggleInterestCollection(true);

        interestCollector.registerVault(address(vault), INTEREST_RATE);

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

        vault.setDoNotMint(true);

        uint256 collateralAmount = 1000 ether; // $200,000 worth
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100; // % LTV

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        assertEq(vault.getCollateralBalance(user1), collateralAmount);
        assertEq(vault.getLoanBalance(user1), debtAmount);
        (, uint256 posCollateral, uint256 posDebt, ) = vault.getPosition(1);
        assertEq(posCollateral, collateralAmount);
        assertEq(posDebt, debtAmount);
        assertEq(shezUSD.balanceOf(user1), debtAmount);
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_OpenPositionSoulbound() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether; // $200,000 worth
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100; // % LTV

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 fee = (collateralAmount * MINT_FEE) / 100; // 2% fee

        assertEq(vault.getCollateralBalance(user1), collateralAmount - fee);
        assertEq(vault.getLoanBalance(user1), debtAmount);
        (, uint256 posCollateral, uint256 posDebt, ) = vault.getPosition(1);
        assertEq(posCollateral, collateralAmount - fee);
        assertEq(posDebt, debtAmount);
        assertEq(shezUSD.balanceOf(user1), debtAmount);
        assertEq(WETH.balanceOf(treasury), fee); // fee to treasury
        assertTrue(vault.getHasSoulBound(1)); // Verify soulbound token was minted
        uint256 expectedEffectiveLTV = vault.getEffectiveLtvRatio(1);
        assertGt(
            expectedEffectiveLTV,
            INITIAL_LTV,
            "Effective LTV should be higher than initial LTV"
        );

        vm.stopPrank();
    }

    function test_BorrowExceedsLTV() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether; // $200,000 worth
        uint256 debtAmount = 2000 ether; // $200,000 worth (100% LTV)

        WETH.approve(address(vault), collateralAmount);
        vm.expectRevert(ERC20Vault.LoanExceedsLTVLimit.selector);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        vm.stopPrank();
    }

    function test_AddCollateral() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 additionalAmount = 200 ether;

        WETH.approve(address(vault), collateralAmount + additionalAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vault.addCollateral(1, additionalAmount);

        (, uint256 posCollateral, , ) = vault.getPosition(1);
        assertEq(posCollateral, collateralAmount + additionalAmount);
        assertEq(
            vault.getCollateralBalance(user1),
            collateralAmount + additionalAmount
        );
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_AddCollateralSoulbound() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 additionalAmount = 200 ether;

        WETH.approve(address(vault), collateralAmount + additionalAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vault.addCollateral(1, additionalAmount);

        uint256 fee = (collateralAmount * MINT_FEE) / 100;

        (, uint256 posCollateral, , ) = vault.getPosition(1);
        assertEq(posCollateral, collateralAmount + additionalAmount - fee);
        assertEq(
            vault.getCollateralBalance(user1),
            collateralAmount + additionalAmount - fee
        );
        assertEq(WETH.balanceOf(treasury), fee);

        vm.stopPrank();
    }

    function test_WithdrawCollateralSuccess() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 withdrawAmount = 200 ether;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vault.withdrawCollateral(1, withdrawAmount);

        (, uint256 posCollateral, , ) = vault.getPosition(1);
        assertEq(posCollateral, collateralAmount - withdrawAmount);
        assertEq(
            WETH.balanceOf(user1),
            2_000_000 ether - collateralAmount + withdrawAmount
        );
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_WithdrawCollateralSuccessSoulbound() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 withdrawAmount = 200 ether;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 fee = (collateralAmount * MINT_FEE) / 100; // 2% fee
        vault.withdrawCollateral(1, withdrawAmount);

        (, uint256 posCollateral, , ) = vault.getPosition(1);
        assertEq(posCollateral, collateralAmount - withdrawAmount - fee);
        assertEq(
            WETH.balanceOf(user1),
            2_000_000 ether - collateralAmount + withdrawAmount
        );
        assertEq(WETH.balanceOf(treasury), fee);

        vm.stopPrank();
    }

    function test_WithdrawCollateralFailInsufficient() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        vm.expectRevert(
            ERC20Vault.InsufficientCollateralAfterWithdrawal.selector
        );
        vault.withdrawCollateral(1, 200 ether);
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_WithdrawCollateralFailInsufficientSoulbound() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 fee = (collateralAmount * MINT_FEE) / 100; // 2% fee

        vm.expectRevert(
            ERC20Vault.InsufficientCollateralAfterWithdrawal.selector
        );
        vault.withdrawCollateral(1, 200 ether);
        assertEq(WETH.balanceOf(treasury), fee);

        vm.stopPrank();
    }

    function test_RepayDebt() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100;
        uint256 repayAmount = 300 ether;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        shezUSD.approve(address(vault), repayAmount);
        vault.repayDebt(1, repayAmount);

        (, , uint256 posDebt, ) = vault.getPosition(1);
        assertEq(posDebt, debtAmount - repayAmount);
        assertEq(vault.getLoanBalance(user1), debtAmount - repayAmount);

        vm.stopPrank();
    }

    function test_GetPositionHealth() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 collateralAmount = 1000 ether; // $200,000
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 health = vault.getPositionHealth(1);
        uint256 healthEq = (vault.getCollateralValue(collateralAmount) *
            vault.PRECISION()) / vault.getLoanValue(debtAmount);
        assertEq(health, healthEq);

        uint256 healthInfinite = vault.getPositionHealth(2);
        assertEq(healthInfinite, type(uint256).max); // ~ / 0 = infinity

        vm.stopPrank();
    }

    function test_GetPositionHealthSoulbound() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether; // $200,000
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 fee = (collateralAmount * MINT_FEE) / 100;
        uint256 health = vault.getPositionHealth(1);
        uint256 healthEq = (vault.getCollateralValue(collateralAmount - fee) *
            vault.PRECISION()) / vault.getLoanValue(debtAmount);
        assertEq(health, healthEq);
        assertTrue(vault.getHasSoulBound(1));

        uint256 healthInfinite = vault.getPositionHealth(2);
        assertEq(healthInfinite, type(uint256).max);

        vm.stopPrank();
    }

    function test_MultiplePositions() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 collateral1 = 1000 ether;
        uint256 debt1 = 500 ether;
        uint256 collateral2 = 500 ether;
        uint256 debt2 = 250 ether;

        WETH.approve(address(vault), collateral1 + collateral2);
        vault.openPosition(user1, address(WETH), collateral1, debt1);
        vault.openPosition(user1, address(WETH), collateral2, debt2);

        (, uint256 posCollateral1, , ) = vault.getPosition(1);
        (, uint256 posCollateral2, , ) = vault.getPosition(2);
        assertEq(posCollateral1, collateral1);
        assertEq(posCollateral2, collateral2);
        assertEq(vault.getCollateralBalance(user1), collateral1 + collateral2);
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_MultiplePositionsSoulbound() public {
        vm.startPrank(user1);

        uint256 collateral1 = 1000 ether;
        uint256 debt1 = 500 ether;
        uint256 collateral2 = 500 ether;
        uint256 debt2 = 250 ether;

        uint256 fee1 = (collateral1 * MINT_FEE) / 100;
        uint256 fee2 = (collateral2 * MINT_FEE) / 100;

        WETH.approve(address(vault), collateral1 + collateral2);
        vault.openPosition(user1, address(WETH), collateral1, debt1);
        vault.openPosition(user1, address(WETH), collateral2, debt2);

        (, uint256 posCollateral1, , ) = vault.getPosition(1);
        (, uint256 posCollateral2, , ) = vault.getPosition(2);
        assertEq(posCollateral1, collateral1 - fee1);
        assertEq(posCollateral2, collateral2 - fee2);
        assertEq(
            vault.getCollateralBalance(user1),
            collateral1 + collateral2 - fee1 - fee2
        );
        assertEq(WETH.balanceOf(treasury), fee1 + fee2);
        assertTrue(vault.getHasSoulBound(1));
        assertTrue(vault.getHasSoulBound(2));

        vm.stopPrank();
    }

    function test_VerySmallAmount() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 tinyCollateral = 10;
        uint256 tinyDebt = 5;

        WETH.approve(address(vault), tinyCollateral);
        vault.openPosition(user1, address(WETH), tinyCollateral, tinyDebt);

        (, uint256 posCollateral, uint256 posDebt, ) = vault.getPosition(1);
        assertEq(posCollateral, tinyCollateral);
        assertEq(posDebt, tinyDebt);
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_VerySmallAmountSoulbound() public {
        vm.startPrank(user1);

        uint256 tinyCollateral = 1000;
        uint256 tinyDebt = 500;

        WETH.approve(address(vault), tinyCollateral);
        vault.openPosition(user1, address(WETH), tinyCollateral, tinyDebt);

        uint256 fee = (tinyCollateral * MINT_FEE) / 100;
        (, uint256 posCollateral, uint256 posDebt, ) = vault.getPosition(1);
        assertEq(posCollateral, tinyCollateral - fee);
        assertEq(posDebt, tinyDebt);
        assertEq(WETH.balanceOf(treasury), fee);
        assertTrue(vault.getHasSoulBound(1));

        vm.stopPrank();
    }

    function test_ZeroAmounts() public {
        vm.startPrank(user1);

        WETH.approve(address(vault), 1000 ether);

        vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
        vault.openPosition(user1, address(WETH), 0, 500 ether);

        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
        vault.withdrawCollateral(1, 0);

        vm.expectRevert(ERC20Vault.ZeroLoanAmount.selector);
        vault.repayDebt(1, 0);

        vm.stopPrank();
    }

    function test_PriceChangeAffectsHealth() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        wethPriceFeed.setPrice(100 * 10 ** 8); // Drop to $100
        uint256 health = vault.getPositionHealth(1);
        uint256 healthEq = (vault.getCollateralValue(collateralAmount) *
            vault.PRECISION()) / vault.getLoanValue(debtAmount);
        assertEq(health, healthEq);

        vm.expectRevert(
            ERC20Vault.InsufficientCollateralAfterWithdrawal.selector
        );
        vault.withdrawCollateral(1, 100 ether);
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_PriceChangeAffectsHealthSoulbound() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 fee = (collateralAmount * MINT_FEE) / 100;
        wethPriceFeed.setPrice(100 * 10 ** 8); // Drop to $100
        uint256 health = vault.getPositionHealth(1);
        uint256 healthEq = (vault.getCollateralValue(collateralAmount - fee) *
            vault.PRECISION()) / vault.getLoanValue(debtAmount);
        assertEq(health, healthEq);

        vm.expectRevert(
            ERC20Vault.InsufficientCollateralAfterWithdrawal.selector
        );
        vault.withdrawCollateral(1, 100 ether);
        assertEq(WETH.balanceOf(treasury), fee);
        assertTrue(vault.getHasSoulBound(1));

        vm.stopPrank();
    }

    function test_InvalidPrice() public {
        vm.startPrank(user1);

        wethPriceFeed.setPrice(0);
        WETH.approve(address(vault), 1000 ether);
        vm.expectRevert(ERC20Vault.InvalidPrice.selector);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);

        vm.stopPrank();
    }

    function test_NegativePriceEdgeCase() public {
        vm.startPrank(user1);

        wethPriceFeed.setPrice(-1 * 10 ** 8);
        WETH.approve(address(vault), 1000 ether);
        vm.expectRevert(ERC20Vault.InvalidPrice.selector);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);

        vm.stopPrank();
    }

    function test_MultipleUsersMultiplePositions() public {
        vm.startPrank(user1);
        vault.setDoNotMint(true);
        WETH.approve(address(vault), 2000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vault.openPosition(user1, address(WETH), 500 ether, 250 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        vault.setDoNotMint(true);
        WETH.approve(address(vault), 3000 ether);
        vault.openPosition(user2, address(WETH), 1500 ether, 750 ether);
        vault.openPosition(user2, address(WETH), 750 ether, 375 ether);
        vm.stopPrank();

        (address pos1Owner, , , ) = vault.getPosition(1);
        (address pos2Owner, , , ) = vault.getPosition(2);
        (address pos3Owner, , , ) = vault.getPosition(3);
        (address pos4Owner, , , ) = vault.getPosition(4);
        assertEq(pos1Owner, user1);
        assertEq(pos2Owner, user1);
        assertEq(pos3Owner, user2);
        assertEq(pos4Owner, user2);
        assertEq(vault.getCollateralBalance(user1), 1500 ether);
        assertEq(vault.getCollateralBalance(user2), 2250 ether);
        assertEq(WETH.balanceOf(treasury), 0);
    }

    function test_MultipleUsersMultiplePositionsSoulbound() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 2000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vault.openPosition(user1, address(WETH), 500 ether, 250 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        WETH.approve(address(vault), 3000 ether);
        vault.openPosition(user2, address(WETH), 1500 ether, 750 ether);
        vault.openPosition(user2, address(WETH), 750 ether, 375 ether);
        vm.stopPrank();

        uint256 totalFees = ((1000 ether + 500 ether + 1500 ether + 750 ether) *
            MINT_FEE) / 100;

        assertEq(
            vault.getCollateralBalance(user1),
            1500 ether - ((1500 ether * MINT_FEE) / 100)
        );
        assertEq(
            vault.getCollateralBalance(user2),
            2250 ether - ((2250 ether * MINT_FEE) / 100)
        );
        assertEq(WETH.balanceOf(treasury), totalFees);
    }

    function test_FullDebtRepayment() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        shezUSD.approve(address(vault), debtAmount);
        vault.repayDebt(1, debtAmount);

        (, , uint256 posDebt, ) = vault.getPosition(1);
        assertEq(posDebt, 0);
        assertEq(vault.getLoanBalance(user1), 0);
        assertEq(vault.getPositionHealth(1), type(uint256).max);

        vault.withdrawCollateral(1, collateralAmount);
        (, uint256 posCollateral, , ) = vault.getPosition(1);
        assertEq(posCollateral, 0);

        vm.stopPrank();
    }

    function test_FullDebtRepaymentSoulbound() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;

        uint256 fees = (1000 ether * MINT_FEE) / 100;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        shezUSD.approve(address(vault), debtAmount);
        vault.repayDebt(1, debtAmount);

        (, , uint256 posDebt, ) = vault.getPosition(1);
        assertEq(posDebt, 0);
        assertEq(vault.getLoanBalance(user1), 0);
        assertEq(vault.getPositionHealth(1), type(uint256).max);

        vault.withdrawCollateral(1, collateralAmount - fees);
        (, uint256 posCollateral, , ) = vault.getPosition(1);
        assertEq(posCollateral, 0);

        vm.stopPrank();
    }

    function test_UnauthorizedPositionAccess() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.startPrank(user2);
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
        vault.openPosition(user1, address(shezUSD), 1000 ether, 500 ether);

        vm.stopPrank();
    }

    function test_PositionHealthEdgeCases() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 collateralAmount = 1000 ether;

        WETH.approve(address(vault), 2000 ether);

        vault.openPosition(user1, address(WETH), collateralAmount, 1);
        uint256 healthSmallDebt = vault.getPositionHealth(1);
        assertGt(healthSmallDebt, 1000 ether);

        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100; // % LTV
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 healthEq = (vault.getCollateralValue(collateralAmount) *
            vault.PRECISION()) / vault.getLoanValue(debtAmount);
        assertEq(vault.getPositionHealth(2), healthEq);
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_PositionHealthEdgeCasesSoulbound() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 2000 ether);

        uint256 collateralAmount = 1000 ether;

        vault.openPosition(user1, address(WETH), collateralAmount, 1);

        uint256 fee1 = (collateralAmount * MINT_FEE) / 100;
        uint256 healthSmallDebt = vault.getPositionHealth(1);

        assertGt(healthSmallDebt, 1000 ether);

        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100; // % LTV

        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 fee2 = (collateralAmount * MINT_FEE) / 100;
        uint256 healthEq = (vault.getCollateralValue(collateralAmount - fee2) *
            vault.PRECISION()) / vault.getLoanValue(debtAmount);

        assertEq(vault.getPositionHealth(2), healthEq);
        assertEq(WETH.balanceOf(treasury), fee1 + fee2);

        vm.stopPrank();
    }

    function test_AddCollateralImprovesHealth() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);
        WETH.approve(address(vault), 1200 ether);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100; // % LTV

        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        uint256 initialHealth = vault.getPositionHealth(1);
        vault.addCollateral(1, 200 ether);
        uint256 newHealth = vault.getPositionHealth(1);

        assertGt(newHealth, initialHealth);
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_AddCollateralImprovesHealthSoulbound() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1200 ether);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100; // % LTV

        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        uint256 initialFee = (collateralAmount * MINT_FEE) / 100;
        uint256 initialHealth = vault.getPositionHealth(1);
        uint256 healthEq = (vault.getCollateralValue(
            collateralAmount - initialFee
        ) * vault.PRECISION()) / vault.getLoanValue(debtAmount);

        assertEq(initialHealth, healthEq);

        vault.addCollateral(1, 200 ether);
        uint256 newHealth = vault.getPositionHealth(1);

        assertGt(newHealth, initialHealth);
        assertEq(WETH.balanceOf(treasury), initialFee);

        vm.stopPrank();
    }

    function test_PriceDropLiquidationThreshold() public {
        vm.startPrank(user1);

        vault.setDoNotMint(true);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100; // % LTV

        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 healthEq = (vault.getCollateralValue(collateralAmount) *
            vault.PRECISION()) / vault.getLoanValue(debtAmount);
        assertEq(vault.getPositionHealth(1), healthEq);

        wethPriceFeed.setPrice(150 * 10 ** 8);
        assertLt(vault.getPositionHealth(1), healthEq);

        vm.expectRevert(
            ERC20Vault.InsufficientCollateralAfterWithdrawal.selector
        );
        vault.withdrawCollateral(1, 1 ether);
        assertEq(WETH.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function test_PriceDropLiquidationThresholdSoulbound() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100; // % LTV

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        uint256 fee = (collateralAmount * MINT_FEE) / 100;

        uint256 healthEq = (vault.getCollateralValue(collateralAmount - fee) *
            vault.PRECISION()) / vault.getLoanValue(debtAmount);

        assertEq(vault.getPositionHealth(1), healthEq);

        wethPriceFeed.setPrice(150 * 10 ** 8);
        assertLt(vault.getPositionHealth(1), healthEq);

        vm.expectRevert(
            ERC20Vault.InsufficientCollateralAfterWithdrawal.selector
        );
        vault.withdrawCollateral(1, 1 ether);
        assertEq(WETH.balanceOf(treasury), fee);

        vm.stopPrank();
    }

    function test_UserPositionIdsTracking() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 2000 ether);

        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vault.openPosition(user1, address(WETH), 500 ether, 250 ether);

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
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                0x00
            )
        );
        vault.updatePriceFeeds(
            address(newWETHPriceFeed),
            address(newShezUSDPriceFeed)
        );
        vm.stopPrank();
    }

    function test_UpdatePriceFeedsInvalid() public {
        vm.startPrank(deployer);

        MockPriceFeed newWETHPriceFeed = new MockPriceFeed(250 ether, 8);
        MockPriceFeed newShezUSDPriceFeed = new MockPriceFeed(120 ether, 8);

        vm.expectRevert(ERC20Vault.InvalidLoanPriceFeed.selector);
        vault.updatePriceFeeds(address(newWETHPriceFeed), address(0));

        vm.expectRevert(ERC20Vault.InvalidCollateralPriceFeed.selector);
        vault.updatePriceFeeds(address(0), address(newShezUSDPriceFeed));

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
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
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
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
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
            LIQUIDATION_THRESHOLD,
            LIQUIDATOR_REWARD,
            address(wethPriceFeed),
            address(shezUSDPriceFeed),
            treasury
        );

        vm.expectRevert(ERC20Vault.InvalidLoanToken.selector);
        new ERC20Vault(
            address(WETH),
            address(0),
            INITIAL_LTV,
            LIQUIDATION_THRESHOLD,
            LIQUIDATOR_REWARD,
            address(wethPriceFeed),
            address(shezUSDPriceFeed),
            treasury
        );

        vm.expectRevert(ERC20Vault.InvalidCollateralPriceFeed.selector);
        new ERC20Vault(
            address(WETH),
            address(shezUSD),
            INITIAL_LTV,
            LIQUIDATION_THRESHOLD,
            LIQUIDATOR_REWARD,
            address(0),
            address(shezUSDPriceFeed),
            treasury
        );

        vm.expectRevert(ERC20Vault.InvalidLoanPriceFeed.selector);
        new ERC20Vault(
            address(WETH),
            address(shezUSD),
            INITIAL_LTV,
            LIQUIDATION_THRESHOLD,
            LIQUIDATOR_REWARD,
            address(wethPriceFeed),
            address(0),
            treasury
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
        assertEq(loanValue, 200_000 ether); // 1000 * 200
    }

    function test_WithdrawCollateralFailInsufficientCollateral() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 withdrawAmount = 2000 ether; // More than deposited

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
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
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
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

    function test_OpenPositionTransferFromFail() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;

        WETH.approve(address(vault), collateralAmount);
        vm.mockCall(
            address(WETH),
            abi.encodeWithSelector(WETH.transferFrom.selector),
            abi.encode(false)
        );
        vm.expectRevert(ERC20Vault.CollateralTransferFailed.selector);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vm.stopPrank();
    }

    function test_RepayDebtExceedsLoan() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 repayAmount = 600 ether; // Exceeds the debt amount

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);

        vm.expectRevert(ERC20Vault.AmountExceedsLoan.selector);
        vault.repayDebt(1, repayAmount);
        vm.stopPrank();
    }

    function test_AddCollateralTransferFromFail() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 initialDebt = 500 ether;
        uint256 addAmount = 200 ether;

        // Open a position to get a valid positionId
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, initialDebt);

        // Approve the vault for the additional amount
        WETH.approve(address(vault), addAmount);

        // Mock the transferFrom call to fail
        vm.mockCall(
            address(WETH),
            abi.encodeWithSelector(
                WETH.transferFrom.selector,
                user1,
                address(vault),
                addAmount
            ),
            abi.encode(false)
        );

        vm.expectRevert(ERC20Vault.CollateralTransferFailed.selector);
        vault.addCollateral(1, addAmount); // Use positionId 1
        vm.stopPrank();
    }

    function test_UpdatePriceFeedsZeroAddress() public {
        vm.startPrank(deployer);
        MockPriceFeed newWETHPriceFeed = new MockPriceFeed(250 * 10 ** 8, 8);

        // Test _collateralFeed == address(0)
        vm.expectRevert(ERC20Vault.InvalidCollateralPriceFeed.selector);
        vault.updatePriceFeeds(address(0), address(newWETHPriceFeed));

        // Test _loanFeed == address(0)
        vm.expectRevert(ERC20Vault.InvalidLoanPriceFeed.selector);
        vault.updatePriceFeeds(address(newWETHPriceFeed), address(0));
        vm.stopPrank();
    }

    function test_NonExistentPosition() public {
        vm.startPrank(user2);
        uint256 nonExistentPositionId = 999;
        vm.expectRevert(ERC20Vault.InvalidPosition.selector);
        vault.liquidatePosition(nonExistentPositionId);
        vm.stopPrank();
    }

    function test_NotLiquidatable() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        // Health = 4e18, threshold = 5.5e17
        vm.startPrank(user2);
        uint256 positionId = vault.nextPositionId() - 1;
        vm.expectRevert(ERC20Vault.PositionNotLiquidatable.selector);
        vault.liquidatePosition(positionId);
        vm.stopPrank();
    }

    function test_SuccessfulLiquidation() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 fee = (collateralAmount * MINT_FEE) / 100; // 2% fee
        uint256 actualCollateral = collateralAmount - fee;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, 500 ether);
        vm.stopPrank();

        uint256 positionId = vault.nextPositionId() - 1;

        vm.prank(deployer);
        wethPriceFeed.setPrice(int256(1 * 10 ** 8)); // $1

        address liquidator = user2;

        uint256 liquidatorWETHBefore = WETH.balanceOf(liquidator);
        uint256 userLoanBalanceBefore = shezUSD.balanceOf(user1);

        vm.prank(liquidator);
        vault.liquidatePosition(positionId);

        // Check position state
        (, uint256 collateral, uint256 debt, ) = vault.getPosition(positionId);
        assertEq(collateral, 0, "Collateral should be 0 after liquidation");
        assertEq(debt, 0, "Debt should be 0 after liquidation");

        // Check liquidator reward (50% of actual collateral after fee)
        uint256 penalty = (actualCollateral * PENALTY_RATE) / 100;
        uint256 liquidatorWETHAfter = WETH.balanceOf(liquidator);
        assertEq(
            liquidatorWETHAfter - liquidatorWETHBefore,
            actualCollateral / 2,
            "Liquidator should receive 50% of remaining collateral"
        );

        // Check debt repayment
        uint256 userLoanBalanceAfter = shezUSD.balanceOf(user1);
        assertEq(
            userLoanBalanceBefore - userLoanBalanceAfter,
            500 ether,
            "Debt should be fully repaid"
        );

        // Check balances
        assertEq(
            vault.getCollateralBalance(user1),
            0,
            "User collateral balance should be 0"
        );
        assertEq(
            vault.getLoanBalance(user1),
            0,
            "User loan balance should be 0"
        );
        assertEq(WETH.balanceOf(treasury), penalty + fee);
    }

    function test_LiquidationTransferFailure() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        uint256 fee = (collateralAmount * MINT_FEE) / 100; // 2% fee
        uint256 actualCollateral = collateralAmount - fee;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vm.stopPrank();

        uint256 positionId = vault.nextPositionId() - 1;

        // Make position liquidatable
        vm.prank(deployer);
        wethPriceFeed.setPrice(1 * 10 ** 8); // $1

        address liquidator = user2;
        vm.mockCall(
            address(WETH),
            abi.encodeWithSelector(
                WETH.transfer.selector,
                liquidator,
                actualCollateral / 2 // 50% of remaining collateral after fee
            ),
            abi.encode(false)
        );

        vm.prank(liquidator);
        vm.expectRevert(ERC20Vault.LiquidationFailed.selector);
        vault.liquidatePosition(positionId);

        // Verify position unchanged
        (, uint256 collateral, uint256 debt, ) = vault.getPosition(positionId);
        assertEq(collateral, actualCollateral, "Collateral should remain");
        assertEq(debt, debtAmount, "Debt should remain");
    }

    function test_LiquidationZeroDebt() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        shezUSD.approve(address(vault), debtAmount);
        vault.repayDebt(1, debtAmount); // Repay all debt
        vm.stopPrank();

        uint256 positionId = vault.nextPositionId() - 1;
        assertFalse(
            vault.isLiquidatable(positionId),
            "Position with zero debt should not be liquidatable"
        );

        address liquidator = user2;
        vm.prank(liquidator);
        vm.expectRevert(ERC20Vault.PositionNotLiquidatable.selector);
        vault.liquidatePosition(positionId);
    }

    function test_HealthSlightlyBelowThreshold() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vm.stopPrank();

        uint256 positionId = vault.nextPositionId() - 1;

        vm.prank(deployer);
        wethPriceFeed.setPrice(274 * 10 ** 7); // $27.4

        bool liquidatable = vault.isLiquidatable(positionId);
        assertTrue(
            liquidatable,
            "Health slightly below threshold should be liquidatable"
        );
    }

    function test_BurnFailure() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        uint256 positionId = vault.nextPositionId() - 1;

        vm.prank(deployer);
        wethPriceFeed.setPrice(1 * 10 ** 8); // $1

        // Revoke burn permission
        vm.prank(deployer);
        shezUSD.revokeRole(keccak256("BURNER_ROLE"), address(vault));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(vault),
                keccak256("BURNER_ROLE")
            )
        );
        vm.prank(user2);
        vault.liquidatePosition(positionId);
    }

    function test_RemainingCollateralTransferFailure() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;

        uint256 fee = (collateralAmount * MINT_FEE) / 100; // 2% fee
        uint256 actualCollateral = collateralAmount - fee;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vm.stopPrank();

        uint256 positionId = vault.nextPositionId() - 1;

        // Make position liquidatable
        vm.prank(deployer);
        wethPriceFeed.setPrice(1 * 10 ** 8); // $1

        address liquidator = user2;

        // First mock the liquidator reward transfer to succeed
        vm.mockCall(
            address(WETH),
            abi.encodeWithSelector(
                WETH.transfer.selector,
                liquidator,
                actualCollateral / 2 // 50% of remaining collateral after fee
            ),
            abi.encode(true)
        );

        // Then mock the remaining collateral transfer to fail
        vm.mockCall(
            address(WETH),
            abi.encodeWithSelector(
                WETH.transfer.selector,
                user1, // position owner
                (actualCollateral * 40) / 100 // Remaining collateral after reward and penalty
            ),
            abi.encode(false)
        );

        vm.prank(liquidator);
        vm.expectRevert(ERC20Vault.LiquidationFailed.selector);
        vault.liquidatePosition(positionId);

        // Verify position unchanged
        (, uint256 collateral, uint256 debt, ) = vault.getPosition(positionId);
        assertEq(collateral, actualCollateral, "Collateral should remain");
        assertEq(debt, debtAmount, "Debt should remain");
    }

    function test_LiquidationMultiplePositionsLoop() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;

        uint256 fee = (collateralAmount * MINT_FEE) / 100; // 2% fee
        uint256 actualCollateral = collateralAmount - fee;

        // Open three positions
        WETH.approve(address(vault), collateralAmount * 3);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount); // Position 1
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount); // Position 2
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount); // Position 3

        uint256 positionId1 = 1;
        uint256 positionId2 = 2; // Middle position (to be liquidated)
        uint256 positionId3 = 3;

        vm.stopPrank();

        // Make the middle position liquidatable
        vm.prank(deployer);
        wethPriceFeed.setPrice(1 * 10 ** 8); // $1

        address liquidator = user2;
        vm.prank(liquidator);
        vault.liquidatePosition(positionId2);

        // Assert that position 2 is removed
        uint256[] memory userPositions = vault.getUserPositionIds(user1);
        assertEq(
            userPositions.length,
            2,
            "User should have only two positions left"
        );

        // Check that the array correctly shifts elements
        assertEq(userPositions[0], positionId1, "First position should remain");
        assertEq(userPositions[1], positionId3, "Last position should remain");

        // Check that position 2 is fully removed
        (, uint256 pos2Collateral, uint256 pos2Debt, ) = vault.getPosition(
            positionId2
        );
        assertEq(
            pos2Collateral,
            0,
            "Liquidated position should have zero collateral"
        );
        assertEq(pos2Debt, 0, "Liquidated position should have zero debt");

        // Verify the remaining positions are untouched
        (, uint256 pos1Collateral, uint256 pos1Debt, ) = vault.getPosition(
            positionId1
        );
        (, uint256 pos3Collateral, uint256 pos3Debt, ) = vault.getPosition(
            positionId3
        );

        assertEq(
            pos1Collateral,
            actualCollateral,
            "Position 1 should be unaffected"
        );
        assertEq(pos1Debt, debtAmount, "Position 1 debt should be intact");
        assertEq(
            pos3Collateral,
            actualCollateral,
            "Position 3 should be unaffected"
        );
        assertEq(pos3Debt, debtAmount, "Position 3 debt should be intact");
    }

    function test_InterestCollectorDeployment() public view {
        assertEq(interestCollector.treasury(), treasury);
        assertEq(interestCollector.blocksPerYear(), 7160 * 365);
        assertEq(interestCollector.periodBlocks(), 300);
    }

    function test_CollectInterestManually() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.roll(block.number + 300);

        uint256 due = interestCollector.calculateInterestDue(
            address(vault),
            1,
            500 ether
        );
        assertGt(due, 0, "Interest should be due after block advance");
    }

    function test_ToggleInterestCollection() public {
        vm.startPrank(deployer);
        vault.toggleInterestCollection(false);
        assertFalse(
            vault.interestCollectionEnabled(),
            "Interest collection should be disabled"
        );

        vm.expectRevert();
        vm.prank(user1);
        vault.toggleInterestCollection(true); // Only owner can toggle
        vm.stopPrank();
    }

    function test_RegisterVault() public {
        vm.startPrank(deployer);
        assertEq(interestCollector.getVaultInterestRate(address(vault)), 500);
        assertEq(interestCollector.getRegisteredVaultsCount(), 1);
        vm.stopPrank();
    }

    function test_RegisterVaultErrors() public {
        vm.startPrank(deployer);
        vm.expectRevert(InterestCollector.ZeroAddress.selector);
        interestCollector.registerVault(address(0), 500);

        vm.expectRevert(InterestCollector.InvalidInterestRate.selector);
        interestCollector.registerVault(address(this), 0);

        vm.expectRevert(InterestCollector.VaultAlreadyRegistered.selector);
        interestCollector.registerVault(address(vault), 500);
        vm.stopPrank();
    }

    function test_UpdateInterestRate() public {
        vm.startPrank(deployer);
        interestCollector.updateInterestRate(address(vault), 1000);
        assertEq(interestCollector.getVaultInterestRate(address(vault)), 1000);

        vm.expectRevert(InterestCollector.VaultNotRegistered.selector);
        interestCollector.updateInterestRate(address(user1), 500);

        vm.expectRevert(InterestCollector.InvalidInterestRate.selector);
        interestCollector.updateInterestRate(address(vault), 0);
        vm.stopPrank();
    }

    function test_CollectInterestNotReady() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.prank(address(vault));
        interestCollector.collectInterest(
            address(vault),
            address(shezUSD),
            1,
            500 ether
        ); // Not ready yet
        assertEq(interestCollector.getCollectedInterest(address(shezUSD)), 0);
    }

    function test_WithdrawInterest() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.roll(block.number + 300);

        // Calculate interest due
        uint256 interestDue = interestCollector.calculateInterestDue(
            address(vault),
            1,
            500 ether
        );

        // User approves the vault to burn shezUSD on their behalf
        vm.prank(user1);
        shezUSD.approve(address(vault), interestDue);

        // Collect interest
        vm.prank(address(vault));
        interestCollector.collectInterest(
            address(vault),
            address(shezUSD),
            1,
            500 ether
        );

        // Verify collected interest
        assertEq(
            interestCollector.getCollectedInterest(address(shezUSD)),
            interestDue,
            "Collected interest should match calculated interest"
        );

        // Withdraw interest to treasury
        uint256 treasuryBalanceBefore = shezUSD.balanceOf(treasury);
        vm.prank(deployer);
        interestCollector.withdrawInterest(address(shezUSD));
        assertEq(
            shezUSD.balanceOf(treasury),
            treasuryBalanceBefore + interestDue,
            "Treasury should receive the collected interest"
        );
    }

    function test_WithdrawInterestTransferFail() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.roll(block.number + 300);
        vm.prank(address(vault));
        interestCollector.collectInterest(
            address(vault),
            address(shezUSD),
            1,
            500 ether
        );

        vm.mockCall(
            address(shezUSD),
            abi.encodeWithSelector(shezUSD.transfer.selector),
            abi.encode(false)
        );
        vm.expectRevert(InterestCollector.TransferFailed.selector);
        vm.prank(deployer);
        interestCollector.withdrawInterest(address(shezUSD));
    }

    function test_UpdateTreasury() public {
        vm.startPrank(deployer);
        address newTreasury = vm.addr(5);
        interestCollector.updateTreasury(newTreasury);
        assertEq(interestCollector.treasury(), newTreasury);

        vm.expectRevert(InterestCollector.ZeroAddress.selector);
        interestCollector.updateTreasury(address(0));
        vm.stopPrank();
    }

    function test_SetPeriodBlocks() public {
        vm.startPrank(deployer);
        interestCollector.setPeriodBlocks(600);
        assertEq(interestCollector.periodBlocks(), 600);
        vm.stopPrank();
    }

    function test_IsCollectionReady() public {
        assertFalse(interestCollector.isCollectionReady(address(vault), 1));

        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.roll(block.number + 300);

        assertTrue(interestCollector.isCollectionReady(address(vault), 1));
    }

    function test_CalculateInterestDueEdgeCases() public {
        vm.startPrank(deployer);
        assertEq(interestCollector.getCollectedInterest(address(vault)), 0); // No rate set

        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.roll(block.number + 299); // Less than periodBlocks

        assertEq(
            interestCollector.calculateInterestDue(
                address(vault),
                1,
                500 ether
            ),
            0
        );

        vm.roll(block.number + 1); // Exactly one period
        uint256 interest = interestCollector.calculateInterestDue(
            address(vault),
            1,
            500 ether
        );
        assertGt(interest, 0);
        vm.stopPrank();
    }

    function test_InterestCollectorGetLastCollectionBlock() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        uint256 currentBlock = block.number;
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        uint256 lastCollectionBlock = interestCollector.getLastCollectionBlock(
            address(vault),
            1
        );
        assertEq(
            lastCollectionBlock,
            currentBlock,
            "Last collection block should match the block when position was opened"
        );
    }

    function test_CalculateInterestDueZeroDebt() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        shezUSD.approve(address(vault), 500 ether);
        vault.repayDebt(1, 500 ether); // Repay all debt
        vm.stopPrank();

        vm.roll(block.number + 300);

        uint256 interestDue = interestCollector.calculateInterestDue(
            address(vault),
            1,
            0 // Debt amount is 0
        );
        assertEq(interestDue, 0, "Interest should be 0 when debt amount is 0");
    }

    function test_SetLastCollectionBlockNotVault() public {
        vm.prank(user1);
        vm.expectRevert(InterestCollector.VaultNotCaller.selector);
        interestCollector.setLastCollectionBlock(address(vault), 1);
    }

    function test_CollectInterestUnregisteredVault() public {
        vm.prank(address(user3)); // user3 is not a registered vault
        vm.expectRevert(InterestCollector.VaultNotRegistered.selector);
        interestCollector.collectInterest(
            address(user3),
            address(shezUSD),
            1,
            500 ether
        );
    }

    function test_CollectInterestNotVaultCaller() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.roll(block.number + 300);

        vm.prank(user1); // Not the vault
        vm.expectRevert(InterestCollector.VaultNotCaller.selector);
        interestCollector.collectInterest(
            address(vault),
            address(shezUSD),
            1,
            500 ether
        );
    }

    function test_CollectInterestNoInterestDue() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        vm.stopPrank();

        vm.roll(block.number + 300);

        vm.prank(address(vault));
        vm.expectRevert(InterestCollector.NoInterestToCollect.selector);
        interestCollector.collectInterest(
            address(vault),
            address(shezUSD),
            1,
            0 // Debt amount is 0
        );
    }

    function test_GetLastCollectionBlock() public {
        vm.startPrank(user1);
        WETH.approve(address(vault), 1000 ether);
        uint256 currentBlock = block.number;
        vault.openPosition(user1, address(WETH), 1000 ether, 500 ether);
        uint256 positionId = vault.nextPositionId() - 1; // Ensure correct position ID
        vm.stopPrank();

        (, , , uint256 lastCollectionBlock) = vault.getPosition(positionId);
        assertEq(
            lastCollectionBlock,
            currentBlock,
            "Last collection block should match the block when position was opened"
        );
    }

    function test_LiquidationTreasuryTransferFailure() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;

        uint256 fee = (collateralAmount * MINT_FEE) / 100; // 2% fee
        uint256 actualCollateral = collateralAmount - fee;

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vm.stopPrank();

        uint256 positionId = vault.nextPositionId() - 1;

        vm.prank(deployer);
        wethPriceFeed.setPrice(1 * 10 ** 8); // Make position liquidatable

        address liquidator = user2;

        // Mock the transfer to treasury to fail
        vm.mockCall(
            address(WETH),
            abi.encodeWithSelector(
                WETH.transfer.selector,
                treasury,
                (actualCollateral * PENALTY_RATE) / 100 // penalty = (1000 * 10) / 100
            ),
            abi.encode(false)
        );

        vm.prank(liquidator);
        vm.expectRevert(ERC20Vault.LiquidationFailed.selector);
        vault.liquidatePosition(positionId);

        // Verify position unchanged
        (, uint256 collateral, uint256 debt, ) = vault.getPosition(positionId);
        assertEq(collateral, actualCollateral, "Collateral should remain");
        assertEq(debt, debtAmount, "Debt should remain");
    }

    function test_CollectIInterestNotInterestCollector() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.collectInterest(1, 500 ether);
    }

    function test_CalculateInterestDueUnregisteredVault() public view {
        uint256 interestDue = interestCollector.calculateInterestDue(
            address(user3), // Unregistered vault
            1,
            500 ether
        );
        assertEq(
            interestDue,
            0,
            "Interest should be 0 for an unregistered vault"
        );
    }

    function test_CalculateInterestDueLastCollectionBlockZero() public view {
        uint256 lastCollectionBlock = interestCollector.getLastCollectionBlock(
            address(vault),
            1
        );
        assertEq(lastCollectionBlock, 0, "Last collection block should be 0");

        // Calculate interest due
        uint256 interestDue = interestCollector.calculateInterestDue(
            address(vault),
            1,
            500 ether
        );
        assertEq(
            interestDue,
            0,
            "Interest should be 0 when lastCollectionBlock is 0"
        );
    }

    function test_WithdrawInterestNoInterestCollected() public {
        vm.prank(deployer);
        vm.expectRevert(InterestCollector.NoInterestToCollect.selector);
        interestCollector.withdrawInterest(address(shezUSD));
    }

    function test_SoulBoundUnauthorizedReverts() public {
        SoulBound soulBound = vault.soulBoundToken();

        vm.expectRevert("Only vault can mint");
        soulBound.mint(user1, 1);

        vm.expectRevert("Only vault can burn");
        soulBound.burn(1);
    }

    function test_SoulBoundTransferReverts() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vm.stopPrank();

        uint256 positionId = vault.nextPositionId() - 1;
        SoulBound soulBound = vault.soulBoundToken();

        vm.expectRevert("Soul-bound tokens cannot be transferred");
        soulBound.transferFrom(user1, user2, positionId);

        vm.expectRevert("Soul-bound tokens cannot be transferred");
        soulBound.safeTransferFrom(user1, user2, positionId, "");
    }

    function test_OpenPositionZeroFeeReverts() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 10; // Very small amount to make fee = 0
        uint256 debtAmount = 5;

        WETH.approve(address(vault), collateralAmount);
        vm.expectRevert(ERC20Vault.InsufficientFee.selector);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vm.stopPrank();
    }

    function test_BorrowForAndAddCollateralFor() public {
        vm.startPrank(user1);
        uint256 collateralAmount = 1000 ether;
        uint256 debtAmount = 500 ether;
        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(user1, address(WETH), collateralAmount, debtAmount);
        vm.stopPrank();

        uint256 positionId = vault.nextPositionId() - 1;

        // Grant LEVERAGE_ROLE to user2
        vm.startPrank(deployer);
        vault.grantRole(vault.LEVERAGE_ROLE(), user2);
        vm.stopPrank();

        // Test addCollateralFor
        vm.startPrank(user2);
        uint256 additionalCollateral = 200 ether;
        WETH.approve(address(vault), additionalCollateral);
        vault.addCollateralFor(positionId, user1, additionalCollateral);
        vm.stopPrank();

        (, uint256 posCollateral, , ) = vault.getPosition(positionId);
        uint256 fee = (collateralAmount * MINT_FEE) / 100;
        assertEq(
            posCollateral,
            collateralAmount - fee + additionalCollateral,
            "Collateral should increase"
        );

        // Test borrowFor
        vm.startPrank(user2);
        uint256 additionalDebt = 100 ether;
        vault.borrowFor(positionId, user1, additionalDebt);
        vm.stopPrank();

        (, , uint256 posDebt, ) = vault.getPosition(positionId);
        assertEq(posDebt, debtAmount + additionalDebt, "Debt should increase");
    }

    function test_SetDoNotMint() public {
        vm.startPrank(user1);
        vault.setDoNotMint(true);
        assertTrue(vault.getDoNotMint(user1), "doNotMint should be true");

        vault.setDoNotMint(false);
        assertFalse(vault.getDoNotMint(user1), "doNotMint should be false");
        vm.stopPrank();
    }
}
