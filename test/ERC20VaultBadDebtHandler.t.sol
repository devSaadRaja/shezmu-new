// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.19;

// import "forge-std/Test.sol";

// import "../src/ERC20Vault.sol";
// import "../src/mock/MockERC20.sol";
// import "../src/mock/MockERC20Mintable.sol";
// import "../src/mock/MockPriceFeed.sol";

// import "../src/interfaces/IPriceFeed.sol";

// // Handler contract to simulate actions that could lead to bad debt
// contract BadDebtHandler {
//     uint256 private constant UINT256_MAX =
//         115792089237316195423570985008687907853269984665640564039457584007913129639935;

//     ERC20Vault public vault;
//     MockERC20 public WETH;
//     MockERC20Mintable public shezUSD;
//     MockPriceFeed public wethPriceFeed;
//     MockPriceFeed public shezUSDPriceFeed;
//     address public user1;

//     mapping(uint256 => uint256) public initialCollateral;
//     mapping(uint256 => uint256) public addedCollateral;
//     mapping(uint256 => uint256) public withdrawnCollateral;
//     mapping(uint256 => uint256) public initialDebt;
//     mapping(uint256 => uint256) public repaidDebt;

//     constructor(
//         ERC20Vault _vault,
//         MockERC20 _WETH,
//         MockERC20Mintable _shezUSD,
//         MockPriceFeed _wethPriceFeed,
//         MockPriceFeed _shezUSDPriceFeed,
//         address _user1
//     ) {
//         vault = _vault;
//         WETH = _WETH;
//         shezUSD = _shezUSD;
//         wethPriceFeed = _wethPriceFeed;
//         shezUSDPriceFeed = _shezUSDPriceFeed;
//         user1 = _user1;
//     }

//     function openPosition(
//         uint256 collateralAmount,
//         uint256 debtAmount
//     ) external {
//         collateralAmount = _bound(collateralAmount, 1 ether, 2_000_000 ether); // Realistic range
//         debtAmount = _bound(debtAmount, 1 ether, 1e24); // Allow high debt for testing

//         WETH.approve(address(vault), collateralAmount);

//         if (
//             collateralAmount > 0 &&
//             debtAmount > 0 &&
//             debtAmount <=
//             (vault.getCollateralValue(collateralAmount) * 50) / 100
//         ) {
//             try
//                 vault.openPosition(address(WETH), collateralAmount, debtAmount)
//             {
//                 uint256 positionId = vault.nextPositionId() - 1;
//                 initialCollateral[positionId] = collateralAmount;
//                 initialDebt[positionId] = debtAmount;
//             } catch {}
//         }
//     }

//     function addCollateral(
//         uint256 positionId,
//         uint256 additionalAmount
//     ) external {
//         uint256 nextId = vault.nextPositionId();
//         if (nextId > 1) {
//             positionId = _bound(positionId, 1, nextId - 1);
//             (address owner, uint256 posCollateral, ) = vault.getPosition(
//                 positionId
//             );
//             additionalAmount = _bound(
//                 additionalAmount,
//                 1 ether,
//                 2_000_000 ether
//             );

//             if (
//                 owner == user1 &&
//                 posCollateral > 0 &&
//                 WETH.balanceOf(user1) >= additionalAmount
//             ) {
//                 WETH.approve(address(vault), additionalAmount);
//                 try vault.addCollateral(positionId, additionalAmount) {
//                     addedCollateral[positionId] += additionalAmount;
//                 } catch {}
//             }
//         }
//     }

//     function repayDebt(uint256 positionId, uint256 repayAmount) external {
//         uint256 nextId = vault.nextPositionId();
//         if (nextId > 1) {
//             positionId = _bound(positionId, 1, nextId - 1);
//             (, , uint256 posDebt) = vault.getPosition(positionId);

//             repayAmount = _bound(repayAmount, 0, posDebt);

//             if (repayAmount > 0 && shezUSD.balanceOf(user1) >= repayAmount) {
//                 shezUSD.approve(address(vault), repayAmount);
//                 try vault.repayDebt(positionId, repayAmount) {
//                     repaidDebt[positionId] += repayAmount;
//                 } catch {}
//             }
//         }
//     }

