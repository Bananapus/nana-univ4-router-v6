// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";

contract AddLiquidityScript is BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////

    uint24 lpFee = 3000; // 0.30%
    int24 tickSpacing = 60;

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 1e18;
    uint256 public token1Amount = 1e18;

    /////////////////////////////////////

    int24 tickLower;
    int24 tickUpper;

    function run() external {
        PoolKey memory poolKey = PoolKey({
            currency0: CURRENCY0, currency1: CURRENCY1, fee: lpFee, tickSpacing: tickSpacing, hooks: HOOK_CONTRACT
        });
        bytes memory hookData = new bytes(0);

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolKey.toId());

        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        tickLower = truncateTickSpacing({tick: (currentTick - 1000 * tickSpacing), tickSpacing: tickSpacing});
        tickUpper = truncateTickSpacing({tick: (currentTick + 1000 * tickSpacing), tickSpacing: tickSpacing});

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtRatioX96: sqrtPriceX96,
            sqrtRatioAX96: TickMath.getSqrtPriceAtTick(tickLower),
            sqrtRatioBX96: TickMath.getSqrtPriceAtTick(tickUpper),
            amount0: token0Amount,
            amount1: token1Amount
        });

        // slippage limits
        uint256 amount0Max = token0Amount + 1 wei;
        uint256 amount1Max = token1Amount + 1 wei;

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
        bytes[] memory params = new bytes[](1);

        // Mint Liquidity
        params[0] = abi.encodeWithSelector(
            POSITION_MANAGER.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 60
        );

        // If the pool is an ETH pair, native tokens are to be transferred
        uint256 valueToPass = CURRENCY0.isAddressZero() ? amount0Max : 0;

        vm.startBroadcast();
        tokenApprovals();

        // Add liquidity to existing pool
        POSITION_MANAGER.multicall{value: valueToPass}(params);
        vm.stopBroadcast();
    }
}
