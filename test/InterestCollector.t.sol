// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// import "forge-std/Test.sol";
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
// import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
// import "../src/InterestCollector.sol";
// import "../src/ERC20Vault.sol";
// import "../src/mock/MockERC20.sol";
// import "../src/mock/MockERC20Mintable.sol";
// import "../src/mock/MockPriceFeed.sol";
// import "../src/interfaces/IPriceFeed.sol";

// contract InterestCollectorTest is Test {
//     // =============================================== //
//     // ================== STRUCTURE ================== //
//     // =============================================== //

//     InterestCollector interestCollector;
//     ERC20Vault vault;
//     MockERC20 WETH;
//     MockERC20Mintable shezUSD;

//     MockPriceFeed wethPriceFeed;
//     MockPriceFeed shezUSDPriceFeed;

//     address deployer = vm.addr(1);
//     address user1 = vm.addr(2);
//     address user2 = vm.addr(3);
//     address treasury = vm.addr(4);

//     uint256 constant INITIAL_LTV = 50;
//     uint256 constant LIQUIDATION_THRESHOLD = 110; // 110% of INITIAL_LTV
//     uint256 constant LIQUIDATOR_REWARD = 50; // 50%
//     uint256 constant INTEREST_RATE = 500; // 5% annual interest in basis points

//     // =========================================== //
//     // ================== SETUP ================== //
//     // =========================================== //

//     function setUp() public {
//         vm.startPrank(deployer);

//         // Deploy tokens and price feeds
//         WETH = new MockERC20("Collateral Token", "COL");
//         shezUSD = new MockERC20Mintable("Shez USD", "shezUSD");

//         wethPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8); // $200
//         shezUSDPriceFeed = new MockPriceFeed(100 * 10 ** 8, 8); // $100

//         // Deploy InterestCollector
//         interestCollector = new InterestCollector(treasury);

//         // Deploy ERC20Vault and set InterestCollector
//         vault = new ERC20Vault(
//             address(WETH),
//             address(shezUSD),
//             INITIAL_LTV,
//             LIQUIDATION_THRESHOLD,
//             LIQUIDATOR_REWARD,
//             address(wethPriceFeed),
//             address(shezUSDPriceFeed)
//         );
//         vault.setInterestCollector(address(interestCollector));
//         vault.toggleInterestCollection(true);

//         // Register vault with interest rate
//         interestCollector.registerVault(address(vault), INTEREST_RATE);

//         // Fund users and vault
//         WETH.transfer(user1, 2_000_000 ether);
//         WETH.transfer(user2, 2_000_000 ether);
//         shezUSD.grantRole(keccak256("MINTER_ROLE"), address(vault));
//         shezUSD.grantRole(keccak256("BURNER_ROLE"), address(vault));

//         vm.stopPrank();
//     }

//     // ================================================ //
//     // ================== TEST CASES ================== //
//     // ================================================ //

//     function test_ConstructorSetsTreasury() public view {
//         assertEq(interestCollector.treasury(), treasury);
//     }

//     function test_ConstructorZeroAddressTreasury() public {
//         vm.expectRevert(InterestCollector.ZeroAddress.selector);
//         new InterestCollector(address(0));
//     }

//     function test_ConstructorSetsOwner() public view {
//         assertEq(interestCollector.owner(), deployer);
//     }

//     function test_GetRegisteredVaultsCountInitial() public view {
//         assertEq(interestCollector.getRegisteredVaultsCount(), 1); // Vault registered in setUp
//     }

//     function test_CalculateInterestDueUnregisteredVault() public view {
//         assertEq(
//             interestCollector.calculateInterestDue(address(0), 1000 ether),
//             0
//         );
//     }

//     function test_CalculateInterestDueNoDebt() public view {
//         assertEq(interestCollector.calculateInterestDue(address(vault), 0), 0);
//     }