//     function updatePriceFeed(
//         uint256 priceFeedIndex,
//         uint256 newPrice
//     ) external {
//         newPrice = _bound(newPrice, 1 * 10 ** 6, 200 * 10 ** 8); // Allow extreme lows (e.g., $0.01 to $200)

//         address priceFeed = priceFeedIndex % 2 == 0
//             ? address(wethPriceFeed)
//             : address(shezUSDPriceFeed);

//         try MockPriceFeed(priceFeed).setPrice(int256(newPrice)) {} catch {}
//     }

//     function _bound(
//         uint256 x,
//         uint256 min,
//         uint256 max
//     ) internal pure virtual returns (uint256 result) {
//         require(
//             min <= max,
//             "StdUtils bound(uint256,uint256,uint256): Max is less than min."
//         );
//         // If x is between min and max, return x directly. This is to ensure that dictionary values
//         // do not get shifted if the min is nonzero. More info: https://github.com/foundry-rs/forge-std/issues/188
//         if (x >= min && x <= max) return x;

//         uint256 size = max - min + 1;

//         // If the value is 0, 1, 2, 3, wrap that to min, min+1, min+2, min+3. Similarly for the UINT256_MAX side.
//         // This helps ensure coverage of the min/max values.
//         if (x <= 3 && size > x) return min + x;
//         if (x >= UINT256_MAX - 3 && size > UINT256_MAX - x)
//             return max - (UINT256_MAX - x);

//         // Otherwise, wrap x into the range [min, max], i.e. the range is inclusive.
//         if (x > max) {
//             uint256 diff = x - max;
//             uint256 rem = diff % size;
//             if (rem == 0) return max;
//             result = min + rem - 1;
//         } else if (x < min) {
//             uint256 diff = min - x;
//             uint256 rem = diff % size;
//             if (rem == 0) return min;
//             result = max - rem + 1;
//         }
//     }
// }

// contract ERC20VaultInvariantTest is Test {
//     // =============================================== //
//     // ================== STRUCTURE ================== //
//     // =============================================== //

//     ERC20Vault vault;
//     MockERC20 WETH;
//     MockERC20Mintable shezUSD;

//     // IPriceFeed wethPriceFeed;
//     MockPriceFeed wethPriceFeed;
//     MockPriceFeed shezUSDPriceFeed;

//     BadDebtHandler badDebtHandler;

//     address deployer = vm.addr(1);
//     address user1 = vm.addr(2);
//     address user2 = vm.addr(3);

//     uint256 constant INITIAL_LTV = 50;
//     uint256 constant LIQUIDATION_THRESHOLD = 110; // 110% of INITIAL_LTV
//     uint256 constant LIQUIDATOR_REWARD = 50; // 50%

//     mapping(uint256 => uint256) public initialCollateral; // positionId => initial amount
//     mapping(uint256 => uint256) public addedCollateral; // positionId => total added
//     mapping(uint256 => uint256) public withdrawnCollateral; // positionId => total withdrawn
//     mapping(uint256 => uint256) public initialDebt; // positionId => initial debt
//     mapping(uint256 => uint256) public repaidDebt; // positionId => total repaid
//     mapping(address => uint256) public lastPriceUpdate; // Token address => last price
//     mapping(uint256 => uint256) public ltvAtCreation; // positionId => LTV at creation
//     uint256 public initialWETHBalance; // User1's initial WETH balance

//     // =========================================== //
//     // ================== SETUP ================== //
//     // =========================================== //

//     function setUp() public {
//         vm.startPrank(deployer);

//         WETH = new MockERC20("Collateral Token", "COL");
//         shezUSD = new MockERC20Mintable("Shez USD", "shezUSD");

//         // wethPriceFeed = IPriceFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
//         wethPriceFeed = new MockPriceFeed(200 * 10 ** 8, 8); // $200
//         shezUSDPriceFeed = new MockPriceFeed(100 * 10 ** 8, 8); // $100

//         vault = new ERC20Vault(
//             address(WETH),
//             address(shezUSD),
//             INITIAL_LTV,
//             LIQUIDATION_THRESHOLD,
//             LIQUIDATOR_REWARD,
//             address(wethPriceFeed),
//             address(shezUSDPriceFeed)
//         );

