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

contract MetadataOnlySellPreviewTerminal {
    uint256 internal immutable _liveCashOutAmount;

    uint256 public lastProjectId;

    constructor(uint256 liveCashOutAmount) {
        _liveCashOutAmount = liveCashOutAmount;
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
        returns (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256, bytes memory)
    {
        beneficiaryTokenCount = 0;
        return (ruleset, beneficiaryTokenCount, 0, bytes(""));
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
            uint256 hookAdjustedReclaimAmount,
            JBCashOutHookSpecification[] memory specs
        )
    {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 66,
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
                _liveCashOutAmount
            )
        });

        reclaimAmount = 0;
        hookAdjustedReclaimAmount = 0;
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
        returns (uint256)
    {
        require(_liveCashOutAmount >= minTokensReclaimed, "MetadataOnlySellPreviewTerminal: insufficient output");

        lastProjectId = projectId;
        MockERC20(tokenToReclaim).mint(beneficiary, _liveCashOutAmount);
        return _liveCashOutAmount;
    }
}

contract BuybackCashOutMetadataIgnoredTest is JuiceboxHookTest {
    MetadataOnlySellPreviewTerminal internal metadataOnlySellTerminal;

    function _installMetadataOnlySellTerminal(uint256 liveCashOutAmount) internal {
        metadataOnlySellTerminal = new MetadataOnlySellPreviewTerminal(liveCashOutAmount);
        mockJBDirectory.setMockTerminal(address(metadataOnlySellTerminal));
    }

    function test_metadataOnlySellPreviewRoutesThroughBetterJBPath() public {
        uint256 amountIn = 1 ether;
        uint256 liveCashOutAmount = 2 ether;
        _installMetadataOnlySellTerminal(liveCashOutAmount);
        token0.approve(address(jbSwapRouter), amountIn);

        uint256 previewQuote = hook.calculateExpectedOutputFromSelling(
            123, amountIn, address(token1), IJBTerminal(address(metadataOnlySellTerminal))
        );
        // The preview now always deducts the 2.5% protocol fee: 2 ether * 975/1000 = 1.95 ether.
        uint256 expectedPreview = liveCashOutAmount - liveCashOutAmount * 25 / 1000;
        assertEq(previewQuote, expectedPreview, "hook should surface metadata-only sell preview (after fee)");

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

        assertEq(metadataOnlySellTerminal.lastProjectId(), 123, "router should execute the JB sell path");
        assertEq(received, liveCashOutAmount, "JB path should settle the metadata-backed output");
    }

    function test_metadataOnlySellPreviewCanSatisfyMinOutputOrder() public {
        uint256 amountIn = 1 ether;
        uint256 amountOutMin = 1.5 ether;
        _installMetadataOnlySellTerminal(2 ether);
        token0.approve(address(jbSwapRouter), amountIn);

        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            amountOutMin
        );

        assertEq(metadataOnlySellTerminal.lastProjectId(), 123, "minimum order should route through the JB path");
    }

    function test_directJBCashOutCouldHaveSatisfiedTheSameMinimum() public {
        uint256 balanceBefore = token1.balanceOf(address(this));
        _installMetadataOnlySellTerminal(2 ether);

        uint256 reclaimed = metadataOnlySellTerminal.cashOutTokensOf(
            address(this), 123, 1 ether, address(token1), 1.5 ether, payable(address(this)), bytes("")
        );

        assertEq(reclaimed, 2 ether, "terminal itself can satisfy the minimum");
        assertEq(token1.balanceOf(address(this)) - balanceBefore, 2 ether, "direct JB cash-out would have succeeded");
    }
}
