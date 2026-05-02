// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";

contract SellFallbackLikeTerminal {
    uint256 internal immutable _previewCashOutAmount;

    uint256 public lastProjectId;
    uint256 public lastCashOutCount;
    address public lastTokenToReclaim;
    address public lastBeneficiary;

    constructor(uint256 previewCashOutAmount) {
        _previewCashOutAmount = previewCashOutAmount;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 0;
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
        view
        returns (JBRuleset memory, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        JBRuleset memory ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        JBCashOutHookSpecification[] memory specs = new JBCashOutHookSpecification[](0);
        return (ruleset, _previewCashOutAmount, 0, specs);
    }

    function cashOutTokensOf(
        address,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256 reclaimAmount)
    {
        lastProjectId = projectId;
        lastCashOutCount = cashOutCount;
        lastTokenToReclaim = tokenToReclaim;
        lastBeneficiary = beneficiary;

        // Mimic the observable buyback sell-fallback surface:
        // the holder keeps the project tokens, but the terminal reports zero reclaimed output.
        return 0;
    }
}

contract BuybackSellFallbackStrandsProjectTokensTest is JuiceboxHookTest {
    SellFallbackLikeTerminal internal sellFallbackTerminal;

    function test_sellFallbackLikeCashOutRevertsInsteadOfStrandingProjectTokensOnHook() public {
        uint256 amountIn = 1 ether;
        sellFallbackTerminal = new SellFallbackLikeTerminal(2 ether);
        mockJBDirectory.setMockTerminal(address(sellFallbackTerminal));
        token0.approve(address(jbSwapRouter), amountIn);

        uint256 previewQuote = hook.calculateExpectedOutputFromSelling(
            123, amountIn, address(token1), IJBTerminal(address(sellFallbackTerminal))
        );
        assertEq(previewQuote, 2 ether, "preview should make the JB sell route look best");

        uint256 userToken0Before = token0.balanceOf(address(this));
        uint256 userToken1Before = token1.balanceOf(address(this));
        uint256 hookToken0Before = token0.balanceOf(address(hook));

        // PoolManager wraps hook reverts in WrappedError(address,bytes4,bytes,bytes4), so match the revert generally.
        vm.expectRevert();
        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            0
        );

        assertEq(sellFallbackTerminal.lastProjectId(), 0, "terminal effects should revert");
        assertEq(token1.balanceOf(address(this)), userToken1Before, "user should receive no output on revert");
        assertEq(token0.balanceOf(address(this)), userToken0Before, "user should keep the project tokens on revert");
        assertEq(token0.balanceOf(address(hook)), hookToken0Before, "project tokens should not remain on the hook");
    }
}
