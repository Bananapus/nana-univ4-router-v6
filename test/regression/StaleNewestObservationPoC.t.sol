// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";

/// @notice Regression coverage for capped oracle writes: under-covered windows must fail closed, not leave stale data.
contract StaleNewestObservationPoC is JuiceboxHookTest {
    function test_cappedOracleContinuesWritingAndReportsUnderCoveredWindow() external {
        token1.approve(address(swapRouter), type(uint256).max);

        uint16 cardinality;
        while (cardinality < hook.MAX_TWAP_CARDINALITY()) {
            _swapAtNextTimestamp();
            (, cardinality,) = hook.states(id);
        }

        assertFalse(hook.hasObservationCoverage(key, hook.TWAP_PERIOD()), "high-cadence buffer is under-covered");

        (uint16 indexBefore,,) = hook.states(id);
        _swapAtNextTimestamp();
        (uint16 indexAfter,,) = hook.states(id);

        assertNotEq(indexAfter, indexBefore, "capped oracle must keep writing instead of leaving stale newest data");
    }

    function _swapAtNextTimestamp() internal {
        vm.warp(block.timestamp + 1);

        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});

        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }
}
