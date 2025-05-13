// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {IPool} from "../src/interfaces/aave-v3/IPool.sol";
import {IRewardsController} from "../src/interfaces/aave-v3/IRewardsController.sol";

import {RehypothecationVault} from "../src/RehypothecationVault.sol";

contract RehypothecationVaultTest is Test {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    //* ETHEREUM ADDRESSES *//
    IPool POOL_V3 = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IRewardsController INCENTIVES_V3 =
        IRewardsController(0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb);

    RehypothecationVault rehypoVault;

    IERC20 collateralToken; // collateral
    IERC20 aToken; // just like LP tokens
    IERC20 rewardToken;

    address deployer = vm.addr(1);
    address vault = vm.addr(2);
    address user1 = vm.addr(3);
    address user2 = vm.addr(4);
    address treasury = vm.addr(5);

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

        rehypoVault = new RehypothecationVault();
        rehypoVault.initialize(
            treasury,
            address(collateralToken),
            address(aToken),
            address(rewardToken),
            address(POOL_V3),
            address(INCENTIVES_V3)
        );

        // rehypoVault.setVault(user1);
        rehypoVault.setVault(vault);

        // collateralToken.transfer(user1, 2_000_000 ether);
        // collateralToken.transfer(user2, 2_000_000 ether);
        collateralToken.transfer(vault, 2_000_000 ether);

        // ! ACCESS_CONTROL
        // collateralToken.approve(address(rehypoVault), 1);
        // rehypoVault.deposit(0, 1);

        vm.stopPrank();

        vm.startPrank(address(vault));
        collateralToken.approve(address(rehypoVault), 1);
        rehypoVault.deposit(0, 1);
        vm.stopPrank();

        vm.prank(deployer);
        rehypoVault.setUserUseReserveAsCollateral();
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
        // ) = POOL_V3.getUserAccountData(vault);
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

        vm.startPrank(vault);

        // DataTypes.ReserveConfigurationMap memory data = POOL_V3
        //     .getConfiguration(address(collateralToken));
        // uint256 mask = 1 << 56;
        // bool isCollateralEnabled = (data.data & mask) != 0;
        // console.log(isCollateralEnabled, "<<< isCollateralEnabled");

        console.log(aToken.balanceOf(vault), "<<< aToken.balanceOf(vault)");
        console.log(
            IERC20(collateralToken).balanceOf(vault),
            "<<< collateralToken.balanceOf(vault)"
        );
        console.log(
            aToken.balanceOf(address(rehypoVault)),
            "<<< aToken.balanceOf(address(rehypoVault))"
        );
        console.log(
            IERC20(collateralToken).balanceOf(address(rehypoVault)),
            "<<< collateralToken.balanceOf(address(rehypoVault))"
        );

        // !
        collateralToken.approve(address(rehypoVault), principal);
        rehypoVault.deposit(1, principal);

        vm.stopPrank();

        vm.prank(deployer);
        rehypoVault.setUserUseReserveAsCollateral();

        vm.startPrank(vault);

        // collateralToken.approve(address(POOL_V3), principal);
        // POOL_V3.supply(address(collateralToken), principal, address(rehypoVault), 0);

        // POOL_V3.setUserUseReserveAsCollateral(address(collateralToken), false);
        // !

        console.log();
        console.log("AFTER DEPOSIT");
        console.log(aToken.balanceOf(vault), "<<< aToken.balanceOf(vault)");
        console.log(
            IERC20(collateralToken).balanceOf(vault),
            "<<< collateralToken.balanceOf(vault)"
        );
        console.log(
            aToken.balanceOf(address(rehypoVault)),
            "<<< aToken.balanceOf(address(rehypoVault))"
        );
        console.log(
            IERC20(collateralToken).balanceOf(address(rehypoVault)),
            "<<< collateralToken.balanceOf(address(rehypoVault))"
        );
        // console.log(
        //     IERC20(rewardToken).balanceOf(address(rehypoVault)),
        //     "<<< rewardToken.balanceOf(address(rehypoVault))"
        // );

        // !
        vm.warp(block.timestamp + 100 days);
        // !

        // vm.stopPrank();
        // vm.startPrank(deployer);
        // collateralToken.approve(address(POOL_V3), principal);
        // POOL_V3.supply(address(collateralToken), principal, deployer, 0);

        collateralToken.approve(address(rehypoVault), principal);
        rehypoVault.deposit(2, principal);

        console.log();
        console.log("AFTER TIME PASSED");
        console.log(aToken.balanceOf(vault), "<<< aToken.balanceOf(vault)");
        console.log(
            IERC20(collateralToken).balanceOf(vault),
            "<<< collateralToken.balanceOf(vault)"
        );
        console.log(
            aToken.balanceOf(address(rehypoVault)),
            "<<< aToken.balanceOf(address(rehypoVault))"
        );
        console.log(
            IERC20(collateralToken).balanceOf(address(rehypoVault)),
            "<<< collateralToken.balanceOf(address(rehypoVault))"
        );
        // console.log(
        //     IERC20(rewardToken).balanceOf(address(rehypoVault)),
        //     "<<< rewardToken.balanceOf(address(rehypoVault))"
        // );

        // console.log(
        //     INCENTIVES_V3.getUserRewards(assets, address(rehypoVault), address(rewardToken)),
        //     "<<< USER REWARDS"
        // );
        // console.log(
        //     INCENTIVES_V3.getUserAccruedRewards(address(rehypoVault), address(rewardToken)),
        //     "<<< ACCRUED REWARDS"
        // );

        // DataTypes.ReserveDataLegacy memory reserveData = POOL_V3.getReserveData(
        //     address(collateralToken)
        // );
        // console.log();
        // console.log(principal, "<<< principal");
        // uint256 timeElapsed = block.timestamp - reserveData.lastUpdateTimestamp;
        // console.log(timeElapsed, "<<< timeElapsed");
        // uint256 currentLiquidityRate = reserveData.currentLiquidityRate;
        // console.log(currentLiquidityRate, "<<< currentLiquidityRate");
        // uint256 interest = (principal * currentLiquidityRate * timeElapsed) /
        //     (365 * 24 * 3600 * 1e27);
        // console.log(interest, "<<< interest");

        // !
        // rehypoVault.withdraw(1);
        // POOL_V3.withdraw(address(collateralToken), principal + interest, address(rehypoVault)); // type(uint256).max

        // INCENTIVES_V3.claimRewards(
        //     assets,
        //     type(uint256).max,
        //     address(rehypoVault),
        //     address(rewardToken)
        // );
        // !

        // console.log();
        // console.log("AFTER CLAIM");
        // console.log(aToken.balanceOf(address(rehypoVault)), "<<< aToken.balanceOf(address(rehypoVault))");
        // console.log(
        //     IERC20(collateralToken).balanceOf(address(rehypoVault)),
        //     "<<< collateralToken.balanceOf(address(rehypoVault))"
        // );
        // console.log(
        //     IERC20(rewardToken).balanceOf(address(rehypoVault)),
        //     "<<< rewardToken.balanceOf(address(rehypoVault))"
        // );

        vm.stopPrank();
    }

    // function testInitialize() public {
    //     vm.startPrank(deployer);
    //     RehypothecationVault newVault = new RehypothecationVault();
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

    //     vm.startPrank(vault);
    //     uint256 initialBalance = collateralToken.balanceOf(vault);
    //     uint256 initialVaultBalance = collateralToken.balanceOf(
    //         address(rehypoVault)
    //     );

    //     collateralToken.approve(address(rehypoVault), amount);
    //     rehypoVault.deposit(positionId, amount);

    //     assertEq(
    //         rehypoVault.amounts(positionId),
    //         amount,
    //         "Amount not recorded correctly"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(vault),
    //         initialBalance - amount,
    //         "User balance not updated"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(address(rehypoVault)),
    //         initialVaultBalance,
    //         "Vault balance should not hold tokens"
    //     );
    //     vm.stopPrank();
    // }

    // function testDepositZeroAmount() public {
    //     vm.startPrank(vault);
    //     vm.expectRevert(RehypothecationVault.ZeroAmount.selector);
    //     rehypoVault.deposit(1, 0);
    //     vm.stopPrank();
    // }

    // function testDepositUnauthorized() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 1_000_000 ether;

    //     vm.startPrank(user2); // user2 is not the rehypoVault
    //     vm.expectRevert(RehypothecationVault.Unauthorized.selector);
    //     rehypoVault.deposit(positionId, amount);
    //     vm.stopPrank();
    // }

    // function testWithdraw() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 10000 ether;

    //     // Deposit
    //     vm.startPrank(vault);
    //     collateralToken.approve(address(rehypoVault), amount);
    //     rehypoVault.deposit(positionId, amount);

    //     // Withdraw
    //     uint256 expectedUserBalance = collateralToken.balanceOf(vault) + amount;
    //     uint256 expectedTreasuryBalance = collateralToken.balanceOf(treasury);

    //     rehypoVault.withdraw(positionId, amount);

    //     assertEq(
    //         rehypoVault.amounts(positionId),
    //         0,
    //         "Position amount not cleared"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(vault),
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
    //     vm.startPrank(vault);
    //     collateralToken.approve(address(rehypoVault), amount);
    //     rehypoVault.deposit(positionId, amount);
    //     vm.stopPrank();

    //     // Try to withdraw as user2
    //     vm.startPrank(user2);
    //     vm.expectRevert(RehypothecationVault.Unauthorized.selector);
    //     rehypoVault.withdraw(positionId, amount);
    //     vm.stopPrank();
    // }

    // function testSetVaultSuccess() public {
    //     vm.startPrank(deployer);
    //     rehypoVault.setVault(user2);
    //     assertEq(rehypoVault.vault(), user2, "Vault address not updated");
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
    //     rehypoVault.setVault(user2);
    //     vm.stopPrank();
    // }

    // function testUpdatePoolProxySuccess() public {
    //     address newPool = vm.addr(6);

    //     vm.startPrank(deployer);
    //     rehypoVault.updatePoolProxy(newPool);
    //     assertEq(
    //         address(rehypoVault.pool()),
    //         newPool,
    //         "Pool address not updated"
    //     );
    //     vm.stopPrank();
    // }

    // function testUpdatePoolProxyZeroAddress() public {
    //     vm.startPrank(deployer);
    //     vm.expectRevert(RehypothecationVault.InvalidAddress.selector);
    //     rehypoVault.updatePoolProxy(address(0));
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
    //     rehypoVault.updatePoolProxy(vm.addr(6));
    //     vm.stopPrank();
    // }

    // function testUpdateRewardsControllerSuccess() public {
    //     address newController = vm.addr(7);

    //     vm.startPrank(deployer);
    //     rehypoVault.updateRewardsController(newController);
    //     assertEq(
    //         address(rehypoVault.rewardsController()),
    //         newController,
    //         "Rewards controller not updated"
    //     );
    //     vm.stopPrank();
    // }

    // function testUpdateRewardsControllerZeroAddress() public {
    //     vm.startPrank(deployer);
    //     vm.expectRevert(RehypothecationVault.InvalidAddress.selector);
    //     rehypoVault.updateRewardsController(address(0));
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
    //     rehypoVault.updateRewardsController(vm.addr(7));
    //     vm.stopPrank();
    // }

    // function testClaimRewardSuccess() public {
    //     uint256 positionId = 1;
    //     uint256 amount = 10000 ether;

    //     vm.startPrank(vault);
    //     collateralToken.approve(address(rehypoVault), amount);
    //     rehypoVault.deposit(positionId, amount);

    //     uint256 oldVaultBalance = collateralToken.balanceOf(
    //         address(rehypoVault)
    //     );
    //     uint256 oldTreasuryAmount = collateralToken.balanceOf(treasury);

    //     vm.warp(block.timestamp + 100 days); // pass 100 days

    //     assertGt(
    //         rehypoVault.getUserRewards(),
    //         0,
    //         "User Rewards should be greater than 0"
    //     );

    //     rehypoVault.withdraw(positionId, amount);
    //     assertGt(
    //         rehypoVault.getAccumulatedRewards(),
    //         0,
    //         "Accumulated Rewards should be greater than 0"
    //     );

    //     vm.stopPrank();

    //     vm.startPrank(deployer);

    //     rehypoVault.claimReward();

    //     uint256 rehypoRewardBalance = rewardToken.balanceOf(
    //         address(rehypoVault)
    //     );

    //     assertGt(
    //         rehypoRewardBalance,
    //         oldVaultBalance,
    //         "User reward balance not updated"
    //     );

    //     rehypoVault.withdrawToken(address(rewardToken), rehypoRewardBalance);

    //     assertGt(
    //         rewardToken.balanceOf(treasury),
    //         oldTreasuryAmount,
    //         "Treasury reward balance not updated"
    //     );
    //     vm.stopPrank();
    // }

    // function testClaimRewardZeroRewards() public {
    //     vm.startPrank(deployer);
    //     vm.expectRevert(RehypothecationVault.ZeroReward.selector);
    //     rehypoVault.claimReward();
    //     vm.stopPrank();
    // }

    // function testClaimRewardUnauthorized() public {
    //     vm.startPrank(user2); // user2 is not the vault
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
    //             user2
    //         )
    //     );
    //     rehypoVault.claimReward();
    //     vm.stopPrank();
    // }

    // function testWithdrawTokenSuccess() public {
    //     uint256 amount = 1000 ether;

    //     vm.startPrank(deployer);
    //     collateralToken.transfer(address(rehypoVault), amount);

    //     rehypoVault.withdrawToken(address(collateralToken), amount);

    //     assertEq(
    //         collateralToken.balanceOf(treasury),
    //         amount,
    //         "Treasury balance not updated"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(address(rehypoVault)),
    //         0,
    //         "Vault balance not cleared"
    //     );
    //     vm.stopPrank();
    // }

    // function testWithdrawTokenZeroAmount() public {
    //     vm.startPrank(deployer);
    //     vm.expectRevert(RehypothecationVault.ZeroAmount.selector);
    //     rehypoVault.withdrawToken(address(collateralToken), 0);
    //     vm.stopPrank();
    // }

    // function testWithdrawTokenNonOwner() public {
    //     vm.startPrank(user2);
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
    //             user2
    //         )
    //     );
    //     rehypoVault.withdrawToken(address(collateralToken), 100_000 ether);
    //     vm.stopPrank();
    // }

    // function testMultipleUsers() public {
    //     uint256 positionId1 = 1;
    //     uint256 positionId2 = 2;
    //     uint256 amount1 = 500 ether;
    //     uint256 amount2 = 300 ether;

    //     uint256 initialBalance = collateralToken.balanceOf(vault);

    //     vm.startPrank(vault);

    //     collateralToken.approve(address(rehypoVault), 1000 ether);

    //     rehypoVault.deposit(positionId1, amount1);
    //     assertEq(
    //         rehypoVault.amounts(positionId1),
    //         amount1,
    //         "position 1 amount incorrect"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(vault),
    //         initialBalance - amount1,
    //         "vault first deposit balance incorrect"
    //     );

    //     rehypoVault.deposit(positionId2, amount2);
    //     assertEq(
    //         rehypoVault.amounts(positionId2),
    //         amount2,
    //         "position 2 amount incorrect"
    //     );
    //     assertEq(
    //         collateralToken.balanceOf(vault),
    //         initialBalance - amount1 - amount2,
    //         "vault second deposit balance incorrect"
    //     );

    //     // uint256 withdrawAmount1 = 500 ether;
    //     // rehypoVault.withdraw(positionId1, withdrawAmount1);
    //     // assertEq(
    //     //     rehypoVault.amounts(positionId1),
    //     //     amount1 - withdrawAmount1,
    //     //     "position 1 amount after withdraw incorrect"
    //     // );
    //     // assertEq(
    //     //     collateralToken.balanceOf(vault),
    //     //     (initialBalance - amount1 - amount2) + withdrawAmount1,
    //     //     "vault first withdraw balance incorrect"
    //     // );

    //     // rehypoVault.withdraw(positionId2, amount2);
    //     // assertEq(rehypoVault.amounts(positionId2), 0, "position 2 not cleared");
    //     // assertEq(
    //     //     collateralToken.balanceOf(vault),
    //     //     (initialBalance - amount1) + withdrawAmount1,
    //     //     "vault second withdraw balance incorrect"
    //     // );
    //     vm.stopPrank();
    // }
}