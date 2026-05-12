// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {BuybackCashOutMetadataIgnoredTest} from "../regression/BuybackCashOutMetadataIgnored.t.sol";

contract CodexNemesisBuybackSellMetadataUnderquoteTest is BuybackCashOutMetadataIgnoredTest {
    function test_sellMetadataFeeDiscountCanMisrouteToV4EvenWhenLiveJbOutputIsBetter() public {
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

        assertLt(previewQuote, v4Quote, "fee-discounted metadata quote loses to V4 quote");
        assertGt(liveCashOutAmount, v4Quote, "live JB output would beat the V4 quote");

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

        assertEq(metadataOnlySellTerminal.lastProjectId(), 0, "router chose V4 instead of the live-better JB path");
        assertLt(received, liveCashOutAmount, "user received less than the executable JB cash-out output");
    }
}
