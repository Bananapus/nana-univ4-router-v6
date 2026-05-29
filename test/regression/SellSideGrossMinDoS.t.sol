// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";
import {FeeFreeSurplusLikeTerminal} from "../regression/RegressionFeeFreeSurplusCashoutMisroute.t.sol";

contract SellSideGrossMinDoSTest is JuiceboxHookTest {
    function test_sellRouteRevertsWhenGrossPreviewExceedsNetExecutableCashout() public {
        FeeFreeSurplusLikeTerminal terminal = new FeeFreeSurplusLikeTerminal();
        terminal.setProjectToken(address(token0));
        mockJBDirectory.setMockTerminal(address(terminal));

        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(jbSwapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        uint256 amountIn = 1 ether;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // The test amount is fixed at 1 ether and fits safely in int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 v4Snapshot = vm.snapshotState();
        uint256 v4BalanceBefore = token1.balanceOf(address(this));
        terminal.setReclaimAmounts({previewReclaim_: 0, actualReclaim_: 0});
        jbSwapRouter.swap(key, params, 0);
        uint256 v4Received = token1.balanceOf(address(this)) - v4BalanceBefore;
        vm.revertToState(v4Snapshot);

        uint256 grossPreview = 1.95 ether;
        uint256 netCashOut = 1.9 ether;
        assertGt(netCashOut, v4Received, "net JB cash-out is still better than V4");
        terminal.setReclaimAmounts({previewReclaim_: grossPreview, actualReclaim_: netCashOut});

        vm.expectRevert();
        jbSwapRouter.swap(key, params, 0);
    }
}
