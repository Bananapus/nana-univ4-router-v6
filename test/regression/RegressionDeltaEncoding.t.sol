// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";

contract RegressionDeltaEncoding is JuiceboxHookTest {
    function test_jbRouteOutputAboveInt128FallsBackToV4() public {
        uint256 amountIn = 35_000 ether;

        mockJBController.setWeight(123, type(uint112).max);

        uint256 oversizedOutput = hook.calculateExpectedTokensWithCurrency(123, address(token1), amountIn);
        assertGt(oversizedOutput, uint256(uint128(type(int128).max)), "test setup must exceed int128 delta capacity");

        // Model the real terminal path: pay() would return the same oversized beneficiary token count that
        // routing estimated from the ruleset weight. The hook should now reject that JB path before execution.
        mockJBMultiTerminal.setPayReturnAmount(oversizedOutput);

        token1.mint(address(this), amountIn);
        token1.approve(address(jbSwapRouter), amountIn);

        uint256 balanceBefore = token0.balanceOf(address(this));
        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                // Safe: the test input is 35_000 ether, well within int256.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            0
        );

        assertEq(mockJBMultiTerminal.lastProjectId(), 0, "oversized JB quote should be treated as ineligible");
        assertGt(token0.balanceOf(address(this)) - balanceBefore, 0, "swap should succeed through the V4 fallback");
    }
}
