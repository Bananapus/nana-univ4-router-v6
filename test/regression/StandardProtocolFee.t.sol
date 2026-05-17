// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {Test} from "forge-std/Test.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";

/// @notice Standard protocol fee deduction used by cash-out previews.
/// @dev Core exposes the standard fee through `JBConstants`, not terminal-specific getters.
contract StandardProtocolFee is Test {
    /// @notice Replicate the current fee deduction logic.
    function _deductStandardFee(uint256 grossReclaim) internal pure returns (uint256) {
        return grossReclaim - JBFees.standardFeeAmountFrom(grossReclaim);
    }

    /// @notice Replicate the OLD hardcoded fee deduction.
    function _deductFeeOld(uint256 grossReclaim) internal pure returns (uint256) {
        return grossReclaim - (grossReclaim / 40);
    }

    /// @notice At the current fee (25/1000), both methods should agree.
    function test_currentFee_matchesOldBehavior() public pure {
        uint256 grossReclaim = 10 ether;

        uint256 standardResult = _deductStandardFee(grossReclaim);
        uint256 oldResult = _deductFeeOld(grossReclaim);

        assertEq(standardResult, oldResult, "Standard fee should match old hardcoded result at fee=25");
        // 10 ether - 2.5% = 9.75 ether
        assertEq(standardResult, 9.75 ether, "Net reclaim should be 9.75 ether");
    }

    /// @notice The standard fee numerator should be 25 (2.5%).
    function test_standardFeeConstant() public pure {
        assertEq(JBConstants.STANDARD_FEE, 25, "STANDARD_FEE should be 25");
    }

    /// @notice MAX_FEE should be 1000 (Juicebox constant).
    function test_maxFeeConstant() public pure {
        assertEq(JBConstants.MAX_FEE, 1000, "MAX_FEE should be 1000");
    }
}
