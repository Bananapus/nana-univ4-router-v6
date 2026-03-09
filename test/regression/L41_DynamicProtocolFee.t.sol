// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

/// @notice Dynamic protocol fee read from terminal.
/// @dev The old code hardcoded `grossReclaim - mulDiv(grossReclaim, 25, 1000)`.
/// The fix reads FEE() from the terminal and uses JBConstants.MAX_FEE as the
/// denominator, so the estimate stays correct if the fee ever changes.
contract L41_DynamicProtocolFee is Test {
    /// @notice Replicate the fixed fee deduction logic.
    function _deductFeeDynamic(uint256 grossReclaim, uint256 fee) internal pure returns (uint256) {
        return grossReclaim - FullMath.mulDiv(grossReclaim, fee, JBConstants.MAX_FEE);
    }

    /// @notice Replicate the OLD hardcoded fee deduction.
    function _deductFeeOld(uint256 grossReclaim) internal pure returns (uint256) {
        return grossReclaim - FullMath.mulDiv(grossReclaim, 25, 1000);
    }

    /// @notice At the current fee (25/1000), both methods should agree.
    function test_currentFee_matchesOldBehavior() public pure {
        uint256 grossReclaim = 10 ether;
        uint256 currentFee = 25; // 2.5%

        uint256 dynamicResult = _deductFeeDynamic(grossReclaim, currentFee);
        uint256 oldResult = _deductFeeOld(grossReclaim);

        assertEq(dynamicResult, oldResult, "Dynamic fee should match old hardcoded result at fee=25");
        // 10 ether - 2.5% = 9.75 ether
        assertEq(dynamicResult, 9.75 ether, "Net reclaim should be 9.75 ether");
    }

    /// @notice If the fee changes to 50 (5%), the dynamic method adapts but the old one would not.
    function test_changedFee_dynamicAdapts() public pure {
        uint256 grossReclaim = 10 ether;
        uint256 newFee = 50; // 5%

        uint256 dynamicResult = _deductFeeDynamic(grossReclaim, newFee);
        uint256 oldResult = _deductFeeOld(grossReclaim);

        // Dynamic: 10 ether - 5% = 9.5 ether
        assertEq(dynamicResult, 9.5 ether, "Dynamic should deduct 5% fee");
        // Old: still deducts 2.5% = 9.75 ether (WRONG for new fee)
        assertEq(oldResult, 9.75 ether, "Old code ignores fee change");
        assertTrue(dynamicResult < oldResult, "Dynamic should deduct more when fee increases");
    }

    /// @notice Zero fee should return full gross reclaim.
    function test_zeroFee_returnsFullReclaim() public pure {
        uint256 grossReclaim = 10 ether;
        uint256 result = _deductFeeDynamic(grossReclaim, 0);
        assertEq(result, grossReclaim, "Zero fee should return full reclaim");
    }

    /// @notice MAX_FEE should be 1000 (Juicebox constant).
    function test_maxFeeConstant() public pure {
        assertEq(JBConstants.MAX_FEE, 1000, "MAX_FEE should be 1000");
    }
}
