// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";

import {JuiceboxHookTest} from "../JBUniswapV4Hook.t.sol";
import {MockERC20} from "../mock/MockERC20.sol";

contract FeeFreeSurplusLikeTerminal {
    uint256 public previewReclaim;
    uint256 public actualReclaim;
    uint256 public lastProjectId;
    address public projectToken;

    function setReclaimAmounts(uint256 previewReclaim_, uint256 actualReclaim_) external {
        previewReclaim = previewReclaim_;
        actualReclaim = actualReclaim_;
    }

    function setProjectToken(address projectToken_) external {
        projectToken = projectToken_;
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
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: 1,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });

        reclaimAmount = previewReclaim;
        cashOutTaxRate = 0;
        specs = new JBCashOutHookSpecification[](0);
    }

    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata,
        uint256 /* referralProjectId */
    )
        external
        returns (uint256)
    {
        require(actualReclaim >= minTokensReclaimed, "min reclaim");
        lastProjectId = projectId;
        if (projectToken != address(0) && cashOutCount != 0) {
            MockERC20(projectToken).burn(holder, cashOutCount);
        }
        MockERC20(tokenToReclaim).mint(beneficiary, actualReclaim);
        return actualReclaim;
    }
}

contract RegressionFeeFreeSurplusCashoutMisrouteTest is JuiceboxHookTest {
    FeeFreeSurplusLikeTerminal internal feeFreeTerminal;

    function test_zeroTaxFeeFreeSurplusRouteSettlesActualCashOutOutput() public {
        feeFreeTerminal = new FeeFreeSurplusLikeTerminal();
        feeFreeTerminal.setProjectToken(address(token0));
        mockJBDirectory.setMockTerminal(address(feeFreeTerminal));

        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(jbSwapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        uint256 amountIn = 1 ether;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // The regression amount is a small constant and fits safely in int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        feeFreeTerminal.setReclaimAmounts({previewReclaim_: 0, actualReclaim_: 0});

        uint256 snapshot = vm.snapshotState();
        uint256 v4BalanceBefore = token1.balanceOf(address(this));
        jbSwapRouter.swap(key, params, 0);
        uint256 v4Received = token1.balanceOf(address(this)) - v4BalanceBefore;
        vm.revertToState(snapshot);

        // Keep the executable cash-out above V4. The router should compare the zero-tax preview directly without
        // applying the standard fee discount.
        uint256 zeroTaxReclaim = 1.95 ether;
        feeFreeTerminal.setReclaimAmounts({previewReclaim_: zeroTaxReclaim, actualReclaim_: zeroTaxReclaim});

        uint256 jbBalanceBefore = token1.balanceOf(address(this));
        jbSwapRouter.swap(key, params, 0);
        uint256 jbReceived = token1.balanceOf(address(this)) - jbBalanceBefore;

        assertEq(feeFreeTerminal.lastProjectId(), 123, "preview made the hook choose JB cash-out");
        assertEq(jbReceived, zeroTaxReclaim, "settlement should use the actual token balance received");
        assertGt(jbReceived, v4Received, "JB route is genuinely better than V4");
    }

    function test_sellRouteUsesV4BeatFloorNotGrossPreview() public {
        feeFreeTerminal = new FeeFreeSurplusLikeTerminal();
        feeFreeTerminal.setProjectToken(address(token0));
        mockJBDirectory.setMockTerminal(address(feeFreeTerminal));

        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(jbSwapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        uint256 amountIn = 1 ether;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // The regression amount is a small constant and fits safely in int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 snapshot = vm.snapshotState();
        uint256 v4BalanceBefore = token1.balanceOf(address(this));
        feeFreeTerminal.setReclaimAmounts({previewReclaim_: 0, actualReclaim_: 0});
        jbSwapRouter.swap(key, params, 0);
        uint256 v4Received = token1.balanceOf(address(this)) - v4BalanceBefore;
        vm.revertToState(snapshot);

        uint256 grossPreview = 1.95 ether;
        uint256 netCashOut = 1.9 ether;
        assertGt(netCashOut, v4Received, "net JB cash-out is still better than V4");
        feeFreeTerminal.setReclaimAmounts({previewReclaim_: grossPreview, actualReclaim_: netCashOut});

        uint256 jbBalanceBefore = token1.balanceOf(address(this));
        jbSwapRouter.swap(key, params, 0);
        uint256 jbReceived = token1.balanceOf(address(this)) - jbBalanceBefore;

        assertEq(feeFreeTerminal.lastProjectId(), 123, "preview made the hook choose JB cash-out");
        assertEq(jbReceived, netCashOut, "settlement should accept the better executable net cash-out");
    }
}
