# Juicebox UniV4 Router

## Use this file for

- Use this file when the task involves the V4 router hook, route selection between Uniswap and Juicebox, TWAP observations, or hook-permission-bit deployment requirements.
- Start here, then decide whether the issue is buy-side routing, sell-side routing, oracle history, or deployment and flag setup.

## Read this next

| If you need... | Open this next |
|---|---|
| Repo overview and intended composition | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Router-hook implementation | [`src/JBUniswapV4Hook.sol`](./src/JBUniswapV4Hook.sol) |
| Runtime and fallback assumptions | [`references/runtime.md`](./references/runtime.md), [`references/operations.md`](./references/operations.md) |
| Oracle internals | [`src/libraries/Oracle.sol`](./src/libraries/Oracle.sol), [`test/TestObserve.t.sol`](./test/TestObserve.t.sol), [`test/OracleDeepTest.t.sol`](./test/OracleDeepTest.t.sol) |
| Deployment script and setup | [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Routing invariants and slippage behavior | [`test/Invariant.t.sol`](./test/Invariant.t.sol), [`test/SlippageTolerance.t.sol`](./test/SlippageTolerance.t.sol), [`test/ThreeWayRouting.t.sol`](./test/ThreeWayRouting.t.sol), [`test/JBUniswapV4HookFork.t.sol`](./test/JBUniswapV4HookFork.t.sol) |
| Structural edge cases and pinned notes | [`test/StressAndOrderOfMagnitude.t.sol`](./test/StressAndOrderOfMagnitude.t.sol), [`test/TestStructuralArbitrage.t.sol`](./test/TestStructuralArbitrage.t.sol), [`test/JBUniswapV4Hook.t.sol`](./test/JBUniswapV4Hook.t.sol), [`test/TestRegressionGaps.sol`](./test/TestRegressionGaps.sol) |

## Repo map

| Area | Where to look |
|---|---|
| Main contract | [`src/JBUniswapV4Hook.sol`](./src/JBUniswapV4Hook.sol) |
| Libraries | [`src/libraries/`](./src/libraries/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Uniswap V4 hook and oracle surface for Juicebox-aware swaps. This repo compares market execution against Juicebox-native mint or cash-out execution and records per-pool observations for TWAP-aware routing.

## Reference files

- Open [`references/runtime.md`](./references/runtime.md) for the swap decision path, oracle write and read behavior, and the main economic invariants.
- Open [`references/operations.md`](./references/operations.md) for deployment constraints, hook-data expectations, and common stale assumptions around fallback and TWAP quality.

## Working rules

- Start in [`src/JBUniswapV4Hook.sol`](./src/JBUniswapV4Hook.sol) for routing behavior, but verify oracle assumptions in [`src/libraries/Oracle.sol`](./src/libraries/Oracle.sol) before changing quote logic.
- This hook is designed to compose with the buyback hook on the same pool. Treat composition limits and recursion guards as first-class behavior.
- Treat exact-input assumptions, fallback-to-V4 behavior, and slippage checks as high-risk.
- Buy-side routing trusts `previewPayFor(...)` for live decisions when it is available.
- Sell-side routing depends on `previewCashOutFrom(...)` and intentionally falls back to V4 rather than reviving stale static reclaim math.
- The V4 quote model is intentionally approximate. Do not oversell estimates as execution guarantees.
- Uniswap V4 signed-delta limits are a real routing boundary. Oversized Juicebox outputs must degrade to V4.
- Keep the `hookData` contract straight: `_beforeSwap` expects the first 32 bytes to encode `amountOutMin`.
- When a task mentions buyback composition, confirm whether the behavior actually lives here or in `nana-buyback-hook-v6`.
