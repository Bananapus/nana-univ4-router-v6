// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract ZeroTaxNoFeeCashoutTerminal {
    uint256 internal immutable _cashOutAmount;
    address internal _projectToken;
    uint256 public lastProjectId;

    constructor(uint256 cashOutAmount) {
        _cashOutAmount = cashOutAmount;
    }

    function setProjectToken(address projectToken) external {
        _projectToken = projectToken;
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
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory specs
        )
    {
        ruleset = JBRuleset({
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
        reclaimAmount = _cashOutAmount;
        cashOutTaxRate = 0;
        specs = new JBCashOutHookSpecification[](0);
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
        returns (uint256)
    {
        require(_cashOutAmount >= minTokensReclaimed, "under min");
        lastProjectId = projectId;
        // Burn the input project tokens from the caller to match real-terminal semantics —
        // `JBUniswapV4Hook` checks that the input balance dropped post-call.
        if (_projectToken != address(0) && cashOutCount != 0) {
            MockERC20(_projectToken).burn(msg.sender, cashOutCount);
        }
        MockERC20(tokenToReclaim).mint(beneficiary, _cashOutAmount);
        return _cashOutAmount;
    }

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return JBAccountingContext({token: token, decimals: 18, currency: uint32(uint160(token))});
    }

    function currentSurplusOf(uint256, address[] calldata, uint256, uint256) external view returns (uint256) {
        return _cashOutAmount;
    }
}

contract ZeroTaxCashoutUnderquoteTest is JuiceboxHookTest {
    function test_zeroTaxCashoutWithoutFeeFreeSurplusRoutesThroughJBWhenItPaysMore() public {
        uint256 amountIn = 1 ether;
        uint256 liveCashOutAmount = 1.01 ether;

        ZeroTaxNoFeeCashoutTerminal terminal = new ZeroTaxNoFeeCashoutTerminal(liveCashOutAmount);
        terminal.setProjectToken(address(token0));
        mockJBDirectory.setMockTerminal(address(terminal));

        uint256 routerPreview = hook.calculateExpectedOutputFromSelling({
            projectId: 123,
            tokenAmountIn: amountIn,
            outputToken: address(token1),
            terminal: IJBTerminal(address(terminal))
        });
        uint256 v4Quote = hook.estimateUniswapOutput({poolId: id, key: key, amountIn: amountIn, zeroForOne: true});

        assertEq(routerPreview, liveCashOutAmount, "zero-tax router preview should not subtract a blanket fee");
        assertGt(routerPreview, v4Quote, "router should rank the better JB cash-out higher");
        assertGt(liveCashOutAmount, v4Quote, "the executable zero-tax cashout would pay more than V4");

        token0.approve(address(jbSwapRouter), amountIn);
        uint256 balanceBefore = token1.balanceOf(address(this));
        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                // Safe: amountIn is a fixed 1 ether test constant.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            0
        );

        uint256 received = token1.balanceOf(address(this)) - balanceBefore;
        assertEq(terminal.lastProjectId(), 123, "router should use the better JB cash-out");
        assertEq(received, liveCashOutAmount, "user should receive the no-fee JB cash-out amount");
    }
}
