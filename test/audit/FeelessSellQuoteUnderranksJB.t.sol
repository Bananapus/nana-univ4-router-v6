// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IJBFeelessAddresses} from "@bananapus/core-v6/src/interfaces/IJBFeelessAddresses.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract FeelessRegistry {
    address internal immutable _feelessAddress;

    constructor(address feelessAddress) {
        _feelessAddress = feelessAddress;
    }

    function isFeeless(address addr) external view returns (bool) {
        return addr == _feelessAddress;
    }

    function setFeelessAddress(address, bool) external pure {}
}

contract FeelessSellPreviewTerminal {
    uint256 internal immutable _cashOutAmount;

    IJBFeelessAddresses public immutable FEELESS_ADDRESSES;

    uint256 public lastProjectId;

    constructor(uint256 cashOutAmount, IJBFeelessAddresses feelessAddresses) {
        _cashOutAmount = cashOutAmount;
        FEELESS_ADDRESSES = feelessAddresses;
    }

    // forge-lint: disable-next-line(mixed-case-function)
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
        return (ruleset, beneficiaryTokenCount, 0, new JBPayHookSpecification[](0));
    }

    function pay(uint256, address, uint256, address, uint256, string calldata, bytes calldata)
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
            id: 7,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        JBCashOutHookSpecification[] memory specs = new JBCashOutHookSpecification[](0);
        return (ruleset, _cashOutAmount, 0, specs);
    }

    function cashOutTokensOf(
        address,
        uint256 projectId,
        uint256,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256 reclaimAmount)
    {
        require(_cashOutAmount >= minTokensReclaimed, "FeelessSellPreviewTerminal: insufficient output");

        lastProjectId = projectId;
        MockERC20(tokenToReclaim).mint(beneficiary, _cashOutAmount);
        return _cashOutAmount;
    }
}

contract FeelessSellQuoteUnderranksJBTest is JuiceboxHookTest {
    FeelessSellPreviewTerminal internal feelessTerminal;

    function test_feelessSellQuoteRoutesThroughBetterJBsellPath() public {
        uint256 amountIn = 1 ether;
        uint256 v4Estimate = hook.estimateUniswapOutput(key.toId(), key, amountIn, true);
        uint256 liveCashOutAmount = v4Estimate + (v4Estimate / 100);

        feelessTerminal = new FeelessSellPreviewTerminal(
            liveCashOutAmount, IJBFeelessAddresses(address(new FeelessRegistry(address(hook))))
        );
        mockJBDirectory.setMockTerminal(address(feelessTerminal));
        token0.approve(address(jbSwapRouter), amountIn);

        uint256 feeAwareQuote =
            hook.calculateExpectedOutputFromSelling(123, amountIn, address(token1), IJBTerminal(address(feelessTerminal)));
        assertEq(feeAwareQuote, liveCashOutAmount, "feeless quote should not deduct the terminal fee");
        assertGt(liveCashOutAmount, v4Estimate, "live JB sell path should still beat V4");

        uint256 balanceBefore = token1.balanceOf(address(this));

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

        uint256 received = token1.balanceOf(address(this)) - balanceBefore;

        assertEq(feelessTerminal.lastProjectId(), 123, "router should execute the better JB sell path");
        assertEq(received, liveCashOutAmount, "JB path should settle the full feeless cash-out amount");
    }
}