//         WETH.transfer(user1, 2_000_000 ether);
//         WETH.transfer(user2, 2_000_000 ether);

//         shezUSD.grantRole(keccak256("MINTER_ROLE"), address(vault));
//         shezUSD.grantRole(keccak256("BURNER_ROLE"), address(vault));

//         vm.stopPrank();

//         // Record initial WETH balance for user1
//         initialWETHBalance = WETH.balanceOf(user1); // 2_000_000 ether;

//         // Record initial prices
//         (, int256 priceWETH, , , ) = wethPriceFeed.latestRoundData();
//         (, int256 priceShezUSD, , , ) = shezUSDPriceFeed.latestRoundData();
//         lastPriceUpdate[address(wethPriceFeed)] = uint256(priceWETH);
//         lastPriceUpdate[address(shezUSDPriceFeed)] = uint256(priceShezUSD);

//         // Deploy handler
//         badDebtHandler = new BadDebtHandler(
//             vault,
//             WETH,
//             shezUSD,
//             wethPriceFeed,
//             shezUSDPriceFeed,
//             user1
//         );

//         // Target the handler for invariant testing
//         targetContract(address(badDebtHandler));

//         FuzzSelector memory selector = FuzzSelector({
//             addr: address(badDebtHandler),
//             selectors: new bytes4[](4)
//         });
//         selector.selectors[0] = BadDebtHandler.openPosition.selector;
//         selector.selectors[1] = BadDebtHandler.addCollateral.selector;
//         selector.selectors[2] = BadDebtHandler.repayDebt.selector;
//         selector.selectors[3] = BadDebtHandler.updatePriceFeed.selector;
//         targetSelector(selector);
//     }

//     // ================================================ //
//     // ================== TEST CASES ================== //
//     // ================================================ //

//     function invariant_PositionDataMatchesBalances() public view {
//         uint256[] memory posIds = vault.getUserPositionIds(user1);
//         uint256 totalCollateral;
//         uint256 totalDebt;
//         for (uint256 i = 0; i < posIds.length; i++) {
//             (, uint256 posCollateral, uint256 posDebt) = vault.getPosition(
//                 posIds[i]
//             );
//             totalCollateral += posCollateral;
//             totalDebt += posDebt;
//         }
//         assertEq(vault.getCollateralBalance(user1), totalCollateral);
//         assertEq(vault.getLoanBalance(user1), totalDebt);
//         assertEq(shezUSD.balanceOf(user1), vault.getLoanBalance(user1));
//     }

//     function invariant_LTVLimitRespected() public view {
//         uint256[] memory posIds = vault.getUserPositionIds(user1);
//         for (uint256 i = 0; i < posIds.length; i++) {
//             uint256 positionId = posIds[i];
//             (, , uint256 debtAmount) = vault.getPosition(positionId);
//             if (debtAmount > 0) {
//                 // Check LTV at the time of position creation
//                 uint256 ltvAtCreationForPos = ltvAtCreation[positionId];
//                 assertLe(
//                     ltvAtCreationForPos,
//                     INITIAL_LTV,
//                     "LTV at creation exceeds limit"
//                 );
//             }
//         }
//     }

//     function invariant_CollateralAdditionsAccurate() public view {
//         uint256[] memory posIds = vault.getUserPositionIds(user1);
//         uint256 totalCollateralExpected;

//         for (uint256 i = 0; i < posIds.length; i++) {
//             uint256 positionId = posIds[i];
//             (, uint256 posCollateral, ) = vault.getPosition(positionId);
//             uint256 expectedCollateral = initialCollateral[positionId] +
//                 addedCollateral[positionId] -
//                 withdrawnCollateral[positionId]; // Subtract withdrawals
//             assertEq(
//                 posCollateral,
//                 expectedCollateral,
//                 "Position collateral mismatch"
//             );
//             totalCollateralExpected += expectedCollateral;
//         }

//         assertEq(
//             vault.getCollateralBalance(user1),
//             totalCollateralExpected,
//             "Total collateral balance mismatch"
//         );
//     }

