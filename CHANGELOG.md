# Changelog

## Scope

This repo was not part of the deployed v5 ecosystem that the top-level changelog measures, so it is excluded from the ecosystem delta.

## Current v6 surface

- `JBUniswapV4Hook`
- `Oracle`

## 0.0.31 — Bump nana-core-v6 to 0.0.52

`nana-core-v6@0.0.52` centralized the protocol fee constant into `JBConstants.FEE` and dropped `IJBFeeTerminal.FEE()`. Updated `JBUniswapV4Hook` accordingly:

- `calculateExpectedOutputFromSelling` no longer does `try IJBFeeTerminal(terminal).FEE()` + fallback to 0 — it reads the compile-time constant `JBConstants.FEE` directly. The previous fallback and the `fee > MAX_FEE` guard are now both dead (constant is `25`, `MAX_FEE` is `1000`), so they're removed.
- Dropped the `IJBFeeTerminal` import (no longer referenced).
- Deleted `test/regression/RegressionInvalidFeeSellDoS.t.sol` — it specifically tested the "terminal-reported FEE > MAX_FEE" failure mode, which is no longer reachable because the fee is no longer a per-terminal value.
- Added `pauseCrossProjectFeeFreeInflows: false` to all `JBRulesetMetadata` literals across `test/` for the new ruleset field added in core 0.0.52.

## Summary

- This repo is a dedicated Uniswap v4 hook package for the v6 stack rather than a deployed v5 migration target.
- The current codebase is tightly connected to the v6 buyback and preview-routing model, with tests that exercise preview paths, oracle logic, swap estimates, slippage handling, and structural arbitrage scenarios.
- The repo mixes exact and ranged pragmas across files, but the main runtime contract is on the v6 `0.8.28` baseline.

## Migration notes

- Do not count this repo in the deployed v5-to-v6 ecosystem summary.
- If you are integrating it, use the current v6 sources and tests as the source of truth rather than trying to map it onto the older deployed ecosystem.

## Local review remediations

- JB quotes that exceed Uniswap V4's signed `int128` delta capacity are now treated as ineligible, so swaps fall back to V4 instead of reverting during settlement.
- `_beforeSwap` and `_afterSwap` now agree on hook-data parsing: the first 32 bytes are `amountOutMin`, and extra trailing metadata is tolerated.
- Buy-side live routing now trusts `previewPayFor()` only. Preview failures, missing buy terminals, and extreme token-decimal metadata all degrade to a `0` JB quote so V4 stays live.
- Sell-side live routing now treats `previewCashOutFrom()` as authoritative. If that preview surface is unavailable or reverts, the JB sell quote intentionally degrades to `0` so the router does not rely on a stale static reclaim estimate.
- Large-trade V4 quote drift remains a documented limitation of the current linear estimator; fork tests pin sample small-trade and large-trade drift envelopes for operators.
- `calculateExpectedOutputFromSelling` now returns 0 when the terminal fee exceeds `JBConstants.MAX_FEE`, so the swap degrades to V4 instead of reverting on an arithmetic underflow.
- Live routing ignores buyback-hook metadata-only preview hints. Buy and sell decisions use the terminal-reported `previewPayFor(...)` and `previewCashOutFrom(...)` amounts only; if those direct preview amounts are zero, the Juicebox side is ineligible and the swap stays on V4.
