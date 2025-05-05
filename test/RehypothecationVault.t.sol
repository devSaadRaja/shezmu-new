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

        rehypoVault = new RehypothecationVault();
        rehypoVault.initialize(
            treasury,
            address(collateralToken),
            address(aToken),
            address(rewardToken),
            address(POOL_V3),
            address(INCENTIVES_V3)
        );

        rehypoVault.setVault(user1);

        collateralToken.transfer(user1, 2_000_000 ether);
        collateralToken.transfer(user2, 2_000_000 ether);

        vm.stopPrank();
    }

    // ================================================ //
    // ================== TEST CASES ================== //
    // ================================================ //

    // function test_TEST() public {
    //     // address[] memory reserveAddresses = POOL_V3.getReservesList();
    //     // for (uint i = 0; i < reserveAddresses.length; i++) {
    //     //     console.log();
    //     //     address reserve = reserveAddresses[i];
    //     //     console.log(reserve, "<<< reserve");
    //     //     address aT = POOL_V3.getReserveAToken(reserve);
    //     //     console.log(aT, "<<< aT");
    //     //     address[] memory rewards = INCENTIVES_V3.getRewardsByAsset(aT);
    //     //     for (uint j = 0; j < rewards.length; j++) {
    //     //         console.log(rewards[j], "<<< rewards[j]");
    //     //     }
    //     //     console.log();
    //     // }

    //     vm.startPrank(user1);

    //     console.log(aToken.balanceOf(user1), "<<< aToken.balanceOf(user1)");
    //     console.log(
    //         IERC20(collateralToken).balanceOf(user1),
    //         "<<< collateralToken.balanceOf(user1)"
    //     );

    //     // !
    //     collateralToken.approve(address(rehypoVault), 1000 ether);
    //     rehypoVault.deposit(1, 1000 ether);

    //     // collateralToken.approve(address(POOL_V3), 1000 ether);
    //     // POOL_V3.supply(address(collateralToken), 1000 ether, user1, 0);
    //     // !

    //     console.log();
    //     console.log("AFTER DEPOSIT");
    //     console.log(aToken.balanceOf(user1), "<<< aToken.balanceOf(user1)");
    //     console.log(
    //         IERC20(collateralToken).balanceOf(user1),
    //         "<<< collateralToken.balanceOf(user1)"
    //     );
    //     console.log(
    //         IERC20(rewardToken).balanceOf(user1),
    //         "<<< rewardToken.balanceOf(user1)"
    //     );

    //     vm.warp(block.timestamp + 120 days);

    //     // !
    //     // rehypoVault.withdraw(1);

    //     // POOL_V3.withdraw(address(collateralToken), type(uint256).max, user1);

    //     address[] memory assets = new address[](1);
    //     assets[0] = address(aToken);
    //     console.log(
    //         INCENTIVES_V3.getUserRewards(assets, user1, address(rewardToken)),
    //         "<<< USER REWARDS"
    //     );
    //     console.log(
    //         INCENTIVES_V3.getUserAccruedRewards(user1, address(rewardToken)),
    //         "<<< ACCRUED REWARDS"
    //     );
    //     // INCENTIVES_V3.claimRewards(
    //     //     assets,
    //     //     type(uint256).max,
    //     //     user1,
    //     //     address(rewardToken)
    //     // );
    //     // !

    //     console.log();
    //     console.log("AFTER CLAIM");
    //     console.log(aToken.balanceOf(user1), "<<< aToken.balanceOf(user1)");
    //     console.log(
    //         IERC20(collateralToken).balanceOf(user1),
    //         "<<< collateralToken.balanceOf(user1)"
    //     );
    //     console.log(
    //         IERC20(rewardToken).balanceOf(user1),
    //         "<<< rewardToken.balanceOf(user1)"
    //     );

    //     vm.stopPrank();
    // }

    function testInitialize() public {
        vm.startPrank(deployer);
        RehypothecationVault newVault = new RehypothecationVault();
        newVault.initialize(
            treasury,
            address(collateralToken),
            address(aToken),
            address(rewardToken),
            address(POOL_V3),
            address(INCENTIVES_V3)
        );

        assertEq(newVault.owner(), deployer, "Owner not set correctly");
        assertEq(newVault.treasury(), treasury, "Treasury not set correctly");
        assertEq(
            address(newVault.collateralToken()),
            address(collateralToken),
            "Collateral token not set correctly"
        );
        assertEq(
            address(newVault.rewardToken()),
            address(aToken),
            "Reward token not set correctly"
        );
        assertEq(
            address(newVault.pool()),
            address(POOL_V3),
            "Pool not set correctly"
        );
        assertEq(
            address(newVault.rewardsController()),
            address(INCENTIVES_V3),
            "Rewards controller not set correctly"
        );
    }

    function testDepositSuccess() public {
        uint256 positionId = 1;
        uint256 amount = 1000 ether;

        vm.startPrank(user1);
        uint256 initialBalance = collateralToken.balanceOf(user1);
        uint256 initialVaultBalance = collateralToken.balanceOf(
            address(rehypoVault)
        );

        collateralToken.approve(address(rehypoVault), amount);
        rehypoVault.deposit(positionId, amount);

        assertEq(
            rehypoVault.amounts(positionId),
            amount,
            "Amount not recorded correctly"
        );
        assertEq(
            collateralToken.balanceOf(user1),
            initialBalance - amount,
            "User balance not updated"
        );
        assertEq(
            collateralToken.balanceOf(address(rehypoVault)),
            initialVaultBalance,
            "Vault balance should not hold tokens"
        );
        vm.stopPrank();
    }

    function testDepositZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(RehypothecationVault.ZeroAmount.selector);
        rehypoVault.deposit(1, 0);
        vm.stopPrank();
    }

    function testDepositActivePosition() public {
        uint256 positionId = 1;
        uint256 amount = 1000 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(rehypoVault), amount);
        rehypoVault.deposit(positionId, amount);

        vm.expectRevert(RehypothecationVault.AlreadyActive.selector);
        rehypoVault.deposit(positionId, amount);
        vm.stopPrank();
    }

    function testDepositUnauthorized() public {
        uint256 positionId = 1;
        uint256 amount = 1_000_000 ether;

        vm.startPrank(user2); // user2 is not the rehypoVault
        vm.expectRevert(RehypothecationVault.Unauthorized.selector);
        rehypoVault.deposit(positionId, amount);
        vm.stopPrank();
    }

    function testWithdrawWithInterest() public {
        uint256 positionId = 1;
        uint256 amount = 10000 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(rehypoVault), amount);
        rehypoVault.deposit(positionId, amount);

        uint256 oldUserBalance = collateralToken.balanceOf(treasury);
        uint256 oldTreasuryAmount = collateralToken.balanceOf(treasury);

        vm.warp(block.timestamp + 100 days); // pass 100 days

        rehypoVault.withdraw(positionId);

        assertEq(
            rehypoVault.amounts(positionId),
            0,
            "Position amount not cleared"
        );
        assertGt(
            collateralToken.balanceOf(user1),
            oldUserBalance,
            "User balance not updated"
        );
        assertGt(
            collateralToken.balanceOf(treasury),
            oldTreasuryAmount,
            "Treasury balance not updated"
        );
        vm.stopPrank();
    }

    function testWithdrawNoInterest() public {
        uint256 positionId = 1;
        uint256 amount = 10000 ether;

        // Deposit
        vm.startPrank(user1);
        collateralToken.approve(address(rehypoVault), amount);
        rehypoVault.deposit(positionId, amount);

        // Withdraw
        uint256 expectedUserBalance = collateralToken.balanceOf(user1) + amount;
        uint256 expectedTreasuryBalance = collateralToken.balanceOf(treasury);

        rehypoVault.withdraw(positionId);

        assertEq(
            rehypoVault.amounts(positionId),
            0,
            "Position amount not cleared"
        );
        assertEq(
            collateralToken.balanceOf(user1),
            expectedUserBalance,
            "User balance not updated"
        );
        assertEq(
            collateralToken.balanceOf(treasury),
            expectedTreasuryBalance,
            "Treasury balance not updated"
        );
        vm.stopPrank();
    }

    function testWithdrawUnauthorized() public {
        uint256 positionId = 1;
        uint256 amount = 10000 ether;

        // Deposit
        vm.startPrank(user1);
        collateralToken.approve(address(rehypoVault), amount);
        rehypoVault.deposit(positionId, amount);
        vm.stopPrank();

        // Try to withdraw as user2
        vm.startPrank(user2);
        vm.expectRevert(RehypothecationVault.Unauthorized.selector);
        rehypoVault.withdraw(positionId);
        vm.stopPrank();
    }

    function testSetVaultSuccess() public {
        vm.startPrank(deployer);
        rehypoVault.setVault(user2);
        assertEq(rehypoVault.vault(), user2, "Vault address not updated");
        vm.stopPrank();
    }

    function testSetVaultNonOwner() public {
        vm.startPrank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                user2
            )
        );
        rehypoVault.setVault(user2);
        vm.stopPrank();
    }

    function testUpdatePoolProxySuccess() public {
        address newPool = vm.addr(6);

        vm.startPrank(deployer);
        rehypoVault.updatePoolProxy(newPool);
        assertEq(
            address(rehypoVault.pool()),
            newPool,
            "Pool address not updated"
        );
        vm.stopPrank();
    }

    function testUpdatePoolProxyZeroAddress() public {
        vm.startPrank(deployer);
        vm.expectRevert(RehypothecationVault.InvalidAddress.selector);
        rehypoVault.updatePoolProxy(address(0));
        vm.stopPrank();
    }

    function testUpdatePoolProxyNonOwner() public {
        vm.startPrank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                user2
            )
        );
        rehypoVault.updatePoolProxy(vm.addr(6));
        vm.stopPrank();
    }

    function testUpdateRewardsControllerSuccess() public {
        address newController = vm.addr(7);

        vm.startPrank(deployer);
        rehypoVault.updateRewardsController(newController);
        assertEq(
            address(rehypoVault.rewardsController()),
            newController,
            "Rewards controller not updated"
        );
        vm.stopPrank();
    }

    function testUpdateRewardsControllerZeroAddress() public {
        vm.startPrank(deployer);
        vm.expectRevert(RehypothecationVault.InvalidAddress.selector);
        rehypoVault.updateRewardsController(address(0));
        vm.stopPrank();
    }

    function testUpdateRewardsControllerNonOwner() public {
        vm.startPrank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                user2
            )
        );
        rehypoVault.updateRewardsController(vm.addr(7));
        vm.stopPrank();
    }

    function testClaimRewardSuccess() public {
        uint256 positionId = 1;
        uint256 amount = 10000 ether;

        vm.startPrank(user1);
        collateralToken.approve(address(rehypoVault), amount);
        rehypoVault.deposit(positionId, amount);

        uint256 oldUserBalance = collateralToken.balanceOf(treasury);
        uint256 oldTreasuryAmount = collateralToken.balanceOf(treasury);

        vm.warp(block.timestamp + 100 days); // pass 100 days

        assertGt(
            rehypoVault.getUserRewards(address(rehypoVault)),
            0,
            "User Rewards should be greater than 0"
        );

        rehypoVault.withdraw(positionId);
        assertGt(
            rehypoVault.getAccumulatedRewards(address(rehypoVault)),
            0,
            "Accumulated Rewards should be greater than 0"
        );

        rehypoVault.claimReward();

        assertGt(
            rewardToken.balanceOf(user1),
            oldUserBalance,
            "User reward balance not updated"
        );
        assertGt(
            rewardToken.balanceOf(treasury),
            oldTreasuryAmount,
            "Treasury reward balance not updated"
        );
        vm.stopPrank();
    }

    function testClaimRewardZeroRewards() public {
        vm.startPrank(user1);
        vm.expectRevert(RehypothecationVault.ZeroReward.selector);
        rehypoVault.claimReward();
        vm.stopPrank();
    }

    function testClaimRewardUnauthorized() public {
        vm.startPrank(user2); // user2 is not the vault
        vm.expectRevert(RehypothecationVault.Unauthorized.selector);
        rehypoVault.claimReward();
        vm.stopPrank();
    }
}
