// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "../test/interfaces/IPositionManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {EasyPosm} from "../test/utils/EasyPosm.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {ERC20Vault} from "../src/ERC20Vault.sol";
import {InterestCollector} from "../src/InterestCollector.sol";
import {LeverageBooster} from "../src/LeverageBooster.sol";
import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {MockERC20Mintable} from "../src/mock/MockERC20Mintable.sol";
import {MockPriceFeed} from "../src/mock/MockPriceFeed.sol";

import {EERC20} from "../src/interfaces/EERC20.sol";
import {IERC20Vault} from "../src/interfaces/IERC20Vault.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {IPool} from "../src/interfaces/aave-v3/IPool.sol";
import {IRewardsController} from "../src/interfaces/aave-v3/IRewardsController.sol";

contract DeployScript is Script {
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    //* BASE SEPOLIA ADDRESSES *//
    IPoolManager POOL_MANAGER =
        IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    IPositionManager POSITION_MANAGER =
        IPositionManager(payable(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80));
    IUniversalRouter SWAP_ROUTER =
        IUniversalRouter(0x492E6456D9528771018DeB9E87ef7750EF184104);
    IAllowanceTransfer PERMIT2 =
        IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    uint256 public privateKeyDeployer = vm.envUint("PRIVATE_KEY");
    address public deployer = vm.addr(privateKeyDeployer);
    uint256 public privateKeyUser1 = vm.envUint("PRIVATE_KEY_2");
    address public user1 = vm.addr(privateKeyUser1);

    address public treasury = deployer;

    uint256 constant INITIAL_LTV = 50; // 50%
    uint256 constant LIQUIDATION_THRESHOLD = 80; // 80%
    uint256 constant LIQUIDATOR_REWARD = 5; // 5%
    uint256 constant INTEREST_RATE = 10; // 10%

    // Contract instances
    ERC20Vault public vault;
    InterestCollector public interestCollector;
    MockERC20 public WETH;
    MockERC20Mintable public shezUSD;
    MockPriceFeed public wethPriceFeed;
    MockPriceFeed public shezUSDPriceFeed;
    LeverageBooster public leverageBooster;
    PoolKey public pool;

    // address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // Mainnet address
    // address constant WETH = 0x4200000000000000000000000000000000000006; // base sepolia address

    function setUp() public {}

    function run() external {
        // Begin recording actions for deployment
        vm.startBroadcast(privateKeyDeployer); // DEPLOYER

        // Deploy mock price feeds (for testing - replace with real price feeds for mainnet)
        wethPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8); // $200
        shezUSDPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8); // $200

        // Deploy WETH (test) token
        WETH = new MockERC20("WETH", "WETH");
        // Deploy shezUSD token
        shezUSD = new MockERC20Mintable("Shez USD", "shezUSD");

        // Deploy main contracts
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

        leverageBooster = new LeverageBooster(
            "",
            address(vault),
            address(PERMIT2),
            address(SWAP_ROUTER)
        );

        interestCollector = new InterestCollector(treasury);

        // Setup permissions and configurations
        vault.setInterestCollector(address(interestCollector));
        vault.toggleInterestCollection(true);
        interestCollector.registerVault(address(vault), INTEREST_RATE);

        WETH.transfer(user1, 2_000_000 ether);

        shezUSD.grantRole(keccak256("MINTER_ROLE"), address(vault));
        shezUSD.grantRole(keccak256("BURNER_ROLE"), address(vault));

        vault.grantRole(keccak256("LEVERAGE_ROLE"), address(leverageBooster));

        vm.stopBroadcast();

        console.log();
        console.log("Deployed contracts:");
        console.log("ERC20Vault:", address(vault));
        console.log("InterestCollector:", address(interestCollector));
        console.log("LeverageBooster:", address(leverageBooster));
        console.log("WETH:", address(WETH));
        console.log("ShezUSD:", address(shezUSD));
        console.log("WETH PriceFeed:", address(wethPriceFeed));
        console.log("ShezUSD PriceFeed:", address(shezUSDPriceFeed));
    }

    // * LOCAL ADDRESSES
    // ERC20Vault: 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
    // InterestCollector: 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
    // WETH: 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
    // ShezUSD: 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
    // WETH PriceFeed: 0x5FbDB2315678afecb367f032d93F642f64180aa3
    // ShezUSD PriceFeed: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

    function init() external {
        IERC20Vault erc20Vault = IERC20Vault(
            0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
        );
        EERC20 weth = EERC20(0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0);

        vm.startBroadcast(privateKeyUser1);

        for (uint i = 0; i < 1517; i++) {
            uint256 collateralAmount = 1000 ether;
            uint256 debtAmount = (collateralAmount * INITIAL_LTV) / 100;

            weth.approve(address(erc20Vault), collateralAmount);
            erc20Vault.openPosition(
                user1,
                address(weth),
                collateralAmount,
                debtAmount
            );
        }

        vm.stopBroadcast();
    }

    function updatePrice() external {
        IPriceFeed WETHPriceFeed = IPriceFeed(
            0x5FbDB2315678afecb367f032d93F642f64180aa3
        );

        vm.startBroadcast(privateKeyDeployer);
        WETHPriceFeed.setPrice(int256(1 * 10 ** 8)); // $1
        vm.stopBroadcast();
    }

    function poolAndLiquidity() external {
        _poolAndLiquidity();

        // ! update with deployed address before running
        leverageBooster = LeverageBooster(
            0x4f86a458064870Aa69336b6421930B169Ca21270
        );

        bytes memory encodedKey = abi.encode(pool);
        vm.startBroadcast(privateKeyDeployer); // DEPLOYER
        leverageBooster.setPool(encodedKey);
        vm.stopBroadcast();
    }

    function _poolAndLiquidity() internal {
        // ! update with deployed addresses before running
        WETH = MockERC20(0xFB16868524d929Be22855F67217f155CD5B76A16);
        shezUSD = MockERC20Mintable(0xcdA47692B7300ED3C6fa52a6DF52972d71Ee03f0);

        vm.startBroadcast(privateKeyDeployer); // DEPLOYER

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

        (address currency0, address currency1) = address(WETH) <
            address(shezUSD)
            ? (address(WETH), address(shezUSD))
            : (address(shezUSD), address(WETH));

        pool = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
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

        vm.stopBroadcast();
    }

    function deployStrategy() external {
        address user = 0xC02aB1A5eaA8d1B114EF786D9bde108cD4364359;
        // string[] memory inputs = new string[](3);
        // inputs[0] = "cast";
        // inputs[1] = "rpc";
        // inputs[2] = string(abi.encodePacked("anvil_impersonateAccount", user));
        // vm.ffi(inputs);

        // ! MAINNET ADDRESSES

        IPool POOL_V3 = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
        IRewardsController INCENTIVES_V3 = IRewardsController(
            0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb
        );

        IERC20 collateralToken = IERC20(
            0xdC035D45d973E3EC169d2276DDab16f1e407384F
        ); // USDS (USDS Stablecoin)
        IERC20 aToken = IERC20(0x32a6268f9Ba3642Dda7892aDd74f1D34469A4259); // aEthUSDS (Aave Ethereum USDS)
        IERC20 rewardToken = IERC20(0x32a6268f9Ba3642Dda7892aDd74f1D34469A4259); // aEthUSDS (Aave Ethereum USDS)

        // vm.startBroadcast(); // Start with the default signer
        // vm.allowCheatcodes(address(this)); // Important for some setups

        // // Make the RPC call to impersonate the account
        // bytes memory result = vm.ffi(
        //     [
        //         "curl",
        //         "-s",
        //         "-X",
        //         "POST",
        //         "http://127.0.0.1:8545", // Your anvil URL
        //         "-H",
        //         "Content-Type: application/json",
        //         "--data",
        //         string(
        //             abi.encodePacked(
        //                 '{"jsonrpc":"2.0","method":"anvil_impersonateAccount","params":["',
        //                 vm.toString(0xC02aB1A5eaA8d1B114EF786D9bde108cD4364359),
        //                 '"],"id":1}'
        //             )
        //         )
        //     ]
        // );

        // vm.stopBroadcast();

        // vm.broadcast(user);
        // vm.prank(user);
        // vm.startPrank(user);
        // vm.startBroadcast(user);
        // collateralToken.transfer(deployer, 1000 ether);
        // // vm.stopPrank();
        // vm.stopBroadcast();
        // console.log(collateralToken.balanceOf(deployer), "<<< BALANCE");

        // vm.startBroadcast();
        // deal(address(collateralToken), deployer, 1000 ether);
        console.log(collateralToken.balanceOf(deployer), "<<< BALANCE");
        // vm.stopBroadcast();

        vm.startBroadcast(privateKeyDeployer);

        AaveStrategy aaveStrategy = new AaveStrategy();
        aaveStrategy.initialize(
            treasury,
            address(collateralToken),
            address(aToken),
            address(rewardToken),
            address(POOL_V3),
            address(INCENTIVES_V3)
        );

        console.log(deployer, "<<< deployer");
        console.log(address(aaveStrategy), "<<< address(aaveStrategy)");

        aaveStrategy.setVault(deployer);

        collateralToken.approve(address(aaveStrategy), 1 ether);
        aaveStrategy.deposit(0, 1 ether);

        aaveStrategy.setUserUseReserveAsCollateral();

        vm.stopBroadcast();
    }
}