//     function test_CalculateInterestDueNoBlocksPassed() public view {
//         assertEq(
//             interestCollector.calculateInterestDue(address(vault), 1000 ether),
//             0
//         );
//     }

//     function test_CalculateInterestDueAfterOnePeriod() public {
//         vm.roll(block.number + 300); // Advance 1 period (300 blocks)
//         uint256 debtAmount = 1000 ether;
//         uint256 expectedInterest = (debtAmount *
//             INTEREST_RATE *
//             interestCollector.periodShare()) /
//             (10000 * interestCollector.PRECISION());
//         assertEq(
//             interestCollector.calculateInterestDue(address(vault), debtAmount),
//             expectedInterest
//         );
//     }

//     function test_IsCollectionReadyInitial() public view {
//         assertFalse(interestCollector.isCollectionReady(address(vault)));
//     }

//     function test_IsCollectionReadyAfterPeriod() public {
//         vm.roll(block.number + 300);
//         assertTrue(interestCollector.isCollectionReady(address(vault)));
//     }

//     function test_RegisterVaultSuccess() public {
//         vm.prank(deployer);
//         address newVault = vm.addr(5);
//         interestCollector.registerVault(newVault, 1000); // 10%
//         assertEq(interestCollector.getVaultInterestRate(newVault), 1000);
//         assertEq(
//             interestCollector.getLastCollectionBlock(newVault),
//             block.number
//         );
//         assertEq(interestCollector.getRegisteredVaultsCount(), 2);
//     }

//     function test_RegisterVaultZeroAddress() public {
//         vm.prank(deployer);
//         vm.expectRevert(InterestCollector.ZeroAddress.selector);
//         interestCollector.registerVault(address(0), 1000);
//     }

//     function test_RegisterVaultAlreadyRegistered() public {
//         vm.prank(deployer);
//         vm.expectRevert(InterestCollector.VaultAlreadyRegistered.selector);
//         interestCollector.registerVault(address(vault), 1000);
//     }

//     function test_RegisterVaultInvalidInterestRate() public {
//         vm.prank(deployer);
//         vm.expectRevert(InterestCollector.InvalidInterestRate.selector);
//         interestCollector.registerVault(vm.addr(5), 0);
//     }

//     function test_RegisterVaultNonOwner() public {
//         vm.prank(user1);
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 Ownable.OwnableUnauthorizedAccount.selector,
//                 user1
//             )
//         );
//         interestCollector.registerVault(vm.addr(5), 1000);
//     }

//     function test_UpdateInterestRateSuccess() public {
//         vm.prank(deployer);
//         interestCollector.updateInterestRate(address(vault), 1000);
//         assertEq(interestCollector.getVaultInterestRate(address(vault)), 1000);
//     }

//     function test_UpdateInterestRateVaultNotRegistered() public {
//         vm.prank(deployer);
//         vm.expectRevert(InterestCollector.VaultNotRegistered.selector);
//         interestCollector.updateInterestRate(vm.addr(5), 1000);
//     }

//     function test_UpdateInterestRateInvalidInterestRate() public {
//         vm.prank(deployer);
//         vm.expectRevert(InterestCollector.InvalidInterestRate.selector);
//         interestCollector.updateInterestRate(address(vault), 0);
//     }

//     function test_UpdateInterestRateNonOwner() public {
//         vm.prank(user1);
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 Ownable.OwnableUnauthorizedAccount.selector,
//                 user1
//             )
//         );
//         interestCollector.updateInterestRate(address(vault), 1000);
//     }

//     function test_CollectInterestSuccess() public {
//         vm.startPrank(user1);
//         WETH.approve(address(vault), 1000 ether);
//         vault.openPosition(address(WETH), 1000 ether, 500 ether); // Creates debt
//         vm.stopPrank();

//         vm.roll(block.number + 300); // Advance 1 period
//         uint256 interestDue = interestCollector.calculateInterestDue(
//             address(vault),
//             500 ether
//         );

