// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract ActualBuybackMetadataLengthTerminal {
    uint256 internal immutable _liveCashOutAmount;
    uint256 public lastProjectId;

    constructor(uint256 liveCashOutAmount) {
        _liveCashOutAmount = liveCashOutAmount;
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
                uint256(1 ether),
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
        uint256
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

contract ActualBuybackMetadataLengthTest is JuiceboxHookTest {
    function test_actualEightWordBuybackSellMetadataIsIgnoredForRouting() public {
        uint256 amountIn = 1 ether;
        uint256 liveCashOutAmount = 1.02 ether;

        ActualBuybackMetadataLengthTerminal terminal = new ActualBuybackMetadataLengthTerminal(liveCashOutAmount);
        mockJBDirectory.setMockTerminal(address(terminal));

        uint256 preview = hook.calculateExpectedOutputFromSelling({
            projectId: 123,
            tokenAmountIn: amountIn,
            outputToken: address(token1),
            terminal: IJBTerminal(address(terminal))
        });
        uint256 v4Quote = hook.estimateUniswapOutput({poolId: id, key: key, amountIn: amountIn, zeroForOne: true});

        assertEq(preview, 0, "router ignores current 8-word buyback metadata");
        assertLt(v4Quote, liveCashOutAmount, "direct JB output would beat V4");

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
        assertEq(terminal.lastProjectId(), 0, "router must skip the JB metadata sell route");
        assertGt(received, 0, "swap should fall back to V4");
        assertLt(received, liveCashOutAmount, "metadata-only preview must not steer route choice");
    }
}
