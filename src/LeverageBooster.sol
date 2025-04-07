// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IERC20Vault.sol";

// import "./interfaces/ISwapRouter.sol";

contract LeverageBooster is AccessControl, ReentrancyGuard {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    bytes32 internal constant ROUTE_ROLE = keccak256("ROUTE_ROLE");

    uint256 public constant MAX_LEVERAGE = 10;

    string public description;

    IERC20Vault public vault;
    IERC20 public collateralToken;
    IERC20 public loanToken;

    // ISwapRouter public swapRouter;
    // ISwapRouter.SwapRoute public swapRoute;

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

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

    // ============================================ //
    // ================== ERRORS ================== //
    // ============================================ //

    error NoRoutes(address from, address to);
    error InvalidRoute();
    error PositionUnhealthy(uint256 health, uint256 minHealth);
    error ExceedMaxLeverage(uint256 leverage);

    // ================================================= //
    // ================== CONSTRUCTOR ================== //
    // ================================================= //

    constructor(
        string memory _description,
        address _vault,
        address _swapRouter
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        _grantRole(ROUTE_ROLE, msg.sender);

        description = _description;
        vault = IERC20Vault(_vault);
        collateralToken = IERC20(vault.collateralToken());
        loanToken = IERC20(vault.loanToken());
        // swapRouter = ISwapRouter(_swapRouter);
    }

    // ===================================================== //
    // ================== WRITE FUNCTIONS ================== //
    // ===================================================== //

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
        uint256 collateralAmount,
        uint256 leverage
    ) external nonReentrant returns (uint256 positionId) {
        if (leverage > MAX_LEVERAGE) revert ExceedMaxLeverage(leverage);

        collateralToken.transferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );

        // Open the initial position with zero debt
        collateralToken.approve(address(vault), collateralAmount);
        vault.openPosition(
            msg.sender,
            address(collateralToken),
            collateralAmount,
            0
        );
        positionId = vault.nextPositionId() - 1;

        for (uint256 i = 0; i < leverage; i++) {
            (, , uint256 currentDebt, ) = vault.getPosition(positionId);
            uint256 maxBorrowable = vault.getMaxBorrowable(positionId);

            uint256 borrowAmount = maxBorrowable > currentDebt
                ? maxBorrowable - currentDebt
                : 0;
            if (borrowAmount == 0) revert("No borrow capacity");

            vault.borrowFor(positionId, msg.sender, borrowAmount);

            // Not buying collateral tokens again at final loop to return stablecoins to user.
            if (i < leverage - 1) {
                uint256 collateralOutput = _swapLoanToCollateral(borrowAmount);

                collateralToken.approve(address(vault), collateralOutput);
                vault.addCollateralFor(
                    positionId,
                    msg.sender,
                    collateralOutput
                );

                // Check position health to ensure it's not liquidatable
                uint256 health = vault.getPositionHealth(positionId);
                uint256 minHealth = (vault.ltvRatio() *
                    vault.liquidationThreshold()) / 100;
                minHealth = (vault.PRECISION() * minHealth) / 100;
                if (health < minHealth) {
                    revert PositionUnhealthy(health, minHealth);
                }
            }
        }

        uint256 debtAmount = loanToken.balanceOf(address(this));
        loanToken.transfer(msg.sender, debtAmount);

        emit LeveragedPositionOpened(
            msg.sender,
            positionId,
            collateralAmount,
            debtAmount,
            leverage
        );
    }

    // ======================================================== //
    // ================== INTERNAL FUNCTIONS ================== //
    // ======================================================== //

    function _swapLoanToCollateral(
        uint256 loanAmount
    ) internal returns (uint256 collateralOutput) {
        // !  only for testing (until uniswap v4 implementation)
        collateralOutput = loanAmount;
        collateralToken.transferFrom(msg.sender, address(this), loanAmount);
        // !

        // if (swapRoute.dex == ISwapRouter.Dex.NONE) {
        //     revert NoRoutes(address(loanToken), address(collateralToken));
        // }
        // loanToken.approve(address(swapRouter), loanAmount);
        // collateralOutput = swapRouter.swap(swapRoute, loanAmount);
    }
}
