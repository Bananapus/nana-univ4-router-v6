// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Oracle} from "../../src/libraries/Oracle.sol";

/// @notice Halmos proofs for the Oracle library's bounded storage transitions and accumulator math.
/// @dev The production hook reaches these paths through Uniswap callbacks. This harness calls the library directly so
/// the solver can prove the exact circular-buffer behavior without modeling the full pool manager.
contract OracleHalmos {
    using Oracle for Oracle.Observation[65_535];

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Storage-backed observations used by the library under test.
    Oracle.Observation[65_535] internal _observations;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Wrapper used to prove `grow()` rejects an uninitialized observation array.
    /// @param next The requested next cardinality.
    /// @return cardinalityNext The returned next cardinality if the call unexpectedly succeeds.
    function growWithZeroCurrent(uint16 next) external returns (uint16 cardinalityNext) {
        return _observations.grow({current: 0, next: next});
    }

    /// @notice Wrapper used to prove requests older than the oldest observation revert.
    /// @param start The timestamp of the oldest and only stored observation.
    /// @param elapsed The elapsed time between `start` and the current observation time.
    /// @return tickCumulatives The cumulative ticks returned if the call unexpectedly succeeds.
    /// @return secondsPerLiquidityCumulativeX128s The cumulative seconds per liquidity returned if the call succeeds.
    function observeBeforeOldest(
        uint32 start,
        uint16 elapsed
    )
        external
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        _observations.initialize({time: start});

        uint32[] memory secondsAgos = new uint32[](1);
        // Ask for one second before the only stored observation. This covers both normal and wrapped uint32 time.
        secondsAgos[0] = uint32(elapsed) + 1;

        return _observations.observe({
            time: _timeAfter({start: start, delta: elapsed}),
            secondsAgos: secondsAgos,
            tick: 0,
            index: 0,
            liquidity: 1,
            cardinality: 1
        });
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Proves `grow()` no-ops when the requested next cardinality is not larger than current.
    /// @param current The current next cardinality.
    /// @param next The requested next cardinality.
    function check_growNoopsWhenNextIsNotLarger(uint8 current, uint8 next) public {
        if (current == 0 || next > current) return;

        assert(_observations.grow({current: current, next: next}) == current);
    }

    /// @notice Proves `grow()` rejects zero current cardinality, matching the uninitialized-pool guard.
    /// @param next The requested next cardinality.
    function check_growRejectsZeroCurrent(uint16 next) public {
        try this.growWithZeroCurrent({next: next}) returns (uint16) {
            assert(false);
        } catch {}
    }

    /// @notice Proves `grow()` initializes sentinel timestamps and returns the requested larger cardinality.
    function check_growWritesSentinelSlots() public {
        uint8 current = 1;
        uint8 next = 8;

        assert(_observations.grow({current: current, next: next}) == next);

        _assertGrownSlotIfCovered({slot: 1, current: current, next: next});
        _assertGrownSlotIfCovered({slot: 2, current: current, next: next});
        _assertGrownSlotIfCovered({slot: 3, current: current, next: next});
        _assertGrownSlotIfCovered({slot: 4, current: current, next: next});
        _assertGrownSlotIfCovered({slot: 5, current: current, next: next});
        _assertGrownSlotIfCovered({slot: 6, current: current, next: next});
        _assertGrownSlotIfCovered({slot: 7, current: current, next: next});
    }

    /// @notice Proves initialization writes the first observation and reports a one-slot live buffer.
    /// @param time The initialization timestamp.
    function check_initializeSetsFirstObservation(uint32 time) public {
        (uint16 cardinality, uint16 cardinalityNext) = _observations.initialize({time: time});

        assert(cardinality == 1);
        assert(cardinalityNext == 1);

        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            observationAt(0);

        assert(blockTimestamp == time);
        assert(tickCumulative == 0);
        assert(secondsPerLiquidityCumulativeX128 == 0);
        assert(initialized);
    }

    /// @notice Proves interpolation between two stored observations follows the production formula.
    /// @dev Uses concrete timestamps because the binary-search path is storage-index heavy under symbolic time.
    function check_observeInterpolatesBetweenStoredObservations() public {
        uint32 start = 100;
        uint16 firstDelta = 10;
        uint16 targetDelta = 4;
        int16 tick = -3;
        uint128 liquidity = 7;
        uint32 secondTimestamp = _timeAfter({start: start, delta: firstDelta});

        _observations.initialize({time: start});
        _observations.grow({current: 1, next: 2});
        _observations.write({
            index: 0,
            blockTimestamp: secondTimestamp,
            tick: tick,
            liquidity: liquidity,
            cardinality: 1,
            cardinalityNext: 2
        });

        uint32[] memory secondsAgos = new uint32[](1);
        // Query at `start + targetDelta` while the current oracle time is the second observation.
        secondsAgos[0] = uint32(firstDelta) - uint32(targetDelta);

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = _observations.observe({
            time: secondTimestamp, secondsAgos: secondsAgos, tick: tick, index: 1, liquidity: liquidity, cardinality: 2
        });

        assert(tickCumulatives.length == 1);
        assert(secondsPerLiquidityCumulativeX128s.length == 1);
        assert(tickCumulatives[0] == int56(tick) * int56(uint56(targetDelta)));
        assert(
            secondsPerLiquidityCumulativeX128s[0]
                == uint160(
                    (uint256(_secondsPerLiquidity({delta: firstDelta, liquidity: liquidity})) * targetDelta)
                        / firstDelta
                )
        );
    }

    /// @notice Proves observations older than the oldest stored observation are rejected.
    function check_observePredatesOldestReverts() public {
        uint32 start = 100;
        uint16 elapsed = 10;

        try this.observeBeforeOldest({start: start, elapsed: elapsed}) returns (int56[] memory, uint160[] memory) {
            assert(false);
        } catch {}
    }

    /// @notice Proves `observe(..., secondsAgo=0)` matches a fresh transform from the latest stored observation.
    /// @param start The timestamp of the stored observation.
    /// @param elapsed The elapsed time to the current observation time.
    /// @param tick The current tick used for the counterfactual transform.
    /// @param liquiditySeed The current liquidity used for the counterfactual transform.
    function check_observeZeroSecondsAgoMatchesFreshTransform(
        uint32 start,
        uint16 elapsed,
        int16 tick,
        uint64 liquiditySeed
    )
        public
    {
        uint128 liquidity = uint128(liquiditySeed);
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;

        _observations.initialize({time: start});

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) = _observations.observe({
            time: _timeAfter({start: start, delta: elapsed}),
            secondsAgos: secondsAgos,
            tick: tick,
            index: 0,
            liquidity: liquidity,
            cardinality: 1
        });

        assert(tickCumulatives.length == 1);
        assert(secondsPerLiquidityCumulativeX128s.length == 1);
        assert(tickCumulatives[0] == int56(tick) * int56(uint56(elapsed)));
        assert(secondsPerLiquidityCumulativeX128s[0] == _secondsPerLiquidity({delta: elapsed, liquidity: liquidity}));
    }

    /// @notice Proves a first new-block write advances the buffer, grows cardinality, and stores exact accumulators.
    /// @param start The timestamp of the initial observation.
    /// @param delta The elapsed time before the next observation.
    /// @param tick The active tick at the next observation.
    /// @param liquiditySeed The active liquidity at the next observation.
    function check_writeAdvancesAtCapacityAndAccumulates(
        uint32 start,
        uint16 delta,
        int16 tick,
        uint64 liquiditySeed
    )
        public
    {
        if (delta == 0) return;

        uint128 liquidity = uint128(liquiditySeed);

        _observations.initialize({time: start});
        _observations.grow({current: 1, next: 2});

        (uint16 indexUpdated, uint16 cardinalityUpdated) = _observations.write({
            index: 0,
            blockTimestamp: _timeAfter({start: start, delta: delta}),
            tick: tick,
            liquidity: liquidity,
            cardinality: 1,
            cardinalityNext: 2
        });

        assert(indexUpdated == 1);
        assert(cardinalityUpdated == 2);

        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            observationAt(1);

        assert(blockTimestamp == _timeAfter({start: start, delta: delta}));
        assert(tickCumulative == int56(tick) * int56(uint56(delta)));
        assert(secondsPerLiquidityCumulativeX128 == _secondsPerLiquidity({delta: delta, liquidity: liquidity}));
        assert(initialized);
    }

    /// @notice Proves writes in the same timestamp are no-ops, preserving the one-write-per-block invariant.
    /// @param time The timestamp shared by the existing observation and attempted write.
    /// @param tick The ignored tick for the attempted same-timestamp write.
    /// @param liquidity The ignored liquidity for the attempted same-timestamp write.
    function check_writeSameTimestampNoops(uint32 time, int24 tick, uint128 liquidity) public {
        _observations.initialize({time: time});

        (uint16 indexUpdated, uint16 cardinalityUpdated) = _observations.write({
            index: 0, blockTimestamp: time, tick: tick, liquidity: liquidity, cardinality: 1, cardinalityNext: 2
        });

        assert(indexUpdated == 0);
        assert(cardinalityUpdated == 1);

        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            observationAt(0);

        assert(blockTimestamp == time);
        assert(tickCumulative == 0);
        assert(secondsPerLiquidityCumulativeX128 == 0);
        assert(initialized);
    }

    /// @notice Proves the circular buffer overwrites index 0 after index 1 when cardinality is full.
    /// @param start The timestamp of the initial observation.
    /// @param firstDelta The elapsed time before the first write.
    /// @param secondDelta The elapsed time before the second write.
    /// @param firstTick The active tick at the first write.
    /// @param secondTick The active tick at the second write.
    /// @param firstLiquiditySeed The active liquidity at the first write.
    /// @param secondLiquiditySeed The active liquidity at the second write.
    function check_writeWrapsIndexWhenCardinalityFull(
        uint32 start,
        uint16 firstDelta,
        uint16 secondDelta,
        int16 firstTick,
        int16 secondTick,
        uint64 firstLiquiditySeed,
        uint64 secondLiquiditySeed
    )
        public
    {
        if (firstDelta == 0 || secondDelta == 0) return;

        uint128 firstLiquidity = uint128(firstLiquiditySeed);
        uint128 secondLiquidity = uint128(secondLiquiditySeed);
        uint32 firstTimestamp = _timeAfter({start: start, delta: firstDelta});
        uint32 secondTimestamp = _timeAfter({start: firstTimestamp, delta: secondDelta});

        _observations.initialize({time: start});
        _observations.grow({current: 1, next: 2});
        _observations.write({
            index: 0,
            blockTimestamp: firstTimestamp,
            tick: firstTick,
            liquidity: firstLiquidity,
            cardinality: 1,
            cardinalityNext: 2
        });

        (uint16 indexUpdated, uint16 cardinalityUpdated) = _observations.write({
            index: 1,
            blockTimestamp: secondTimestamp,
            tick: secondTick,
            liquidity: secondLiquidity,
            cardinality: 2,
            cardinalityNext: 2
        });

        assert(indexUpdated == 0);
        assert(cardinalityUpdated == 2);

        (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized) =
            observationAt(0);

        assert(blockTimestamp == secondTimestamp);
        assert(
            tickCumulative
                == int56(firstTick) * int56(uint56(firstDelta)) + int56(secondTick) * int56(uint56(secondDelta))
        );
        assert(
            secondsPerLiquidityCumulativeX128
                == _secondsPerLiquidity({delta: firstDelta, liquidity: firstLiquidity})
                    + _secondsPerLiquidity({delta: secondDelta, liquidity: secondLiquidity})
        );
        assert(initialized);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns a stored observation tuple for assertions without exposing the full storage array.
    /// @param index The observation slot to read.
    /// @return blockTimestamp The observation timestamp.
    /// @return tickCumulative The cumulative tick value.
    /// @return secondsPerLiquidityCumulativeX128 The cumulative seconds per liquidity.
    /// @return initialized Whether the slot has been written as a real observation.
    function observationAt(uint16 index)
        public
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        Oracle.Observation memory observation = _observations[index];
        return (
            observation.blockTimestamp,
            observation.tickCumulative,
            observation.secondsPerLiquidityCumulativeX128,
            observation.initialized
        );
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Checks one concrete slot when symbolic `current` and `next` require `grow()` to warm it.
    /// @dev Halmos cannot read storage at a symbolic slot index, so each candidate slot is asserted separately.
    /// @param slot The concrete storage slot to check.
    /// @param current The current next cardinality passed to `grow()`.
    /// @param next The larger next cardinality returned by `grow()`.
    function _assertGrownSlotIfCovered(uint16 slot, uint8 current, uint8 next) internal view {
        if (slot < current || slot >= next) return;

        (uint32 blockTimestamp,,, bool initialized) = observationAt(slot);

        // `grow()` warms future slots with timestamp 1 but leaves them logically unused until `write()`.
        assert(blockTimestamp == 1);
        assert(!initialized);
    }

    /// @notice Mirrors Oracle's seconds-per-liquidity accumulator for small bounded proof deltas.
    /// @param delta The elapsed time.
    /// @param liquidity The active liquidity, where zero is treated as one by the Oracle.
    /// @return secondsPerLiquidityCumulativeX128 The cumulative seconds per liquidity over `delta`.
    function _secondsPerLiquidity(
        uint16 delta,
        uint128 liquidity
    )
        internal
        pure
        returns (uint160 secondsPerLiquidityCumulativeX128)
    {
        return (uint160(delta) << 128) / (liquidity > 0 ? liquidity : 1);
    }

    /// @notice Adds a bounded delta to a uint32 timestamp with the same wrap behavior as the Oracle.
    /// @param start The starting timestamp.
    /// @param delta The elapsed time.
    /// @return timestamp The wrapped uint32 timestamp after `delta` seconds.
    function _timeAfter(uint32 start, uint16 delta) internal pure returns (uint32 timestamp) {
        unchecked {
            return start + uint32(delta);
        }
    }
}
