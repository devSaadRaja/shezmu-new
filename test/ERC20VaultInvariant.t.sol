// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "../src/ERC20Vault.sol";
import "../src/InterestCollector.sol";
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
    address user3 = vm.addr(4);
    address treasury = vm.addr(5);

    InterestCollector interestCollector;

    uint256 constant INITIAL_LTV = 50;
    uint256 constant LIQUIDATION_THRESHOLD = 110; // 110% of INITIAL_LTV
    uint256 constant LIQUIDATOR_REWARD = 50; // 50%
    uint256 constant INTEREST_RATE = 500; // 5% annual interest in basis points

    mapping(uint256 => uint256) public initialCollateral; // positionId => initial amount
    mapping(uint256 => uint256) public addedCollateral; // positionId => total added
    mapping(uint256 => uint256) public withdrawnCollateral; // positionId => total withdrawn
    mapping(uint256 => uint256) public initialDebt; // positionId => initial debt
    mapping(uint256 => uint256) public repaidDebt; // positionId => total repaid
    mapping(address => uint256) public lastPriceUpdate; // Token address => last price
    mapping(uint256 => uint256) public ltvAtCreation; // positionId => LTV at creation
    mapping(uint256 => uint256) public interestAccrued;
    uint256 public initialWETHBalance; // User1's initial WETH balance

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
            LIQUIDATION_THRESHOLD,
            LIQUIDATOR_REWARD,
            address(wethPriceFeed),
            address(shezUSDPriceFeed)
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

        // Record initial WETH balance for user1
        initialWETHBalance = WETH.balanceOf(user1); // 2_000_000 ether;

        // Record initial prices
        (, int256 priceWETH, , , ) = wethPriceFeed.latestRoundData();
        (, int256 priceShezUSD, , , ) = shezUSDPriceFeed.latestRoundData();
        lastPriceUpdate[address(wethPriceFeed)] = uint256(priceWETH);
        lastPriceUpdate[address(shezUSDPriceFeed)] = uint256(priceShezUSD);

        // Explicitly target this contract for invariant testing
        targetContract(address(this));
        // targetContract(address(vault));

        // Specify the openPosition function as a target selector
        FuzzSelector memory selectorTest = FuzzSelector({
            addr: address(this),
            selectors: new bytes4[](6)
        });
        selectorTest.selectors[0] = this.handler_openPosition.selector;
        selectorTest.selectors[1] = this.handler_addCollateral.selector;
        selectorTest.selectors[2] = this.handler_withdrawCollateral.selector;
        selectorTest.selectors[3] = this.handler_repayDebt.selector;
        selectorTest.selectors[4] = this.handler_updatePriceFeed.selector;
        selectorTest.selectors[5] = this.handler_collectInterest.selector;
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
        collateralAmount = bound(collateralAmount, 0, 1e24); // 0 to 1e24 (allow zero)
        debtAmount = bound(debtAmount, 0, 1e24); // 0 to 1e24 (allow zero)

        WETH.approve(address(vault), collateralAmount);

        // Test success path
        if (
            collateralAmount > 0 &&
            debtAmount > 0 &&
            debtAmount <=
            (vault.getCollateralValue(collateralAmount) * INITIAL_LTV) / 100
        ) {
            try
                vault.openPosition(address(WETH), collateralAmount, debtAmount)
            {
                uint256 positionId = vault.nextPositionId() - 1;
                initialCollateral[positionId] = collateralAmount;
                initialDebt[positionId] = debtAmount;
                // Calculate and store LTV at creation
                uint256 collateralValue = vault.getCollateralValue(
                    collateralAmount
                );
                uint256 loanValue = vault.getLoanValue(debtAmount);
                ltvAtCreation[positionId] = (loanValue * 100) / collateralValue;
            } catch {}
        }
        // Test revert paths
        else if (collateralAmount == 0) {
            vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
            vault.openPosition(address(WETH), collateralAmount, debtAmount);
        } else if (debtAmount == 0) {
            vm.expectRevert(ERC20Vault.ZeroLoanAmount.selector);
            vault.openPosition(address(WETH), collateralAmount, debtAmount);
        } else if (
            debtAmount >
            (vault.getCollateralValue(collateralAmount) * INITIAL_LTV) / 100
        ) {
            vm.expectRevert(ERC20Vault.LoanExceedsLTVLimit.selector);
            vault.openPosition(address(WETH), collateralAmount, debtAmount);
        } else if (address(WETH) != address(vault.collateralToken())) {
            vm.expectRevert(ERC20Vault.InvalidCollateralToken.selector);
            vault.openPosition(address(shezUSD), collateralAmount, debtAmount);
        }
        vm.stopPrank();
    }

    function handler_addCollateral(
        uint256 positionId,
        uint256 additionalAmount
    ) public virtual {
        vm.startPrank(user1);
        additionalAmount = bound(additionalAmount, 0, 1e24); // 0 to 1e24 (allow zero)
        uint256 nextId = vault.nextPositionId();
        if (nextId > 1) {
            positionId = bound(positionId, 1, nextId - 1);

            // Test success path
            (address owner, uint256 posCollateral, ) = vault.getPosition(
                positionId
            );
            if (
                additionalAmount > 0 &&
                posCollateral > 0 &&
                WETH.balanceOf(user1) >= additionalAmount
            ) {
                WETH.approve(address(vault), additionalAmount);
                try vault.addCollateral(positionId, additionalAmount) {
                    addedCollateral[positionId] += additionalAmount;
                } catch {}
            }
            // Test revert paths
            else if (additionalAmount == 0) {
                vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
                vault.addCollateral(positionId, additionalAmount);
            } else if (owner != user1) {
                vm.expectRevert(ERC20Vault.NotPositionOwner.selector);
                vault.addCollateral(positionId, additionalAmount);
            } else if (WETH.balanceOf(user1) < additionalAmount) {
                vm.mockCall(
                    address(WETH),
                    abi.encodeWithSelector(WETH.transferFrom.selector),
                    abi.encode(false)
                );
                vm.expectRevert(ERC20Vault.CollateralTransferFailed.selector);
                vault.addCollateral(positionId, additionalAmount);
            }
        }
        vm.stopPrank();
    }

    function handler_withdrawCollateral(
        uint256 positionId,
        uint256 withdrawAmount
    ) public virtual {
        vm.startPrank(user1);
        uint256 nextId = vault.nextPositionId();
        if (nextId > 1) {
            positionId = bound(positionId, 1, nextId - 1);
            (address owner, uint256 posCollateral, uint256 posDebt) = vault
                .getPosition(positionId);

            // Test success path
            if (
                withdrawAmount > 0 &&
                withdrawAmount <= posCollateral &&
                posDebt == 0 &&
                WETH.balanceOf(address(vault)) >= withdrawAmount
            ) {
                try vault.withdrawCollateral(positionId, withdrawAmount) {
                    withdrawnCollateral[positionId] += withdrawAmount;
                } catch {}
            }
            // Test revert paths
            else if (withdrawAmount == 0) {
                vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
                vault.withdrawCollateral(positionId, withdrawAmount);
            } else if (withdrawAmount > posCollateral) {
                vm.expectRevert(ERC20Vault.InsufficientCollateral.selector);
                vault.withdrawCollateral(positionId, withdrawAmount);
            } else if (posDebt > 0) {
                // Calculate minimum required collateral based on current health
                uint256 collateralValue = vault.getCollateralValue(
                    posCollateral - withdrawAmount
                );
                uint256 loanValue = vault.getLoanValue(posDebt);
                uint256 minRequiredValue = (loanValue * 100) / INITIAL_LTV;
                if (collateralValue < minRequiredValue) {
                    vm.expectRevert(
                        ERC20Vault
                            .InsufficientCollateralAfterWithdrawal
                            .selector
                    );
                    vault.withdrawCollateral(positionId, withdrawAmount);
                }
            } else if (owner != user1) {
                vm.expectRevert(ERC20Vault.NotPositionOwner.selector);
                vault.withdrawCollateral(positionId, withdrawAmount);
            }
            //  else {
            //     vm.mockCall(
            //         address(WETH),
            //         abi.encodeWithSelector(WETH.transfer.selector),
            //         abi.encode(false)
            //     );
            //     vm.expectRevert(ERC20Vault.CollateralWithdrawalFailed.selector);
            //     vault.withdrawCollateral(positionId, withdrawAmount);
            // }
        }
        vm.stopPrank();
    }

    function handler_repayDebt(
        uint256 positionId,
        uint256 repayAmount
    ) public virtual {
        vm.startPrank(user1);
        uint256 nextId = vault.nextPositionId();
        if (nextId > 1) {
            positionId = bound(positionId, 1, nextId - 1);
            (address owner, , uint256 posDebt) = vault.getPosition(positionId);

            // Test success path
            if (
                repayAmount > 0 &&
                repayAmount <= posDebt &&
                shezUSD.balanceOf(user1) >= repayAmount
            ) {
                shezUSD.approve(address(vault), repayAmount);
                try vault.repayDebt(positionId, repayAmount) {
                    repaidDebt[positionId] += repayAmount;
                } catch {}
            }
            // Test revert paths
            else if (repayAmount == 0) {
                vm.expectRevert(ERC20Vault.ZeroLoanAmount.selector);
                vault.repayDebt(positionId, repayAmount);
            } else if (owner != user1) {
                vm.expectRevert(ERC20Vault.NotPositionOwner.selector);
                vault.repayDebt(positionId, repayAmount);
            } else if (repayAmount > posDebt) {
                vm.expectRevert(ERC20Vault.AmountExceedsLoan.selector);
                vault.repayDebt(positionId, repayAmount);
            } else if (shezUSD.balanceOf(user1) < repayAmount) {
                vm.mockCall(
                    address(shezUSD),
                    abi.encodeWithSelector(shezUSD.burn.selector),
                    abi.encode(false)
                );
                vm.expectRevert(); // Custom revert from burn failure
                vault.repayDebt(positionId, repayAmount);
            }
        }
        vm.stopPrank();
    }

    function handler_updatePriceFeed(
        uint256 priceFeedIndex,
        uint256 newPrice
    ) public {
        vm.startPrank(deployer); // Assume only deployer can update price feeds
        newPrice = bound(newPrice, 1 * 10 ** 8, 1000 * 10 ** 8); // Reasonable price range (e.g., $1 to $1000 with 8 decimals)

        // Select the price feed based on the index (0 for wethPriceFeed, 1 for shezUSDPriceFeed)
        address priceFeed;
        if (priceFeedIndex % 2 == 0) {
            priceFeed = address(wethPriceFeed);
        } else {
            priceFeed = address(shezUSDPriceFeed);
        }

        try MockPriceFeed(priceFeed).setPrice(int256(newPrice)) {
            lastPriceUpdate[priceFeed] = newPrice; // Update last known price
        } catch {}
        vm.stopPrank();
    }

    function handler_collectInterest(
        uint256 positionId,
        uint256 blocksToAdvance
    ) public {
        blocksToAdvance = bound(blocksToAdvance, 0, 10000); // Limit block advancement
        vm.roll(block.number + blocksToAdvance); // Advance past periodBlocks

        uint256 nextId = vault.nextPositionId();
        if (nextId > 1) {
            positionId = bound(positionId, 1, nextId - 1);
            (, , uint256 debtAmount) = vault.getPosition(positionId);

            uint256 interestDue = interestCollector.calculateInterestDue(
                address(vault),
                positionId,
                debtAmount
            );
            vm.prank(address(vault));
            try
                interestCollector.collectInterest(
                    address(vault),
                    address(shezUSD),
                    positionId,
                    debtAmount
                )
            {
                interestAccrued[positionId] += interestDue;
            } catch {}
        }
    }

    // ================================================ //
    // ================== TEST CASES ================== //
    // ================================================ //

    // function invariant_PositionDataMatchesBalances() public view {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);
    //     uint256 totalCollateral;
    //     uint256 totalDebt;
    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         (, uint256 posCollateral, uint256 posDebt) = vault.getPosition(
    //             posIds[i]
    //         );
    //         totalCollateral += posCollateral;
    //         totalDebt += posDebt;
    //     }
    //     assertEq(vault.getCollateralBalance(user1), totalCollateral);
    //     assertEq(vault.getLoanBalance(user1), totalDebt);
    // }

    // function invariant_LTVLimitRespected() public view {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);
    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, , uint256 debtAmount) = vault.getPosition(positionId);
    //         if (debtAmount > 0) {
    //             // Check LTV at the time of position creation
    //             uint256 ltvAtCreationForPos = ltvAtCreation[positionId];
    //             assertLe(
    //                 ltvAtCreationForPos,
    //                 INITIAL_LTV,
    //                 "LTV at creation exceeds limit"
    //             );
    //         }
    //     }
    // }

    // function invariant_CollateralAdditionsAccurate() public view {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);
    //     uint256 totalCollateralExpected;

    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, uint256 posCollateral, ) = vault.getPosition(positionId);
    //         uint256 expectedCollateral = initialCollateral[positionId] +
    //             addedCollateral[positionId] -
    //             withdrawnCollateral[positionId]; // Subtract withdrawals
    //         assertEq(
    //             posCollateral,
    //             expectedCollateral,
    //             "Position collateral mismatch"
    //         );
    //         totalCollateralExpected += expectedCollateral;
    //     }

    //     assertEq(
    //         vault.getCollateralBalance(user1),
    //         totalCollateralExpected,
    //         "Total collateral balance mismatch"
    //     );
    // }

    // function invariant_CollateralWithdrawalsAccurate() public view {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);
    //     uint256 totalCollateralInVault;
    //     uint256 totalWithdrawn;

    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, uint256 posCollateral, ) = vault.getPosition(positionId);
    //         totalCollateralInVault += posCollateral;
    //         totalWithdrawn += withdrawnCollateral[positionId];
    //     }

    //     uint256 totalDeposited = vault.getCollateralBalance(user1) +
    //         totalWithdrawn;
    //     uint256 expectedWETHBalance = initialWETHBalance -
    //         totalDeposited +
    //         totalWithdrawn;

    //     assertEq(
    //         WETH.balanceOf(user1),
    //         expectedWETHBalance,
    //         "WETH balance mismatch"
    //     );
    //     assertEq(
    //         vault.getCollateralBalance(user1),
    //         totalCollateralInVault,
    //         "Vault collateral mismatch"
    //     );
    // }

    // function invariant_DebtRepaymentsAccurate() public view {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);
    //     uint256 totalDebtExpected;

    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, , uint256 posDebt) = vault.getPosition(positionId);
    //         uint256 expectedDebt = initialDebt[positionId] -
    //             repaidDebt[positionId];
    //         assertEq(posDebt, expectedDebt, "Position debt mismatch");
    //         totalDebtExpected += expectedDebt;
    //     }

    //     assertEq(
    //         vault.getLoanBalance(user1),
    //         totalDebtExpected,
    //         "Total debt balance mismatch"
    //     );
    //     assertEq(
    //         shezUSD.balanceOf(user1),
    //         totalDebtExpected,
    //         "shezUSD balance mismatch"
    //     );
    // }

    function invariant_HealthRatioCorrect() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 collateralAmount, uint256 debtAmount) = vault
                .getPosition(positionId);
            uint256 health = vault.getPositionHealth(positionId);

            if (debtAmount == 0) {
                assertEq(
                    health,
                    type(uint256).max,
                    "Health should be infinity for zero debt"
                );
            } else {
                uint256 collateralValue = vault.getCollateralValue(
                    collateralAmount
                );
                uint256 loanValue = vault.getLoanValue(debtAmount);
                uint256 expectedHealth = (collateralValue * 1 ether) /
                    loanValue; // Scaled to match vault precision
                assertApproxEqAbs(
                    health,
                    expectedHealth,
                    1e12,
                    "Health ratio mismatch"
                ); // Allow small precision errors
            }
        }

        // Check health for non-existent positions
        uint256 nextId = vault.nextPositionId();
        if (nextId > 0) {
            uint256 nonExistentId = nextId;
            uint256 healthNonExistent = vault.getPositionHealth(nonExistentId);
            assertEq(
                healthNonExistent,
                type(uint256).max,
                "Health should be infinity for non-existent position"
            );
        }
    }

    function invariant_HealthReflectsPriceChanges() public {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 collateralAmount, uint256 debtAmount) = vault
                .getPosition(positionId);
            if (collateralAmount > 0 && debtAmount > 0) {
                uint256 health = vault.getPositionHealth(positionId);
                uint256 collateralValue = vault.getCollateralValue(
                    collateralAmount
                );
                uint256 loanValue = vault.getLoanValue(debtAmount);
                uint256 expectedHealth = (collateralValue * 1 ether) /
                    loanValue;

                // Verify health reflects current price
                assertApproxEqAbs(
                    health,
                    expectedHealth,
                    1e12,
                    "Health does not reflect current price"
                );

                // Check withdrawal revert when health is insufficient
                uint256 minCollateralValue = (loanValue * 100) / INITIAL_LTV;
                if (collateralValue <= minCollateralValue) {
                    vm.expectRevert();
                    vault.withdrawCollateral(positionId, 1); // Attempt to withdraw 1 wei
                }
            }
        }
    }

    // function invariant_FullDebtRepayment() public view {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);
    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, uint256 posCollateral, uint256 posDebt) = vault.getPosition(
    //             positionId
    //         );

    //         // Check if the debt has been fully repaid
    //         if (
    //             initialDebt[positionId] > 0 &&
    //             repaidDebt[positionId] >= initialDebt[positionId]
    //         ) {
    //             // Debt should be 0
    //             assertEq(posDebt, 0, "Debt should be 0 after full repayment");

    //             // Position health should be infinite
    //             assertEq(
    //                 vault.getPositionHealth(positionId),
    //                 type(uint256).max,
    //                 "Health should be infinite after full debt repayment"
    //             );

    //             // If all collateral has been withdrawn, collateral should be 0
    //             uint256 expectedCollateral = initialCollateral[positionId] +
    //                 addedCollateral[positionId] -
    //                 withdrawnCollateral[positionId];
    //             assertEq(
    //                 posCollateral,
    //                 expectedCollateral,
    //                 "Collateral mismatch after full debt repayment"
    //             );

    //             // If collateral is fully withdrawn, it should be 0
    //             if (
    //                 withdrawnCollateral[positionId] >=
    //                 (initialCollateral[positionId] +
    //                     addedCollateral[positionId])
    //             ) {
    //                 assertEq(
    //                     posCollateral,
    //                     0,
    //                     "Collateral should be 0 after full withdrawal"
    //                 );
    //             }
    //         }
    //     }

    //     // Check total loan balance reflects fully repaid positions
    //     uint256 totalDebtExpected;
    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         uint256 expectedDebt = initialDebt[positionId] >
    //             repaidDebt[positionId]
    //             ? initialDebt[positionId] - repaidDebt[positionId]
    //             : 0;
    //         totalDebtExpected += expectedDebt;
    //     }
    //     assertEq(
    //         vault.getLoanBalance(user1),
    //         totalDebtExpected,
    //         "Loan balance mismatch after full debt repayment"
    //     );
    // }

    function invariant_BadDebtCannotPersist() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);

        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 collateralAmount, uint256 debtAmount) = vault
                .getPosition(positionId);

            if (debtAmount > 0 && collateralAmount > 0) {
                uint256 health = vault.getPositionHealth(positionId);
                bool liquidatable = vault.isLiquidatable(positionId);

                // Calculate expected liquidation threshold
                uint256 liquidationThresholdValue = (vault.ltvRatio() *
                    vault.liquidationThreshold()) / 100;
                uint256 requiredHealth = (vault.PRECISION() *
                    liquidationThresholdValue) / 100;

                if (health >= requiredHealth) {
                    assertFalse(
                        liquidatable,
                        "Position should NOT be liquidatable but is!"
                    );
                } else {
                    assertTrue(
                        liquidatable,
                        "Position should be liquidatable but is not!"
                    );
                }
            }
        }
    }

    // function invariant_ZeroCollateralButDebtExists() public {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);

    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, uint256 collateralAmount, uint256 debtAmount) = vault
    //             .getPosition(positionId);

    //         // If debt exists but no collateral, it should always be liquidatable
    //         if (debtAmount > 0 && collateralAmount == 0) {
    //             bool liquidatable = vault.isLiquidatable(positionId);
    //             assertTrue(
    //                 liquidatable,
    //                 "Position with zero collateral but debt should be liquidatable!"
    //             );

    //             // Ensure that liquidating actually removes the debt
    //             vm.prank(user2); // Simulate a liquidator
    //             vault.liquidatePosition(positionId);

    //             // Verify the position no longer exists
    //             (, uint256 newCollateral, uint256 newDebt) = vault.getPosition(
    //                 positionId
    //             );
    //             assertEq(
    //                 newCollateral,
    //                 0,
    //                 "Collateral should remain 0 after liquidation"
    //             );
    //             assertEq(newDebt, 0, "Debt should be 0 after liquidation");
    //         }
    //     }
    // }

    // function invariant_DebtGreaterThanCollateralStillLiquidatable() public {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);

    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, uint256 collateralAmount, ) = vault.getPosition(positionId);

    //         // Fetch critical values
    //         uint256 health = vault.getPositionHealth(positionId);
    //         bool liquidatable = vault.isLiquidatable(positionId);

    //         // Compute the expected liquidation threshold
    //         uint256 liquidationThresholdValue = (vault.ltvRatio() *
    //             vault.liquidationThreshold()) / 100;
    //         uint256 requiredHealth = (vault.PRECISION() *
    //             liquidationThresholdValue) / 100;

    //         if (health < requiredHealth) {
    //             assertTrue(
    //                 liquidatable,
    //                 "Position should be liquidatable but is not!"
    //             );
    //         } else {
    //             assertFalse(
    //                 liquidatable,
    //                 "Position should NOT be liquidatable but is!"
    //             );
    //         }

    //         if (liquidatable) {
    //             uint256 liquidatorReward = (collateralAmount *
    //                 vault.liquidatorReward()) / 100;
    //             uint256 penalty = (collateralAmount * vault.penaltyRate()) /
    //                 100;
    //             uint256 remainingCollateral = collateralAmount -
    //                 liquidatorReward -
    //                 penalty;

    //             uint256 borrowerBalanceBefore = WETH.balanceOf(user1);
    //             uint256 liquidatorBalanceBefore = WETH.balanceOf(user3);

    //             vm.prank(user3);
    //             vault.liquidatePosition(positionId);

    //             // Verify calculations remain correct
    //             (, uint256 newCollateral, uint256 newDebt) = vault.getPosition(
    //                 positionId
    //             );
    //             assertEq(
    //                 newCollateral,
    //                 0,
    //                 "Collateral should be 0 after liquidation"
    //             );
    //             assertEq(newDebt, 0, "Debt should be 0 after liquidation");

    //             // Ensure liquidator received the correct reward
    //             uint256 liquidatorBalanceAfter = WETH.balanceOf(user3);
    //             assertEq(
    //                 liquidatorBalanceAfter - liquidatorBalanceBefore,
    //                 liquidatorReward,
    //                 "Liquidator reward mismatch"
    //             );

    //             // Ensure borrower got any remaining collateral (if applicable)
    //             uint256 borrowerBalanceAfter = WETH.balanceOf(user1);
    //             assertEq(
    //                 borrowerBalanceAfter - borrowerBalanceBefore,
    //                 remainingCollateral,
    //                 "Borrower remaining collateral mismatch"
    //             );
    //         }
    //     }
    // }

    // function invariant_CannotLiquidateIfHealthyOrRepaid() public {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);

    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (
    //             address owner,
    //             uint256 collateralAmount,
    //             uint256 debtAmount
    //         ) = vault.getPosition(positionId);

    //         // Ensure we are testing a position owned by user1
    //         if (owner != user1) continue;

    //         bool wasLiquidatable = vault.isLiquidatable(positionId);

    //         // Scenario 1: Fully repaid position (only if debt > 0)
    //         if (debtAmount > 0) {
    //             shezUSD.approve(address(vault), debtAmount);
    //             vm.prank(user1); // Ensure correct sender
    //             vault.repayDebt(positionId, debtAmount);
    //         }

    //         // Scenario 2: Price recovers before liquidation
    //         wethPriceFeed.setPrice(1000 * 10 ** 8); // Massive price recovery

    //         // Scenario 3: Rapid price fluctuations during liquidation
    //         wethPriceFeed.setPrice(500 * 10 ** 8); // Then drops again

    //         bool isStillLiquidatable = vault.isLiquidatable(positionId);

    //         console.log("==== Debug Info ====");
    //         console.log("Position ID:", positionId);
    //         console.log("Initial Liquidatable:", wasLiquidatable);
    //         console.log("Debt Amount Before Repayment:", debtAmount);
    //         console.log("Collateral Amount:", collateralAmount);
    //         console.log("After Recovery Liquidatable:", isStillLiquidatable);
    //         console.log("=====================");

    //         // Assert that a repaid or recovered position cannot be liquidated
    //         assertFalse(
    //             isStillLiquidatable,
    //             "Position should NOT be liquidatable after repayment or recovery!"
    //         );
    //     }
    // }

    // function invariant_LiquidatorCannotReceiveMoreThanCollateral() public {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);

    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, uint256 collateralAmount, uint256 debtAmount) = vault
    //             .getPosition(positionId);

    //         if (debtAmount == 0 || collateralAmount == 0) continue;

    //         // Set extreme values that might trigger precision issues
    //         wethPriceFeed.setPrice(1 * 10 ** 6); // $0.01 per collateral token (massive drop)

    //         bool liquidatable = vault.isLiquidatable(positionId);
    //         if (!liquidatable) continue;

    //         uint256 liquidatorBalanceBefore = WETH.balanceOf(user3);

    //         vm.prank(user3);
    //         vault.liquidatePosition(positionId);

    //         uint256 liquidatorBalanceAfter = WETH.balanceOf(user3);
    //         uint256 liquidatorReward = liquidatorBalanceAfter -
    //             liquidatorBalanceBefore;

    //         assertLe(
    //             liquidatorReward,
    //             collateralAmount,
    //             "Liquidator received more than total collateral!"
    //         );
    //     }
    // }

    // function invariant_LiquidationFailsOnTransferFailure() public {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);

    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, uint256 collateralAmount, uint256 debtAmount) = vault
    //             .getPosition(positionId);

    //         if (debtAmount == 0 || collateralAmount == 0) continue;

    //         wethPriceFeed.setPrice(1 * 10 ** 8); // Price drops drastically

    //         bool liquidatable = vault.isLiquidatable(positionId);
    //         if (!liquidatable) continue;

    //         // Simulate token transfer failure (e.g., ERC20 transfer returning false)
    //         vm.mockCall(
    //             address(WETH),
    //             abi.encodeWithSelector(WETH.transfer.selector),
    //             abi.encode(false)
    //         );

    //         vm.prank(user3);
    //         vm.expectRevert(ERC20Vault.LiquidationFailed.selector);
    //         vault.liquidatePosition(positionId);
    //     }
    // }

    // function invariant_InterestCollectionConsistency() public {
    //     uint256[] memory posIds = vault.getUserPositionIds(user1);
    //     uint256 totalInterestAccrued;

    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         uint256 positionId = posIds[i];
    //         (, uint256 collateralAmount, uint256 debtAmount) = vault
    //             .getPosition(positionId);
    //         uint256 initialDebtForPos = initialDebt[positionId];
    //         uint256 repaidDebtForPos = repaidDebt[positionId];
    //         uint256 expectedDebtWithoutInterest = initialDebtForPos >
    //             repaidDebtForPos
    //             ? initialDebtForPos - repaidDebtForPos
    //             : 0;
    //         uint256 interestDue = interestCollector.calculateInterestDue(
    //             address(vault),
    //             positionId,
    //             debtAmount
    //         );

    //         // Case 1: Interest collection with zero debt
    //         if (initialDebtForPos == 0 && repaidDebtForPos == 0) {
    //             assertEq(
    //                 interestDue,
    //                 0,
    //                 "Interest should be zero for positions with no initial debt"
    //             );
    //             assertEq(
    //                 debtAmount,
    //                 0,
    //                 "Debt should remain zero with no initial debt"
    //             );
    //         }

    //         // Case 2: Interest increases debt beyond LTV limit
    //         if (debtAmount > 0 && collateralAmount > 0) {
    //             uint256 collateralValue = vault.getCollateralValue(
    //                 collateralAmount
    //             );
    //             uint256 loanValue = vault.getLoanValue(debtAmount);
    //             uint256 currentLTV = (loanValue * 100) / collateralValue;

    //             if (currentLTV > INITIAL_LTV) {
    //                 assertTrue(
    //                     vault.isLiquidatable(positionId),
    //                     "Position should be liquidatable when interest pushes debt beyond LTV limit"
    //                 );
    //             }

    //             // Verify debt includes accrued interest
    //             uint256 expectedDebtWithInterest = expectedDebtWithoutInterest +
    //                 interestAccrued[positionId];
    //             assertApproxEqAbs(
    //                 debtAmount,
    //                 expectedDebtWithInterest,
    //                 1e12,
    //                 "Debt should reflect accrued interest"
    //             );
    //             totalInterestAccrued += interestAccrued[positionId];
    //         }

    //         // Case 3: Interest collection failure mid-transaction
    //         // Simulate failure by mocking a revert in collectInterest
    //         vm.mockCallRevert(
    //             address(interestCollector),
    //             abi.encodeWithSelector(
    //                 interestCollector.collectInterest.selector
    //             ),
    //             "Mock interest collection failure"
    //         );
    //         vm.prank(user1);
    //         try vault.repayDebt(positionId, 1) {
    //             // If repay succeeds despite interest failure, debt should still decrease
    //             (, , uint256 debt) = vault.getPosition(positionId);
    //             assertEq(
    //                 debt,
    //                 debtAmount - 1,
    //                 "Debt should decrease even if interest collection fails"
    //             );
    //         } catch {
    //             // If repay fails, debt should remain unchanged
    //             (, , uint256 debt) = vault.getPosition(positionId);
    //             assertEq(
    //                 debt,
    //                 debtAmount,
    //                 "Debt should not change if repay fails due to interest collection failure"
    //             );
    //         }
    //         vm.clearMockedCalls(); // Reset mocks
    //     }

    //     // Verify totalDebt reflects all accrued interest
    //     uint256 expectedTotalDebt = vault.totalDebt() - totalInterestAccrued;
    //     uint256 totalDebtWithoutInterest;
    //     for (uint256 i = 0; i < posIds.length; i++) {
    //         (, , uint256 posDebt) = vault.getPosition(posIds[i]);
    //         totalDebtWithoutInterest += posDebt - interestAccrued[posIds[i]];
    //     }
    //     assertApproxEqAbs(
    //         expectedTotalDebt,
    //         totalDebtWithoutInterest,
    //         1e12,
    //         "totalDebt should match sum of position debts minus interest"
    //     );
    // }
}
