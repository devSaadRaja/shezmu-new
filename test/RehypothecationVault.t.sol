// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

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
    IERC20 AAVE = IERC20(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    IPool POOL_V3 = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IRewardsController INCENTIVES_V3 =
        IRewardsController(0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb);

    RehypothecationVault vault;

    IERC20 WETH; // collateral
    IERC20 aEthWETH; // just like LP tokens

    address deployer = vm.addr(1);
    address user1 = vm.addr(2);
    address user2 = vm.addr(3);
    address treasury = vm.addr(4);

    // =========================================== //
    // ================== SETUP ================== //
    // =========================================== //

    function setUp() public {
        vm.startPrank(deployer);

        WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        deal(address(WETH), deployer, 1_000_000_000 ether);

        aEthWETH = IERC20(0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8);

        vault = new RehypothecationVault();
        vault.initialize(
            treasury,
            address(WETH),
            address(aEthWETH),
            address(POOL_V3),
            address(INCENTIVES_V3)
        );

        vault.setVault(user1);

        WETH.transfer(user1, 2_000_000 ether);
        WETH.transfer(user2, 2_000_000 ether);

        vm.stopPrank();
    }

    // ================================================ //
    // ================== TEST CASES ================== //
    // ================================================ //

    function test_Deposit() public {
        vm.startPrank(user1);

        console.log(aEthWETH.balanceOf(user1), "<<< aEthWETH.balanceOf(user1)");
        console.log(IERC20(WETH).balanceOf(user1), "<<< WETH.balanceOf(user1)");

        // !
        // WETH.approve(address(vault), 1000 ether);
        // vault.deposit(1, 1000 ether);

        WETH.approve(address(POOL_V3), 1000 ether);
        POOL_V3.supply(address(WETH), 1000 ether, user1, 0);
        // !

        console.log();
        console.log("AFTER DEPOSIT");
        console.log(aEthWETH.balanceOf(user1), "<<< aEthWETH.balanceOf(user1)");
        console.log(IERC20(WETH).balanceOf(user1), "<<< WETH.balanceOf(user1)");

        vm.warp(block.timestamp + 60 days);

        // !
        aEthWETH.approve(address(POOL_V3), type(uint256).max);
        POOL_V3.withdraw(address(WETH), type(uint256).max, user1);
        
        address[] memory assets = new address[](1);
        assets[0] = address(aEthWETH);
        INCENTIVES_V3.claimRewards(
            assets,
            type(uint256).max,
            user1,
            address(AAVE)
        );
        // !

        console.log("AFTER CLAIM");
        console.log(aEthWETH.balanceOf(user1), "<<< aEthWETH.balanceOf(user1)");
        console.log(IERC20(WETH).balanceOf(user1), "<<< WETH.balanceOf(user1)");
        console.log(IERC20(AAVE).balanceOf(user1), "<<< AAVE.balanceOf(user1)");

        vm.stopPrank();
    }
}
