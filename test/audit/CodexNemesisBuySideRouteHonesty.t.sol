// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {MockTerminalIgnoringMin} from "../regression/JBRouteMinOutputBypass.t.sol";
import {PreviewPayForRoutingTest} from "../regression/PreviewPayForRouting.t.sol";

contract CodexNemesisBuySideRouteHonestyTest is PreviewPayForRoutingTest {
    /// @notice A terminal that inflates `previewPayFor` to win the routing decision and then mints fewer project
    /// tokens at `pay` time must not be able to silently settle below the V4 quote it displaced. The router's
    /// strict `routeMinimum >= uniswapV4ExpectedTokens + 1` floor rejects the under-fill via
    /// `JBUniswapV4Hook_InsufficientOutput`.
    function test_buySideRevertsWhenActualPayUnderrunsV4Quote() public {
        MockTerminalIgnoringMin terminal = new MockTerminalIgnoringMin();
        terminal.setProjectToken(123, address(projectToken));
        mockDirectory.setDefaultTerminal(address(terminal));

        uint256 amountIn = 1 ether;
        uint256 v4Quote = hook.estimateUniswapOutput({poolId: id, key: key, amountIn: amountIn, zeroForOne: zeroForOne});

        terminal.setPreviewReturn(v4Quote + 1 ether);
        terminal.setActualPayAmount(v4Quote / 2);

        // forge-lint: disable-next-line(unsafe-typecast)
        int256 exactAmountIn = int256(amountIn);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -exactAmountIn,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.expectRevert();
        jbSwapRouter.swap(key, params, 0);
    }
}
