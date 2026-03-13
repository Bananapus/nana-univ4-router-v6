// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";

contract CreatePoolAndAddLiquidityScript is BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////

    uint24 lpFee = 3000; // 0.30%
    int24 tickSpacing = 60;
    uint160 startingPrice = 2 ** 96; // Starting price, sqrtPriceX96; floor(sqrt(1) * 2^96)

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 100e18;
    uint256 public token1Amount = 100e18;

    // range of the position, must be a multiple of tickSpacing
    int24 tickLower;
    int24 tickUpper;
    /////////////////////////////////////

    function run() external {
        PoolKey memory poolKey = PoolKey({
            currency0: CURRENCY0, currency1: CURRENCY1, fee: lpFee, tickSpacing: tickSpacing, hooks: HOOK_CONTRACT
        });

        bytes memory hookData = new bytes(0);

        int24 currentTick = TickMath.getTickAtSqrtPrice(startingPrice);

        tickLower = truncateTickSpacing({tick: (currentTick - 750 * tickSpacing), tickSpacing: tickSpacing});
        tickUpper = truncateTickSpacing({tick: (currentTick + 750 * tickSpacing), tickSpacing: tickSpacing});

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtRatioX96: startingPrice,
            sqrtRatioAX96: TickMath.getSqrtPriceAtTick(tickLower),
            sqrtRatioBX96: TickMath.getSqrtPriceAtTick(tickUpper),
            amount0: token0Amount,
            amount1: token1Amount
        });

        // slippage limits
        uint256 amount0Max = token0Amount + 1;
        uint256 amount1Max = token1Amount + 1;

        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams({
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            amount0Max: amount0Max,
            amount1Max: amount1Max,
            recipient: DEPLOYER_ADDRESS,
            hookData: hookData
        });

        // multicall parameters
        bytes[] memory params = new bytes[](2);

        // Initialize Pool
        params[0] = abi.encodeWithSelector(POSITION_MANAGER.initializePool.selector, poolKey, startingPrice, hookData);

        // Mint Liquidity
        params[1] = abi.encodeWithSelector(
            POSITION_MANAGER.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 3600
        );

        uint256 valueToPass = 0;
        if (CURRENCY0.isAddressZero()) valueToPass += amount0Max;
        if (CURRENCY1.isAddressZero()) valueToPass += amount1Max;

        vm.startBroadcast();
        tokenApprovals();

        // Multicall to atomically create pool & add liquidity
        POSITION_MANAGER.multicall{value: valueToPass}(params);
        vm.stopBroadcast();
    }
}
