// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20Vault} from "./interfaces/IERC20Vault.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Commands} from "../src/libraries/Commands.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";

/**
 * @title LeverageBooster
 * @notice Enables users to open leveraged positions in a vault by looping borrow and swap operations.
 * @dev Integrates with Uniswap v4 Universal Router and Permit2 for token swaps and approvals.
 */
contract LeverageBooster is Ownable, ReentrancyGuard {
    // =============================================== //
    // ================== STRUCTURE ================== //
    // =============================================== //

    uint256 public constant MAX_LEVERAGE = 10;

    string public description;

    IERC20Vault public vault;
    IERC20 public collateralToken;
    IERC20 public loanToken;

    IAllowanceTransfer public permit2;
    IUniversalRouter public swapRouter;
    mapping(address => mapping(address => PoolKey)) public pools;

    // ============================================ //
    // ================== EVENTS ================== //
    // ============================================ //

    event SetPool(address token0, address token1);
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

    error ExceedMaxLeverage(uint256 leverage);

    // ================================================= //
    // ================== CONSTRUCTOR ================== //
    // ================================================= //

    constructor(
        string memory _description,
        address _vault,
        address _permit2,
        address _swapRouter
    ) Ownable(msg.sender) {
        description = _description;
        vault = IERC20Vault(_vault);
        collateralToken = IERC20(vault.collateralToken());
        loanToken = IERC20(vault.loanToken());

        permit2 = IAllowanceTransfer(_permit2);
        swapRouter = IUniversalRouter(_swapRouter);
    }

    // ======================================================== //
    // ================== EXTERNAL FUNCTIONS ================== //
    // ======================================================== //

    /**
     * @notice Sets a PoolKey for a given token pair to be used in swaps.
     * @dev Only callable by admin role.
     * @param encodedKey ABI-encoded PoolKey struct containing the swap pair info.
     */
    function setPool(bytes memory encodedKey) external onlyOwner {
        PoolKey memory key = abi.decode(encodedKey, (PoolKey));

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        pools[token0][token1] = key;
        pools[token1][token0] = key;

        emit SetPool(token0, token1);
    }

    /**
     * @notice Opens a leveraged position by looping borrow and swap steps.
     * @dev This function handles the leverage loop, checks health, and allows leverage up to MAX_LEVERAGE.
     * @param collateralAmount Amount of collateral the user wants to deposit.
     * @param leverage Number of times the user wants to loop borrowing and buying collateral.
     * @param minAmountOut Minimum output amount accepted from each swap.
     * @param hookData Optional additional data for the router hooks.
     * @return positionId The ID of the newly opened leveraged position.
     */
    function leveragePosition(
        uint256 collateralAmount,
        uint256 leverage,
        uint128 minAmountOut,
        bytes memory hookData
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
            0,
            leverage
        );
        positionId = vault.nextPositionId() - 1;

        for (uint256 i = 0; i < leverage; i++) {
            (, , uint256 currentDebt, , , ,) = vault.getPosition(positionId);
            uint256 maxBorrowable = vault.getMaxBorrowable(positionId);

            uint256 borrowAmount = maxBorrowable > currentDebt
                ? maxBorrowable - currentDebt
                : 0;
            if (borrowAmount == 0) revert("No borrow capacity");

            vault.borrowFor(positionId, msg.sender, borrowAmount);

            // Not buying collateral tokens again at final loop to return stablecoins to user.
            if (i < leverage - 1) {
                _addCollateral(
                    positionId,
                    borrowAmount,
                    minAmountOut,
                    hookData
                );
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

    /**
     * @notice Swaps borrowed loan tokens for collateral and adds them to a position.
     * @dev Ensures the PoolKey is set, performs the swap, approves collateral,
     *      and verifies the position health after adding the new collateral.
     * @param positionId ID of the user's position in the vault.
     * @param borrowAmount Amount of loan token to swap for collateral.
     * @param minAmountOut Minimum acceptable amount of collateral received from the swap.
     * @param hookData Optional data passed to the swap router for advanced swap handling.
     */
    function _addCollateral(
        uint256 positionId,
        uint256 borrowAmount,
        uint128 minAmountOut,
        bytes memory hookData
    ) internal {
        PoolKey memory key = pools[address(loanToken)][
            address(collateralToken)
        ];
        require(
            Currency.unwrap(key.currency0) != address(0) &&
                Currency.unwrap(key.currency1) != address(0),
            "PoolKey not set"
        );
        uint256 collateralOutput = _swapLoanToCollateral(
            key,
            uint128(borrowAmount),
            minAmountOut,
            hookData
        );

        collateralToken.approve(address(vault), collateralOutput);
        vault.addCollateralFor(positionId, msg.sender, collateralOutput);
    }

    /**
     * @notice Swaps borrowed loan tokens into collateral tokens via Universal Router.
     * @param key PoolKey struct containing the swap pool configuration.
     * @param amountIn Amount of input token to swap.
     * @param minAmountOut Minimum amount of output token expected.
     * @param hookData Optional router hook data.
     * @return amountOut Amount of collateral token received from the swap.
     */
    function _swapLoanToCollateral(
        PoolKey memory key,
        uint128 amountIn,
        uint128 minAmountOut,
        bytes memory hookData
    ) internal returns (uint256 amountOut) {
        bool zeroForOne = address(loanToken) < address(collateralToken)
            ? true
            : false;

        loanToken.approve(address(permit2), type(uint256).max);
        permit2.approve(
            address(loanToken),
            address(swapRouter),
            type(uint160).max,
            uint48(block.timestamp) + 60
        );

        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: hookData
            })
        );
        params[1] = abi.encode(loanToken, amountIn);
        params[2] = abi.encode(collateralToken, minAmountOut);

        // Combine actions and params into inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        swapRouter.execute(commands, inputs);
        uint256 balanceAfter = collateralToken.balanceOf(address(this));

        amountOut = balanceAfter - balanceBefore;
    }
}
