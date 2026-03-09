// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "../mock/MockERC20.sol";

/// @notice forceApprove instead of safeIncreaseAllowance.
/// @dev safeIncreaseAllowance adds to the existing allowance. If a previous terminal
/// call reverts after partial token consumption, leftover allowance accumulates on the
/// next routing attempt. forceApprove sets an exact allowance regardless of the current
/// value, preventing allowance accumulation.
contract L43_ForceApprove is Test {
    using SafeERC20 for IERC20;

    MockERC20 token;
    address spender;

    function setUp() public {
        token = new MockERC20("Test", "TST");
        spender = makeAddr("spender");
    }

    /// @notice Demonstrate that safeIncreaseAllowance accumulates if not fully consumed.
    function test_safeIncreaseAllowance_accumulates() public {
        // First approval: 100
        IERC20(address(token)).safeIncreaseAllowance(spender, 100);
        assertEq(token.allowance(address(this), spender), 100);

        // Simulate: terminal reverts, no tokens consumed. Allowance stays at 100.
        // Second routing attempt: safeIncreaseAllowance adds another 100.
        IERC20(address(token)).safeIncreaseAllowance(spender, 100);
        assertEq(token.allowance(address(this), spender), 200, "safeIncreaseAllowance accumulates to 200");
    }

    /// @notice Demonstrate that forceApprove sets exact allowance, no accumulation.
    function test_forceApprove_setsExact() public {
        // First approval: 100
        IERC20(address(token)).forceApprove(spender, 100);
        assertEq(token.allowance(address(this), spender), 100);

        // Simulate: terminal reverts, no tokens consumed. Allowance stays at 100.
        // Second routing attempt: forceApprove resets to exactly 100, not 200.
        IERC20(address(token)).forceApprove(spender, 100);
        assertEq(token.allowance(address(this), spender), 100, "forceApprove resets to exact 100");
    }

    /// @notice After partial consumption, forceApprove resets; safeIncreaseAllowance accumulates.
    function test_partialConsumption_forceApproveResets() public {
        // Approve 100
        IERC20(address(token)).forceApprove(spender, 100);
        assertEq(token.allowance(address(this), spender), 100);

        // Simulate partial consumption: spender uses 30, leaving 70.
        token.mint(address(this), 100);
        vm.prank(spender);
        token.transferFrom(address(this), spender, 30);
        assertEq(token.allowance(address(this), spender), 70, "70 allowance remaining after partial use");

        // Next routing: forceApprove sets exactly 100, not 170.
        IERC20(address(token)).forceApprove(spender, 100);
        assertEq(token.allowance(address(this), spender), 100, "forceApprove resets to exact value after partial use");
    }
}
