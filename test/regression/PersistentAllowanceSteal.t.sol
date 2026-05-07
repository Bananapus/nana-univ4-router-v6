// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PreviewPayForRoutingTest} from "./PreviewPayForRouting.t.sol";

contract PreviewPayForAllowanceLeakTest is PreviewPayForRoutingTest {
    function test_PreviewPayFor_RevertsIfTerminalKeepsTemporaryAllowance() public {
        uint256 amountIn = 1 ether;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        mockTerminal.setConsumePaymentTokens(false);

        vm.expectRevert();
        jbSwapRouter.swap(key, params, 0);

        assertEq(paymentToken.allowance(address(hook), address(mockTerminal)), 0, "revert unwinds temporary allowance");
        assertEq(paymentToken.balanceOf(address(hook)), 0, "revert unwinds hook token balance");
    }
}
