// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract PreviewRevertingLiveSellTerminal {
    uint256 internal immutable _liveCashOutAmount;

    constructor(uint256 liveCashOutAmount) {
        _liveCashOutAmount = liveCashOutAmount;
    }

    function FEE() external pure returns (uint256) {
        return 25;
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        pure
        returns (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256, JBPayHookSpecification[] memory)
    {
        beneficiaryTokenCount =
            0;
        return (ruleset, beneficiaryTokenCount, 0, new JBPayHookSpecification[](0));
    }

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 0;
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
        pure
        returns (JBRuleset memory, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        revert("preview unavailable");
    }

    function cashOutTokensOf(
        address,
        uint256,
        uint256,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256)
    {
        require(_liveCashOutAmount >= minTokensReclaimed, "min reclaim");
        MockERC20(tokenToReclaim).mint(beneficiary, _liveCashOutAmount);
        return _liveCashOutAmount;
    }
}

contract CodexNemesisFreshPoC is JuiceboxHookTest {
    function test_poc_largeBuyMisroutesToV4OnLinearQuote() public {
        uint256 amountIn = 5 ether;
        uint256 quotedV4Out = hook.estimateUniswapOutput(id, key, amountIn, false);
        uint256 jbLiveOut = quotedV4Out - 1;

        mockJBMultiTerminal.setPayReturnAmount(jbLiveOut);

        uint256 initialToken0Balance = token0.balanceOf(address(this));
        token1.mint(address(this), amountIn);
        token1.approve(address(jbSwapRouter), amountIn);

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        jbSwapRouter.swap(key, params, 0);

        uint256 actualV4Out = token0.balanceOf(address(this)) - initialToken0Balance;

        assertLt(actualV4Out, jbLiveOut, "actual V4 output should be worse than executable JB buy output");
        assertEq(mockJBMultiTerminal.lastProjectId(), 0, "router should have incorrectly skipped the JB route");
    }

    function test_poc_sellPreviewFailureForcesWorseV4Route() public {
        uint256 amountIn = 1 ether;
        uint256 jbLiveOut = 2 ether;

        PreviewRevertingLiveSellTerminal terminal = new PreviewRevertingLiveSellTerminal(jbLiveOut);
        mockJBDirectory.setMockTerminal(address(terminal));

        uint256 previewQuote =
            hook.calculateExpectedOutputFromSelling(123, amountIn, address(token1), IJBTerminal(address(terminal)));
        assertEq(previewQuote, 0, "preview failure should zero the JB sell quote");

        uint256 initialToken1Balance = token1.balanceOf(address(this));
        token0.approve(address(jbSwapRouter), amountIn);

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        jbSwapRouter.swap(key, params, 0);

        uint256 actualV4Out = token1.balanceOf(address(this)) - initialToken1Balance;

        assertLt(actualV4Out, jbLiveOut, "actual V4 sell output should be worse than live JB cash-out output");
    }
}
