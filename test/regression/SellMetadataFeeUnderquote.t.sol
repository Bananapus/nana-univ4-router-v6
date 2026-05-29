// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract MockSellTerminal {
    uint256 internal immutable _liveCashOutAmount;
    uint256 public lastProjectId;

    constructor(uint256 liveCashOutAmount) {
        _liveCashOutAmount = liveCashOutAmount;
    }

    function FEE() external pure returns (uint256) {
        return 25;
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

        specs = new JBCashOutHookSpecification[](1);
        specs[0] = JBCashOutHookSpecification({
            hook: IJBCashOutHook(address(0xB0B)),
            noop: false,
            amount: 0,
            metadata: abi.encode(
                _liveCashOutAmount,
                uint256(0),
                uint256(0),
                int24(0),
                uint128(0),
                PoolId.wrap(bytes32(0)),
                _liveCashOutAmount,
                false
            )
        });

        reclaimAmount = 0;
        cashOutTaxRate = 0;
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
        returns (uint256)
    {
        require(_liveCashOutAmount >= minTokensReclaimed, "insufficient metadata cash-out");
        lastProjectId = projectId;
        MockERC20(tokenToReclaim).mint(beneficiary, _liveCashOutAmount);
        return _liveCashOutAmount;
    }
}

contract SellMetadataFeeUnderquoteTest is JuiceboxHookTest {
    /// @notice Metadata-only buyback sell previews stay ineligible for route choice.
    function test_metadataBackedSellRouteStaysIneligible() public {
        uint256 amountIn = 1 ether;
        uint256 liveCashOutAmount = 1.02 ether;

        MockSellTerminal terminal = new MockSellTerminal(liveCashOutAmount);
        mockJBDirectory.setMockTerminal(address(terminal));

        uint256 routerPreview =
            hook.calculateExpectedOutputFromSelling(123, amountIn, address(token1), IJBTerminal(address(terminal)));
        uint256 v4Quote = hook.estimateUniswapOutput(id, key, amountIn, true);

        assertEq(routerPreview, 0, "metadata-only preview must not influence routing");
        assertLt(v4Quote, liveCashOutAmount, "direct JB output would beat V4");

        token0.approve(address(jbSwapRouter), amountIn);
        uint256 balanceBefore = token1.balanceOf(address(this));

        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                // The test amount is a small constant and fits safely in int256.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            0
        );

        uint256 received = token1.balanceOf(address(this)) - balanceBefore;

        assertEq(terminal.lastProjectId(), 0, "router must skip the JB metadata sell path");
        assertGt(received, 0, "swap should fall back to V4");
        assertLt(received, liveCashOutAmount, "metadata-only preview must not steer route choice");
    }
}
