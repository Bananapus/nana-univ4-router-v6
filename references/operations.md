# UniV4 Router Operations

## Deployment and Interface Surface

- [`script/Deploy.s.sol`](../script/Deploy.s.sol) is the first stop for constructor wiring and V4 hook deployment setup.
- [`src/JBUniswapV4Hook.sol`](../src/JBUniswapV4Hook.sol) defines the hook-data contract that callers must satisfy.
- [`src/libraries/`](../src/libraries/) contains the observation code that often gets blamed after routing changes.

## Change Checklist

- If you edit route selection, verify both buy and sell paths.
- If you edit oracle behavior, re-check both recording and observation reads.
- If you touch slippage or hook-data handling, verify the tests that cover caller-supplied `amountOutMin`.
- If you edit deployment assumptions, confirm the hook flags and immutable constructor wiring still match V4 expectations.

## Common Failure Modes

- Route-quality issue is blamed on the router when the real issue is immature pool history.
- Juicebox-side estimate fails and the fallback path hides the root cause until execution quality degrades.
- Deployment assumptions about hook flags or immutable wiring drift from what the script actually deploys.

## Useful Proof Points

- [`test/regression/`](../test/regression/) for pinned routing edge cases.
- [`script/helpers/`](../script/helpers/) when deployment or setup logic is the real issue.
