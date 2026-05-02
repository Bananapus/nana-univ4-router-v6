// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {PreviewPayForRoutingTest} from "./PreviewPayForRouting.t.sol";

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @notice Simulates a buyback-style preview that only surfaces the effective output through hook metadata.
contract MetadataOnlyPreviewTerminal {
    mapping(uint256 => address) public projectTokens;

    uint256 public actualPayAmount = 5000e18;
    uint256 public minimumBeneficiaryTokenCount = 5000e18;
    uint256 public lastPayProjectId;

    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 77,
            basedOnId: 0,
            start: 0,
            duration: 0,
            weight: 0,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: 0
        });

        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] = JBPayHookSpecification({
            hook: IJBPayHook(address(0xB0B)),
            noop: false,
            amount: 0,
            metadata: abi.encode(
                false,
                uint256(0),
                uint256(0),
                false,
                address(0),
                uint256(0),
                uint256(0),
                int24(0),
                uint128(0),
                PoolId.wrap(bytes32(0)),
                minimumBeneficiaryTokenCount,
                uint256(0),
                uint256(0)
            )
        });

        beneficiaryTokenCount = 0;
        reservedCount = 0;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 beneficiaryTokenCount)
    {
        require(actualPayAmount >= minReturnedTokens, "MetadataOnlyPreviewTerminal: insufficient output");

        lastPayProjectId = projectId;
        beneficiaryTokenCount = actualPayAmount;

        if (msg.value == 0 && token.code.length != 0) {
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0)) {
            IMintableToken(projectToken).mint(beneficiary, beneficiaryTokenCount);
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    receive() external payable {}
}

/// @title BuybackMetadataPreviewIgnoredTest
/// @notice The V4 hook ignores buyback-style preview metadata and only reads the raw beneficiary token count.
contract BuybackMetadataPreviewIgnoredTest is PreviewPayForRoutingTest {
    MetadataOnlyPreviewTerminal internal metadataOnlyTerminal;

    function _installMetadataOnlyTerminal() internal {
        metadataOnlyTerminal = new MetadataOnlyPreviewTerminal();
        metadataOnlyTerminal.setProjectToken(123, address(projectToken));
        mockDirectory.setDefaultTerminal(address(metadataOnlyTerminal));
    }

    function test_metadataOnlyPreviewRoutesThroughBetterJBPath() public {
        _installMetadataOnlyTerminal();

        uint256 balanceBefore = projectToken.balanceOf(address(this));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        jbSwapRouter.swap(key, params, 0);

        assertEq(metadataOnlyTerminal.lastPayProjectId(), 123, "hook should route through the metadata-backed JB path");
        assertEq(projectToken.balanceOf(address(this)) - balanceBefore, 5000e18, "user should receive the JB output");
    }

    function test_metadataOnlyPreviewCanSatisfyMinOutputOrder() public {
        _installMetadataOnlyTerminal();

        uint256 amountOutMin = 1000e18;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        jbSwapRouter.swap(key, params, amountOutMin);

        assertEq(metadataOnlyTerminal.lastPayProjectId(), 123, "minimum order should route through the JB terminal");
    }

    function test_directJBPayCouldHaveSatisfiedTheSameMinimum() public {
        _installMetadataOnlyTerminal();

        uint256 balanceBefore = projectToken.balanceOf(address(this));
        paymentToken.approve(address(metadataOnlyTerminal), 1 ether);
        uint256 minted = metadataOnlyTerminal.pay(123, address(paymentToken), 1 ether, address(this), 1000e18, "", "");

        assertEq(minted, 5000e18, "terminal itself can satisfy the minimum");
        assertEq(
            projectToken.balanceOf(address(this)) - balanceBefore,
            5000e18,
            "direct JB path would have delivered the expected output"
        );
    }
}
