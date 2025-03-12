// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "../src/ERC20Vault.sol";
import "../src/mock/MockERC20.sol";
import "../src/mock/MockERC20Mintable.sol";
import "../src/mock/MockPriceFeed.sol";

import "../src/interfaces/IPriceFeed.sol";

contract ERC20VaultInvariantTest is Test {
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

    mapping(uint256 => uint256) public initialCollateral; // positionId => initial amount
    mapping(uint256 => uint256) public addedCollateral; // positionId => total added

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error InvalidCollateralToken();
    error InvalidLoanToken();
    error InvalidLTVRatio();
    error InvalidCollateralPriceFeed();
    error InvalidLoanPriceFeed();
    error ZeroCollateralAmount();
    error ZeroLoanAmount();
    error LoanExceedsLTVLimit();
    error CollateralTransferFailed();
    error NotPositionOwner();
    error AmountExceedsLoan();
    error InsufficientCollateral();
    error InsufficientCollateralAfterWithdrawal();
    error CollateralWithdrawalFailed();
    error InvalidPrice();

    // =========================================== //
    // ================== SETUP ================== //
    // =========================================== //

    function setUp() public {
        vm.startPrank(deployer);

        WETH = new MockERC20("Collateral Token", "COL");
        shezUSD = new MockERC20Mintable("Shez USD", "shezUSD");

        // wethPriceFeed = IPriceFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        wethPriceFeed = new MockPriceFeed(200 ether, 8); // $200
        shezUSDPriceFeed = new MockPriceFeed(100 ether, 8); // $100

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

        vm.stopPrank();

        // Explicitly target this contract for invariant testing
        targetContract(address(this));
        // targetContract(address(vault));

        // // Specify the openPosition function as a target selector
        FuzzSelector memory selectorTest = FuzzSelector({
            addr: address(this),
            selectors: new bytes4[](2)
        });
        selectorTest.selectors[0] = this.handler_openPosition.selector;
        selectorTest.selectors[1] = this.handler_addCollateral.selector;
        targetSelector(selectorTest);
        // FuzzSelector memory selectorVault = FuzzSelector({
        //     addr: address(vault),
        //     selectors: new bytes4[](1)
        // });
        // selectorVault.selectors[0] = ERC20Vault.openPosition.selector;
        // targetSelector(selectorVault);
    }

    // ============================================== //
    // ================== HANDLERS ================== //
    // ============================================== //

    function handler_openPosition(
        uint256 collateralAmount,
        uint256 debtAmount
    ) public virtual {
        vm.startPrank(user1);
        collateralAmount = bound(collateralAmount, 1 ether, 1e23); // $200 to $10M
        debtAmount = bound(debtAmount, 0.5 ether, 1e24); // Allow exceeding LTV 
        WETH.approve(address(vault), collateralAmount);
        try vault.openPosition(address(WETH), collateralAmount, debtAmount) {
            uint256 positionId = vault.nextPositionId() - 1; // Last created position
            initialCollateral[positionId] = collateralAmount; // Record initial collateral
        } catch {}
        vm.stopPrank();
    }

    function handler_addCollateral(
        uint256 positionId,
        uint256 additionalAmount
    ) public virtual {
        vm.startPrank(user1);
        additionalAmount = bound(additionalAmount, 1 ether, 1e23); // $200 to $10M
        uint256 nextId = vault.nextPositionId();
        if (nextId > 1) {
            positionId = bound(positionId, 1, nextId - 1);
            WETH.approve(address(vault), additionalAmount);
            try vault.addCollateral(positionId, additionalAmount) {
                addedCollateral[positionId] += additionalAmount; // Record added collateral
            } catch {}
        }
        vm.stopPrank();
    }

    // ================================================ //
    // ================== TEST CASES ================== //
    // ================================================ //

    function invariant_PositionDataMatchesBalances() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        uint256 totalCollateral;
        uint256 totalDebt;
        for (uint256 i = 0; i < posIds.length; i++) {
            (, uint256 posCollateral, uint256 posDebt) = vault.getPosition(
                posIds[i]
            );
            totalCollateral += posCollateral;
            totalDebt += posDebt;
        }
        assertEq(vault.getCollateralBalance(user1), totalCollateral);
        assertEq(vault.getLoanBalance(user1), totalDebt);
        assertEq(shezUSD.balanceOf(user1), vault.getLoanBalance(user1));
    }

    function invariant_LTVLimitRespected() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        for (uint256 i = 0; i < posIds.length; i++) {
            (, uint256 collateralAmount, uint256 debtAmount) = vault
                .getPosition(posIds[i]);
            if (debtAmount > 0) {
                // Only check positions with debt
                uint256 collateralValue = vault.getCollateralValue(
                    collateralAmount
                );
                uint256 loanValue = vault.getLoanValue(debtAmount);
                uint256 maxLoanValue = (collateralValue * INITIAL_LTV) / 100;
                assertLe(loanValue, maxLoanValue, "Debt exceeds LTV limit");
            }
        }
    }

    function invariant_CollateralAdditionsAccurate() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        uint256 totalCollateralExpected;

        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 posCollateral, ) = vault.getPosition(positionId);
            uint256 expectedCollateral = initialCollateral[positionId] +
                addedCollateral[positionId];
            assertEq(
                posCollateral,
                expectedCollateral,
                "Position collateral mismatch"
            );
            totalCollateralExpected += expectedCollateral;
        }

        assertEq(
            vault.getCollateralBalance(user1),
            totalCollateralExpected,
            "Total collateral balance mismatch"
        );
    }

    // function test_WithdrawCollateralSuccess() public {
    //     vm.startPrank(user1);

    //     uint256 collateralAmount = 1000 ether;
    //     uint256 debtAmount = 500 ether;
    //     uint256 withdrawAmount = 200 ether;

    //     WETH.approve(address(vault), collateralAmount);
    //     vault.openPosition(address(WETH), collateralAmount, debtAmount);
    //     vault.withdrawCollateral(1, withdrawAmount);

    //     (, uint256 posCollateral, ) = vault.getPosition(1);
    //     assertEq(posCollateral, collateralAmount - withdrawAmount);
    //     assertEq(
    //         WETH.balanceOf(user1),
    //         2_000_000 ether - collateralAmount + withdrawAmount
    //     );

    //     vm.stopPrank();
    // }

    // function test_WithdrawCollateralFailInsufficient() public {
    //     vm.startPrank(user1);

    //     uint256 collateralAmount = 1000 ether;
    //     uint256 debtAmount = 1000 ether; // Max LTV

    //     WETH.approve(address(vault), collateralAmount);
    //     vault.openPosition(address(WETH), collateralAmount, debtAmount);

    //     vm.expectRevert(InsufficientCollateralAfterWithdrawal.selector);
    //     vault.withdrawCollateral(1, 200 ether);

    //     vm.stopPrank();
    // }

    // function test_RepayDebt() public {
    //     vm.startPrank(user1);

    //     uint256 collateralAmount = 1000 ether;
    //     uint256 debtAmount = 1000 ether;
    //     uint256 repayAmount = 300 ether;

    //     WETH.approve(address(vault), collateralAmount);
    //     vault.openPosition(address(WETH), collateralAmount, debtAmount);
    //     shezUSD.approve(address(vault), repayAmount);
    //     vault.repayDebt(1, repayAmount);

    //     (, , uint256 posDebt) = vault.getPosition(1);
    //     assertEq(posDebt, debtAmount - repayAmount);
    //     assertEq(vault.getLoanBalance(user1), debtAmount - repayAmount);

    //     vm.stopPrank();
    // }

    // function test_GetPositionHealth() public {
    //     vm.startPrank(user1);

    //     uint256 collateralAmount = 1000 ether; // $200,000
    //     uint256 debtAmount = 1000 ether; // $100,000

    //     WETH.approve(address(vault), collateralAmount);
    //     vault.openPosition(address(WETH), collateralAmount, debtAmount);

    //     uint256 health = vault.getPositionHealth(1);
    //     assertEq(health, 2 ether); // 200,000 / 100,000 = 2

    //     uint256 healthInfinite = vault.getPositionHealth(2);
    //     assertEq(healthInfinite, type(uint256).max); // ~ / 0 = infinity

    //     vm.stopPrank();
    // }

    // function test_GetMaxBorrowable() public {
    //     vm.startPrank(user1);

    //     uint256 collateralAmount = 1000 ether;
    //     WETH.approve(address(vault), collateralAmount);
    //     vault.openPosition(address(WETH), collateralAmount, 100 ether);

    //     uint256 maxBorrowable = vault.getMaxBorrowable(user1);
    //     assertEq(maxBorrowable, 1000 ether); // $100,000 worth at 50% LTV

    //     vm.stopPrank();
    // }

    // function test_MultiplePositions() public {
    //     vm.startPrank(user1);

    //     uint256 collateral1 = 1000 ether;
    //     uint256 debt1 = 500 ether;
    //     uint256 collateral2 = 500 ether;
    //     uint256 debt2 = 250 ether;

    //     WETH.approve(address(vault), collateral1 + collateral2);
    //     vault.openPosition(address(WETH), collateral1, debt1);
    //     vault.openPosition(address(WETH), collateral2, debt2);

    //     (, uint256 posCollateral1, ) = vault.getPosition(1);
    //     (, uint256 posCollateral2, ) = vault.getPosition(2);
    //     assertEq(posCollateral1, collateral1);
    //     assertEq(posCollateral2, collateral2);
    //     assertEq(vault.getCollateralBalance(user1), collateral1 + collateral2);

    //     vm.stopPrank();
    // }

    // function test_VerySmallAmount() public {
    //     vm.startPrank(user1);

    //     uint256 tinyCollateral = 10;
    //     uint256 tinyDebt = 5;

    //     WETH.approve(address(vault), tinyCollateral);
    //     vault.openPosition(address(WETH), tinyCollateral, tinyDebt);

    //     (, uint256 posCollateral, uint256 posDebt) = vault.getPosition(1);
    //     assertEq(posCollateral, tinyCollateral);
    //     assertEq(posDebt, tinyDebt);

    //     vm.stopPrank();
    // }

    // function test_ZeroAmounts() public {
    //     vm.startPrank(user1);

    //     WETH.approve(address(vault), 1000 ether);

    //     vm.expectRevert(ZeroCollateralAmount.selector);
    //     vault.openPosition(address(WETH), 0, 500 ether);

    //     vm.expectRevert(ZeroLoanAmount.selector);
    //     vault.openPosition(address(WETH), 1000 ether, 0);

    //     vault.openPosition(address(WETH), 1000 ether, 500 ether);
    //     vm.expectRevert(ZeroCollateralAmount.selector);
    //     vault.withdrawCollateral(1, 0);

    //     vm.stopPrank();
    // }

    // function test_PriceChangeAffectsHealth() public {
    //     vm.startPrank(user1);

    //     uint256 collateralAmount = 1000 ether;
    //     WETH.approve(address(vault), collateralAmount);
    //     vault.openPosition(address(WETH), collateralAmount, 1000 ether);

    //     wethPriceFeed.setPrice(100 ether); // Drop to $100
    //     uint256 health = vault.getPositionHealth(1);
    //     assertEq(health, 1 ether); // 100,000 / 100,000 = 1

    //     vm.expectRevert(InsufficientCollateralAfterWithdrawal.selector);
    //     vault.withdrawCollateral(1, 100 ether);

    //     vm.stopPrank();
    // }

    // function test_InvalidPrice() public {
    //     vm.startPrank(user1);

    //     wethPriceFeed.setPrice(0);
    //     WETH.approve(address(vault), 1000 ether);
    //     vm.expectRevert(InvalidPrice.selector);
    //     vault.openPosition(address(WETH), 1000 ether, 500 ether);

    //     vm.stopPrank();
    // }

    // function test_MultipleUsersMultiplePositions() public {
    //     vm.startPrank(user1);
    //     WETH.approve(address(vault), 2000 ether);
    //     vault.openPosition(address(WETH), 1000 ether, 500 ether);
    //     vault.openPosition(address(WETH), 500 ether, 250 ether);
    //     vm.stopPrank();

    //     vm.startPrank(user2);
    //     WETH.approve(address(vault), 3000 ether);
    //     vault.openPosition(address(WETH), 1500 ether, 750 ether);
    //     vault.openPosition(address(WETH), 750 ether, 375 ether);
    //     vm.stopPrank();

    //     (address pos1Owner, , ) = vault.getPosition(1);
    //     (address pos2Owner, , ) = vault.getPosition(2);
    //     (address pos3Owner, , ) = vault.getPosition(3);
    //     (address pos4Owner, , ) = vault.getPosition(4);
    //     assertEq(pos1Owner, user1);
    //     assertEq(pos2Owner, user1);
    //     assertEq(pos3Owner, user2);
    //     assertEq(pos4Owner, user2);
    //     assertEq(vault.getCollateralBalance(user1), 1500 ether);
    //     assertEq(vault.getCollateralBalance(user2), 2250 ether);
    // }

    // function test_FullDebtRepayment() public {
    //     vm.startPrank(user1);

    //     uint256 collateralAmount = 1000 ether;
    //     uint256 debtAmount = 500 ether;

    //     WETH.approve(address(vault), collateralAmount);
    //     vault.openPosition(address(WETH), collateralAmount, debtAmount);

    //     shezUSD.approve(address(vault), debtAmount);
    //     vault.repayDebt(1, debtAmount);

    //     (, , uint256 posDebt) = vault.getPosition(1);
    //     assertEq(posDebt, 0);
    //     assertEq(vault.getLoanBalance(user1), 0);
    //     assertEq(vault.getPositionHealth(1), type(uint256).max);

    //     vault.withdrawCollateral(1, collateralAmount);
    //     (, uint256 posCollateral, ) = vault.getPosition(1);
    //     assertEq(posCollateral, 0);

    //     vm.stopPrank();
    // }

    // function test_UnauthorizedPositionAccess() public {
    //     vm.startPrank(user1);
    //     WETH.approve(address(vault), 1000 ether);
    //     vault.openPosition(address(WETH), 1000 ether, 500 ether);
    //     vm.stopPrank();

    //     vm.startPrank(user2);
    //     vm.expectRevert(NotPositionOwner.selector);
    //     vault.addCollateral(1, 100 ether);

    //     vm.expectRevert(NotPositionOwner.selector);
    //     vault.withdrawCollateral(1, 100 ether);

    //     vm.expectRevert(NotPositionOwner.selector);
    //     vault.repayDebt(1, 100 ether);
    //     vm.stopPrank();
    // }

    // function test_InvalidCollateralToken() public {
    //     vm.startPrank(user1);
    //     WETH.approve(address(vault), 1000 ether);

    //     vm.expectRevert(InvalidCollateralToken.selector);
    //     vault.openPosition(address(shezUSD), 1000 ether, 500 ether);

    //     vm.stopPrank();
    // }

    // function test_PositionHealthEdgeCases() public {
    //     vm.startPrank(user1);
    //     WETH.approve(address(vault), 2000 ether);

    //     vault.openPosition(address(WETH), 1000 ether, 1);
    //     uint256 healthSmallDebt = vault.getPositionHealth(1);
    //     assertGt(healthSmallDebt, 1000 ether);

    //     vault.openPosition(address(WETH), 1000 ether, 1000 ether);
    //     assertEq(vault.getPositionHealth(2), 2 ether);

    //     vm.stopPrank();
    // }

    // function test_MaxBorrowableWithMultiplePositions() public {
    //     vm.startPrank(user1);
    //     WETH.approve(address(vault), 1500 ether);

    //     vault.openPosition(address(WETH), 1000 ether, 500 ether);
    //     vault.openPosition(address(WETH), 500 ether, 250 ether);

    //     uint256 maxBorrowable = vault.getMaxBorrowable(user1);
    //     assertEq(maxBorrowable, 1500 ether);

    //     vm.stopPrank();
    // }

    // function test_AddCollateralImprovesHealth() public {
    //     vm.startPrank(user1);
    //     WETH.approve(address(vault), 1200 ether);

    //     vault.openPosition(address(WETH), 1000 ether, 1000 ether);
    //     uint256 initialHealth = vault.getPositionHealth(1);
    //     assertEq(initialHealth, 2 ether);

    //     vault.addCollateral(1, 200 ether);
    //     uint256 newHealth = vault.getPositionHealth(1);
    //     assertEq(newHealth, 2.4 ether);

    //     vm.stopPrank();
    // }

    // function test_PriceDropLiquidationThreshold() public {
    //     vm.startPrank(user1);
    //     WETH.approve(address(vault), 1000 ether);
    //     vault.openPosition(address(WETH), 1000 ether, 1000 ether);

    //     assertEq(vault.getPositionHealth(1), 2 ether);

    //     wethPriceFeed.setPrice(150 ether);
    //     assertEq(vault.getPositionHealth(1), 1.5 ether);

    //     vm.expectRevert(InsufficientCollateralAfterWithdrawal.selector);
    //     vault.withdrawCollateral(1, 1 ether);

    //     vm.stopPrank();
    // }

    // function test_UserPositionIdsTracking() public {
    //     vm.startPrank(user1);
    //     WETH.approve(address(vault), 2000 ether);

    //     vault.openPosition(address(WETH), 1000 ether, 500 ether);
    //     vault.openPosition(address(WETH), 500 ether, 250 ether);

    //     uint256[] memory positionIds = vault.getUserPositionIds(user1);
    //     assertEq(positionIds.length, 2);
    //     assertEq(positionIds[0], 1);
    //     assertEq(positionIds[1], 2);

    //     vm.stopPrank();
    // }
}
