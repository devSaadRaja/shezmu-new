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

        USDT.transfer(depositor, 2_000_000 ether);

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
        incentiveGauge.depositIncentives(address(0), 1000 ether, address(WETH));
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
            1000 ether,
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
            1000 ether,
            address(WETH)
        );
        vm.stopPrank();
    }

    function testRevertInvalidToken() public {
        vm.startPrank(depositor);
        USDT.approve(address(incentiveGauge), 1000 ether);
        incentiveGauge.depositIncentives(
            address(USDT),
            1000 ether,
            address(WETH)
        );
        vm.expectRevert(IncentiveGauge.InvalidToken.selector);
        incentiveGauge.depositIncentives(
            address(WETH),
            1000 ether,
            address(WETH)
        );
        vm.stopPrank();
    }

    function testDepositIncentivesSuccess() public {
        _openPosition(user1, 100 ether, 0);

        vm.startPrank(depositor);
        uint256 amount = 1000 ether;
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

    // function testZeroTotalCollateralReturnsZeroRewards() public {
    //     // Deposit 10,000 USDT incentives without any collateral
    //     vm.startPrank(depositor);
    //     uint256 totalIncentive = 10000 ether;
    //     USDT.approve(address(incentiveGauge), totalIncentive);
    //     incentiveGauge.depositIncentives(
    //         address(USDT),
    //         totalIncentive,
    //         address(WETH)
    //     );
    //     vm.stopPrank();

    //     // Fast forward to end of reward period
    //     vm.warp(block.timestamp + incentiveGauge.VESTING_DURATION());

    //     // No collateral in vault
    //     assertEq(vault.totalCollateral(), 0);

    //     // Check rewards for user1 (no position)
    //     uint256 user1Rewards = incentiveGauge.getClaimableIncentives(
    //         address(WETH),
    //         user1
    //     );
    //     assertEq(user1Rewards, 0);

    //     // treasury still gets 25% = 2,500 USDT
    //     assertEq(USDT.balanceOf(treasury), 2500 ether);
    // }

    function testRewardDistributionTwoUsers() public {
        // Total collateral = 1000 ether
        _openPosition(user1, 100 ether, 0);
        _openPosition(user2, 900 ether, 0);

        vm.startPrank(depositor);
        USDT.approve(address(incentiveGauge), 1000 ether);
        incentiveGauge.depositIncentives(
            address(USDT),
            1000 ether,
            address(WETH)
        );
        vm.stopPrank();

        // Fast forward half of reward period (15 days)
        vm.warp(block.timestamp + (incentiveGauge.VESTING_DURATION() / 2));

        uint256 user1Rewards = incentiveGauge.getClaimableIncentives(
            address(USDT),
            user1
        );
        uint256 user2Rewards = incentiveGauge.getClaimableIncentives(
            address(USDT),
            user2
        );

        assertEq(user1Rewards, 37.5 ether);
        assertEq(user2Rewards, 337.5 ether);
        // assertApproxEqAbs(user1Rewards, 37.5 ether, 1e7);
        // assertApproxEqAbs(user2Rewards, 337.5 ether, 1e7);

        // Fast forward to end of reward period (30 days)
        vm.warp(block.timestamp + (incentiveGauge.VESTING_DURATION() / 2));

        user1Rewards = incentiveGauge.getClaimableIncentives(
            address(USDT),
            user1
        );
        user2Rewards = incentiveGauge.getClaimableIncentives(
            address(USDT),
            user2
        );

        assertEq(user1Rewards, 75 ether);
        assertEq(user2Rewards, 675 ether);
        // assertApproxEqAbs(user1Rewards, 75 ether, 1e7);
        // assertApproxEqAbs(user2Rewards, 675 ether, 1e7);

        // protocol fee to treasury
        assertEq(USDT.balanceOf(treasury), 250 ether);
    }

    function testRewardDistributionWithLateCollateralAddition() public {
        // User1 deposits 100 ether collateral at start
        _openPosition(user1, 100 ether, 0);

        // Depositor adds 1000 USDT incentives
        vm.startPrank(depositor);
        uint256 totalIncentive = 1000 ether;
        USDT.approve(address(incentiveGauge), totalIncentive);
        incentiveGauge.depositIncentives(
            address(USDT),
            totalIncentive,
            address(WETH)
        );
        vm.stopPrank();

        // Verify 25% protocol fee (250 USDT) goes to treasury, 75% (750 USDT) to pool
        assertEq(USDT.balanceOf(treasury), 250 ether);
        assertEq(USDT.balanceOf(address(incentiveGauge)), 750 ether);

        // Fast forward 10 days
        vm.warp(block.timestamp + (incentiveGauge.VESTING_DURATION() / 3));

        uint256 user1Rewards = incentiveGauge.getClaimableIncentives(
            address(USDT),
            user1
        );
        assertEq(user1Rewards, 250 ether);

        // User2 adds 900 ether collateral
        _openPosition(user2, 900 ether, 0);

        vm.prank(address(vault));
        // incentiveGauge.notifyCollateralUpdate(address(USDT), user2);
        incentiveGauge.onCollateralBalanceChange(user2, address(USDT));

        // Fast forward to end of 30-day period
        vm.warp(
            block.timestamp + ((2 * incentiveGauge.VESTING_DURATION()) / 3)
        );

        // Check rewards
        user1Rewards = incentiveGauge.getClaimableIncentives(
            address(USDT),
            user1
        );
        uint256 user2Rewards = incentiveGauge.getClaimableIncentives(
            address(USDT),
            user2
        );

        // User1 gets 100% for first 10 days, then 10% for last 20 days
        // Total pool rewards = 750 USDT
        // First 10 days = 750 / 3 = 250 USDT, User1 gets all = 250 USDT
        // Last 20 days = 750 * 2/3 = 500 USDT, User1 gets 10% = 50 USDT
        // Total User1 = 250 + 50 = 300 USDT
        // assertEq(user1Rewards, 300 ether);
        assertApproxEqAbs(user1Rewards, 300 ether, 1e7);

        // User2 gets 90% for last 20 days = 90% of 500 USDT = 450 USDT
        assertApproxEqAbs(user2Rewards, 450 ether, 1e7);

        // Total rewards = 300 + 450 = 750 USDT
        assertApproxEqAbs(user1Rewards + user2Rewards, 750 ether, 1e7);
    }

    // function testAddCollateralMidPeriod() public {
    //     // User1 and User2 open positions
    //     _openPosition(user1, 100 ether, 0);
    //     _openPosition(user2, 900 ether, 0);

    //     // Depositor adds 1000 USDT incentives
    //     vm.startPrank(depositor);
    //     uint256 totalIncentive = 1000 ether;
    //     USDT.approve(address(incentiveGauge), totalIncentive);
    //     incentiveGauge.depositIncentives(
    //         address(USDT),
    //         totalIncentive,
    //         address(WETH)
    //     );
    //     vm.stopPrank();

    //     // Verify protocol fee
    //     assertEq(USDT.balanceOf(treasury), 250 ether);
    //     assertEq(USDT.balanceOf(address(incentiveGauge)), 750 ether);

    //     // Fast forward 15 days
    //     vm.warp(block.timestamp + (incentiveGauge.VESTING_DURATION() / 2));

    //     // User1 adds 100 ether more collateral
    //     vm.startPrank(user1);
    //     WETH.approve(address(vault), 100 ether);
    //     uint256 positionId = vault.getUserPositionIds(user1)[0];
    //     vault.addCollateral(positionId, 100 ether);
    //     vm.stopPrank();

    //     // Fast forward to end of period
    //     vm.warp(block.timestamp + (incentiveGauge.VESTING_DURATION() / 2));

    //     // Check rewards
    //     uint256 user1Rewards = incentiveGauge.getClaimableIncentives(
    //         address(USDT),
    //         user1
    //     );
    //     uint256 user2Rewards = incentiveGauge.getClaimableIncentives(
    //         address(USDT),
    //         user2
    //     );

    //     // Total pool rewards = 750 USDT
    //     // First 15 days: User1 = 10% (100/1000), User2 = 90% (900/1000)
    //     // Rewards for 15 days = 750 / 2 = 375 USDT
    //     // User1 = 10% of 375 = 37.5 USDT
    //     // User2 = 90% of 375 = 337.5 USDT
    //     // Last 15 days: User1 = 18.18% (200/1100), User2 = 81.82% (900/1100)
    //     // Rewards for 15 days = 375 USDT
    //     // User1 = 18.18% of 375 ≈ 68.18 USDT
    //     // User2 = 81.82% of 375 ≈ 306.82 USDT
    //     // Total User1 = 37.5 + 68.18 ≈ 105.68 USDT
    //     // Total User2 = 337.5 + 306.82 ≈ 644.32 USDT
    //     assertApproxEqAbs(user1Rewards, 105.68 ether, 1e7);
    //     assertApproxEqAbs(user2Rewards, 644.32 ether, 1e7);

    //     // Total rewards = 750 USDT
    //     assertApproxEqAbs(user1Rewards + user2Rewards, 750 ether, 1e7);
    // }

    // function testDepositIncentivesDuringActivePeriod() public {
    //     // User1 and User2 open positions
    //     _openPosition(user1, 100 ether, 0);
    //     _openPosition(user2, 900 ether, 0);

    //     // Depositor adds 1000 USDT incentives
    //     vm.startPrank(depositor);
    //     uint256 firstIncentive = 1000 ether;
    //     USDT.approve(address(incentiveGauge), firstIncentive);
    //     incentiveGauge.depositIncentives(
    //         address(USDT),
    //         firstIncentive,
    //         address(WETH)
    //     );
    //     vm.stopPrank();

    //     // Fast forward 10 days
    //     vm.warp(block.timestamp + (incentiveGauge.VESTING_DURATION() / 3));

    //     // Depositor adds another 1000 USDT
    //     vm.startPrank(depositor);
    //     uint256 secondIncentive = 1000 ether;
    //     USDT.approve(address(incentiveGauge), secondIncentive);
    //     incentiveGauge.depositIncentives(
    //         address(USDT),
    //         secondIncentive,
    //         address(WETH)
    //     );
    //     vm.stopPrank();

    //     // Verify protocol fee: 25% of 2000 USDT = 500 USDT
    //     assertEq(USDT.balanceOf(treasury), 500 ether);

    //     // Fast forward to end of new period (30 days from second deposit)
    //     vm.warp(block.timestamp + incentiveGauge.VESTING_DURATION());

    //     // Check rewards
    //     uint256 user1Rewards = incentiveGauge.getClaimableIncentives(
    //         address(USDT),
    //         user1
    //     );
    //     uint256 user2Rewards = incentiveGauge.getClaimableIncentives(
    //         address(USDT),
    //         user2
    //     );

    //     // First period (10 days): 750 USDT, User1 = 10% (75 USDT), User2 = 90% (675 USDT)
    //     // Second deposit: 750 USDT + remaining from first (750 * 2/3 = 500 USDT) = 1250 USDT
    //     // Second period (30 days): User1 = 10% of 1250 USDT = 125 USDT, User2 = 90% = 1125 USDT
    //     // Total User1 = 75 + 125 = 200 USDT
    //     // Total User2 = 675 + 1125 = 1800 USDT
    //     assertApproxEqAbs(user1Rewards, 200 ether, 0.01 ether);
    //     assertApproxEqAbs(user2Rewards, 1800 ether, 0.01 ether);

    //     // Total rewards = 200 + 1800 = 2000 USDT
    //     assertApproxEqAbs(user1Rewards + user2Rewards, 2000 ether, 0.01 ether);
    // }

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