//     function invariant_CollateralWithdrawalsAccurate() public view {
//         uint256[] memory posIds = vault.getUserPositionIds(user1);
//         uint256 totalCollateralInVault;
//         uint256 totalWithdrawn;

//         for (uint256 i = 0; i < posIds.length; i++) {
//             uint256 positionId = posIds[i];
//             (, uint256 posCollateral, ) = vault.getPosition(positionId);
//             totalCollateralInVault += posCollateral;
//             totalWithdrawn += withdrawnCollateral[positionId];
//         }

//         uint256 totalDeposited = vault.getCollateralBalance(user1) +
//             totalWithdrawn;
//         uint256 expectedWETHBalance = initialWETHBalance -
//             totalDeposited +
//             totalWithdrawn;

//         assertEq(
//             WETH.balanceOf(user1),
//             expectedWETHBalance,
//             "WETH balance mismatch"
//         );
//         assertEq(
//             vault.getCollateralBalance(user1),
//             totalCollateralInVault,
//             "Vault collateral mismatch"
//         );
//     }

//     function invariant_DebtRepaymentsAccurate() public view {
//         uint256[] memory posIds = vault.getUserPositionIds(user1);
//         uint256 totalDebtExpected;

//         for (uint256 i = 0; i < posIds.length; i++) {
//             uint256 positionId = posIds[i];
//             (, , uint256 posDebt) = vault.getPosition(positionId);
//             uint256 expectedDebt = initialDebt[positionId] -
//                 repaidDebt[positionId];
//             assertEq(posDebt, expectedDebt, "Position debt mismatch");
//             totalDebtExpected += expectedDebt;
//         }

//         assertEq(
//             vault.getLoanBalance(user1),
//             totalDebtExpected,
//             "Total debt balance mismatch"
//         );
//         assertEq(
//             shezUSD.balanceOf(user1),
//             totalDebtExpected,
//             "shezUSD balance mismatch"
//         );
//     }

//     function invariant_HealthRatioCorrect() public view {
//         uint256[] memory posIds = vault.getUserPositionIds(user1);
//         for (uint256 i = 0; i < posIds.length; i++) {
//             uint256 positionId = posIds[i];
//             (, uint256 collateralAmount, uint256 debtAmount) = vault
//                 .getPosition(positionId);
//             uint256 health = vault.getPositionHealth(positionId);

//             if (debtAmount == 0) {
//                 assertEq(
//                     health,
//                     type(uint256).max,
//                     "Health should be infinity for zero debt"
//                 );
//             } else {
//                 uint256 collateralValue = vault.getCollateralValue(
//                     collateralAmount
//                 );
//                 uint256 loanValue = vault.getLoanValue(debtAmount);
//                 uint256 expectedHealth = (collateralValue * 1 ether) /
//                     loanValue; // Scaled to match vault precision
//                 assertApproxEqAbs(
//                     health,
//                     expectedHealth,
//                     1e12,
//                     "Health ratio mismatch"
//                 ); // Allow small precision errors
//             }
//         }

//         // Check health for non-existent positions
//         uint256 nextId = vault.nextPositionId();
//         if (nextId > 0) {
//             uint256 nonExistentId = nextId;
//             uint256 healthNonExistent = vault.getPositionHealth(nonExistentId);
//             assertEq(
//                 healthNonExistent,
//                 type(uint256).max,
//                 "Health should be infinity for non-existent position"
//             );
//         }
//     }

//     function invariant_HealthReflectsPriceChanges() public {
//         uint256[] memory posIds = vault.getUserPositionIds(user1);
//         for (uint256 i = 0; i < posIds.length; i++) {
//             uint256 positionId = posIds[i];
//             (, uint256 collateralAmount, uint256 debtAmount) = vault
//                 .getPosition(positionId);
//             if (collateralAmount > 0 && debtAmount > 0) {
//                 uint256 health = vault.getPositionHealth(positionId);
//                 uint256 collateralValue = vault.getCollateralValue(
//                     collateralAmount
//                 );
//                 uint256 loanValue = vault.getLoanValue(debtAmount);
//                 uint256 expectedHealth = (collateralValue * 1 ether) /
//                     loanValue;

