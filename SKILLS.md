# Juicebox UniV4 Router

## Use This File For

- Use this file when the task involves the V4 router hook, route selection between Uniswap and Juicebox, TWAP observations, or hook permission-bit deployment requirements.
- Start here, then open the hook contract or oracle-focused tests depending on whether the issue is swap routing, observation math, or deployment setup.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and intended composition | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Router-hook implementation | [`src/JBUniswapV4Hook.sol`](./src/JBUniswapV4Hook.sol) |
| Oracle internals and helper-library behavior | [`src/libraries/`](./src/libraries/), [`src/libraries/Oracle.sol`](./src/libraries/Oracle.sol), [`test/TestObserve.t.sol`](./test/TestObserve.t.sol), [`test/OracleDeepTest.t.sol`](./test/OracleDeepTest.t.sol) |
| Deployment script and setup | [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Routing invariants, slippage behavior, or regressions | [`test/Invariant.t.sol`](./test/Invariant.t.sol), [`test/SlippageTolerance.t.sol`](./test/SlippageTolerance.t.sol), [`test/ThreeWayRouting.t.sol`](./test/ThreeWayRouting.t.sol), [`test/regression/`](./test/regression/) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contract | [`src/JBUniswapV4Hook.sol`](./src/JBUniswapV4Hook.sol) |
| Libraries | [`src/libraries/`](./src/libraries/) |
| Scripts | [`script/`](./script/) |
| Tests | [`test/`](./test/) |

## Purpose

Uniswap V4 hook and oracle surface for Juicebox-aware swaps. This repo compares market execution against Juicebox-native mint or cash-out execution and records per-pool observations for TWAP-aware routing.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) when you need the swap decision path, oracle write/read behavior, or the main economic invariants.
- Open [`references/operations.md`](./references/operations.md) when you need deployment constraints, hook-data expectations, or the common stale assumptions around fallback and TWAP quality.

## Working Rules

- Start in [`src/JBUniswapV4Hook.sol`](./src/JBUniswapV4Hook.sol) for routing behavior, but verify oracle assumptions in [`src/libraries/Oracle.sol`](./src/libraries/Oracle.sol) before changing quote logic.
- Treat exact-input assumptions, fallback-to-V4 behavior, and slippage checks as high-risk. Small changes there alter execution quality directly.
- When a task mentions buyback composition, confirm whether the behavior actually lives in this repo or in `nana-buyback-hook-v6`.
- If you change deployment or permission bits, verify they still match Uniswap V4 hook flag requirements.
