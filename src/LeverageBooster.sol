// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IERC20Vault.sol";

// import "./interfaces/ISwapRouter.sol";

contract LeverageBooster is AccessControl, ReentrancyGuard {
    bytes32 internal constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 internal constant ROUTE_ROLE = keccak256("ROUTE_ROLE");

    uint256 public constant MAX_LEVERAGE = 10;

    string public description;

    IERC20Vault public vault;
    IERC20 public collateralToken;
    IERC20 public loanToken;

    // ISwapRouter public swapRouter;
    // ISwapRouter.SwapRoute public swapRoute;

    error NoRoutes(address from, address to);
    error InvalidRoute();
    error PositionUnhealthy(uint256 health, uint256 minHealth);
    error ExceedMaxLeverage(uint256 leverage);

    // event SwapRouteSet(
    //     address from,
    //     address to,
    //     address pool,
    //     ISwapRouter.Dex dex
    // );
    event LeveragedPositionOpened(
        address indexed user,
        uint256 positionId,
        uint256 collateralAmount,
        uint256 borrowedAmount,
        uint256 leverage
    );

    constructor(
        string memory _description,
        address _vault,
        address _swapRouter
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        _grantRole(DAO_ROLE, msg.sender);
        _grantRole(ROUTE_ROLE, msg.sender);

        description = _description;
        vault = IERC20Vault(_vault);
        collateralToken = IERC20(vault.collateralToken());
        loanToken = IERC20(vault.loanToken());
        // swapRouter = ISwapRouter(_swapRouter);
    }

    // function setSwapRoute(
    //     address from,
    //     address to,
    //     address pool,
    //     ISwapRouter.Dex dex
    // ) external onlyRole(ROUTE_ROLE) {
    //     if (
    //         from == address(0) ||
    //         to == address(0) ||
    //         pool == address(0) ||
    //         dex == ISwapRouter.Dex.NONE
    //     ) revert InvalidRoute();

    //     swapRoute = ISwapRouter.SwapRoute({
    //         fromToken: from,
    //         toToken: to,
    //         pool: pool,
    //         dex: dex,
    //         fee: 0
    //     });

    //     emit SwapRouteSet(from, to, pool, dex);
    // }

    function leveragePosition(
        uint256 collAmount,
        uint256 leverage
    ) external nonReentrant returns (uint256 positionId) {
        if (leverage > MAX_LEVERAGE) revert ExceedMaxLeverage(leverage);

        collateralToken.transferFrom(msg.sender, address(this), collAmount);

        // Approve the vault to spend the initial collateral
        collateralToken.approve(address(vault), collAmount);

        // Open the initial position with zero debt
        vault.openPosition(msg.sender, address(collateralToken), collAmount, 0);

        // uint256 currentCollateral = collAmount;

        positionId = vault.nextPositionId() - 1;

        for (uint256 i = 0; i < leverage - 1; i++) {
            // Calculate the maximum borrowable amount based on current collateral
            uint256 maxBorrowable = vault.getMaxBorrowable(positionId); // currentCollateral
            console.log(maxBorrowable, "<<< maxBorrowable");
            if (maxBorrowable == 0) revert("No borrow capacity");

            // // Borrow the maximum allowed
            // vault.borrowFor(positionId, msg.sender, maxBorrowable);

            // // Swap loanToken (shezUSD) to collateralToken (WETH)
            // uint256 collateralOutput = 100 ether; // _swapLoanTokenToCollateral(maxBorrowable);

            // // Add the new collateral to the position
            // collateralToken.approve(address(vault), collateralOutput);
            // vault.addCollateral(positionId, collateralOutput);

            // // Check position health to ensure it's not liquidatable
            // uint256 health = vault.getPositionHealth(positionId);
            // uint256 minHealth = (vault.ltvRatio() *
            //     vault.liquidationThreshold()) / 100;
            // minHealth = (vault.PRECISION() * minHealth) / 100;
            // if (health < minHealth) {
            //     revert PositionUnhealthy(health, minHealth);
            // }

            // currentCollateral = collateralOutput;
        }

        // // Transfer remaining tokens to the user
        // collateralToken.transfer(
        //     msg.sender,
        //     collateralToken.balanceOf(address(this))
        // );
        // loanToken.transfer(msg.sender, loanToken.balanceOf(address(this)));

        // emit LeveragedPositionOpened(
        //     msg.sender,
        //     positionId,
        //     collAmount,
        //     loanToken.balanceOf(msg.sender),
        //     leverage
        // );
    }

    function _swapLoanTokenToCollateral(
        uint256 loanAmount
    ) internal returns (uint256 collateralOutput) {
        // if (swapRoute.dex == ISwapRouter.Dex.NONE) {
        //     revert NoRoutes(address(loanToken), address(collateralToken));
        // }
        // loanToken.approve(address(swapRouter), loanAmount);
        // collateralOutput = swapRouter.swap(swapRoute, loanAmount);
    }
}
