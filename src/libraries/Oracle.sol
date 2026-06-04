// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Oracle
/// @notice A circular-buffer oracle that stores tick and liquidity snapshots over time, enabling time-weighted average
/// price (TWAP) queries. Each pool maintains its own observation array that grows on demand up to 65,535 slots.
/// @dev Observations are written at most once per block and overwrite the oldest entry when full. The array starts at
/// length 1 and can be expanded by calling `grow()`. Pass 0 seconds to `observe()` to get the current cumulative
/// values.
library Oracle {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when trying to interact with an Oracle of a non-initialized pool
    /// @param cardinality The invalid observation cardinality.
    error Oracle_CardinalityCannotBeZero(uint16 cardinality);

    /// @notice Thrown when trying to observe a price that is older than the oldest recorded price
    /// @param oldestTimestamp Timestamp of the oldest remaining observation
    /// @param targetTimestamp Invalid timestamp targeted to be observed
    error Oracle_TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp);

    //*********************************************************************//
    // ------------------------------ structs ---------------------------- //
    //*********************************************************************//

    /// @notice A single tick and liquidity snapshot recorded at a point in time.
    /// @dev Tightly packed into a single 256-bit slot: 32 + 56 + 160 + 8 = 256.
    /// The `int56 tickCumulative` matches Uniswap V3's width, allowing ~1.4 years at max tick (887272).
    /// @custom:member blockTimestamp The block timestamp of the observation.
    /// @custom:member tickCumulative The tick accumulator, i.e. tick * time elapsed since the pool was first
    /// initialized.
    /// @custom:member secondsPerLiquidityCumulativeX128 The seconds per liquidity, i.e. seconds elapsed /
    /// max(1, liquidity) since the pool was first initialized.
    /// @custom:member initialized Whether the observation is initialized.
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    //*********************************************************************//
    // -------------------------- internal functions -------------------- //
    //*********************************************************************//

    /// @notice Transforms a previous observation into a new observation, given the passage of time and the current tick
    /// and liquidity values.
    /// @dev blockTimestamp _must_ be chronologically equal to or greater than last.blockTimestamp. Safe for 0 or 1
    /// overflows.
    /// @param last The specified observation to be transformed
    /// @param blockTimestamp The timestamp of the new observation
    /// @param tick The active tick at the time of the new observation
    /// @param liquidity The total in-range liquidity at the time of the new observation
    /// @return Observation The newly populated observation
    function transform(
        Observation memory last,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity
    )
        private
        pure
        returns (Observation memory)
    {
        unchecked {
            uint32 delta = blockTimestamp - last.blockTimestamp;
            return Observation({
                blockTimestamp: blockTimestamp,
                // NOTE: int56 overflows after ~1.4 years at max tick (887272).
                tickCumulative: last.tickCumulative + int56(tick) * int56(uint56(delta)),
                secondsPerLiquidityCumulativeX128: last.secondsPerLiquidityCumulativeX128
                    + ((uint160(delta) << 128) / (liquidity > 0 ? liquidity : 1)),
                initialized: true
            });
        }
    }

    /// @notice Initialize the oracle array by writing the first slot. Called once for the lifecycle of the observations
    /// array.
    /// @param self The stored oracle array
    /// @param time The time of the oracle initialization, via block.timestamp truncated to uint32
    /// @return cardinality The number of populated elements in the oracle array
    /// @return cardinalityNext The new length of the oracle array, independent of population
    function initialize(
        Observation[65_535] storage self,
        uint32 time
    )
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({
            blockTimestamp: time, tickCumulative: 0, secondsPerLiquidityCumulativeX128: 0, initialized: true
        });
        return (1, 1);
    }

    /// @notice Writes an oracle observation to the array
    /// @dev Writable at most once per block. Index represents the most recently written element. cardinality and index
    /// must be tracked externally. If the index is at the end of the allowable array length (according to cardinality),
    /// and the next cardinality
    /// is greater than the current one, cardinality may be increased. This restriction is created to preserve ordering.
    /// @param self The stored oracle array
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param blockTimestamp The timestamp of the new observation
    /// @param tick The active tick at the time of the new observation
    /// @param liquidity The total in-range liquidity at the time of the new observation
    /// @param cardinality The number of populated elements in the oracle array
    /// @param cardinalityNext The new length of the oracle array, independent of population
    /// @return indexUpdated The new index of the most recently written element in the oracle array
    /// @return cardinalityUpdated The new cardinality of the oracle array
    function write(
        Observation[65_535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    )
        internal
        returns (uint16 indexUpdated, uint16 cardinalityUpdated)
    {
        unchecked {
            Observation memory last = self[index];

            // early return if we've already written an observation this block
            if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

            // if the conditions are right, we can bump the cardinality
            if (cardinalityNext > cardinality && index == (cardinality - 1)) {
                cardinalityUpdated = cardinalityNext;
            } else {
                cardinalityUpdated = cardinality;
            }

            indexUpdated = (index + 1) % cardinalityUpdated;
            self[indexUpdated] =
                transform({last: last, blockTimestamp: blockTimestamp, tick: tick, liquidity: liquidity});
        }
    }

    /// @notice Prepares the oracle array to store up to `next` observations
    /// @param self The stored oracle array
    /// @param current The current next cardinality of the oracle array
    /// @param next The proposed next cardinality which will be populated in the oracle array
    /// @return next The next cardinality which will be populated in the oracle array
    function grow(Observation[65_535] storage self, uint16 current, uint16 next) internal returns (uint16) {
        unchecked {
            if (current == 0) revert Oracle_CardinalityCannotBeZero(current);
            // no-op if the passed next value isn't greater than the current next value
            if (next <= current) return current;
            // store in each slot to prevent fresh SSTOREs in swaps
            // this data will not be used because the initialized boolean is still false
            for (uint16 i = current; i < next; i++) {
                self[i].blockTimestamp = 1;
            }
            return next;
        }
    }

    /// @notice comparator for 32-bit timestamps
    /// @dev safe for 0 or 1 overflows, a and b _must_ be chronologically before or equal to time
    /// @param time A timestamp truncated to 32 bits
    /// @param a A comparison timestamp from which to determine the relative position of `time`
    /// @param b From which to determine the relative position of `time`
    /// @return Whether `a` is chronologically <= `b`
    function lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        unchecked {
            // if there hasn't been overflow, no need to adjust
            if (a <= time && b <= time) return a <= b;

            uint256 aAdjusted = a > time ? a : a + 2 ** 32;
            uint256 bAdjusted = b > time ? b : b + 2 ** 32;

            return aAdjusted <= bAdjusted;
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a target, i.e. where [beforeOrAt, atOrAfter] is
    /// satisfied. The result may be the same observation, or adjacent observations.
    /// @dev The answer must be contained in the array, used when the target is located within the stored observation
    /// boundaries: older than the most recent observation and younger, or the same age as, the oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation recorded before, or at, the target
    /// @return atOrAfter The observation recorded at, or after, the target
    function binarySearch(
        Observation[65_535] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    )
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        unchecked {
            uint256 l = (index + 1) % cardinality; // oldest observation
            uint256 r = l + cardinality - 1; // newest observation
            uint256 i;
            while (true) {
                i = (l + r) / 2;

                beforeOrAt = self[i % cardinality];

                // we've landed on an uninitialized tick, keep searching higher (more recently)
                if (!beforeOrAt.initialized) {
                    l = i + 1;
                    continue;
                }

                atOrAfter = self[(i + 1) % cardinality];

                bool targetAtOrAfter = lte({time: time, a: beforeOrAt.blockTimestamp, b: target});

                // check if we've found the answer!
                if (targetAtOrAfter && lte({time: time, a: target, b: atOrAfter.blockTimestamp})) break;

                if (!targetAtOrAfter) r = i - 1;
                else l = i + 1;
            }
        }
    }

    /// @notice Fetches the observations around a target, where [beforeOrAt, atOrAfter] is satisfied.
    /// @dev Assumes there is at least 1 initialized observation.
    /// Used by observeSingle() to compute the counterfactual accumulator values as of a given block timestamp.
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param tick The active tick at the time of the returned or simulated observation
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The total pool liquidity at the time of the call
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation which occurred at, or before, the given timestamp
    /// @return atOrAfter The observation which occurred at, or after, the given timestamp
    function getSurroundingObservations(
        Observation[65_535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        unchecked {
            // optimistically set before to the newest observation
            beforeOrAt = self[index];

            // if the target is chronologically at or after the newest observation, we can early return
            if (lte({time: time, a: beforeOrAt.blockTimestamp, b: target})) {
                if (beforeOrAt.blockTimestamp == target) {
                    // if newest observation equals target, we're in the same block, so we can ignore atOrAfter
                    return (beforeOrAt, atOrAfter);
                } else {
                    // otherwise, we need to transform
                    return (
                        beforeOrAt,
                        transform({last: beforeOrAt, blockTimestamp: target, tick: tick, liquidity: liquidity})
                    );
                }
            }

            // now, set before to the oldest observation
            beforeOrAt = self[(index + 1) % cardinality];
            if (!beforeOrAt.initialized) beforeOrAt = self[0];

            // ensure that the target is chronologically at or after the oldest observation
            if (!lte({time: time, a: beforeOrAt.blockTimestamp, b: target})) {
                revert Oracle_TargetPredatesOldestObservation({
                    oldestTimestamp: beforeOrAt.blockTimestamp, targetTimestamp: target
                });
            }

            // if we've reached this point, we have to binary search
            return binarySearch({self: self, time: time, target: target, index: index, cardinality: cardinality});
        }
    }

    /// @notice Returns the cumulative tick and seconds-per-liquidity values at a single point in the past.
    /// @dev Reverts if an observation at or before the desired observation timestamp does not exist.
    /// 0 may be passed as `secondsAgo` to return the current cumulative values.
    /// If called with a timestamp falling between two observations, returns the counterfactual accumulator values
    /// at exactly the timestamp between the two observations.
    /// @param self The stored oracle array
    /// @param time The current block timestamp
    /// @param secondsAgo The amount of time to look back, in seconds, at which point to return an observation
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The current in-range pool liquidity
    /// @param cardinality The number of populated elements in the oracle array
    /// @return tickCumulative The tick * time elapsed since the pool was first initialized, as of `secondsAgo`
    /// @return secondsPerLiquidityCumulativeX128 The time elapsed / max(1, liquidity) since the pool was first
    /// initialized, as of `secondsAgo`
    function observeSingle(
        Observation[65_535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        internal
        view
        returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128)
    {
        unchecked {
            if (secondsAgo == 0) {
                Observation memory last = self[index];
                if (last.blockTimestamp != time) {
                    last = transform({last: last, blockTimestamp: time, tick: tick, liquidity: liquidity});
                }
                return (last.tickCumulative, last.secondsPerLiquidityCumulativeX128);
            }

            uint32 target = time - secondsAgo;

            (Observation memory beforeOrAt, Observation memory atOrAfter) = getSurroundingObservations({
                self: self,
                time: time,
                target: target,
                tick: tick,
                index: index,
                liquidity: liquidity,
                cardinality: cardinality
            });

            if (target == beforeOrAt.blockTimestamp) {
                // we're at the left boundary
                return (beforeOrAt.tickCumulative, beforeOrAt.secondsPerLiquidityCumulativeX128);
            } else if (target == atOrAfter.blockTimestamp) {
                // we're at the right boundary
                return (atOrAfter.tickCumulative, atOrAfter.secondsPerLiquidityCumulativeX128);
            } else {
                // we're in the middle
                uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
                uint32 targetDelta = target - beforeOrAt.blockTimestamp;
                // forge-lint: disable-start(divide-before-multiply)
                // NOTE: The divide-before-multiply here loses up to (observationTimeDelta - 1) units of
                // tickCumulative precision. For realistic observation intervals (seconds to minutes) and
                // tick ranges, this is bounded and economically insignificant.
                return (
                    beforeOrAt.tickCumulative
                        + ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(uint56(observationTimeDelta)))
                        * int56(uint56(targetDelta)),
                    beforeOrAt.secondsPerLiquidityCumulativeX128
                        + uint160(
                            (uint256(
                                        atOrAfter.secondsPerLiquidityCumulativeX128
                                            - beforeOrAt.secondsPerLiquidityCumulativeX128
                                    )
                                    * targetDelta) / observationTimeDelta
                        )
                );
                // forge-lint: disable-end(divide-before-multiply)
            }
        }
    }

    /// @notice Returns accumulator values as of each `secondsAgos` offset from the given time.
    /// @dev Reverts if `secondsAgos` > oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param secondsAgos Each amount of time to look back, in seconds, at which point to return an observation
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The current in-range pool liquidity
    /// @param cardinality The number of populated elements in the oracle array
    /// @return tickCumulatives The tick * time elapsed since the pool was first initialized, as of each `secondsAgo`
    /// @return secondsPerLiquidityCumulativeX128s The cumulative seconds / max(1, liquidity) since the pool was first
    /// initialized, as of each `secondsAgo`
    function observe(
        Observation[65_535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        internal
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        unchecked {
            if (cardinality == 0) revert Oracle_CardinalityCannotBeZero(cardinality);

            uint256 secondsAgosLength = secondsAgos.length;
            tickCumulatives = new int56[](secondsAgosLength);
            secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgosLength);
            for (uint256 i; i < secondsAgosLength; i++) {
                (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) = observeSingle({
                    self: self,
                    time: time,
                    secondsAgo: secondsAgos[i],
                    tick: tick,
                    index: index,
                    liquidity: liquidity,
                    cardinality: cardinality
                });
            }
        }
    }
}
