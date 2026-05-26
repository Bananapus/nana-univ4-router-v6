// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

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

    function test_oversizedBuyQuoteDoesNotSuppressEligibleSellRoute() public {
        uint256 amountIn = 1 ether;
        uint256 buyProjectId = 456;

        mockJBTokens.setProjectId(address(token1), buyProjectId);
        mockJBMultiTerminal.setProjectToken(buyProjectId, address(token1));

        // The buy-side preview is real but cannot be represented in V4's signed-delta accounting domain.
        uint256 oversizedBuyQuote = hook.MAX_V4_DELTA() + 1;
        mockJBMultiTerminal.setPayReturnAmount(oversizedBuyQuote);

        // The sell-side cash-out remains representable and beats the pool quote.
        mockJBTerminalStore.setSurplus(123, address(token1), 3 ether);

        uint256 sellSideQuote = hook.calculateExpectedOutputFromSelling(
            123, amountIn, address(token1), IJBTerminal(address(mockJBMultiTerminal))
        );
        uint256 v4Quote = hook.estimateUniswapOutput(id, key, amountIn, true);

        assertGt(oversizedBuyQuote, hook.MAX_V4_DELTA(), "buy-side quote must be ineligible");
        assertGt(sellSideQuote, v4Quote, "sell-side quote should still beat V4");

        token0.approve(address(jbSwapRouter), amountIn);
        uint256 balanceBefore = token1.balanceOf(address(this));

        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                // Safe: amountIn is 1 ether.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            0
        );

        assertEq(mockJBMultiTerminal.lastProjectId(), 123, "router should select the eligible sell route");
        assertGt(token1.balanceOf(address(this)) - balanceBefore, v4Quote, "sell route should beat the V4 fallback");
    }
}
