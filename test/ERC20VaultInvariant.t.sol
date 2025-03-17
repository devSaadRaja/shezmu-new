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
    uint256 constant LIQUIDATION_THRESHOLD = 110; // 110% of INITIAL_LTV
    uint256 constant LIQUIDATOR_REWARD = 50; // 50%

    mapping(uint256 => uint256) public initialCollateral; // positionId => initial amount
    mapping(uint256 => uint256) public addedCollateral; // positionId => total added
    mapping(uint256 => uint256) public withdrawnCollateral; // positionId => total withdrawn
    mapping(uint256 => uint256) public initialDebt; // positionId => initial debt
    mapping(uint256 => uint256) public repaidDebt; // positionId => total repaid
    mapping(address => uint256) public lastPriceUpdate; // Token address => last price
    mapping(uint256 => uint256) public ltvAtCreation; // positionId => LTV at creation
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
            selectors: new bytes4[](5)
        });
        selectorTest.selectors[0] = this.handler_openPosition.selector;
        selectorTest.selectors[1] = this.handler_addCollateral.selector;
        selectorTest.selectors[2] = this.handler_withdrawCollateral.selector;
        selectorTest.selectors[3] = this.handler_repayDebt.selector;
        selectorTest.selectors[4] = this.handler_updatePriceFeed.selector;
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
            uint256 positionId = posIds[i];
            (, , uint256 debtAmount) = vault.getPosition(positionId);
            if (debtAmount > 0) {
                // Check LTV at the time of position creation
                uint256 ltvAtCreationForPos = ltvAtCreation[positionId];
                assertLe(
                    ltvAtCreationForPos,
                    INITIAL_LTV,
                    "LTV at creation exceeds limit"
                );
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
                addedCollateral[positionId] -
                withdrawnCollateral[positionId]; // Subtract withdrawals
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

    function invariant_CollateralWithdrawalsAccurate() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        uint256 totalCollateralInVault;
        uint256 totalWithdrawn;

        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 posCollateral, ) = vault.getPosition(positionId);
            totalCollateralInVault += posCollateral;
            totalWithdrawn += withdrawnCollateral[positionId];
        }

        uint256 totalDeposited = vault.getCollateralBalance(user1) +
            totalWithdrawn;
        uint256 expectedWETHBalance = initialWETHBalance -
            totalDeposited +
            totalWithdrawn;

        assertEq(
            WETH.balanceOf(user1),
            expectedWETHBalance,
            "WETH balance mismatch"
        );
        assertEq(
            vault.getCollateralBalance(user1),
            totalCollateralInVault,
            "Vault collateral mismatch"
        );
    }

    function invariant_DebtRepaymentsAccurate() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        uint256 totalDebtExpected;

        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, , uint256 posDebt) = vault.getPosition(positionId);
            uint256 expectedDebt = initialDebt[positionId] -
                repaidDebt[positionId];
            assertEq(posDebt, expectedDebt, "Position debt mismatch");
            totalDebtExpected += expectedDebt;
        }

        assertEq(
            vault.getLoanBalance(user1),
            totalDebtExpected,
            "Total debt balance mismatch"
        );
        assertEq(
            shezUSD.balanceOf(user1),
            totalDebtExpected,
            "shezUSD balance mismatch"
        );
    }

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

    function invariant_FullDebtRepayment() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 posCollateral, uint256 posDebt) = vault.getPosition(
                positionId
            );

            // Check if the debt has been fully repaid
            if (
                initialDebt[positionId] > 0 &&
                repaidDebt[positionId] >= initialDebt[positionId]
            ) {
                // Debt should be 0
                assertEq(posDebt, 0, "Debt should be 0 after full repayment");

                // Position health should be infinite
                assertEq(
                    vault.getPositionHealth(positionId),
                    type(uint256).max,
                    "Health should be infinite after full debt repayment"
                );

                // If all collateral has been withdrawn, collateral should be 0
                uint256 expectedCollateral = initialCollateral[positionId] +
                    addedCollateral[positionId] -
                    withdrawnCollateral[positionId];
                assertEq(
                    posCollateral,
                    expectedCollateral,
                    "Collateral mismatch after full debt repayment"
                );

                // If collateral is fully withdrawn, it should be 0
                if (
                    withdrawnCollateral[positionId] >=
                    (initialCollateral[positionId] +
                        addedCollateral[positionId])
                ) {
                    assertEq(
                        posCollateral,
                        0,
                        "Collateral should be 0 after full withdrawal"
                    );
                }
            }
        }

        // Check total loan balance reflects fully repaid positions
        uint256 totalDebtExpected;
        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            uint256 expectedDebt = initialDebt[positionId] >
                repaidDebt[positionId]
                ? initialDebt[positionId] - repaidDebt[positionId]
                : 0;
            totalDebtExpected += expectedDebt;
        }
        assertEq(
            vault.getLoanBalance(user1),
            totalDebtExpected,
            "Loan balance mismatch after full debt repayment"
        );
    }
}
