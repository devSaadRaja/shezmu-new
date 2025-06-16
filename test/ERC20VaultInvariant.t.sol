// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IPool} from "../src/interfaces/aave-v3/IPool.sol";
import {IRewardsController} from "../src/interfaces/aave-v3/IRewardsController.sol";

import {EasyPosm} from "./utils/EasyPosm.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import "../src/ERC20Vault.sol";
import "../src/InterestCollector.sol";
import "../src/mock/MockERC20.sol";
import "../src/mock/MockERC20Mintable.sol";
import "../src/mock/MockPriceFeed.sol";
import "../src/strategies/AaveStrategy.sol";

import "../src/interfaces/IPriceFeed.sol";

contract ERC20VaultInvariantTest is Test {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    //* ETHEREUM ADDRESSES *//
    IPool POOL_V3 = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IRewardsController INCENTIVES_V3 =
        IRewardsController(0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb);

    // IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // eth mainnet

    IERC20 WETH = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F); // USDS (USDS Stablecoin)
    IERC20 aToken = IERC20(0x32a6268f9Ba3642Dda7892aDd74f1D34469A4259); // aEthUSDS (Aave Ethereum USDS)
    IERC20 rewardToken = IERC20(0x32a6268f9Ba3642Dda7892aDd74f1D34469A4259); // aEthUSDS (Aave Ethereum USDS)

    ERC20Vault vault;
    // IERC20 WETH;
    // MockERC20 WETH;
    MockERC20Mintable shezUSD;
    AaveStrategy aaveStrategy;

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
    uint256 constant LIQUIDATION_THRESHOLD = 90; // 90% of INITIAL_LTV
    uint256 constant LIQUIDATOR_REWARD = 50; // 50%
    uint256 constant INTEREST_RATE = 500; // 5% annual interest in basis points

    mapping(uint256 => uint256) public initialCollateral; // positionId => initial amount
    mapping(uint256 => uint256) public addedCollateral; // positionId => total added
    mapping(uint256 => uint256) public withdrawnCollateral; // positionId => total withdrawn
    mapping(uint256 => uint256) public initialDebt; // positionId => initial debt
    mapping(uint256 => uint256) public repaidDebt; // positionId => total repaid
    mapping(uint256 => bool) public wasLiquidated; // positionId => true if liquidated
    mapping(uint256 => uint256) public preLiquidationCollateral; // positionId => collateral amount before liquidation
    mapping(uint256 => uint256) public liquidatedCollateralReturned; // positionId => collateral returned to owner during liquidation
    mapping(uint256 => uint256) public interestAccrued; // positionId => interest collected
    uint256 public totalInterestAccrued; // Total interest accrued across all positions
    uint256 public totalInterestMintedToTreasury; // Total interest minted to treasury
    uint256 public initialWETHBalance; // User1's initial WETH balance
    uint256 public totalPenaltiesAcrossAllTime; // Total penalties from liquidations
    uint256 public totalSoulBoundFees; // Total soul-bound fees paid to treasury
    mapping(uint256 => bool) public interestOptOutAtPosition; // positionId => interestOptOut

    // =========================================== //
    // ================== SETUP ================== //
    // =========================================== //

    function setUp() public {
        vm.startPrank(deployer);

        // WETH = new MockERC20("Collateral Token", "COL");

        deal(address(WETH), deployer, 1_000_000_000 ether);

        shezUSD = new MockERC20Mintable("Shez USD", "shezUSD");

        // wethPriceFeed = IPriceFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        wethPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8); // $200
        shezUSDPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8); // $200

        aaveStrategy = new AaveStrategy();
        aaveStrategy.initialize(
            treasury,
            address(WETH),
            address(aToken),
            address(rewardToken),
            address(POOL_V3),
            address(INCENTIVES_V3)
        );

        vault = new ERC20Vault(
            address(WETH),
            address(shezUSD),
            INITIAL_LTV,
            LIQUIDATION_THRESHOLD,
            LIQUIDATOR_REWARD,
            address(wethPriceFeed),
            address(shezUSDPriceFeed),
            treasury,
            address(aaveStrategy)
        );
        interestCollector = new InterestCollector(treasury);

        vault.setInterestCollector(address(interestCollector));
        vault.toggleInterestCollection(true);

        interestCollector.registerVault(address(vault), INTEREST_RATE);

        WETH.transfer(user1, 2_000_000 ether);
        WETH.transfer(user2, 2_000_000 ether);

        shezUSD.grantRole(keccak256("MINTER_ROLE"), address(vault));
        shezUSD.grantRole(keccak256("BURNER_ROLE"), address(vault));

        aaveStrategy.setVault(deployer);
        WETH.approve(address(aaveStrategy), 1);
        aaveStrategy.deposit(0, 1);
        aaveStrategy.setUserUseReserveAsCollateral();

        aaveStrategy.setVault(address(vault));

        vm.stopPrank();

        vm.prank(deployer);

        // Record initial WETH balance for user1
        initialWETHBalance = WETH.balanceOf(user1); // 2_000_000 ether;

        // Explicitly target this contract for invariant testing
        targetContract(address(this));
        // targetContract(address(vault));

        // Specify the openPosition function as a target selector
        FuzzSelector memory selectorTest = FuzzSelector({
            addr: address(this),
            selectors: new bytes4[](10)
        });
        selectorTest.selectors[0] = this.handler_openPosition.selector;
        selectorTest.selectors[1] = this.handler_addCollateral.selector;
        selectorTest.selectors[2] = this.handler_withdrawCollateral.selector;
        selectorTest.selectors[3] = this.handler_repayDebt.selector;
        selectorTest.selectors[4] = this.handler_updatePriceFeed.selector;
        selectorTest.selectors[5] = this.handler_liquidatePosition.selector;
        selectorTest.selectors[6] = this.handler_collectInterest.selector;
        selectorTest.selectors[7] = this.handler_withdrawInterest.selector;
        // selectorTest.selectors[8] = this.handler_leveragePosition.selector;
        selectorTest.selectors[8] = this.handler_borrow.selector;
        selectorTest.selectors[9] = this
            .handler_batchLiquidatePositions
            .selector;
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

    function _collectInterest(uint256 positionId, uint256 debtAmount) internal {
        if (
            !interestOptOutAtPosition[positionId] &&
            address(vault.interestCollector()) != address(0) &&
            vault.interestCollectionEnabled()
        ) {
            if (debtAmount > 0) {
                uint256 interestDue = interestCollector.calculateInterestDue(
                    address(vault),
                    positionId,
                    debtAmount
                );
                if (
                    interestDue > 0 &&
                    interestCollector.isCollectionReady(
                        address(vault),
                        positionId
                    )
                ) {
                    interestAccrued[positionId] += interestDue;
                }
            }
        }
    }

    function handler_openPosition(
        uint256 collateralAmount,
        uint256 debtAmount,
        bool interestOptOut,
        uint256 leverage
    ) public {
        vm.startPrank(user1);
        collateralAmount = bound(collateralAmount, 0, 1e24); // 0 to 1e24 (allow zero)
        debtAmount = bound(debtAmount, 0, 1e24); // 0 to 1e24 (allow zero)
        leverage = bound(leverage, 1, 10);

        vault.setInterestOptOut(interestOptOut);

        WETH.approve(address(vault), collateralAmount);

        // // Test success path
        // if (
        //     collateralAmount > 0 &&
        //     // debtAmount > 0 &&
        //     vault.getLoanValue(debtAmount) <=
        //     (vault.getCollateralValue(collateralAmount) * INITIAL_LTV) / 100
        // ) {
        try
            vault.openPosition(
                user1,
                address(WETH),
                collateralAmount,
                debtAmount,
                leverage
            )
        {
            uint256 positionId = vault.nextPositionId() - 1;

            // Adjust collateral amount for soul-bound fee if applicable
            uint256 adjustedCollateral = collateralAmount;
            if (!vault.getDoNotMint(user1)) {
                uint256 fee = (collateralAmount * vault.soulBoundFeePercent()) /
                    100;
                adjustedCollateral = collateralAmount - fee;
                totalSoulBoundFees += fee;
            }

            initialCollateral[positionId] = adjustedCollateral;
            initialDebt[positionId] = debtAmount;

            // Track interest opt-out status for this position
            interestOptOutAtPosition[positionId] = interestOptOut;
        } catch {}
        // }
        // // Test revert paths
        // else if (collateralAmount == 0) {
        //     vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
        //     vault.openPosition(address(WETH), collateralAmount, debtAmount);
        // } else if (debtAmount == 0) {
        //     vm.expectRevert(ERC20Vault.ZeroLoanAmount.selector);
        //     vault.openPosition(address(WETH), collateralAmount, debtAmount);
        // } else if (
        //     debtAmount >
        //     (vault.getCollateralValue(collateralAmount) * INITIAL_LTV) / 100
        // ) {
        //     vm.expectRevert(ERC20Vault.LoanExceedsLTVLimit.selector);
        //     vault.openPosition(address(WETH), collateralAmount, debtAmount);
        // } else if (address(WETH) != address(vault.collateralToken())) {
        //     vm.expectRevert(ERC20Vault.InvalidCollateralToken.selector);
        //     vault.openPosition(address(shezUSD), collateralAmount, debtAmount);
        // }
        vm.stopPrank();
    }

    function handler_addCollateral(
        uint256 positionId,
        uint256 additionalAmount
    ) public {
        vm.startPrank(user1);
        additionalAmount = bound(additionalAmount, 0, 1e24); // 0 to 1e24 (allow zero)
        uint256 nextId = vault.nextPositionId();
        if (nextId > 1) {
            positionId = bound(positionId, 1, nextId - 1);

            (address owner, , , , , , ) = vault.getPosition(positionId);
            if (owner != user1) {
                vm.stopPrank();
                return;
            }

            WETH.approve(address(vault), additionalAmount);

            // // Test success path
            // (address owner, uint256 posCollateral, ,,) = vault.getPosition(
            //     positionId
            // );
            // if (
            //     additionalAmount > 0 &&
            //     posCollateral > 0 &&
            //     WETH.balanceOf(user1) >= additionalAmount &&
            //     owner == user1
            // ) {
            try vault.addCollateral(positionId, additionalAmount) {
                addedCollateral[positionId] += additionalAmount;
            } catch {}
            // }
            // // Test revert paths
            // else if (additionalAmount == 0) {
            //     vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
            //     vault.addCollateral(positionId, additionalAmount);
            // } else if (owner != user1) {
            //     vm.expectRevert(ERC20Vault.NotPositionOwner.selector);
            //     vault.addCollateral(positionId, additionalAmount);
            // } else if (WETH.balanceOf(user1) < additionalAmount) {
            //     vm.mockCall(
            //         address(WETH),
            //         abi.encodeWithSelector(WETH.transferFrom.selector),
            //         abi.encode(false)
            //     );
            //     vm.expectRevert(ERC20Vault.CollateralTransferFailed.selector);
            //     vault.addCollateral(positionId, additionalAmount);
            // }
        }
        vm.stopPrank();
    }

    function handler_withdrawCollateral(
        uint256 positionId,
        uint256 withdrawAmount
    ) public {
        vm.startPrank(user1);
        uint256 nextId = vault.nextPositionId();
        if (nextId > 1) {
            positionId = bound(positionId, 1, nextId - 1);
            (
                address owner,
                uint256 posCollateral,
                uint256 posDebt,
                ,
                ,
                ,

            ) = vault.getPosition(positionId);

            // Test success path
            if (
                withdrawAmount > 0 &&
                withdrawAmount <= posCollateral &&
                // posDebt == 0 &&
                WETH.balanceOf(address(vault)) >= withdrawAmount &&
                owner == user1
            ) {
                // Simulate interest collection (since _collectInterestIfAvailable is called in withdrawCollateral)
                _collectInterest(positionId, posDebt);

                try vault.withdrawCollateral(positionId, withdrawAmount) {
                    withdrawnCollateral[positionId] += withdrawAmount;
                } catch {}
            }
            // // Test revert paths
            // else if (owner != user1) {
            //     vm.expectRevert(ERC20Vault.NotPositionOwner.selector);
            //     vault.withdrawCollateral(positionId, withdrawAmount);
            // } else if (withdrawAmount == 0) {
            //     vm.expectRevert(ERC20Vault.ZeroCollateralAmount.selector);
            //     vault.withdrawCollateral(positionId, withdrawAmount);
            // } else if (withdrawAmount > posCollateral) {
            //     vm.expectRevert(ERC20Vault.InsufficientCollateral.selector);
            //     vault.withdrawCollateral(positionId, withdrawAmount);
            // } else if (posDebt > 0) {
            //     // Calculate minimum required collateral based on current health
            //     uint256 collateralValue = vault.getCollateralValue(
            //         posCollateral - withdrawAmount
            //     );
            //     uint256 loanValue = vault.getLoanValue(posDebt);
            //     uint256 minRequiredValue = (loanValue * 100) / INITIAL_LTV;
            //     if (collateralValue < minRequiredValue) {
            //         vm.expectRevert(
            //             ERC20Vault
            //                 .InsufficientCollateralAfterWithdrawal
            //                 .selector
            //         );
            //         vault.withdrawCollateral(positionId, withdrawAmount);
            //     }
            // }
            // //  else {
            // //     vm.mockCall(
            // //         address(WETH),
            // //         abi.encodeWithSelector(WETH.transfer.selector),
            // //         abi.encode(false)
            // //     );
            // //     vm.expectRevert(ERC20Vault.CollateralWithdrawalFailed.selector);
            // //     vault.withdrawCollateral(positionId, withdrawAmount);
            // // }
        }
        vm.stopPrank();
    }

    function handler_repayDebt(uint256 positionId, uint256 repayAmount) public {
        vm.startPrank(user1);
        uint256 nextId = vault.nextPositionId();
        if (nextId > 1) {
            positionId = bound(positionId, 1, nextId - 1);
            (address owner, , uint256 posDebt, , , , ) = vault.getPosition(
                positionId
            );

            shezUSD.approve(address(vault), repayAmount);

            // Test success path
            if (
                repayAmount > 0 &&
                repayAmount <= posDebt &&
                shezUSD.balanceOf(user1) >= repayAmount &&
                owner == user1
            ) {
                // Simulate interest collection (since _collectInterestIfAvailable is called in repayDebt)
                _collectInterest(positionId, repayAmount);

                try vault.repayDebt(positionId, repayAmount) {
                    repaidDebt[positionId] += repayAmount;
                } catch {}
            }
            // // Test revert paths
            // else if (repayAmount == 0) {
            //     vm.expectRevert(ERC20Vault.ZeroLoanAmount.selector);
            //     vault.repayDebt(positionId, repayAmount);
            // } else if (owner != user1) {
            //     vm.expectRevert(ERC20Vault.NotPositionOwner.selector);
            //     vault.repayDebt(positionId, repayAmount);
            // } else if (repayAmount > posDebt) {
            //     vm.expectRevert(ERC20Vault.AmountExceedsLoan.selector);
            //     vault.repayDebt(positionId, repayAmount);
            // } else if (shezUSD.balanceOf(user1) < repayAmount) {
            //     vm.mockCall(
            //         address(shezUSD),
            //         abi.encodeWithSelector(shezUSD.burn.selector),
            //         abi.encode(false)
            //     );
            //     vm.expectRevert(); // Custom revert from burn failure
            //     vault.repayDebt(positionId, repayAmount);
            // }
        }
        vm.stopPrank();
    }

    function handler_updatePriceFeed(
        // uint256 priceFeedIndex,
        uint256 newPrice
    ) public {
        vm.startPrank(deployer); // Assume only deployer can update price feeds
        newPrice = bound(newPrice, 1 * 10 ** 8, 100 * 10 ** 8); // Reasonable price range (e.g., $1 to $1000 with 8 decimals)

        // // Select the price feed based on the index (0 for wethPriceFeed, 1 for shezUSDPriceFeed)
        // address priceFeed;
        // if (priceFeedIndex % 2 == 0) {
        //     priceFeed = address(wethPriceFeed);
        // } else {
        //     priceFeed = address(shezUSDPriceFeed);
        // }

        address priceFeed = address(wethPriceFeed);

        try MockPriceFeed(priceFeed).setPrice(int256(newPrice)) {} catch {}
        vm.stopPrank();
    }

    function handler_liquidatePosition(uint256 positionId) public {
        uint256 nextId = vault.nextPositionId();
        if (nextId > 1) {
            positionId = bound(positionId, 1, nextId - 1);

            (
                address owner,
                uint256 collateralAmount,
                uint256 debtAmount,
                ,
                ,
                ,

            ) = vault.getPosition(positionId);

            shezUSD.approve(address(vault), shezUSD.balanceOf(owner));

            if (
                owner != address(0) &&
                vault.isLiquidatable(positionId) &&
                WETH.balanceOf(address(vault)) >= collateralAmount &&
                shezUSD.balanceOf(address(owner)) >= debtAmount
            ) {
                // Simulate interest collection (since _collectInterestIfAvailable is called in liquidatePosition)
                _collectInterest(positionId, debtAmount);

                // Store the pre-liquidation collateral amount
                preLiquidationCollateral[positionId] = collateralAmount;

                vm.startPrank(user2);
                try vault.liquidatePosition(positionId) {
                    wasLiquidated[positionId] = true;

                    // Calculate the collateral returned to the owner during liquidation
                    uint256 reward = (collateralAmount * LIQUIDATOR_REWARD) /
                        100;
                    uint256 penalty = (collateralAmount * vault.penaltyRate()) /
                        100;
                    uint256 remainingCollateral = collateralAmount -
                        reward -
                        penalty;

                    totalPenaltiesAcrossAllTime += penalty; // Accumulate penalties
                    liquidatedCollateralReturned[
                        positionId
                    ] = remainingCollateral;
                } catch {}
                vm.stopPrank();
            }
        }
    }

    function handler_batchLiquidatePositions(
        uint256[] calldata positionIds
    ) public {
        uint256 nextId = vault.nextPositionId();
        if (nextId <= 1) return; // No positions exist yet

        // Prepare a list of valid, liquidatable position IDs
        uint256[] memory validIds = new uint256[](positionIds.length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = bound(positionIds[i], 1, nextId - 1);
            (
                address owner,
                uint256 collateralAmount,
                uint256 debtAmount,
                ,
                ,
                ,

            ) = vault.getPosition(positionId);

            // Only consider positions that are owned, liquidatable, and not already marked as liquidated
            if (
                owner != address(0) &&
                vault.isLiquidatable(positionId) &&
                WETH.balanceOf(address(vault)) >= collateralAmount &&
                shezUSD.balanceOf(address(owner)) >= debtAmount &&
                !wasLiquidated[positionId]
            ) {
                // Simulate interest collection
                _collectInterest(positionId, debtAmount);

                // Store pre-liquidation collateral
                preLiquidationCollateral[positionId] = collateralAmount;

                validIds[validCount] = positionId;
                validCount++;
            }
        }

        if (validCount == 0) return;

        // Prepare the array to pass to batchLiquidate
        uint256[] memory toLiquidate = new uint256[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            toLiquidate[i] = validIds[i];
        }

        vm.startPrank(user2);
        try vault.batchLiquidate(toLiquidate) {
            // Mark all as liquidated and record collateral returned
            for (uint256 i = 0; i < validCount; i++) {
                uint256 positionId = toLiquidate[i];
                wasLiquidated[positionId] = true;

                uint256 collateralAmount = preLiquidationCollateral[positionId];
                uint256 reward = (collateralAmount * LIQUIDATOR_REWARD) / 100;
                uint256 penalty = (collateralAmount * vault.penaltyRate()) /
                    100;
                uint256 remainingCollateral = collateralAmount -
                    reward -
                    penalty;

                totalPenaltiesAcrossAllTime += penalty;
                liquidatedCollateralReturned[positionId] = remainingCollateral;
            }
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
            (, , uint256 debtAmount, , , , ) = vault.getPosition(positionId);

            // uint256 interestDue = interestCollector.calculateInterestDue(
            //     address(vault),
            //     positionId,
            //     debtAmount
            // );
            vm.startPrank(address(vault));
            try
                interestCollector.collectInterest(
                    address(vault),
                    address(shezUSD),
                    positionId,
                    debtAmount
                )
            {
                (, , uint256 debtAfter, , , , ) = vault.getPosition(positionId);
                uint256 interestApplied = debtAfter - debtAmount;
                interestAccrued[positionId] += interestApplied;

                totalInterestAccrued += interestApplied;

                // interestAccrued[positionId] += interestDue;
            } catch {}
            vm.stopPrank();
        }
    }

    function handler_withdrawInterest() public {
        uint256 amount = interestCollector.getCollectedInterest(
            address(shezUSD)
        );
        if (
            amount > 0 &&
            shezUSD.balanceOf(address(interestCollector)) >= amount
        ) {
            vm.startPrank(deployer);
            try interestCollector.withdrawInterest(address(shezUSD)) {
                totalInterestMintedToTreasury += amount;
            } catch {}
            vm.stopPrank();
        }
    }

    function handler_borrow(uint256 positionId, uint256 borrowAmount) public {
        uint256 nextId = vault.nextPositionId();
        if (nextId <= 1) return; // No positions exist yet

        positionId = bound(positionId, 1, nextId - 1);
        (address owner, , uint256 posDebt, , , , ) = vault.getPosition(
            positionId
        );

        // Skip if position doesn't exist or has been liquidated
        if (owner == address(0) || wasLiquidated[positionId]) return;

        borrowAmount = bound(borrowAmount, 0, 1e24);

        uint256 newDebtAmount = posDebt + borrowAmount;
        uint256 newLoanValue = vault.getLoanValue(newDebtAmount);
        uint256 maxLoanValue = vault.getMaxBorrowable(positionId);

        vm.startPrank(user1);
        if (
            borrowAmount > 0 && newLoanValue <= maxLoanValue && owner == user1
        ) {
            _collectInterest(positionId, posDebt);

            try vault.borrow(positionId, borrowAmount) {
                initialDebt[positionId] += borrowAmount;
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
            (, uint256 posCollateral, uint256 posDebt, , , , ) = vault
                .getPosition(posIds[i]);
            totalCollateral += posCollateral;
            totalDebt += posDebt;
        }
        assertEq(vault.getCollateralBalance(user1), totalCollateral);
        assertEq(vault.getLoanBalance(user1), totalDebt);
    }

    function invariant_CollateralAdditionsAccurate() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        uint256 totalCollateralExpected;

        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 posCollateral, , , , , ) = vault.getPosition(positionId);
            uint256 expectedCollateral = initialCollateral[positionId] +
                addedCollateral[positionId] -
                withdrawnCollateral[positionId];
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
        uint256 totalReturnedFromLiquidation;

        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 posCollateral, , , , , ) = vault.getPosition(positionId);
            totalCollateralInVault += posCollateral;
            totalWithdrawn += withdrawnCollateral[positionId];
        }

        // Sum penalties for all positions (including liquidated ones)
        uint256 nextId = vault.nextPositionId();
        for (uint256 positionId = 1; positionId < nextId; positionId++) {
            totalReturnedFromLiquidation += liquidatedCollateralReturned[
                positionId
            ];
        }

        uint256 WETHBalance = WETH.balanceOf(user1) +
            totalPenaltiesAcrossAllTime;
        uint256 expectedWETHBalance = initialWETHBalance -
            vault.getCollateralBalance(user1) -
            totalReturnedFromLiquidation -
            totalPenaltiesAcrossAllTime -
            totalSoulBoundFees;

        assertApproxEqAbs(
            WETHBalance,
            expectedWETHBalance,
            5, // Allow 5 wei tolerance
            "WETH balance mismatch"
        );

        assertEq(
            vault.getCollateralBalance(user1),
            totalCollateralInVault,
            "Vault collateral mismatch"
        );

        assertEq(
            WETH.balanceOf(treasury),
            totalPenaltiesAcrossAllTime + totalSoulBoundFees,
            "Treasury Penalties mismatch"
        );
    }

    function invariant_DebtRepaymentsAccurate() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        uint256 totalDebtExpected;

        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, , uint256 posDebt, , , , ) = vault.getPosition(positionId);
            uint256 expectedDebt = (initialDebt[positionId] +
                interestAccrued[positionId]) - repaidDebt[positionId];
            assertEq(posDebt, expectedDebt, "Position debt mismatch");
            totalDebtExpected += expectedDebt;
        }

        assertEq(
            vault.getLoanBalance(user1),
            shezUSD.balanceOf(user1) + totalInterestAccrued,
            "Loan balances mismatch"
        );
        assertEq(
            vault.getLoanBalance(user1),
            totalDebtExpected,
            "Total debt balance mismatch"
        );
        assertEq(
            totalDebtExpected,
            shezUSD.balanceOf(user1) + totalInterestAccrued,
            "shezUSD balance mismatch"
        );
    }

    function invariant_HealthRatioCorrect() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 collateralAmount, uint256 debtAmount, , , , ) = vault
                .getPosition(positionId);
            uint256 health = vault.getPositionHealth(positionId);

            if (debtAmount == 0) {
                assertEq(
                    health,
                    type(uint256).max,
                    "Health should be infinity for zero debt"
                );
            } else {
                (, , , , uint256 effectiveLtvRatio, , uint256 leverage) = vault
                    .getPosition(positionId);
                uint256 collateralValue = vault.getCollateralValue(
                    collateralAmount
                );
                uint256 loanValue = vault.getLoanValue(debtAmount);
                uint256 x = (collateralValue * leverage * effectiveLtvRatio) /
                    100;
                uint256 y = (loanValue * (1000 - (1000 / (leverage + 1)))) /
                    1000;

                uint256 expectedHealth = (x * 1e18) / y;

                assertEq(health, expectedHealth, "Health ratio mismatch");
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
            (, uint256 collateralAmount, uint256 debtAmount, , , , ) = vault
                .getPosition(positionId);
            if (collateralAmount > 0 && debtAmount > 0) {
                uint256 health = vault.getPositionHealth(positionId);

                (, , , , uint256 effectiveLtvRatio, , uint256 leverage) = vault
                    .getPosition(positionId);
                uint256 collateralValue = vault.getCollateralValue(
                    collateralAmount
                );
                uint256 loanValue = vault.getLoanValue(debtAmount);
                uint256 x = (collateralValue * leverage * effectiveLtvRatio) /
                    100;
                uint256 y = (loanValue * (1000 - (1000 / (leverage + 1)))) /
                    1000;
                uint256 expectedHealth = (x * 1e18) / y;

                // Verify health reflects current price
                assertEq(
                    health,
                    expectedHealth,
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
            (, uint256 posCollateral, uint256 posDebt, , , , ) = vault
                .getPosition(positionId);

            // Check if the debt has been fully repaid
            if (
                initialDebt[positionId] > 0 &&
                repaidDebt[positionId] >= initialDebt[positionId]
            ) {
                assertEq(posDebt, 0, "Debt should be 0 after full repayment");
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
                ? initialDebt[positionId] +
                    interestAccrued[positionId] -
                    repaidDebt[positionId]
                : 0;
            totalDebtExpected += expectedDebt;
        }
        assertEq(
            vault.getLoanBalance(user1),
            totalDebtExpected,
            "Loan balance mismatch after full debt repayment"
        );
    }

    function invariant_BadDebtCannotPersist() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);

        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, uint256 collateralAmount, uint256 debtAmount, , , , ) = vault
                .getPosition(positionId);

            if (debtAmount > 0 && collateralAmount > 0) {
                uint256 health = vault.getPositionHealth(positionId);
                bool liquidatable = vault.isLiquidatable(positionId);
                uint256 threshold = (1e18 * LIQUIDATION_THRESHOLD) / 100;

                if (health >= threshold) {
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

    function invariant_LiquidationConsistency() public view {
        uint256 nextId = vault.nextPositionId();
        for (uint256 positionId = 1; positionId < nextId; positionId++) {
            if (wasLiquidated[positionId]) {
                (
                    address owner,
                    uint256 collateralAmount,
                    uint256 debtAmount,
                    ,
                    ,
                    ,

                ) = vault.getPosition(positionId);
                assertEq(
                    owner,
                    address(0),
                    "Liquidated position should have no owner"
                );
                assertEq(
                    collateralAmount,
                    0,
                    "Liquidated position should have 0 collateral"
                );
                assertEq(
                    debtAmount,
                    0,
                    "Liquidated position should have 0 debt"
                );

                // Verify collateral distribution
                uint256 preLiquidationAmount = preLiquidationCollateral[
                    positionId
                ];
                if (preLiquidationAmount > 0) {
                    uint256 expectedReward = (preLiquidationAmount *
                        LIQUIDATOR_REWARD) / 100;
                    uint256 expectedPenalty = (preLiquidationAmount *
                        vault.penaltyRate()) / 100;
                    uint256 expectedRemaining = preLiquidationAmount -
                        expectedReward -
                        expectedPenalty;

                    assertEq(
                        liquidatedCollateralReturned[positionId],
                        expectedRemaining,
                        "Remaining collateral returned to owner does not match expected amount"
                    );
                }

                // Verify that the position is no longer in the user's position list
                uint256[] memory posIds = vault.getUserPositionIds(user1);
                for (uint256 i = 0; i < posIds.length; i++) {
                    assertTrue(
                        posIds[i] != positionId,
                        "Liquidated position should not be in user's position list"
                    );
                }
            }
        }

        // Verify that the vault's collateral and loan balances do not include liquidated positions
        uint256[] memory activePosIds = vault.getUserPositionIds(user1);
        uint256 totalCollateralInVault;
        uint256 totalDebtInVault;

        for (uint256 i = 0; i < activePosIds.length; i++) {
            uint256 positionId = activePosIds[i];
            (, uint256 posCollateral, uint256 posDebt, , , , ) = vault
                .getPosition(positionId);
            totalCollateralInVault += posCollateral;
            totalDebtInVault += posDebt;
        }

        assertEq(
            vault.getCollateralBalance(user1),
            totalCollateralInVault,
            "Vault collateral balance should only include active positions"
        );
        assertEq(
            vault.getLoanBalance(user1),
            totalDebtInVault,
            "Vault loan balance should only include active positions"
        );
    }

    function invariant_InterestCollectionConsistency() public view {
        uint256[] memory posIds = vault.getUserPositionIds(user1);
        uint256 totalDebtExpected;
        uint256 totalInterestForActivePositions;

        // Verify each position's debt matches expected debt (including interest)
        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, , uint256 posDebt, , , , ) = vault.getPosition(positionId);
            uint256 expectedDebt = (initialDebt[positionId] +
                interestAccrued[positionId]) - repaidDebt[positionId];
            assertEq(
                posDebt,
                expectedDebt,
                "Position debt does not match expected debt after interest accrual"
            );
            totalDebtExpected += expectedDebt;
            totalInterestForActivePositions += interestAccrued[positionId];
        }

        // Verify the vault's loan balance matches the total expected debt
        assertEq(
            vault.getLoanBalance(user1),
            totalDebtExpected,
            "Vault loan balance does not match total expected debt"
        );

        // The treasury should have received all interest accrued
        assertEq(
            shezUSD.balanceOf(treasury),
            totalInterestMintedToTreasury,
            "Treasury shezUSD balance does not match total interest accrued"
        );

        // Verify that interest isn't double-counted by checking lastCollection
        for (uint256 i = 0; i < posIds.length; i++) {
            uint256 positionId = posIds[i];
            (, , uint256 debtAmount, , , , ) = vault.getPosition(positionId);
            if (debtAmount > 0) {
                uint256 lastCollectionBlock = interestCollector
                    .getLastCollectionBlock(address(vault), positionId);
                if (block.number == lastCollectionBlock) {
                    // If we're within the same period, calculateInterestDue should return 0
                    uint256 interestDue = interestCollector
                        .calculateInterestDue(
                            address(vault),
                            positionId,
                            debtAmount
                        );
                    assertEq(
                        interestDue,
                        0,
                        "Interest should not be accrued within the same period"
                    );
                }
            }
        }
    }
}
