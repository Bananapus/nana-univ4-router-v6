# UniV4 Router Runtime

## Core Roles

- [`src/JBUniswapV4Hook.sol`](../src/JBUniswapV4Hook.sol) intercepts swaps involving Juicebox project tokens, compares V4 and Juicebox paths, and records observations after pool activity.
- [`src/libraries/Oracle.sol`](../src/libraries/Oracle.sol) owns the observation ring buffer and TWAP lookup logic.

## Runtime Path

1. A V4 swap involving a Juicebox project token enters the hook.
2. The hook estimates the V4 path and the Juicebox-native path.
3. It chooses the better route or falls back to V4 when Juicebox-side estimation fails.
4. After relevant pool actions, it records observations for future TWAP queries.

## High-Risk Areas

- Route decision logic: buy/sell estimation changes have direct economic impact.
- Oracle maturity: early pools may lack enough history for strong TWAP protection.
- Fallback semantics: liveness is intentionally preserved when estimation fails.
- Hook-data assumptions: swap callers must supply the expected slippage payload.

## Tests To Trust First

- [`test/Invariant.t.sol`](../test/Invariant.t.sol) for broad routing invariants.
- [`test/SlippageTolerance.t.sol`](../test/SlippageTolerance.t.sol) for execution protection.
- [`test/ThreeWayRouting.t.sol`](../test/ThreeWayRouting.t.sol) for route-selection behavior.
- [`test/TestObserve.t.sol`](../test/TestObserve.t.sol) and [`test/OracleDeepTest.t.sol`](../test/OracleDeepTest.t.sol) for observation logic.
