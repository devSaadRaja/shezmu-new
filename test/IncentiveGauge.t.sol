// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import "../src/InterestCollector.sol";
import "../src/ERC20Vault.sol";
import "../src/IncentiveGauge.sol";
import "../src/mock/MockERC20Mintable.sol";
import "../src/mock/MockPriceFeed.sol";

contract IncentiveGaugeTest is Test {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    ERC20Vault vault;
    IERC20 WETH; // collateral token
    MockERC20Mintable shezUSD; // loan token
    MockERC20Mintable USDT; // incentive token
    InterestCollector interestCollector;
    IncentiveGauge incentiveGauge;

    MockPriceFeed wethPriceFeed;
    MockPriceFeed shezUSDPriceFeed;

    address deployer = vm.addr(1);
    address user1 = vm.addr(2);
    address user2 = vm.addr(3);
    address depositor = vm.addr(4);
    address treasury = vm.addr(5);

    uint256 constant INITIAL_LTV = 50;
    uint256 constant LIQUIDATION_THRESHOLD = 90; // 90% of INITIAL_LTV
    uint256 constant LIQUIDATOR_REWARD = 50; // 50%
    uint256 constant INTEREST_RATE = 500; // 5% annual interest in basis points
    uint256 constant PROTOCOL_FEE = 2500; // bips (2500 = 25%)

    // =========================================== //
    // ================== SETUP ================== //
    // =========================================== //

    function setUp() public {
        vm.startPrank(deployer);

        WETH = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        deal(address(WETH), deployer, 1_000_000_000 ether);

        shezUSD = new MockERC20Mintable("Shez USD", "shezUSD");
        USDT = new MockERC20Mintable("Tether USD", "USDT");

        wethPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8);
        shezUSDPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8);

        interestCollector = new InterestCollector(treasury);

        vault = new ERC20Vault(
            address(WETH),
            address(shezUSD),
            INITIAL_LTV,
            LIQUIDATION_THRESHOLD,
            LIQUIDATOR_REWARD,
            address(wethPriceFeed),
            address(shezUSDPriceFeed),
            treasury,
            address(0)
        );
        vault.setInterestCollector(address(interestCollector));
        vault.toggleInterestCollection(true);

        interestCollector.registerVault(address(vault), INTEREST_RATE);

        incentiveGauge = new IncentiveGauge(
            address(vault),
            treasury,
            PROTOCOL_FEE
        );

        WETH.transfer(user1, 2_000_000 ether);
        WETH.transfer(user2, 2_000_000 ether);

        USDT.transfer(depositor, 2_000_000 * 10 ** 6);

        shezUSD.grantRole(keccak256("MINTER_ROLE"), address(vault));
        shezUSD.grantRole(keccak256("BURNER_ROLE"), address(vault));

        incentiveGauge.grantRole(keccak256("PROTOCOL_ROLE"), depositor);
        incentiveGauge.setAllowedToken(address(USDT), true);

        vm.stopPrank();

        vm.startPrank(user1);
        vault.setDoNotMint(true);
        vault.setInterestOptOut(true);
        vm.stopPrank();

        vm.startPrank(user2);
        vault.setDoNotMint(true);
        vault.setInterestOptOut(true);
        vm.stopPrank();
    }

    // ================================================ //
    // ================== TEST CASES ================== //
    // ================================================ //

    function testRevertIfTokenZero() public {
        vm.startPrank(depositor);
        vm.expectRevert(IncentiveGauge.InvalidToken.selector);
        incentiveGauge.depositIncentives(
            address(0),
            1000 * 10 ** 6,
            address(WETH)
        );
        vm.stopPrank();
    }

    function testRevertIfAmountZero() public {
        vm.startPrank(depositor);
        vm.expectRevert(IncentiveGauge.ZeroAmount.selector);
        incentiveGauge.depositIncentives(address(USDT), 0, address(WETH));
        vm.stopPrank();
    }

    function testRevertIfInvalidCollateral() public {
        vm.startPrank(depositor);
        vm.expectRevert(IncentiveGauge.InvalidCollateralType.selector);
        incentiveGauge.depositIncentives(
            address(USDT),
            1000 * 10 ** 6,
            address(USDT)
        );
        vm.stopPrank();
    }

    function testRevertIfNotProtocolRole() public {
        vm.startPrank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                deployer,
                keccak256("PROTOCOL_ROLE")
            )
        );
        incentiveGauge.depositIncentives(
            address(USDT),
            1000 * 10 ** 6,
            address(WETH)
        );
        vm.stopPrank();
    }

    function testRevertInvalidToken() public {
        vm.startPrank(depositor);
        USDT.approve(address(incentiveGauge), 1000 * 10 ** 6);
        incentiveGauge.depositIncentives(
            address(USDT),
            1000 * 10 ** 6,
            address(WETH)
        );
        vm.expectRevert(IncentiveGauge.InvalidToken.selector);
        incentiveGauge.depositIncentives(
            address(WETH),
            1000 * 10 ** 6,
            address(WETH)
        );
        vm.stopPrank();
    }

    function testDepositIncentivesSuccess() public {
        vm.startPrank(depositor);
        uint256 amount = 1000 * 10 ** 6;
        USDT.approve(address(incentiveGauge), amount);
        incentiveGauge.depositIncentives(address(USDT), amount, address(WETH));
        (
            uint256 totalDeposited,
            uint256 rewardRate,
            uint256 periodStart,
            uint256 periodFinish,
            uint256 lastUpdateTime
        ) = incentiveGauge.getPoolData(address(USDT));

        uint256 protocolAmount = (amount * PROTOCOL_FEE) / 10000;
        uint256 depositAmount = amount - protocolAmount;

        assertEq(totalDeposited, depositAmount);
        assertEq(periodStart, block.timestamp);
        assertEq(periodFinish, block.timestamp + 30 days);
        assertEq(rewardRate, depositAmount / uint256(30 days));
        assertEq(USDT.balanceOf(address(treasury)), protocolAmount);
        assertEq(USDT.balanceOf(address(incentiveGauge)), depositAmount);
        assertEq(lastUpdateTime, block.timestamp);
        vm.stopPrank();
    }

    function testRewardDistributionTwoUsers() public {
        // Total collateral = 1000 ether
        _openPosition(user1, 100 ether, 0);
        _openPosition(user2, 900 ether, 0);

        vm.startPrank(depositor);
        USDT.approve(address(incentiveGauge), 1000 * 10 ** 6);
        incentiveGauge.depositIncentives(
            address(USDT),
            1000 * 10 ** 6,
            address(WETH)
        );
        vm.stopPrank();

        // Fast forward half of reward period (15 days)
        vm.warp(block.timestamp + (incentiveGauge.VESTING_DURATION() / 2));

        uint256 user1Rewards = incentiveGauge.getClaimableRewards(
            address(USDT),
            user1
        );
        uint256 user2Rewards = incentiveGauge.getClaimableRewards(
            address(USDT),
            user2
        );

        assertEq(user1Rewards, 37.5 * 10 ** 6);
        assertEq(user2Rewards, 337.5 * 10 ** 6);

        // Fast forward to end of reward period (30 days)
        vm.warp(block.timestamp + (incentiveGauge.VESTING_DURATION() / 2));

        user1Rewards = incentiveGauge.getClaimableRewards(address(USDT), user1);
        user2Rewards = incentiveGauge.getClaimableRewards(address(USDT), user2);

        assertEq(user1Rewards, 75 * 10 ** 6);
        assertEq(user2Rewards, 675 * 10 ** 6);
    }

    function _openPosition(
        address user,
        uint256 collateralAmount,
        uint256 debtAmount
    ) internal returns (uint256) {
        vm.startPrank(user);

        WETH.approve(address(vault), collateralAmount);
        vault.openPosition(
            user,
            address(WETH),
            collateralAmount,
            debtAmount,
            1 // leverage
        );
        uint256[] memory positionIds = vault.getUserPositionIds(user);

        vm.stopPrank();

        return positionIds[positionIds.length - 1];
    }
}
