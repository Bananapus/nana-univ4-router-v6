# UniV4 Router Runtime

## Core roles

- [`src/JBUniswapV4Hook.sol`](../src/JBUniswapV4Hook.sol) intercepts swaps involving Juicebox project tokens, compares V4 and Juicebox paths, and records observations after pool activity.
- [`src/libraries/Oracle.sol`](../src/libraries/Oracle.sol) owns the observation ring buffer and TWAP lookup logic.

## Runtime path

1. A V4 swap involving a Juicebox project token enters the hook.
2. The hook estimates the V4 path and the Juicebox-native path from terminal-reported preview amounts.
3. It chooses the better route or falls back to V4 when Juicebox-side estimation fails, when the buy-side terminal cannot be previewed live, when the sell-side preview surface is unavailable, or when the best JB quote cannot fit Uniswap V4's signed delta accounting.
4. After relevant pool actions, it records observations for future TWAP queries.

## High-risk areas

- Route decision logic: buy/sell estimation changes have direct economic impact.
- Oracle maturity: early pools may lack enough history for strong TWAP protection.
- Fallback semantics: liveness is intentionally preserved when estimation fails.
- Hook-data assumptions: swap callers must supply `amountOutMin` in the first 32 bytes, but may append extra metadata after that prefix.
- Buyback-hook metadata-only hints are ignored for live route scoring; use the V4 path directly when the pool is the intended route.
- Quote-model limits: `estimateUniswapOutput()` is a linear quote, not a full execution simulation. Large trades can still see material V4 quote drift on shallow liquidity.
- Signed-delta capacity: even when Juicebox would return more, V4 settlement still has `int128` output limits. The hook must degrade rather than overflowing that boundary.

## Tests to trust first

- [`test/Invariant.t.sol`](../test/Invariant.t.sol) for broad routing invariants.
- [`test/SlippageTolerance.t.sol`](../test/SlippageTolerance.t.sol) for execution protection.
- [`test/ThreeWayRouting.t.sol`](../test/ThreeWayRouting.t.sol) for route-selection behavior.
- [`test/TestObserve.t.sol`](../test/TestObserve.t.sol) and [`test/OracleDeepTest.t.sol`](../test/OracleDeepTest.t.sol) for observation logic.
- [`test/regression/PreviewPayForRouting.t.sol`](../test/regression/PreviewPayForRouting.t.sol), [`test/regression/RegressionHookDataLength.t.sol`](../test/regression/RegressionHookDataLength.t.sol), [`test/regression/RegressionSellPreviewFallback.t.sol`](../test/regression/RegressionSellPreviewFallback.t.sol), and [`test/regression/RegressionLargeTradeMisroute.t.sol`](../test/regression/RegressionLargeTradeMisroute.t.sol) for the failure modes most likely to misroute production swaps.
