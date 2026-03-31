# Changelog

## Scope

This repo was not part of the deployed v5 ecosystem that the top-level changelog measures, so it is excluded from the ecosystem delta.

## Current v6 surface

- `JBUniswapV4Hook`
- `Oracle`

## Summary

- This repo is a dedicated Uniswap v4 hook package for the v6 stack rather than a deployed v5 migration target.
- The current codebase is tightly connected to the v6 buyback and preview-routing model, with tests that exercise preview paths, oracle logic, swap estimates, slippage handling, and structural arbitrage scenarios.
- The repo mixes exact and ranged pragmas across files, but the main runtime contract is on the v6 `0.8.28` baseline.

## Migration notes

- Do not count this repo in the deployed v5-to-v6 ecosystem summary.
- If you are integrating it, use the current v6 sources and tests as the source of truth rather than trying to map it onto the older deployed ecosystem.
