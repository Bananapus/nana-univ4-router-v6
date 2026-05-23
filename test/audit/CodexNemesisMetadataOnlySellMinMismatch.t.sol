// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";

contract CoreLikeMetadataOnlySellTerminal {
    uint256 internal immutable _hookDeliveredAmount;
    uint256 public lastProjectId;

    constructor(uint256 hookDeliveredAmount) {
        _hookDeliveredAmount = hookDeliveredAmount;
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
        reclaimAmount = 0;
        cashOutTaxRate = 0;
        specs = new JBCashOutHookSpecification[](1);
        specs[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(0xBEEF)),
            noop: false,
            amount: 0,
            metadata: abi.encode(
                _hookDeliveredAmount,
                uint256(0),
                uint256(0),
                int24(0),
                uint128(0),
                PoolId.wrap(bytes32(0)),
                uint256(0),
                false
            )
        });
    }

    function cashOutTokensOf(
        address,
        uint256 projectId,
        uint256,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata,
        uint256 /* referralProjectId */
    )
        external
        returns (uint256 reclaimAmount)
    {
        lastProjectId = projectId;
        MockERC20(tokenToReclaim).mint(beneficiary, _hookDeliveredAmount);

        // Mirrors JBMultiTerminal.cashOutTokensOf(): minTokensReclaimed is checked against direct reclaimAmount,
        // not against tokens delivered later by a cash-out hook.
        require(reclaimAmount >= minTokensReclaimed, "UNDER_MIN_DIRECT_RECLAIM");
    }
}

contract CodexNemesisMetadataOnlySellMinMismatchTest is JuiceboxHookTest {
    function test_unsupportedMetadataOnlySellShapeIsIgnoredForRouting() public {
        uint256 amountIn = 1 ether;
        uint256 hookDeliveredAmount = 2 ether;

        CoreLikeMetadataOnlySellTerminal terminal = new CoreLikeMetadataOnlySellTerminal(hookDeliveredAmount);
        mockJBDirectory.setMockTerminal(address(terminal));

        uint256 quote = hook.calculateExpectedOutputFromSelling({
            projectId: 123,
            tokenAmountIn: amountIn,
            outputToken: address(token1),
            terminal: IJBTerminal(address(terminal))
        });
        assertEq(quote, 0, "unsupported metadata shape must not influence routing");

        token0.approve(address(jbSwapRouter), amountIn);
        uint256 balanceBefore = token1.balanceOf(address(this));

        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            0
        );

        uint256 received = token1.balanceOf(address(this)) - balanceBefore;

        assertEq(terminal.lastProjectId(), 0, "unsupported metadata-only cash-out must not be routed through JB");
        assertGt(received, 0, "fallback V4 route should execute");
    }
}
