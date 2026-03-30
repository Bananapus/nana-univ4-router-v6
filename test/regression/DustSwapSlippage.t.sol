// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title Dust swap slippage must be enforced even when output rounds to zero
/// @notice A "dust swap" has rawOutput == 0 (output rounds down to zero) but non-zero delta
/// (input side is non-zero). The old check `rawOutput != 0` would skip slippage validation,
/// letting users lose input tokens without receiving anything. The fix adds
/// `|| BalanceDelta.unwrap(delta) != 0` to catch this case.
contract DustSwapSlippageTest is Test {
    /// @notice Replicates the FIXED slippage check from _afterSwap (PR #84)
    function _checkSlippageFixed(
        bool zeroForOne,
        BalanceDelta delta,
        uint256 amountOutMin
    )
        internal
        pure
        returns (bool shouldRevert)
    {
        int128 rawOutput = zeroForOne ? BalanceDeltaLibrary.amount1(delta) : BalanceDeltaLibrary.amount0(delta);

        // Fixed: also check BalanceDelta.unwrap(delta) != 0 to catch dust swaps
        if (rawOutput != 0 || BalanceDelta.unwrap(delta) != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 outputAmount = rawOutput < 0 ? uint256(int256(-rawOutput)) : uint256(int256(rawOutput));
            if (outputAmount < amountOutMin) {
                return true;
            }
        }
        return false;
    }

    /// @notice Replicates the OLD (vulnerable) slippage check that only checked rawOutput != 0
    function _checkSlippageOld(
        bool zeroForOne,
        BalanceDelta delta,
        uint256 amountOutMin
    )
        internal
        pure
        returns (bool shouldRevert)
    {
        int128 rawOutput = zeroForOne ? BalanceDeltaLibrary.amount1(delta) : BalanceDeltaLibrary.amount0(delta);

        // Old: only checked rawOutput != 0, missing dust swaps
        if (rawOutput != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 outputAmount = rawOutput < 0 ? uint256(int256(-rawOutput)) : uint256(int256(rawOutput));
            if (outputAmount < amountOutMin) {
                return true;
            }
        }
        return false;
    }

    /// @notice Regression: dust swap with zero output but non-zero input should enforce slippage.
    /// User sends tokens (non-zero input) but receives nothing (output rounds to 0).
    /// With amountOutMin > 0, the swap should revert.
    function test_dustSwap_zeroOutput_nonZeroDelta_enforcessSlippage() public pure {
        // Dust swap: user sends 1 token (input = positive), receives 0 (output = 0)
        // zeroForOne: amount0 = positive (input), amount1 = 0 (output rounds to zero)
        BalanceDelta delta = toBalanceDelta(int128(1), int128(0));

        // User specified amountOutMin = 1, but got 0 output — should revert
        bool shouldRevert = _checkSlippageFixed(true, delta, 1);
        assertTrue(shouldRevert, "Dust swap with zero output should enforce slippage when amountOutMin > 0");

        // OLD code would NOT catch this — the regression
        bool oldWouldRevert = _checkSlippageOld(true, delta, 1);
        assertFalse(oldWouldRevert, "Old code silently skips slippage check on dust swaps");
    }

    /// @notice Dust swap with amountOutMin = 0 should pass (user accepts zero output)
    function test_dustSwap_zeroOutput_zeroAmountOutMin_passes() public pure {
        BalanceDelta delta = toBalanceDelta(int128(1), int128(0));

        // amountOutMin = 0 means user accepts any output (including zero)
        // The check in _afterSwap is gated by `if (amountOutMin > 0)`, so this never enters the block.
        // But if it did, 0 >= 0 would pass anyway.
        bool shouldRevert = _checkSlippageFixed(true, delta, 0);
        assertFalse(shouldRevert, "Dust swap with amountOutMin=0 should not revert");
    }

    /// @notice JB-routed swaps (both rawOutput and delta are zero) should still skip the check
    function test_routedSwap_zeroDelta_skipsSlippage() public pure {
        // Juicebox-routed swaps return ZERO_DELTA — slippage was already validated in _beforeSwap
        BalanceDelta delta = BalanceDeltaLibrary.ZERO_DELTA;

        bool shouldRevert = _checkSlippageFixed(true, delta, 1000);
        assertFalse(shouldRevert, "JB-routed swap (zero delta) should skip afterSwap slippage check");
    }

    /// @notice Dust swap in reverse direction (!zeroForOne)
    function test_dustSwap_reverseDirection_enforcessSlippage() public pure {
        // !zeroForOne: amount1 = positive (input), amount0 = 0 (output rounds to zero)
        BalanceDelta delta = toBalanceDelta(int128(0), int128(1));

        bool shouldRevert = _checkSlippageFixed(false, delta, 1);
        assertTrue(shouldRevert, "Reverse dust swap should enforce slippage");

        bool oldWouldRevert = _checkSlippageOld(false, delta, 1);
        assertFalse(oldWouldRevert, "Old code fails on reverse dust swap too");
    }

    /// @notice Normal V4 swap (non-zero output) still works correctly
    function test_normalSwap_nonZeroOutput_stillWorks() public pure {
        // Normal swap: user sends 1000, receives 500
        BalanceDelta delta = toBalanceDelta(int128(1000), int128(-500));

        // 500 >= 400, should pass
        bool shouldRevert = _checkSlippageFixed(true, delta, 400);
        assertFalse(shouldRevert, "Normal swap meeting minimum should pass");

        // 500 < 600, should revert
        shouldRevert = _checkSlippageFixed(true, delta, 600);
        assertTrue(shouldRevert, "Normal swap below minimum should revert");
    }
}
