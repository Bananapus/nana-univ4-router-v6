// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Functional-correctness harnesses for the pure / view decision logic inside `JBUniswapV4Hook`.
/// @dev The hook's state-mutating surface is PoolManager-only and exercised by the repo's fork + invariant suites.
/// This file isolates the deterministic predicates and arithmetic that drive routing and pricing so a solver
/// (Halmos) or fuzzer (Foundry) can prove them in isolation, matching the dual-implementation house convention
/// in `nana-core-v6/test/formal/FeeProperties.t.sol`: every property gets a `check_<name>` (symbolic) and a
/// `testFuzz_<name>` (fuzz) twin. Each property re-implements the EXACT production expression copied from
/// `src/JBUniswapV4Hook.sol`; a divergence is a functional-correctness finding.
contract RouterProperties is Test {
    //*********************************************************************//
    // ---------------------------- constants ---------------------------- //
    //*********************************************************************//

    /// @dev Mirror of `JBUniswapV4Hook.JB_NATIVE_TOKEN`.
    address internal constant JB_NATIVE_TOKEN = address(0x000000000000000000000000000000000000EEEe);
    /// @dev Mirror of `JBUniswapV4Hook.UNISWAP_NATIVE_ETH`.
    address internal constant UNISWAP_NATIVE_ETH = address(0);
    /// @dev Mirror of `JBUniswapV4Hook.MAX_V4_DELTA = uint256(uint128(type(int128).max))`.
    uint256 internal constant MAX_V4_DELTA = uint256(uint128(type(int128).max));

    //*********************************************************************//
    // ----------------- production-expression mirrors ------------------- //
    //*********************************************************************//

    /// @notice Mirrors `_normalizeToken` (src 1058-1060).
    function _normalizeToken(address token) internal pure returns (address) {
        return token == UNISWAP_NATIVE_ETH ? JB_NATIVE_TOKEN : token;
    }

    /// @notice Mirrors the arithmetic-mean-tick rounding in `_observeTWAP` (src 1102-1108).
    function _meanTick(int56 tickCumulativeDelta, uint32 secondsAgo) internal pure returns (int24 arithmeticMeanTick) {
        // forge-lint: disable-next-line(unsafe-typecast)
        arithmeticMeanTick = int24(tickCumulativeDelta / int56(uint56(secondsAgo)));
        if (tickCumulativeDelta < 0 && (tickCumulativeDelta % int56(uint56(secondsAgo)) != 0)) {
            arithmeticMeanTick--;
        }
    }

    //*********************************************************************//
    // -- Property 1: native-ETH normalization is exact and idempotent -- //
    //*********************************************************************//

    function _prop_normalizeToken(address token) internal pure {
        address normalized = _normalizeToken(token);
        // Postcondition A.5: Uniswap native (address(0)) -> JB native sentinel; everything else unchanged.
        if (token == UNISWAP_NATIVE_ETH) {
            assert(normalized == JB_NATIVE_TOKEN);
        } else {
            assert(normalized == token);
        }
        // Idempotence: the sentinel never re-maps and a second pass is stable.
        assert(_normalizeToken(normalized) == normalized);
        // The normalized side never collapses to address(0) — terminal lookups need a real key.
        assert(normalized != UNISWAP_NATIVE_ETH);
    }

    function check_normalizeToken(address token) public pure {
        _prop_normalizeToken(token);
    }

    function testFuzz_normalizeToken(address token) public pure {
        _prop_normalizeToken(token);
    }

    //*********************************************************************//
    // -- Property 2: zero-tax net fee math (gross - gross/40 capped) --- //
    //*********************************************************************//

    /// @notice Mirrors the non-feeless zero-tax branch of `_exactZeroTaxNet` (src 961-969):
    ///         `feeable = min(gross, feeFreeSurplus); net = gross - standardFee(feeable)`.
    /// @dev NOTE on semantics: `feeFreeSurplusOf` is the running tally of surplus the terminal will still charge the
    /// standard fee on (the fee-free *budget that is consumed*), so `feeable = min(gross, feeFreeSurplus)` is the
    /// portion the fee IS applied to. A larger `feeFreeSurplus` therefore charges MORE fee, not less.
    function _exactZeroTaxNonFeeless(uint256 gross, uint256 feeFreeSurplus) internal pure returns (uint256) {
        uint256 feeable = gross < feeFreeSurplus ? gross : feeFreeSurplus;
        return gross - JBFees.standardFeeAmountFrom(feeable);
    }

    function _prop_zeroTaxNet(uint256 gross, uint256 feeFreeSurplus) internal pure {
        uint256 net = _exactZeroTaxNonFeeless(gross, feeFreeSurplus);

        // Conservative-degrade safety: the net quote never exceeds gross (no phantom output).
        assert(net <= gross);
        // The most fee that can ever be charged is the standard 2.5% of the whole gross: net >= gross - gross/40.
        assert(net >= gross - gross / 40);
        // When the feeable budget is empty, no fee applies and the net equals gross.
        if (feeFreeSurplus == 0) assert(net == gross);
        // When the feeable budget covers the whole reclaim, the FULL standard fee applies.
        if (feeFreeSurplus >= gross) assert(net == gross - gross / 40);
    }

    function check_zeroTaxNet(uint256 gross, uint256 feeFreeSurplus) public pure {
        _prop_zeroTaxNet(gross, feeFreeSurplus);
    }

    function testFuzz_zeroTaxNet(uint256 gross, uint256 feeFreeSurplus) public pure {
        _prop_zeroTaxNet(gross, feeFreeSurplus);
    }

    //*********************************************************************//
    // -- Property 3: positive-tax sell net = gross - standardFee ------- //
    //*********************************************************************//

    function _prop_positiveTaxNet(uint256 gross) internal pure {
        // src 287: positive-tax sell quote subtracts the standard fee from the whole gross reclaim.
        uint256 net = gross - JBFees.standardFeeAmountFrom(gross);
        assert(net <= gross);
        // Exactly gross/40 is removed.
        assert(gross - net == gross / 40);
        // Net is always at least 97.5% of gross (39/40).
        assert(net >= gross - gross / 40);
    }

    function check_positiveTaxNet(uint256 gross) public pure {
        _prop_positiveTaxNet(gross);
    }

    function testFuzz_positiveTaxNet(uint256 gross) public pure {
        _prop_positiveTaxNet(gross);
    }

    //*********************************************************************//
    // -- Property 4: TWAP mean-tick rounds toward negative infinity ---- //
    //*********************************************************************//

    function _prop_meanTickRounding(int56 tickCumulativeDelta, uint32 secondsAgo) internal pure {
        vm.assume(secondsAgo > 0);
        // Restrict the delta magnitude so the int24 cast in production is faithful for these inputs
        // (production reaches this only for in-band ticks within +/- MAX_TICK over TWAP_PERIOD).
        vm.assume(tickCumulativeDelta >= -8_388_608 && tickCumulativeDelta <= 8_388_607);

        int24 mean = _meanTick(tickCumulativeDelta, secondsAgo);

        // Floor-division identity: mean == floor(delta / secondsAgo). Verify mean*secondsAgo straddles delta.
        int256 d = int256(tickCumulativeDelta);
        int256 s = int256(uint256(secondsAgo));
        int256 m = int256(mean);
        // floor: m*s <= d < (m+1)*s
        assert(m * s <= d);
        assert(d < (m + 1) * s);
    }

    function check_meanTickRounding(int56 tickCumulativeDelta, uint32 secondsAgo) public pure {
        if (secondsAgo == 0) return;
        if (tickCumulativeDelta < -8_388_608 || tickCumulativeDelta > 8_388_607) return;
        int24 mean = _meanTick(tickCumulativeDelta, secondsAgo);
        int256 d = int256(tickCumulativeDelta);
        int256 s = int256(uint256(secondsAgo));
        int256 m = int256(mean);
        assert(m * s <= d);
        assert(d < (m + 1) * s);
    }

    function testFuzz_meanTickRounding(int56 tickCumulativeDelta, uint32 secondsAgo) public pure {
        _prop_meanTickRounding(tickCumulativeDelta, secondsAgo);
    }

    //*********************************************************************//
    // -- Property 5: createSwapDelta MAX_V4_DELTA gate (fuzz only) ----- //
    //*********************************************************************//

    /// @notice Mirrors `_createSwapDelta`'s overflow guards (src 913-925). An eligible (in-cap) pair must encode
    /// to int128 without truncation; an over-cap value reverts. This is the settlement-domain bound behind A.3.
    function _createSwapDeltaSpecified(uint256 amountIn, uint256 amountOut) internal pure returns (int128, int128) {
        require(amountIn <= MAX_V4_DELTA, "in");
        require(amountOut <= MAX_V4_DELTA, "out");
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 deltaSpecified = int128(uint128(amountIn));
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 deltaUnspecified = -int128(uint128(amountOut));
        return (deltaSpecified, deltaUnspecified);
    }

    function testFuzz_createSwapDeltaRoundTrips(uint256 amountIn, uint256 amountOut) public pure {
        amountIn = bound(amountIn, 0, MAX_V4_DELTA);
        amountOut = bound(amountOut, 0, MAX_V4_DELTA);
        (int128 dSpec, int128 dUnspec) = _createSwapDeltaSpecified(amountIn, amountOut);
        // No truncation: positive specified equals input, negative unspecified equals -output.
        assert(dSpec >= 0);
        assert(uint128(dSpec) == amountIn);
        assert(dUnspec <= 0);
        assert(uint256(uint128(-dUnspec)) == amountOut);
    }

    function testFuzz_createSwapDeltaRevertsAboveCap(uint256 amountOut) public {
        amountOut = bound(amountOut, MAX_V4_DELTA + 1, type(uint256).max);
        vm.expectRevert(bytes("out"));
        this.createSwapDeltaExternal(0, amountOut);
    }

    function createSwapDeltaExternal(uint256 amountIn, uint256 amountOut) external pure returns (int128, int128) {
        return _createSwapDeltaSpecified(amountIn, amountOut);
    }

    //*********************************************************************//
    // -- Property 6: reserved split never exceeds gross (fuzz only) ---- //
    //*********************************************************************//

    function testFuzz_calculateTokensReservedNeverExceedsGross(uint256 estimated, uint16 reservedPercent) public pure {
        // The reserved-percent reduction (src 376-384) never increases the payer's token count.
        reservedPercent = uint16(bound(reservedPercent, 0, JBConstants.MAX_RESERVED_PERCENT));
        estimated = bound(estimated, 0, type(uint128).max);

        uint256 afterReserved = reservedPercent > 0
            ? FullMath.mulDiv(
                estimated,
                uint256(JBConstants.MAX_RESERVED_PERCENT - reservedPercent),
                uint256(JBConstants.MAX_RESERVED_PERCENT)
            )
            : estimated;

        assertLe(afterReserved, estimated, "reserved reduction cannot inflate payer tokens");
        if (reservedPercent == 0) assertEq(afterReserved, estimated);
        if (reservedPercent == JBConstants.MAX_RESERVED_PERCENT) assertEq(afterReserved, 0);
    }
}
