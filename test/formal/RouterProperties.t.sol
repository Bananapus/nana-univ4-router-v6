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

    /// @notice Mirrors the eligibility + tie-break + better-than-V4 decision in `_beforeSwap` (src 795-810).
    /// @dev `*Available` collapses the `address != 0 && code.length > 0` precondition into a single bool because
    /// code-length is not part of the arithmetic decision being verified.
    function _decide(
        bool buyAvailable,
        bool sellAvailable,
        uint256 buyOut,
        uint256 sellOut,
        uint256 v4Out
    )
        internal
        pure
        returns (bool routeViaBuySide, bool routeViaSellSide, bool juiceboxBetterThanV4, uint256 juiceboxExpectedOutput)
    {
        bool buySideEligible = buyAvailable && buyOut > 0 && buyOut <= MAX_V4_DELTA;
        bool sellSideEligible = sellAvailable && sellOut > 0 && sellOut <= MAX_V4_DELTA;
        routeViaBuySide = buySideEligible && (!sellSideEligible || buyOut >= sellOut);
        routeViaSellSide = sellSideEligible && (!buySideEligible || sellOut > buyOut);
        juiceboxExpectedOutput = routeViaSellSide ? sellOut : buyOut;
        juiceboxBetterThanV4 = (routeViaBuySide || routeViaSellSide) && juiceboxExpectedOutput > v4Out;
    }

    /// @notice Mirrors the `routeMinimum` raise applied once a JB route wins (src 825-838).
    function _routeMinimum(
        bool routeViaSellSide,
        bool routeViaBuySide,
        uint256 amountOutMin,
        uint256 juiceboxExpectedOutput,
        uint256 v4Out
    )
        internal
        pure
        returns (uint256 routeMinimum)
    {
        routeMinimum = amountOutMin;
        if (routeViaSellSide && juiceboxExpectedOutput > routeMinimum) {
            routeMinimum = juiceboxExpectedOutput;
        } else if (routeViaBuySide && v4Out + 1 > routeMinimum) {
            routeMinimum = v4Out + 1;
        }
    }

    /// @notice Mirrors `_calculateTokensWithCurrency` (src 868-891).
    function _calculateTokensWithCurrency(
        uint256 tokensPerBaseCurrency,
        uint256 paymentAmount,
        uint8 paymentTokenDecimals,
        uint256 baseCurrencyPerPaymentToken
    )
        internal
        pure
        returns (uint256 expectedTokens)
    {
        uint256 paymentAmount18 =
            paymentTokenDecimals == 18 ? paymentAmount : (paymentAmount * 1e18) / (10 ** paymentTokenDecimals);

        if (baseCurrencyPerPaymentToken == 1e18) {
            expectedTokens = FullMath.mulDiv({a: tokensPerBaseCurrency, b: paymentAmount18, denominator: 1e18});
        } else {
            uint256 intermediate = FullMath.mulDiv({a: tokensPerBaseCurrency, b: paymentAmount18, denominator: 1e18});
            expectedTokens = FullMath.mulDiv({a: intermediate, b: baseCurrencyPerPaymentToken, denominator: 1e18});
        }
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
    // -- Property 2: route decision is mutually-exclusive + best-exec -- //
    //*********************************************************************//

    function _prop_routeDecisionMutex(
        bool buyAvailable,
        bool sellAvailable,
        uint256 buyOut,
        uint256 sellOut,
        uint256 v4Out
    )
        internal
        pure
    {
        (bool routeViaBuySide, bool routeViaSellSide, bool jbBetter, uint256 jbOut) =
            _decide(buyAvailable, sellAvailable, buyOut, sellOut, v4Out);

        // D.13 tie-break determinism: never both sides at once.
        assert(!(routeViaBuySide && routeViaSellSide));

        // A JB route is only "better than V4" if exactly one side was selected.
        if (jbBetter) {
            assert(routeViaBuySide || routeViaSellSide);
            // A.1 best-execution floor: the winning JB quote strictly beats the V4 quote.
            assert(jbOut > v4Out);
            // The selected output is the chosen side's quote.
            assert(jbOut == (routeViaSellSide ? sellOut : buyOut));
            // Selected side is eligible: positive and within V4 delta capacity (A.1 / A.3).
            assert(jbOut > 0 && jbOut <= MAX_V4_DELTA);
        }

        // Ineligible (zero / over-cap / unavailable) sides can never be selected (A.1, MAX_V4_DELTA gate).
        if (!buyAvailable || buyOut == 0 || buyOut > MAX_V4_DELTA) assert(!routeViaBuySide);
        if (!sellAvailable || sellOut == 0 || sellOut > MAX_V4_DELTA) assert(!routeViaSellSide);
    }

    function check_routeDecisionMutex(
        bool buyAvailable,
        bool sellAvailable,
        uint256 buyOut,
        uint256 sellOut,
        uint256 v4Out
    )
        public
        pure
    {
        _prop_routeDecisionMutex(buyAvailable, sellAvailable, buyOut, sellOut, v4Out);
    }

    function testFuzz_routeDecisionMutex(
        bool buyAvailable,
        bool sellAvailable,
        uint256 buyOut,
        uint256 sellOut,
        uint256 v4Out
    )
        public
        pure
    {
        _prop_routeDecisionMutex(buyAvailable, sellAvailable, buyOut, sellOut, v4Out);
    }

    //*********************************************************************//
    // -- Property 3: tie favors buy side (D.13) ------------------------ //
    //*********************************************************************//

    function _prop_tieFavorsBuySide(uint256 quote, uint256 v4Out) internal pure {
        // Both sides available with the SAME positive eligible quote => buy side must win the tie.
        vm.assume(quote > 0 && quote <= MAX_V4_DELTA);
        (bool routeViaBuySide, bool routeViaSellSide,,) = _decide(true, true, quote, quote, v4Out);
        assert(routeViaBuySide);
        assert(!routeViaSellSide);
    }

    function check_tieFavorsBuySide(uint256 quote, uint256 v4Out) public pure {
        // Bound the symbolic domain so the eligibility precondition is non-vacuous.
        if (quote == 0 || quote > MAX_V4_DELTA) return;
        (bool routeViaBuySide, bool routeViaSellSide,,) = _decide(true, true, quote, quote, v4Out);
        assert(routeViaBuySide);
        assert(!routeViaSellSide);
    }

    function testFuzz_tieFavorsBuySide(uint256 quote, uint256 v4Out) public pure {
        _prop_tieFavorsBuySide(quote, v4Out);
    }

    //*********************************************************************//
    // -- Property 4: routeMinimum never drops below the user floor ----- //
    //*********************************************************************//

    function _prop_routeMinimumFloor(
        bool routeViaSellSide,
        bool routeViaBuySide,
        uint256 amountOutMin,
        uint256 jbOut,
        uint256 v4Out
    )
        internal
        pure
    {
        // Only one JB side can be active, matching `_beforeSwap`.
        vm.assume(!(routeViaSellSide && routeViaBuySide));
        // Constrain the eligible domain so `v4Out + 1` cannot overflow (eligible quotes <= MAX_V4_DELTA).
        vm.assume(v4Out < type(uint256).max);

        uint256 routeMinimum = _routeMinimum(routeViaSellSide, routeViaBuySide, amountOutMin, jbOut, v4Out);

        // Cross-cutting invariant D.1 / A.1: the enforced floor is never weaker than the user's amountOutMin.
        assert(routeMinimum >= amountOutMin);

        // Sell route raises the floor to the previewed reclaim when that exceeds amountOutMin (A.1 src 826-832).
        if (routeViaSellSide && jbOut > amountOutMin) assert(routeMinimum == jbOut);
        // Buy route raises the floor to strictly-beat-V4 when that exceeds amountOutMin (A.1 src 833-837).
        if (routeViaBuySide && !routeViaSellSide && v4Out + 1 > amountOutMin) assert(routeMinimum == v4Out + 1);
    }

    function check_routeMinimumFloor(
        bool routeViaSellSide,
        bool routeViaBuySide,
        uint256 amountOutMin,
        uint256 jbOut,
        uint256 v4Out
    )
        public
        pure
    {
        if (routeViaSellSide && routeViaBuySide) return;
        if (v4Out == type(uint256).max) return;

        uint256 routeMinimum = _routeMinimum(routeViaSellSide, routeViaBuySide, amountOutMin, jbOut, v4Out);
        assert(routeMinimum >= amountOutMin);
        if (routeViaSellSide && jbOut > amountOutMin) assert(routeMinimum == jbOut);
        if (routeViaBuySide && !routeViaSellSide && v4Out + 1 > amountOutMin) assert(routeMinimum == v4Out + 1);
    }

    function testFuzz_routeMinimumFloor(
        bool routeViaSellSide,
        bool routeViaBuySide,
        uint256 amountOutMin,
        uint256 jbOut,
        uint256 v4Out
    )
        public
        pure
    {
        _prop_routeMinimumFloor(routeViaSellSide, routeViaBuySide, amountOutMin, jbOut, v4Out);
    }

    //*********************************************************************//
    // -- Property 5: zero-tax net fee math (gross - gross/40 capped) --- //
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
    // -- Property 6: positive-tax sell net = gross - standardFee ------- //
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
    // -- Property 7: TWAP mean-tick rounds toward negative infinity ---- //
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
    // -- Property 8: createSwapDelta MAX_V4_DELTA gate (fuzz only) ----- //
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
    // -- Property 9: decimal normalization (fuzz only, mulDiv-heavy) --- //
    //*********************************************************************//

    function testFuzz_calculateTokens18DecimalIsExact(uint256 weight, uint256 paymentAmount) public pure {
        // 18-decimal payment with 1:1 conversion => tokens == weight * amount / 1e18 (no decimal scaling).
        weight = bound(weight, 0, 1e30);
        paymentAmount = bound(paymentAmount, 0, 1e30);
        uint256 got = _calculateTokensWithCurrency(weight, paymentAmount, 18, 1e18);
        uint256 expected = FullMath.mulDiv(weight, paymentAmount, 1e18);
        assertEq(got, expected, "18-dec path must equal weight*amount/1e18");
    }

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

    //*********************************************************************//
    // -- Property 10: estimateUniswapOutput fee-then-ratio (fuzz only)- //
    //*********************************************************************//

    /// @notice Mirrors the small-sqrt-price branch of `estimateUniswapOutput` (src 457-463): fee is applied to the
    /// input BEFORE the price-ratio conversion. Applying a larger fee can never increase the estimate (monotone).
    /// @dev `external` so the fuzzer can probe overflow via try/catch: production's `estimateUniswapOutput` would
    /// likewise revert on an overflowing `mulDiv`, and monotonicity is only a claim about the non-reverting domain.
    function estimateSmallPrice(
        uint160 sqrtPriceX96,
        uint256 amountIn,
        uint24 swapFee,
        bool zeroForOne
    )
        external
        pure
        returns (uint256 estimatedOut)
    {
        uint256 PIPS = 1_000_000;
        uint256 amountInAfterFee = amountIn;
        if (swapFee > 0) {
            amountInAfterFee = FullMath.mulDiv(amountIn, PIPS - swapFee, PIPS);
        }
        uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
        if (zeroForOne) {
            estimatedOut = FullMath.mulDiv(amountInAfterFee, ratioX192, 1 << 192);
        } else {
            estimatedOut = FullMath.mulDiv(amountInAfterFee, 1 << 192, ratioX192);
        }
    }

    function testFuzz_estimateOutputFeeMonotone(
        uint128 sqrtPriceX96,
        uint256 amountIn,
        uint24 feeLow,
        uint24 feeHigh,
        bool zeroForOne
    )
        public
        view
    {
        // Keep sqrtPrice in the small branch (<= uint128.max) and non-zero so the inverse direction is defined.
        vm.assume(sqrtPriceX96 > 0);
        feeLow = uint24(bound(feeLow, 0, 999_999));
        feeHigh = uint24(bound(feeHigh, feeLow, 999_999));
        amountIn = bound(amountIn, 0, 1e30);

        // The low-fee leg produces the LARGEST `amountInAfterFee`, so if any leg overflows it is this one. When it
        // does, production's estimator would also revert (it has no try/catch around this mulDiv), so the
        // monotonicity claim is vacuous on that input — skip it. When the low-fee leg succeeds, the high-fee leg
        // has a smaller-or-equal numerator and therefore cannot overflow.
        try this.estimateSmallPrice(sqrtPriceX96, amountIn, feeLow, zeroForOne) returns (uint256 outLow) {
            uint256 outHigh = this.estimateSmallPrice(sqrtPriceX96, amountIn, feeHigh, zeroForOne);
            // A higher swap fee can never yield more output (fee applied to input before conversion, A.4 src 425-451).
            assertLe(outHigh, outLow, "higher fee must not increase estimated output");
        } catch {
            // Overflowing domain: production also reverts here; nothing to assert.
        }
    }
}
