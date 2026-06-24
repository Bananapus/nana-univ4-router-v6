// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Interface for Uniswap V4 hooks that expose pool observation data for TWAP quoting.
/// @dev Consumers can use this interface to distinguish full-window coverage from shorter retained best-effort
/// windows before trusting `observe([secondsAgo, 0])` as a manipulation-resistant TWAP.
interface IGeomeanOracle {
    /// @notice Whether the oracle has stored observations covering `secondsAgo` for `key`.
    /// @param key The pool key to check.
    /// @param secondsAgo The requested lookback window.
    /// @return True if `observe([secondsAgo, 0])` is backed by retained observation history.
    function hasObservationCoverage(PoolKey calldata key, uint32 secondsAgo) external view returns (bool);

    /// @notice The oldest retained observation age for `key`.
    /// @param key The pool key to check.
    /// @return oldestSecondsAgo The age of the oldest retained initialized observation, or 0 if unavailable.
    function observationCoverageOf(PoolKey calldata key) external view returns (uint32 oldestSecondsAgo);

    /// @notice Returns cumulative tick and seconds-per-liquidity values for the given lookback offsets.
    /// @param key The pool key to observe.
    /// @param secondsAgos An array of seconds-ago offsets from the current block timestamp.
    /// @return tickCumulatives Cumulative tick values at the given offsets.
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity at the given offsets.
    function observe(
        PoolKey calldata key,
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
