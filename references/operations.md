# UniV4 Router Operations

## Deployment and Interface Surface

- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is the first stop for constructor wiring and V4 hook deployment setup.
- [`src/JBUniswapV4Hook.sol`](../src/JBUniswapV4Hook.sol) defines the hook-data contract that callers must satisfy.
- [`src/libraries/Oracle.sol`](../src/libraries/Oracle.sol) contains the observation code that often gets blamed after routing changes.

## Change Checklist

- If you edit route selection, verify both buy and sell paths.
- If you edit oracle behavior, re-check both recording and observation reads.
- If you touch slippage or hook-data handling, verify the tests that cover caller-supplied `amountOutMin`.
- If you touch Juicebox settlement sizing, verify that any JB-selected output still fits Uniswap V4's signed `int128` delta domain.
- If you touch buy-side routing, verify the preview-unavailable path falls back to V4 instead of reusing static weight estimation.
- If you touch sell-side routing, verify preview failures still degrade to V4 instead of reviving the older static reclaim estimate.
- If you touch buyback composition, keep buyback-hook metadata out of live route scoring unless direct terminal preview amounts prove the route.
- If you edit deployment assumptions, confirm the hook flags and immutable constructor wiring still match V4 expectations.
- If you edit quote quality claims, re-measure large-trade drift explicitly. The linear V4 estimate is intentionally approximate.

## Common Failure Modes

- Route-quality issue is blamed on the router when the real issue is immature pool history.
- Juicebox-side estimate fails and the fallback path hides the root cause until execution quality degrades.
- Linear V4 quote drift is treated as a known operator limitation today; use the fork drift tests to re-measure practical trade-size envelopes when liquidity changes.
- Deployment assumptions about hook flags or immutable wiring drift from what the script actually deploys.

## Useful Proof Points

- [`test/TestRegressionGaps.sol`](../test/TestRegressionGaps.sol), [`test/TestStructuralArbitrage.t.sol`](../test/TestStructuralArbitrage.t.sol), and [`test/StressAndOrderOfMagnitude.t.sol`](../test/StressAndOrderOfMagnitude.t.sol) for pinned routing edge cases.
- [`test/regression/PreviewPayForRouting.t.sol`](../test/regression/PreviewPayForRouting.t.sol), [`test/regression/RegressionHookDataLength.t.sol`](../test/regression/RegressionHookDataLength.t.sol), and [`test/regression/RegressionLargeTradeMisroute.t.sol`](../test/regression/RegressionLargeTradeMisroute.t.sol) for preview routing, hook-data, and large-trade degradation.
- [`script/Deploy.s.sol`](../script/Deploy.s.sol) when deployment or setup logic is the real issue.
