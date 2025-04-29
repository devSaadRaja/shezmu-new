// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ERC20Vault} from "../src/ERC20Vault.sol";
import {InterestCollector} from "../src/InterestCollector.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {MockERC20Mintable} from "../src/mock/MockERC20Mintable.sol";
import {MockPriceFeed} from "../src/mock/MockPriceFeed.sol";

import {EERC20} from "../src/interfaces/EERC20.sol";
import {IERC20Vault} from "../src/interfaces/IERC20Vault.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";

contract DeployScript is Script {
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
            treasury
        );

        interestCollector = new InterestCollector(treasury);

        // Setup permissions and configurations
        vault.setInterestCollector(address(interestCollector));
        vault.toggleInterestCollection(true);
        interestCollector.registerVault(address(vault), INTEREST_RATE);

        WETH.transfer(user1, 2_000_000 ether);

        shezUSD.grantRole(keccak256("MINTER_ROLE"), address(vault));
        shezUSD.grantRole(keccak256("BURNER_ROLE"), address(vault));

        vm.stopBroadcast();

        console.log();
        console.log("Deployed contracts:");
        console.log("ERC20Vault:", address(vault));
        console.log("InterestCollector:", address(interestCollector));
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
}
