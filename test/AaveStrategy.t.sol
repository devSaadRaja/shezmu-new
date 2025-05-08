// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "../src/interfaces/aave-v3/IPool.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {IRewardsController} from "../src/interfaces/aave-v3/IRewardsController.sol";
import {IPoolDataProvider} from "../src/interfaces/aave-v3/IPoolDataProvider.sol";

import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";

contract AaveStrategyTest is Test {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    //* ETHEREUM ADDRESSES *//
    IPool POOL_V3 = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IRewardsController INCENTIVES_V3 =
        IRewardsController(0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb);
    IPoolDataProvider IPOOL_DATA_PROVIDER =
        IPoolDataProvider(0x497a1994c46d4f6C864904A9f1fac6328Cb7C8a6);

    AaveStrategy aaveStrategy;

    IERC20 collateralToken; // collateral
    IERC20 aToken; // just like LP tokens
    IERC20 rewardToken;

    address deployer = vm.addr(1);
    address user1 = vm.addr(2);
    address user2 = vm.addr(3);
    address treasury = vm.addr(4);

    // =========================================== //
    // ================== SETUP ================== //
    // =========================================== //

    function setUp() public {
        vm.startPrank(deployer);

        // collateralToken = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH
        // aToken = IERC20(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8); // aEthWETH
        // rewardToken = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0); // AAVE

        // collateralToken = IERC20(0xA35b1B31Ce002FBF2058D22F30f95D405200A15b); // ETHx
        // aToken = IERC20(0x1c0E06a0b1A4c160c17545FF2A951bfcA57C0002); // aEthETHx (Aave Ethereum ETHx)
        // rewardToken = IERC20(0x30D20208d987713f46DFD34EF128Bb16C404D10f); // Stader SD

        collateralToken = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F); // USDS (USDS Stablecoin)
        aToken = IERC20(0x32a6268f9Ba3642Dda7892aDd74f1D34469A4259); // aEthUSDS (Aave Ethereum USDS)
        rewardToken = IERC20(0x32a6268f9Ba3642Dda7892aDd74f1D34469A4259); // aEthUSDS (Aave Ethereum USDS)

        deal(address(collateralToken), deployer, 1_000_000_000 ether);

        aaveStrategy = new AaveStrategy();
        aaveStrategy.initialize(
            treasury,
            address(collateralToken),
            address(aToken),
            address(rewardToken),
            address(POOL_V3),
            address(INCENTIVES_V3)
        );

        aaveStrategy.setVault(user1);

        collateralToken.transfer(user1, 2_000_000 ether);
        collateralToken.transfer(user2, 2_000_000 ether);

        vm.stopPrank();
    }

    // ================================================ //
    // ================== TEST CASES ================== //
    // ================================================ //

    function test_TEST() public {
        // address[] memory reserveAddresses = POOL_V3.getReservesList();
        // for (uint i = 0; i < reserveAddresses.length; i++) {
        //     console.log();
        //     address reserve = reserveAddresses[i];
        //     console.log(reserve, "<<< reserve");
        //     address aT = POOL_V3.getReserveAToken(reserve);
        //     console.log(aT, "<<< aT");
        //     address[] memory rewards = INCENTIVES_V3.getRewardsByAsset(aT);
        //     for (uint j = 0; j < rewards.length; j++) {
        //         console.log(rewards[j], "<<< rewards[j]");
        //     }
        //     console.log();
        // }

        // (
        //     uint256 totalCollateralBase,
        //     uint256 totalDebtBase,
        //     uint256 availableBorrowsBase,
        //     uint256 currentLiquidationThreshold,
        //     uint256 ltv,
        //     uint256 healthFactor
        // ) = POOL_V3.getUserAccountData(user1);
        // console.log(totalCollateralBase, "<<< totalCollateralBase");
        // console.log(totalDebtBase, "<<< totalDebtBase");
        // console.log(availableBorrowsBase, "<<< availableBorrowsBase");
        // console.log(
        //     currentLiquidationThreshold,
        //     "<<< currentLiquidationThreshold"
        // );
        // console.log(ltv, "<<< ltv");
        // console.log(healthFactor, "<<< healthFactor");

        // (, , , , uint256 reserveFactor, , , , , ) = IPOOL_DATA_PROVIDER
        //     .getReserveConfigurationData(address(collateralToken));
        // console.log(reserveFactor, "<<< reserveFactor");

        uint256 principal = 1000 ether;

        address[] memory assets = new address[](1);
        assets[0] = address(aToken);

        vm.startPrank(user1);

        // DataTypes.ReserveConfigurationMap memory data = POOL_V3
        //     .getConfiguration(address(collateralToken));
        // uint256 mask = 1 << 56;
        // bool isCollateralEnabled = (data.data & mask) != 0;
        // console.log(isCollateralEnabled, "<<< isCollateralEnabled");

        console.log(aToken.balanceOf(user1), "<<< aToken.balanceOf(user1)");
        console.log(
            IERC20(collateralToken).balanceOf(user1),
            "<<< collateralToken.balanceOf(user1)"
        );
        console.log(aToken.balanceOf(user2), "<<< aToken.balanceOf(user2)");
        console.log(
            IERC20(collateralToken).balanceOf(user2),
            "<<< collateralToken.balanceOf(user2)"
        );

        // !
        // collateralToken.approve(address(aaveStrategy), principal);
        // aaveStrategy.deposit(1, user1, principal);

        collateralToken.approve(address(POOL_V3), principal);
        POOL_V3.supply(address(collateralToken), principal, user1, 0);

        POOL_V3.setUserUseReserveAsCollateral(address(collateralToken), false);

        collateralToken.approve(address(POOL_V3), principal);
        POOL_V3.supply(address(collateralToken), principal, user2, 0);

        POOL_V3.setUserUseReserveAsCollateral(address(collateralToken), false);
        // !

        console.log();
        console.log("AFTER DEPOSIT");
        console.log(aToken.balanceOf(user1), "<<< aToken.balanceOf(user1)");
        console.log(
            IERC20(collateralToken).balanceOf(user1),
            "<<< collateralToken.balanceOf(user1)"
        );
        console.log(
            IERC20(rewardToken).balanceOf(user1),
            "<<< rewardToken.balanceOf(user1)"
        );
        console.log(aToken.balanceOf(user2), "<<< aToken.balanceOf(user2)");
        console.log(
            IERC20(collateralToken).balanceOf(user2),
            "<<< collateralToken.balanceOf(user2)"
        );
        console.log(
            IERC20(rewardToken).balanceOf(user2),
            "<<< rewardToken.balanceOf(user2)"
        );

        // !
        vm.warp(block.timestamp + 100 days);
        // !

        console.log();
        console.log("AFTER TIME PASSED");
        console.log(aToken.balanceOf(user1), "<<< aToken.balanceOf(user1)");
        console.log(
            IERC20(collateralToken).balanceOf(user1),
            "<<< collateralToken.balanceOf(user1)"
        );
        console.log(
            IERC20(rewardToken).balanceOf(user1),
            "<<< rewardToken.balanceOf(user1)"
        );
        console.log(aToken.balanceOf(user2), "<<< aToken.balanceOf(user2)");
        console.log(
            IERC20(collateralToken).balanceOf(user2),
            "<<< collateralToken.balanceOf(user2)"
        );
        console.log(
            IERC20(rewardToken).balanceOf(user2),
            "<<< rewardToken.balanceOf(user2)"
        );

        console.log(
            INCENTIVES_V3.getUserRewards(assets, user1, address(rewardToken)),
            "<<< USER REWARDS"
        );
        console.log(
            INCENTIVES_V3.getUserAccruedRewards(user1, address(rewardToken)),
            "<<< ACCRUED REWARDS"
        );
        console.log(
            INCENTIVES_V3.getUserRewards(assets, user2, address(rewardToken)),
            "<<< USER REWARDS 2"
        );
        console.log(
            INCENTIVES_V3.getUserAccruedRewards(user2, address(rewardToken)),
            "<<< ACCRUED REWARDS 2"
        );

        DataTypes.ReserveDataLegacy memory reserveData = POOL_V3.getReserveData(
            address(collateralToken)
        );
        console.log();
        console.log(principal, "<<< principal");
        uint256 timeElapsed = block.timestamp - reserveData.lastUpdateTimestamp;
        console.log(timeElapsed, "<<< timeElapsed");
        uint256 currentLiquidityRate = reserveData.currentLiquidityRate;
        console.log(currentLiquidityRate, "<<< currentLiquidityRate");
        uint256 interest = (principal * currentLiquidityRate * timeElapsed) /
            (365 * 24 * 3600 * 1e27);
        console.log(interest, "<<< interest");

        // !
        // aaveStrategy.withdraw(1);
        POOL_V3.withdraw(address(collateralToken), principal + interest, user1); // type(uint256).max

        INCENTIVES_V3.claimRewards(
            assets,
            type(uint256).max,
            user1,
            address(rewardToken)
        );
        // !

        console.log();
        console.log("AFTER CLAIM");
        console.log(aToken.balanceOf(user1), "<<< aToken.balanceOf(user1)");
        console.log(
            IERC20(collateralToken).balanceOf(user1),
            "<<< collateralToken.balanceOf(user1)"
        );
        console.log(
            IERC20(rewardToken).balanceOf(user1),
            "<<< rewardToken.balanceOf(user1)"
        );
        console.log(aToken.balanceOf(user2), "<<< aToken.balanceOf(user2)");
        console.log(
            IERC20(collateralToken).balanceOf(user2),
            "<<< collateralToken.balanceOf(user2)"
        );
        console.log(
            IERC20(rewardToken).balanceOf(user2),
            "<<< rewardToken.balanceOf(user2)"
        );

        vm.stopPrank();
    }

    // function testInitialize() public {
    //     vm.startPrank(deployer);
    //     AaveStrategy newVault = new AaveStrategy();
    //     newVault.initialize(
    //         treasury,
    //         address(collateralToken),
    //         address(aToken),
    //         address(rewardToken),
    //         address(POOL_V3),
    //         address(INCENTIVES_V3)
    //     );

    //     assertEq(newVault.owner(), deployer, "Owner not set correctly");
    //     assertEq(newVault.treasury(), treasury, "Treasury not set correctly");
    //     assertEq(
    //         address(newVault.collateralToken()),
    //         address(collateralToken),
    //         "Collateral token not set correctly"
    //     );
    //     assertEq(
    //         address(newVault.rewardToken()),
    //         address(aToken),
    //         "Reward token not set correctly"
    //     );
    //     assertEq(
    //         address(newVault.pool()),
    //         address(POOL_V3),
    //         "Pool not set correctly"
    //     );
    //     assertEq(
    //         address(newVault.rewardsController()),
    //         address(INCENTIVES_V3),
    //         "Rewards controller not set correctly"
    //     );
    // }

    // function testDepositSuccess() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 1000 ether;

    //     vm.startPrank(user1);
    //     uint256 initialBalance = collateralToken.balanceOf(user1);
    //     uint256 initialVaultBalance = collateralToken.balanceOf(
    //         address(aaveStrategy)
    //     );

    //     collateralToken.approve(address(aaveStrategy), amount);
    //     aaveStrategy.deposit(positionId, user1, amount);

    //     assertEq(
    //         aaveStrategy.amounts(positionId),
    //         amount,
    //         "Amount not recorded correctly"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(user1),
    //         initialBalance - amount,
    //         "User balance not updated"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(address(aaveStrategy)),
    //         initialVaultBalance,
    //         "Vault balance should not hold tokens"
    //     );
    //     vm.stopPrank();
    // }

    // function testDepositZeroAmount() public {
    //     vm.startPrank(user1);
    //     vm.expectRevert(AaveStrategy.ZeroAmount.selector);
    //     aaveStrategy.deposit(1, user1, 0);
    //     vm.stopPrank();
    // }

    // function testDepositActivePosition() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 1000 ether;

    //     vm.startPrank(user1);
    //     collateralToken.approve(address(aaveStrategy), amount);
    //     aaveStrategy.deposit(positionId, user1, amount);

    //     vm.expectRevert(AaveStrategy.AlreadyActive.selector);
    //     aaveStrategy.deposit(positionId, user1, amount);
    //     vm.stopPrank();
    // }

    // function testDepositUnauthorized() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 1_000_000 ether;

    //     vm.startPrank(user2); // user2 is not the aaveStrategy
    //     vm.expectRevert(AaveStrategy.Unauthorized.selector);
    //     aaveStrategy.deposit(positionId, user1, amount);
    //     vm.stopPrank();
    // }

    // function testWithdrawWithInterest() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 10000 ether;

    //     vm.startPrank(user1);
    //     collateralToken.approve(address(aaveStrategy), amount);
    //     aaveStrategy.deposit(positionId, user1, amount);

    //     uint256 oldUserBalance = collateralToken.balanceOf(treasury);
    //     uint256 oldTreasuryAmount = collateralToken.balanceOf(treasury);

    //     vm.warp(block.timestamp + 100 days); // pass 100 days

    //     aaveStrategy.withdraw(positionId, user1);

    //     assertEq(
    //         aaveStrategy.amounts(positionId),
    //         0,
    //         "Position amount not cleared"
    //     );
    //     assertGt(
    //         collateralToken.balanceOf(user1),
    //         oldUserBalance,
    //         "User balance not updated"
    //     );
    //     assertGt(
    //         collateralToken.balanceOf(treasury),
    //         oldTreasuryAmount,
    //         "Treasury balance not updated"
    //     );
    //     vm.stopPrank();
    // }

    // function testWithdrawNoInterest() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 10000 ether;

    //     // Deposit
    //     vm.startPrank(user1);
    //     collateralToken.approve(address(aaveStrategy), amount);
    //     aaveStrategy.deposit(positionId, user1, amount);

    //     // Withdraw
    //     uint256 expectedUserBalance = collateralToken.balanceOf(user1) + amount;
    //     uint256 expectedTreasuryBalance = collateralToken.balanceOf(treasury);

    //     aaveStrategy.withdraw(positionId, user1);

    //     assertEq(
    //         aaveStrategy.amounts(positionId),
    //         0,
    //         "Position amount not cleared"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(user1),
    //         expectedUserBalance,
    //         "User balance not updated"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(treasury),
    //         expectedTreasuryBalance,
    //         "Treasury balance not updated"
    //     );
    //     vm.stopPrank();
    // }

    // function testWithdrawUnauthorized() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 10000 ether;

    //     // Deposit
    //     vm.startPrank(user1);
    //     collateralToken.approve(address(aaveStrategy), amount);
    //     aaveStrategy.deposit(positionId, user1, amount);
    //     vm.stopPrank();

    //     // Try to withdraw as user2
    //     vm.startPrank(user2);
    //     vm.expectRevert(AaveStrategy.Unauthorized.selector);
    //     aaveStrategy.withdraw(positionId, user1);
    //     vm.stopPrank();
    // }

    // function testSetVaultSuccess() public {
    //     vm.startPrank(deployer);
    //     aaveStrategy.setVault(user2);
    //     assertEq(aaveStrategy.vault(), user2, "Vault address not updated");
    //     vm.stopPrank();
    // }

    // function testSetVaultNonOwner() public {
    //     vm.startPrank(user2);
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
    //             user2
    //         )
    //     );
    //     aaveStrategy.setVault(user2);
    //     vm.stopPrank();
    // }

    // function testUpdatePoolProxySuccess() public {
    //     address newPool = vm.addr(6);

    //     vm.startPrank(deployer);
    //     aaveStrategy.updatePoolProxy(newPool);
    //     assertEq(
    //         address(aaveStrategy.pool()),
    //         newPool,
    //         "Pool address not updated"
    //     );
    //     vm.stopPrank();
    // }

    // function testUpdatePoolProxyZeroAddress() public {
    //     vm.startPrank(deployer);
    //     vm.expectRevert(AaveStrategy.InvalidAddress.selector);
    //     aaveStrategy.updatePoolProxy(address(0));
    //     vm.stopPrank();
    // }

    // function testUpdatePoolProxyNonOwner() public {
    //     vm.startPrank(user2);
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
    //             user2
    //         )
    //     );
    //     aaveStrategy.updatePoolProxy(vm.addr(6));
    //     vm.stopPrank();
    // }

    // function testUpdateRewardsControllerSuccess() public {
    //     address newController = vm.addr(7);

    //     vm.startPrank(deployer);
    //     aaveStrategy.updateRewardsController(newController);
    //     assertEq(
    //         address(aaveStrategy.rewardsController()),
    //         newController,
    //         "Rewards controller not updated"
    //     );
    //     vm.stopPrank();
    // }

    // function testUpdateRewardsControllerZeroAddress() public {
    //     vm.startPrank(deployer);
    //     vm.expectRevert(AaveStrategy.InvalidAddress.selector);
    //     aaveStrategy.updateRewardsController(address(0));
    //     vm.stopPrank();
    // }

    // function testUpdateRewardsControllerNonOwner() public {
    //     vm.startPrank(user2);
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
    //             user2
    //         )
    //     );
    //     aaveStrategy.updateRewardsController(vm.addr(7));
    //     vm.stopPrank();
    // }

    // function testClaimRewardSuccess() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 10000 ether;

    //     vm.startPrank(user1);
    //     collateralToken.approve(address(aaveStrategy), amount);
    //     aaveStrategy.deposit(positionId, user1, amount);

    //     uint256 oldUserBalance = collateralToken.balanceOf(treasury);
    //     uint256 oldTreasuryAmount = collateralToken.balanceOf(treasury);

    //     vm.warp(block.timestamp + 100 days); // pass 100 days

    //     assertGt(
    //         aaveStrategy.getUserRewards(address(aaveStrategy)),
    //         0,
    //         "User Rewards should be greater than 0"
    //     );

    //     aaveStrategy.withdraw(positionId, user1);
    //     assertGt(
    //         aaveStrategy.getAccruedRewards(address(aaveStrategy)),
    //         0,
    //         "Accumulated Rewards should be greater than 0"
    //     );

    //     aaveStrategy.claimReward(user1);

    //     assertGt(
    //         rewardToken.balanceOf(user1),
    //         oldUserBalance,
    //         "User reward balance not updated"
    //     );
    //     assertGt(
    //         rewardToken.balanceOf(treasury),
    //         oldTreasuryAmount,
    //         "Treasury reward balance not updated"
    //     );
    //     vm.stopPrank();
    // }

    // function testClaimRewardZeroRewards() public {
    //     vm.startPrank(user1);
    //     vm.expectRevert(AaveStrategy.ZeroReward.selector);
    //     aaveStrategy.claimReward(user1);
    //     vm.stopPrank();
    // }

    // function testClaimRewardUnauthorized() public {
    //     vm.startPrank(user2); // user2 is not the vault
    //     vm.expectRevert(AaveStrategy.Unauthorized.selector);
    //     aaveStrategy.claimReward(user1);
    //     vm.stopPrank();
    // }

    // function testMultipleUsers() public {
    //     uint256 positionId1 = 1;
    //     uint256 positionId2 = 2;
    //     uint256 DEPOSIT_AMOUNT = 10000 ether;
    //     uint256 depositAmount1 = 1000 ether;
    //     uint256 depositAmount2 = 2000 ether;
    //     uint256 interest1 = 100_000 ether;
    //     uint256 interest2 = 200_000 ether;
    //     uint256 rewardAmount = 150_000 ether;

    //     vm.prank(user1);
    //     collateralToken.approve(address(aaveStrategy), 1_000_000 ether);
    //     vm.prank(user2);
    //     collateralToken.approve(address(aaveStrategy), 1_000_000 ether);

    //     // User1 deposits
    //     vm.prank(deployer);
    //     aaveStrategy.setVault(user1); // Ensure user1 is vault
    //     vm.startPrank(user1);
    //     aaveStrategy.deposit(positionId1, user1, depositAmount1);
    //     assertEq(
    //         aaveStrategy.amounts(positionId1),
    //         depositAmount1,
    //         "User1 position amount incorrect"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(user1),
    //         DEPOSIT_AMOUNT - depositAmount1,
    //         "User1 collateral balance incorrect"
    //     );
    //     vm.stopPrank();

    //     // User2 deposits
    //     vm.prank(deployer);
    //     aaveStrategy.setVault(user2); // Set user2 as vault
    //     vm.startPrank(user2);
    //     aaveStrategy.deposit(positionId2, user2, depositAmount2);
    //     assertEq(
    //         aaveStrategy.amounts(positionId2),
    //         depositAmount2,
    //         "User2 position amount incorrect"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(user2),
    //         DEPOSIT_AMOUNT - depositAmount2,
    //         "User2 collateral balance incorrect"
    //     );
    //     // assertEq(
    //     //     collateralToken.balanceOf(address(mockPool)),
    //     //     depositAmount1 + depositAmount2,
    //     //     "Pool collateral balance incorrect"
    //     // );
    //     vm.stopPrank();

    //     // // Simulate interest in mock pool
    //     // vm.startPrank(deployer);
    //     // deal(
    //     //     address(collateralToken),
    //     //     address(mockPool),
    //     //     depositAmount1 + depositAmount2 + interest1 + interest2
    //     // );
    //     // mockPool.setWithdrawAmount(depositAmount1 + interest1); // For user1's withdrawal
    //     // vm.stopPrank();

    //     // User1 withdraws
    //     vm.prank(deployer);
    //     aaveStrategy.setVault(user1);
    //     vm.startPrank(user1);
    //     uint256 borrowerShare1 = (interest1 * 7500) / 10000;
    //     uint256 protocolShare1 = (interest1 * 2500) / 10000;
    //     uint256 expectedUser1Balance = collateralToken.balanceOf(user1) +
    //         depositAmount1 +
    //         borrowerShare1;
    //     uint256 expectedTreasuryBalance = collateralToken.balanceOf(treasury) +
    //         protocolShare1;

    //     aaveStrategy.withdraw(positionId1, user1);

    //     assertEq(
    //         aaveStrategy.amounts(positionId1),
    //         0,
    //         "User1 position not cleared"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(user1),
    //         expectedUser1Balance,
    //         "User1 collateral balance after withdraw incorrect"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(treasury),
    //         expectedTreasuryBalance,
    //         "Treasury collateral balance after user1 withdraw incorrect"
    //     );
    //     vm.stopPrank();

    //     // // Simulate interest for user2
    //     // vm.startPrank(deployer);
    //     // mockPool.setWithdrawAmount(depositAmount2 + interest2); // For user2's withdrawal
    //     // vm.stopPrank();

    //     // User2 withdraws
    //     vm.prank(deployer);
    //     aaveStrategy.setVault(user2);
    //     vm.startPrank(user2);
    //     uint256 borrowerShare2 = (interest2 * 7500) / 10000;
    //     uint256 protocolShare2 = (interest2 * 2500) / 10000;
    //     uint256 expectedUser2Balance = collateralToken.balanceOf(user2) +
    //         depositAmount2 +
    //         borrowerShare2;
    //     expectedTreasuryBalance += protocolShare2;

    //     aaveStrategy.withdraw(positionId2, user2);

    //     assertEq(
    //         aaveStrategy.amounts(positionId2),
    //         0,
    //         "User2 position not cleared"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(user2),
    //         expectedUser2Balance,
    //         "User2 collateral balance after withdraw incorrect"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(treasury),
    //         expectedTreasuryBalance,
    //         "Treasury collateral balance after user2 withdraw incorrect"
    //     );
    //     // assertEq(
    //     //     collateralToken.balanceOf(address(mockPool)),
    //     //     0,
    //     //     "Pool collateral balance not cleared"
    //     // );
    //     vm.stopPrank();

    //     // // Simulate rewards
    //     // vm.startPrank(deployer);
    //     // mockRewardsController.setRewardAmount(rewardAmount);
    //     // vm.stopPrank();

    //     // User1 claims rewards
    //     vm.prank(deployer);
    //     aaveStrategy.setVault(user1);
    //     vm.startPrank(user1);
    //     uint256 borrowerRewardShare1 = (rewardAmount * 7500) / 10000;
    //     uint256 protocolRewardShare1 = (rewardAmount * 2500) / 10000;
    //     uint256 expectedUser1RewardBalance = rewardToken.balanceOf(user1) +
    //         borrowerRewardShare1;
    //     uint256 expectedTreasuryRewardBalance = rewardToken.balanceOf(
    //         treasury
    //     ) + protocolRewardShare1;

    //     aaveStrategy.claimReward(user1);

    //     assertEq(
    //         rewardToken.balanceOf(user1),
    //         expectedUser1RewardBalance,
    //         "User1 reward balance incorrect"
    //     );
    //     assertEq(
    //         rewardToken.balanceOf(treasury),
    //         expectedTreasuryRewardBalance,
    //         "Treasury reward balance after user1 claim incorrect"
    //     );
    //     vm.stopPrank();

    //     // User2 claims rewards
    //     vm.prank(deployer);
    //     aaveStrategy.setVault(user2);
    //     vm.startPrank(user2);
    //     // mockRewardsController.setRewardAmount(rewardAmount); // Reset rewards for user2
    //     uint256 borrowerRewardShare2 = (rewardAmount * 7500) / 10000;
    //     uint256 protocolRewardShare2 = (rewardAmount * 2500) / 10000;
    //     uint256 expectedUser2RewardBalance = rewardToken.balanceOf(user2) +
    //         borrowerRewardShare2;
    //     expectedTreasuryRewardBalance += protocolRewardShare2;

    //     vm.expectEmit(false, false, false, true);
    //     emit AaveStrategy.RewardClaimed(
    //         borrowerRewardShare2,
    //         protocolRewardShare2
    //     );
    //     aaveStrategy.claimReward(user2);

    //     assertEq(
    //         rewardToken.balanceOf(user2),
    //         expectedUser2RewardBalance,
    //         "User2 reward balance incorrect"
    //     );
    //     assertEq(
    //         rewardToken.balanceOf(treasury),
    //         expectedTreasuryRewardBalance,
    //         "Treasury reward balance after user2 claim incorrect"
    //     );
    //     // assertEq(
    //     //     rewardToken.balanceOf(address(mockRewardsController)),
    //     //     INITIAL_BALANCE - 2 * rewardAmount,
    //     //     "Rewards controller balance incorrect"
    //     // );
    //     vm.stopPrank();
    // }
}
