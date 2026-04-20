# Architecture

## Purpose

`univ4-router-v6` is a Uniswap V4 hook that compares live pool execution against Juicebox-native mint or cash-out routes whenever a project token is traded. It also maintains the TWAP oracle surface that other repos, especially `nana-buyback-hook-v6`, rely on.

## System Overview

`JBUniswapV4Hook` is the runtime hook that inspects swaps, estimates both market and protocol routes, and can override settlement when the protocol path is better. `Oracle` maintains the observation ring buffer used for TWAP lookup and interpolation. The deployment is intentionally immutable after construction.

## Core Invariants

- The oracle must stay queryable and sufficiently manipulation-resistant for routing decisions.
- Routing recursion with buyback integrations must stay impossible.
- If Juicebox estimation fails, the hook should degrade predictably instead of inventing new semantics.
- Sell-side Juicebox estimates are intentionally conservative and may return `0` rather than trust stale static math.
- Exposed V4 hook permissions must match actual implemented behavior.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBUniswapV4Hook` | Routing-aware Uniswap V4 hook and settlement override logic | Immutable runtime core |
| `Oracle` | Observation ring buffer and TWAP interpolation | Quote-critical |

## Trust Boundaries

- Juicebox still owns minting and cash-out execution when the protocol path is selected.
- Pool state and hook entrypoints come from Uniswap V4.
- Downstream integrations such as `nana-buyback-hook-v6` depend on this repo's oracle and routing semantics.

## Critical Flows

### Swap With Routing

```text
swap involving a project token
  -> beforeSwap checks whether Juicebox-aware routing applies
  -> hook estimates the pool route using its oracle
  -> hook estimates the Juicebox route from current protocol state
  -> if Juicebox wins, the hook overrides settlement into the protocol path
  -> if the pool wins, the AMM swap continues normally
  -> afterSwap and liquidity callbacks record new observations
```

## Accounting Model

This repo does not own the canonical treasury ledger. It owns route comparison and oracle observation state.

Its route comparison is intentionally asymmetric: helper surfaces can be more permissive for offchain inspection, while live routing trusts stricter preview surfaces.

## Security Model

- Oracle upkeep and routing are tightly coupled.
- Warmup behavior matters because low-history pools fall back toward spot pricing.
- Buy and sell estimation rely on `previewPayFor(...)` and `previewCashOutFrom(...)` behavior in core.
- Conservative underestimation is part of the safety model. The hook may prefer V4 over a risky Juicebox route.
- Because the deployment is immutable, constructor mistakes are expensive to fix.

## Safe Change Guide

- Treat routing and oracle logic as one system.
- Review changes under standalone swaps, buyback-hook integration, and low-history warmup conditions.
- If estimation logic changes, keep the distinction between offchain helpers and live-routing trust surfaces explicit.
- Resist mutable-config creep. Constructor-configured behavior is the design goal.

## Canonical Checks

- oracle observation depth and TWAP interpolation:
  `test/OracleDeepTest.t.sol`
- preview-to-live routing alignment on buy paths:
  `test/audit/PreviewPayForRouting.t.sol`
- sell-path safety under hostile callback conditions:
  `test/regression/SellPathReentrancy.t.sol`

## Source Map

- `src/JBUniswapV4Hook.sol`
- `src/libraries/Oracle.sol`
- `test/OracleDeepTest.t.sol`
- `test/audit/PreviewPayForRouting.t.sol`
- `test/regression/SellPathReentrancy.t.sol`
