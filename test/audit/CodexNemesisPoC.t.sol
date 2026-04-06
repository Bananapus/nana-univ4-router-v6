// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

import {MockERC20} from "../mock/MockERC20.sol";
import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";

contract NoFeeCashOutTerminal {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 internal immutable _reclaimAmount;

    constructor(uint256 reclaimAmount) {
        _reclaimAmount = reclaimAmount;
    }

    function previewCashOutFrom(
        address,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    )
        external
        view
        returns (JBRuleset memory ruleset, uint256 reclaimAmount, uint256, JBCashOutHookSpecification[] memory specs)
    {
        return (ruleset, _reclaimAmount, 0, specs);
    }
}

contract CodexNemesisPoC is JuiceboxHookTest {
    using PoolIdLibrary for PoolKey;

    function test_PoC_DualJBPoolUsesBetterSellSideRoute() public {
        MockERC20 dualToken0 = new MockERC20("DualJB0", "DJB0");
        MockERC20 dualToken1 = new MockERC20("DualJB1", "DJB1");

        if (address(dualToken0) > address(dualToken1)) {
            (dualToken0, dualToken1) = (dualToken1, dualToken0);
        }

        uint256 sellProjectId = 111;
        uint256 buyProjectId = 222;

        mockJBTokens.setProjectId(address(dualToken0), sellProjectId);
        mockJBTokens.setProjectId(address(dualToken1), buyProjectId);

        mockJBController.setWeight(buyProjectId, 5000e18);
        mockJBMultiTerminal.setProjectToken(buyProjectId, address(dualToken1));

        uint32 dualToken0CurrencyId = uint32(uint160(address(dualToken0)));
        mockJBPrices.setPricePerUnitOf(buyProjectId, dualToken0CurrencyId, 1, 1e18);

        // Gross reclaim is set so the hook's sell-side preview returns 10_000 tokens after the 2.5% fee deduction.
        mockJBTerminalStore.setSurplus(sellProjectId, address(dualToken1), 10_256.410_256_410_256_410_256 ether);

        PoolKey memory dualKey = PoolKey({
            currency0: Currency.wrap(address(dualToken0)),
            currency1: Currency.wrap(address(dualToken1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        dualToken0.mint(address(this), 1000 ether);
        dualToken1.mint(address(this), 1000 ether);
        dualToken0.approve(address(modifyLiquidityRouter), type(uint256).max);
        dualToken1.approve(address(modifyLiquidityRouter), type(uint256).max);
        dualToken0.approve(address(hook), type(uint256).max);
        dualToken1.approve(address(hook), type(uint256).max);

        manager.initialize(dualKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            dualKey,
            // Keep the pool shallow so the V4 quote stays below the buy-side quote.
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        uint256 buySideQuote = hook.calculateExpectedTokensWithCurrency(buyProjectId, address(dualToken0), 1 ether);
        uint256 sellSideQuote = hook.calculateExpectedOutputFromSelling(
            sellProjectId, 1 ether, address(dualToken1), IJBTerminal(address(mockJBMultiTerminal))
        );
        uint256 v4Quote = hook.estimateUniswapOutput(dualKey.toId(), dualKey, 1 ether, true);

        assertEq(buySideQuote, 5000 ether, "buy-side preview sanity");
        assertEq(sellSideQuote, 10_000 ether, "sell-side preview sanity");
        assertLt(v4Quote, buySideQuote, "the hook must prefer a JB route over V4 in this setup");
        assertGt(sellSideQuote, buySideQuote, "sell-side route should now be strictly better than buy-side");

        dualToken0.approve(address(jbSwapRouter), 1 ether);
        uint256 balanceBefore = dualToken1.balanceOf(address(this));

        jbSwapRouter.swap(
            dualKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            0
        );

        uint256 received = dualToken1.balanceOf(address(this)) - balanceBefore;

        assertGe(received, sellSideQuote, "execution should use the better sell-side Juicebox route");
        assertGt(received, buySideQuote, "sell-side route should outperform the stale buy-side estimate");
        assertEq(mockJBMultiTerminal.lastProjectId(), sellProjectId, "routing should select the sell-side project");
    }

    /// @dev After audit remediation, FEE() is wrapped in try-catch.
    /// A terminal that lacks IJBFeeTerminal no longer bricks the swap;
    /// fee defaults to 0 and the swap routes through V4 instead of reverting.
    function test_PoC_SellSideGracefullyFallsBackWhenTerminalLacksFeeInterface() public {
        NoFeeCashOutTerminal noFeeTerminal = new NoFeeCashOutTerminal(1);
        mockJBDirectory.setMockTerminal(address(noFeeTerminal));

        token0.approve(address(jbSwapRouter), 1 ether);

        uint256 v4Quote = hook.estimateUniswapOutput(id, key, 1 ether, true);
        assertGt(v4Quote, 0, "V4 route is otherwise live");

        // With the try-catch fix, the swap no longer reverts. It falls back to V4.
        uint256 balanceBefore = token1.balanceOf(address(this));
        jbSwapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            0
        );
        uint256 received = token1.balanceOf(address(this)) - balanceBefore;
        assertGt(received, 0, "swap should succeed via V4 fallback");
    }
}
