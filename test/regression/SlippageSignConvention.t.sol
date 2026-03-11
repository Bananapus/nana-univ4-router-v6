// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title afterSwap slippage check must handle V4's negative output convention
/// @notice In Uniswap V4, output amounts in BalanceDelta are negative (credits to the user).
/// The old code checked `outputAmount > 0` which was never true for actual V4 swaps,
/// meaning the slippage check was effectively disabled.
contract SlippageSignConventionTest is Test {
    /// @notice Replicates the fixed slippage check logic from _afterSwap
    function _checkSlippage(bool zeroForOne, BalanceDelta delta, uint256 amountOutMin) internal pure returns (bool) {
        int128 rawOutput = zeroForOne ? BalanceDeltaLibrary.amount1(delta) : BalanceDeltaLibrary.amount0(delta);

        if (rawOutput != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 outputAmount = rawOutput < 0 ? uint256(int256(-rawOutput)) : uint256(int256(rawOutput));
            if (outputAmount < amountOutMin) {
                return true; // would revert
            }
        }
        return false; // would not revert
    }

    /// @notice The OLD buggy check — output > 0 never true for V4 convention
    function _checkSlippageOld(bool zeroForOne, BalanceDelta delta, uint256 amountOutMin) internal pure returns (bool) {
        int128 outputAmount = zeroForOne ? BalanceDeltaLibrary.amount1(delta) : BalanceDeltaLibrary.amount0(delta);

        // forge-lint: disable-next-line(unsafe-typecast)
        if (outputAmount > 0 && uint256(int256(outputAmount)) < amountOutMin) {
            return true; // would revert
        }
        return false; // would not revert
    }

    /// @notice Regression: negative output (V4 convention) should trigger slippage check
    function test_negativeOutput_triggersSlippageCheck() public pure {
        // V4 convention: zeroForOne swap gives negative amount1 (output credit)
        // User swaps token0 for token1, receives 500 tokens of token1
        BalanceDelta delta = toBalanceDelta(int128(1000), int128(-500));

        // User wants at least 600 tokens — should revert
        bool shouldRevert = _checkSlippage(true, delta, 600);
        assertTrue(shouldRevert, "Slippage check should fire when output (500) < amountOutMin (600)");

        // OLD code would NOT catch this
        bool oldWouldRevert = _checkSlippageOld(true, delta, 600);
        assertFalse(oldWouldRevert, "Old code fails to catch insufficient output with negative amounts");
    }

    /// @notice Regression: slippage check passes when output meets minimum
    function test_negativeOutput_passesWhenSufficient() public pure {
        // V4 convention: output is -1000 (1000 tokens credited to user)
        BalanceDelta delta = toBalanceDelta(int128(500), int128(-1000));

        // User wants at least 800 tokens — should NOT revert (1000 >= 800)
        bool shouldRevert = _checkSlippage(true, delta, 800);
        assertFalse(shouldRevert, "Slippage check should pass when output (1000) >= amountOutMin (800)");
    }

    /// @notice Test !zeroForOne direction (swapping token1 for token0)
    function test_reverseDirection_negativeAmount0() public pure {
        // !zeroForOne: amount0 is negative (output), amount1 is positive (input)
        BalanceDelta delta = toBalanceDelta(int128(-300), int128(1000));

        // User wants at least 500 — should revert (300 < 500)
        bool shouldRevert = _checkSlippage(false, delta, 500);
        assertTrue(shouldRevert, "Reverse direction slippage should fire when output (300) < amountOutMin (500)");
    }

    /// @notice Zero output (routed swap) should not trigger slippage check
    function test_zeroOutput_noSlippageCheck() public pure {
        // For routed swaps (V3/Juicebox), delta is zero — slippage was already checked in _beforeSwap
        BalanceDelta delta = BalanceDeltaLibrary.ZERO_DELTA;

        bool shouldRevert = _checkSlippage(true, delta, 1000);
        assertFalse(shouldRevert, "Zero output should not trigger slippage check (handled by _beforeSwap)");
    }
}
