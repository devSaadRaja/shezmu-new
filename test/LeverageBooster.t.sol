// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import "../src/ERC20Vault.sol";
import "../src/LeverageBooster.sol";
import "../src/InterestCollector.sol";
import "../src/mock/MockERC20.sol";
import "../src/mock/MockERC20Mintable.sol";
import "../src/mock/MockPriceFeed.sol";

import "../src/interfaces/IPriceFeed.sol";

contract ERC20VaultTest is Test {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    address public SWAP_ROUTER = address(0);

    LeverageBooster leverageBooster;
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
            address(shezUSDPriceFeed),
            treasury
        );
        interestCollector = new InterestCollector(treasury);
        leverageBooster = new LeverageBooster("", address(vault), SWAP_ROUTER);

        vault.setInterestCollector(address(interestCollector));
        vault.toggleInterestCollection(true);

        interestCollector.registerVault(address(vault), INTEREST_RATE);

        WETH.transfer(user1, 2_000_000 ether);
        WETH.transfer(user2, 2_000_000 ether);

        shezUSD.grantRole(keccak256("MINTER_ROLE"), address(vault));
        shezUSD.grantRole(keccak256("BURNER_ROLE"), address(vault));

        vault.grantRole(keccak256("LEVERAGE_ROLE"), address(leverageBooster));

        vm.stopPrank();
    }

    // ================================================ //
    // ================== TEST CASES ================== //
    // ================================================ //

    function test_GetMaxBorrowable() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether; // $200,000 worth
        // uint256 debtAmount = 100 ether;

        WETH.approve(address(leverageBooster), collateralAmount);
        WETH.approve(address(leverageBooster), 1_000_000 ether); // ! only for testing (until uniswap v4 implementation)
        leverageBooster.leveragePosition(collateralAmount, 4);

        // WETH.approve(address(vault), collateralAmount);
        // vault.openPosition(address(WETH), collateralAmount, debtAmount);

        // assertEq(vault.getCollateralBalance(user1), collateralAmount);
        // assertEq(vault.getLoanBalance(user1), debtAmount);
        // (, uint256 posCollateral, uint256 posDebt, ) = vault.getPosition(1);
        // assertEq(posCollateral, collateralAmount);
        // assertEq(posDebt, debtAmount);
        // assertEq(shezUSD.balanceOf(user1), debtAmount);

        // uint256 maxBorrowable = vault.getTotalMaxBorrowable(user1);
        // assertEq(maxBorrowable, 1000 ether); // $100,000 worth at 50% LTV

        vm.stopPrank();
    }
}
