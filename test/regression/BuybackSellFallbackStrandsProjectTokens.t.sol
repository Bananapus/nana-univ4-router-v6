// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract SellFallbackLikeTerminal {
    uint256 internal immutable _previewCashOutAmount;

    uint256 public lastProjectId;
    uint256 public lastCashOutCount;
    address public lastTokenToReclaim;
    address public lastBeneficiary;

    constructor(uint256 previewCashOutAmount) {
        _previewCashOutAmount = previewCashOutAmount;
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

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external view returns (uint256) {
        return _previewCashOutAmount;
    }
}

contract SellPartialFillLikeTerminal {
    uint256 internal immutable _previewCashOutAmount;
    uint256 internal immutable _reclaimAmount;

    uint256 public lastProjectId;
    uint256 public lastCashOutCount;
    address public lastTokenToReclaim;
    address public lastBeneficiary;

    constructor(uint256 previewCashOutAmount, uint256 reclaimAmount) {
        _previewCashOutAmount = previewCashOutAmount;
        _reclaimAmount = reclaimAmount;
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
        uint256 minTokensReclaimed,
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

        require(_reclaimAmount >= minTokensReclaimed, "min reclaim");

        // Delivers output while leaving the exact-input project tokens on the hook.
        MockERC20(tokenToReclaim).mint(beneficiary, _reclaimAmount);
        return _reclaimAmount;
    }

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external view returns (uint256) {
        return _previewCashOutAmount;
    }
}

contract BuybackSellFallbackStrandsProjectTokensTest is JuiceboxHookTest {
    SellFallbackLikeTerminal internal sellFallbackTerminal;
    SellPartialFillLikeTerminal internal sellPartialFillTerminal;

    function test_sellFallbackLikeCashOutRevertsInsteadOfStrandingProjectTokensOnHook() public {
        uint256 amountIn = 1 ether;
        sellFallbackTerminal = new SellFallbackLikeTerminal(2 ether);
        mockJBDirectory.setMockTerminal(address(sellFallbackTerminal));
        token0.approve(address(jbSwapRouter), amountIn);

        uint256 previewQuote = hook.calculateExpectedOutputFromSelling(
            123, amountIn, address(token1), IJBTerminal(address(sellFallbackTerminal))
        );
        assertEq(previewQuote, 2 ether, "zero-tax preview should make the JB sell route look best");

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

    function test_sellCashOutMustConsumeExactInputProjectTokens() public {
        uint256 amountIn = 1 ether;
        sellPartialFillTerminal = new SellPartialFillLikeTerminal(2 ether, 2 ether);
        mockJBDirectory.setMockTerminal(address(sellPartialFillTerminal));
        token0.approve(address(jbSwapRouter), amountIn);

        uint256 previewQuote = hook.calculateExpectedOutputFromSelling(
            123, amountIn, address(token1), IJBTerminal(address(sellPartialFillTerminal))
        );
        assertEq(previewQuote, 2 ether, "sell preview should make the JB route look best");

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

        assertEq(sellPartialFillTerminal.lastProjectId(), 0, "terminal effects should revert");
        assertEq(token1.balanceOf(address(this)), userToken1Before, "user should receive no output on revert");
        assertEq(token0.balanceOf(address(this)), userToken0Before, "user should keep the project tokens on revert");
        assertEq(token0.balanceOf(address(hook)), hookToken0Before, "project tokens should not remain on the hook");
    }
}