//         // Mint tokens to vault for interest payment
//         vm.prank(address(vault));
//         shezUSD.mint(address(vault), interestDue);
//         vm.prank(user1);
//         shezUSD.approve(address(interestCollector), interestDue);

//         vm.prank(address(vault));
//         interestCollector.collectInterest(
//             address(vault),
//             address(shezUSD),
//             500 ether
//         );

//         assertEq(
//             interestCollector.getCollectedInterest(address(shezUSD)),
//             interestDue
//         );
//         assertEq(
//             interestCollector.getLastCollectionBlock(address(vault)),
//             block.number
//         );
//     }

//     function test_CollectInterestUnregisteredVault() public {
//         vm.prank(vm.addr(5));
//         vm.expectRevert(InterestCollector.VaultNotRegistered.selector);
//         interestCollector.collectInterest(
//             vm.addr(5),
//             address(shezUSD),
//             1000 ether
//         );
//     }

//     function test_CollectInterestNotVault() public {
//         vm.prank(user1);
//         vm.expectRevert(InterestCollector.VaultNotRegistered.selector);
//         interestCollector.collectInterest(
//             address(vault),
//             address(shezUSD),
//             1000 ether
//         );
//     }

//     function test_CollectInterestTooEarly() public {
//         uint256 amountBefore = interestCollector.getCollectedInterest(
//             address(vault)
//         );

//         vm.prank(address(vault));
//         interestCollector.collectInterest(
//             address(vault),
//             address(shezUSD),
//             1000 ether
//         );

//         uint256 amountAfter = interestCollector.getCollectedInterest(
//             address(vault)
//         );
//         assertEq(
//             amountBefore,
//             amountAfter,
//             "Collected amount should not update."
//         );
//     }

//     function test_CollectInterestNoInterestDue() public {
//         vm.roll(block.number + 300);
//         vm.prank(address(vault));
//         vm.expectRevert(InterestCollector.NoInterestToCollect.selector);
//         interestCollector.collectInterest(address(vault), address(shezUSD), 0);
//     }

//     function test_WithdrawInterestSuccess() public {
//         vm.roll(block.number + 300);

//         vm.startPrank(user1);
//         WETH.approve(address(vault), 1000 ether);
//         vault.openPosition(address(WETH), 1000 ether, 500 ether);
//         vm.stopPrank();

//         uint256 due = interestCollector.getCollectedInterest(address(shezUSD));
//         assertEq(shezUSD.balanceOf(treasury), 0);

//         vm.prank(deployer);
//         interestCollector.withdrawInterest(address(shezUSD));

//         assertEq(shezUSD.balanceOf(treasury), due);
//         assertEq(interestCollector.getCollectedInterest(address(shezUSD)), 0);
//     }

//     function test_WithdrawInterestNoInterest() public {
//         vm.prank(deployer);
//         vm.expectRevert(InterestCollector.NoInterestToCollect.selector);
//         interestCollector.withdrawInterest(address(shezUSD));
//     }

//     function test_WithdrawInterestNonOwner() public {
//         vm.prank(user1);
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 Ownable.OwnableUnauthorizedAccount.selector,
//                 user1
//             )
//         );
//         interestCollector.withdrawInterest(address(shezUSD));
//     }

//     function test_UpdateTreasurySuccess() public {
//         vm.prank(deployer);
//         address newTreasury = vm.addr(5);
//         interestCollector.updateTreasury(newTreasury);
//         assertEq(interestCollector.treasury(), newTreasury);
//     }

//     function test_UpdateTreasuryZeroAddress() public {
//         vm.prank(deployer);
//         vm.expectRevert(InterestCollector.ZeroAddress.selector);
//         interestCollector.updateTreasury(address(0));
//     }

//     function test_UpdateTreasuryNonOwner() public {
//         vm.prank(user1);
//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 Ownable.OwnableUnauthorizedAccount.selector,
//                 user1
//             )
//         );
//         interestCollector.updateTreasury(vm.addr(5));
//     }
// }
