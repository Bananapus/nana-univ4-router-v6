// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {BuybackCashOutMetadataIgnoredTest} from "../regression/BuybackCashOutMetadataIgnored.t.sol";

contract CodexNemesisBuybackSellMetadataUnderquoteTest is BuybackCashOutMetadataIgnoredTest {
    /// @notice After the fix, the metadata-only sell preview surfaces the executable amount as-is. When the JB
    /// route pays more than the V4 spot quote, the router must route through JB instead of misrouting to V4.
    function test_metadataBackedSellRouteWinsAfterFix() public {
        uint256 amountIn = 1 ether;
        uint256 liveCashOutAmount = 1.02 ether;

        _installMetadataOnlySellTerminal(liveCashOutAmount);
        token0.approve(address(jbSwapRouter), amountIn);

        uint256 previewQuote = hook.calculateExpectedOutputFromSelling({
            projectId: 123,
            tokenAmountIn: amountIn,
            outputToken: address(token1),
            terminal: IJBTerminal(address(metadataOnlySellTerminal))
        });
        uint256 v4Quote = hook.estimateUniswapOutput({poolId: id, key: key, amountIn: amountIn, zeroForOne: true});

        assertEq(previewQuote, liveCashOutAmount, "preview must reflect the executable metadata amount");
        assertGt(previewQuote, v4Quote, "JB metadata route must rank ahead of V4 when it pays more");

        uint256 balanceBefore = token1.balanceOf(address(this));
        jbSwapRouter.swap({
            key: key,
            params: SwapParams({
                zeroForOne: true,
                // Safe: `amountIn` is the fixed 1 ether test constant.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            amountOutMin: 0
        });
        uint256 received = token1.balanceOf(address(this)) - balanceBefore;

        assertEq(metadataOnlySellTerminal.lastProjectId(), 123, "router must execute the JB metadata sell path");
        assertGe(received, liveCashOutAmount, "user must receive at least the executable JB metadata amount");
    }
}
