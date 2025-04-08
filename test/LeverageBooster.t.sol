// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {EasyPosm} from "./utils/EasyPosm.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {ERC20Vault} from "../src/ERC20Vault.sol";
import {LeverageBooster} from "../src/LeverageBooster.sol";
import {InterestCollector} from "../src/InterestCollector.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {MockERC20Mintable} from "../src/mock/MockERC20Mintable.sol";
import {MockPriceFeed} from "../src/mock/MockPriceFeed.sol";

contract ERC20VaultTest is Test {
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    //* BASE ADDRESSES *//
    IUniversalRouter SWAP_ROUTER =
        IUniversalRouter(0x6fF5693b99212Da76ad316178A184AB56D299b43);
    IPoolManager POOL_MANAGER =
        IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IPositionManager POSITION_MANAGER =
        IPositionManager(payable(0x7C5f5A4bBd8fD63184577525326123B519429bDc));
    IAllowanceTransfer PERMIT2 =
        IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    PoolKey pool;
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
        leverageBooster = new LeverageBooster(
            "",
            address(vault),
            address(PERMIT2),
            address(SWAP_ROUTER)
        );

        vault.setInterestCollector(address(interestCollector));
        vault.toggleInterestCollection(true);

        interestCollector.registerVault(address(vault), INTEREST_RATE);

        WETH.transfer(user1, 2_000_000 ether);
        WETH.transfer(user2, 2_000_000 ether);

        shezUSD.grantRole(keccak256("MINTER_ROLE"), address(vault));
        shezUSD.grantRole(keccak256("BURNER_ROLE"), address(vault));

        vault.grantRole(keccak256("LEVERAGE_ROLE"), address(leverageBooster));

        vm.stopPrank();

        _poolAndLiquidity();

        bytes memory encodedKey = abi.encode(pool);
        vm.prank(deployer);
        leverageBooster.setPool(encodedKey);
    }

    // ================================================ //
    // ================== TEST CASES ================== //
    // ================================================ //

    function test_LeveragePosition() public {
        vm.startPrank(user1);

        uint256 collateralAmount = 1000 ether; // $200,000 worth
        // uint256 debtAmount = 100 ether;

        WETH.approve(address(leverageBooster), collateralAmount);
        leverageBooster.leveragePosition(collateralAmount, 4, 0, new bytes(0));

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

    function _poolAndLiquidity() internal {
        vm.startPrank(deployer);

        /////////////////////////////////////
        // --- Parameters to Configure --- //
        /////////////////////////////////////

        // --- POOL Configuration --- //

        uint24 lpFee = 3000;
        int24 tickSpacing = 60;
        uint160 startingPrice = 79228162514264337593543950336; // 1:1 | floor(sqrt(1) * 2^96)

        // --- LIQUIDITY POSITION Configuration --- //

        uint256 token0Amount = 1_000_000 ether;
        uint256 token1Amount = 1_000_000 ether;

        int24 tickLower = -887220; //  -887260; // -600;
        int24 tickUpper = 887220; //  887260; // 600;

        ///////////////////////////
        // --- CREATING POOL --- //
        ///////////////////////////

        pool = PoolKey({
            currency0: Currency.wrap(address(WETH)),
            currency1: Currency.wrap(address(shezUSD)),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        IPoolManager(address(POOL_MANAGER)).initialize(pool, startingPrice);

        //////////////////////////////
        // --- ADDING LIQUIDITY --- //
        //////////////////////////////

        (uint160 sqrtPriceX96, , , ) = IPoolManager(address(POOL_MANAGER))
            .getSlot0(pool.toId());

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        uint48 expiration = uint48(block.timestamp) + 60;
        shezUSD.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(
            address(shezUSD),
            address(POSITION_MANAGER),
            type(uint160).max,
            expiration
        ); // type(uint48).max
        WETH.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(
            address(WETH),
            address(POSITION_MANAGER),
            type(uint160).max,
            expiration
        ); // type(uint48).max

        // slippage limits
        uint256 amount0Max = token0Amount + 1000 wei;
        uint256 amount1Max = token1Amount + 1000 wei;

        POSITION_MANAGER.mint(
            pool,
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            deployer,
            expiration,
            new bytes(0)
        );

        vm.stopPrank();
    }
}
