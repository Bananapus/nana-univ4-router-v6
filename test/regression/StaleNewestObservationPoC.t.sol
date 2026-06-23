// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Oracle} from "../../src/libraries/Oracle.sol";

/// @notice Documents that a stale newest observation can make a successful TWAP response equal the current tick.
contract StaleNewestObservationPoC is Test {
    using Oracle for Oracle.Observation[65_535];

    Oracle.Observation[65_535] internal observations;

    function test_staleNewestObservationLetsCurrentTickDefineWholeWindow() external {
        uint32 start = 10_000;
        uint32 newestTimestamp = start + 100;
        uint32 window = 120;
        uint32 nowTimestamp = newestTimestamp + window;
        int24 manipulatedCurrentTick = 1234;
        uint128 liquidity = 1_000_000 ether;

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize({time: start});
        cardinalityNext = observations.grow({current: cardinalityNext, next: 2});

        (uint16 index, uint16 cardinalityUpdated) = observations.write({
            index: 0,
            blockTimestamp: newestTimestamp,
            tick: 0,
            liquidity: liquidity,
            cardinality: cardinality,
            cardinalityNext: cardinalityNext
        });

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = observations.observe({
            time: nowTimestamp,
            secondsAgos: secondsAgos,
            tick: manipulatedCurrentTick,
            index: index,
            liquidity: liquidity,
            cardinality: cardinalityUpdated
        });

        int24 meanTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(window)));

        assertEq(meanTick, manipulatedCurrentTick, "stale newest observation produced a spot-equivalent TWAP");
    }
}