//                 // Verify health reflects current price
//                 assertApproxEqAbs(
//                     health,
//                     expectedHealth,
//                     1e12,
//                     "Health does not reflect current price"
//                 );

//                 // Check withdrawal revert when health is insufficient
//                 uint256 minCollateralValue = (loanValue * 100) / INITIAL_LTV;
//                 if (collateralValue <= minCollateralValue) {
//                     vm.expectRevert();
//                     vault.withdrawCollateral(positionId, 1); // Attempt to withdraw 1 wei
//                 }
//             }
//         }
//     }

//     function invariant_FullDebtRepayment() public view {
//         uint256[] memory posIds = vault.getUserPositionIds(user1);
//         for (uint256 i = 0; i < posIds.length; i++) {
//             uint256 positionId = posIds[i];
//             (, uint256 posCollateral, uint256 posDebt) = vault.getPosition(
//                 positionId
//             );

//             // Check if the debt has been fully repaid
//             if (
//                 initialDebt[positionId] > 0 &&
//                 repaidDebt[positionId] >= initialDebt[positionId]
//             ) {
//                 // Debt should be 0
//                 assertEq(posDebt, 0, "Debt should be 0 after full repayment");

//                 // Position health should be infinite
//                 assertEq(
//                     vault.getPositionHealth(positionId),
//                     type(uint256).max,
//                     "Health should be infinite after full debt repayment"
//                 );

//                 // If all collateral has been withdrawn, collateral should be 0
//                 uint256 expectedCollateral = initialCollateral[positionId] +
//                     addedCollateral[positionId] -
//                     withdrawnCollateral[positionId];
//                 assertEq(
//                     posCollateral,
//                     expectedCollateral,
//                     "Collateral mismatch after full debt repayment"
//                 );

//                 // If collateral is fully withdrawn, it should be 0
//                 if (
//                     withdrawnCollateral[positionId] >=
//                     (initialCollateral[positionId] +
//                         addedCollateral[positionId])
//                 ) {
//                     assertEq(
//                         posCollateral,
//                         0,
//                         "Collateral should be 0 after full withdrawal"
//                     );
//                 }
//             }
//         }

//         // Check total loan balance reflects fully repaid positions
//         uint256 totalDebtExpected;
//         for (uint256 i = 0; i < posIds.length; i++) {
//             uint256 positionId = posIds[i];
//             uint256 expectedDebt = initialDebt[positionId] >
//                 repaidDebt[positionId]
//                 ? initialDebt[positionId] - repaidDebt[positionId]
//                 : 0;
//             totalDebtExpected += expectedDebt;
//         }
//         assertEq(
//             vault.getLoanBalance(user1),
//             totalDebtExpected,
//             "Loan balance mismatch after full debt repayment"
//         );
//     }

//     function invariant_CanProtocolOccurBadDebt() public {
//         uint256[] memory posIds = vault.getUserPositionIds(user1);
//         uint256 totalCollateralValue = 0;
//         uint256 totalLoanValue = 0;

//         for (uint256 i = 0; i < posIds.length; i++) {
//             uint256 positionId = posIds[i];
//             (, uint256 collateralAmount, uint256 debtAmount) = vault
//                 .getPosition(positionId);
//             if (collateralAmount > 0 && debtAmount > 0) {
//                 totalCollateralValue += vault.getCollateralValue(
//                     collateralAmount
//                 );
//                 totalLoanValue += vault.getLoanValue(debtAmount);
//             }
//         }

//         // Trigger the condition to test bad debt
//         if (totalLoanValue > totalCollateralValue) {
//             console.log("HERE");
//             emit log_named_uint("Total Collateral Value", totalCollateralValue);
//             emit log_named_uint("Total Loan Value", totalLoanValue);
//             assertFalse(
//                 true,
//                 "Protocol has potential bad debt: Loan value exceeds collateral value"
//             );
//         }

//         // Additional check: Ensure the vault's loan balance is recoverable
//         uint256 vaultLoanBalance = vault.getLoanBalance(user1);
//         assertLe(
//             vaultLoanBalance,
//             totalCollateralValue,
//             "Vault loan balance exceeds recoverable collateral value"
//         );
//     }
// }
