# Juicebox UniV4 Router

## Use This File For

- Use this file when the task involves the V4 router hook, route selection between Uniswap and Juicebox, TWAP observations, or hook permission-bit deployment requirements.
- Start here, then decide whether the issue is buy-side routing, sell-side routing, oracle history, or deployment/flag setup. Those paths fail differently.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and intended composition | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Router-hook implementation | [`src/JBUniswapV4Hook.sol`](./src/JBUniswapV4Hook.sol) |
| Runtime and fallback assumptions | [`references/runtime.md`](./references/runtime.md), [`references/operations.md`](./references/operations.md) |
| Oracle internals and helper-library behavior | [`src/libraries/`](./src/libraries/), [`src/libraries/Oracle.sol`](./src/libraries/Oracle.sol), [`test/TestObserve.t.sol`](./test/TestObserve.t.sol), [`test/OracleDeepTest.t.sol`](./test/OracleDeepTest.t.sol) |
| Deployment script and setup | [`script/Deploy.s.sol`](./script/Deploy.s.sol) |
| Routing invariants and slippage behavior | [`test/Invariant.t.sol`](./test/Invariant.t.sol), [`test/SlippageTolerance.t.sol`](./test/SlippageTolerance.t.sol), [`test/ThreeWayRouting.t.sol`](./test/ThreeWayRouting.t.sol), [`test/JBUniswapV4HookFork.t.sol`](./test/JBUniswapV4HookFork.t.sol) |
| Structural edge cases and pinned findings | [`test/StressAndOrderOfMagnitude.t.sol`](./test/StressAndOrderOfMagnitude.t.sol), [`test/TestStructuralArbitrage.t.sol`](./test/TestStructuralArbitrage.t.sol), [`test/JBUniswapV4Hook.t.sol`](./test/JBUniswapV4Hook.t.sol), [`test/TestAuditGaps.sol`](./test/TestAuditGaps.sol) |

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
- This hook is designed to compose with the buyback hook on the same pool. Treat composition limits and recursion guards as first-class behavior, not implementation trivia.
- Treat exact-input assumptions, fallback-to-V4 behavior, and slippage checks as high-risk. Small changes there alter execution quality directly.
- Buy-side quoting now prefers `previewPayFor(...)` when a terminal is available, then falls back to static weight estimation. Keep both paths in sync with the docs.
- Sell-side quoting depends on `previewCashOutFrom(...)` plus optional fee deduction, so review terminal-interface assumptions before simplifying that path.
- The V4 quote model is intentionally approximate. Large-trade drift is a known limitation, so do not oversell estimates as execution-quality guarantees.
- Uniswap V4 signed-delta limits are a real routing boundary. Oversized Juicebox outputs must degrade to V4 rather than forcing an impossible delta shape.
- Keep the `hookData` contract straight: `_beforeSwap` expects exactly one encoded `uint256 amountOutMin`, while `_afterSwap` is intentionally more permissive for passthrough swaps.
- When a task mentions buyback composition, confirm whether the behavior actually lives in this repo or in `nana-buyback-hook-v6`.
- If you change deployment or permission bits, verify they still match Uniswap V4 hook flag requirements.
