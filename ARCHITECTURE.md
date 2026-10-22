# Architecture

## Purpose

`univ4-router-v6` is a Uniswap V4 hook that fills buys of a project token from the pool while it beats issuance and mints the rest, and compares sells against the project's cash-out route. It also maintains the TWAP oracle surface that other repos, especially `nana-buyback-hook-v6`, rely on.

## System overview

`JBUniswapV4Hook` is the runtime hook that inspects swaps, estimates both market and protocol routes, and can override settlement when the protocol path is better. It implements `IGeomeanOracle`, the canonical downstream interface for pool-local TWAP reads. `Oracle` maintains the observation ring buffer used for TWAP lookup and interpolation. The deployment is intentionally immutable after construction.

## Core invariants

- The oracle must stay queryable and sufficiently manipulation-resistant for routing decisions.
- Routing recursion with buyback integrations must stay impossible.
- If Juicebox estimation fails, the hook should degrade predictably instead of inventing new semantics.
- Sell-side Juicebox estimates are intentionally conservative and may return `0` rather than trust stale static math.
- Exposed V4 hook permissions must match actual implemented behavior.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `IGeomeanOracle` | External oracle-read interface for downstream packages | Import from this package instead of redeclaring |
| `JBUniswapV4Hook` | Routing-aware Uniswap V4 hook and settlement override logic | Immutable runtime core |
| `Oracle` | Observation ring buffer and TWAP interpolation | Quote-critical |

## Trust boundaries

- Juicebox still owns minting and cash-out execution when the protocol path is selected.
- Pool state and hook entrypoints come from Uniswap V4.
- Downstream integrations such as `nana-buyback-hook-v6` depend on this repo's oracle and routing semantics through `IGeomeanOracle`.

## Critical flows

### Swap with routing

```text
swap involving a project token
  -> beforeSwap checks whether Juicebox-aware routing applies
  -> buy: hook swaps the pool itself up to the issuance limit (price where the pool's output after fees equals
     issuance), mints the leftover input through the terminal, and settles both legs as one delta;
     a caller limit at or inside the issuance price (the buyback hook's swaps) stays a plain V4 swap
  -> sell: hook estimates the pool route using its oracle
  -> hook estimates the Juicebox route from current protocol state
  -> if Juicebox wins, the hook overrides settlement into the protocol path
  -> if the pool wins, the AMM swap continues normally
  -> afterSwap and liquidity callbacks record new observations
```

## Accounting model

This repo does not own the canonical treasury ledger. It owns route comparison and oracle observation state.

Its route comparison is intentionally asymmetric: helper surfaces can be more permissive for offchain inspection, while live routing trusts stricter terminal preview surfaces and ignores buyback-hook metadata-only hints.

## Security model

- Oracle upkeep and routing are tightly coupled.
- Warmup behavior matters because low-history pools fall back toward spot pricing.
- Buy issuance relies on `previewPayFor(...)` (or the ruleset weight when the preview mints nothing for the payer and forwards the pay to a hook, as the buyback hook does when it swaps), and sell estimation on `previewCashOutFrom(...)`, in core. A buyer never gets less than minting the whole input, less a rounding margin.
- Conservative underestimation is part of the safety model. The hook may prefer V4 over a risky Juicebox route.
- Because the deployment is immutable, constructor mistakes are expensive to fix.

## Safe change guide

- Treat routing and oracle logic as one system.
- Review changes under standalone swaps, buyback-hook integration, and low-history warmup conditions.
- If estimation logic changes, keep the distinction between offchain helpers and live-routing trust surfaces explicit.
- Resist mutable-config creep. Constructor-configured behavior is the design goal.

## Canonical checks

- oracle observation depth and TWAP interpolation:
  `test/OracleDeepTest.t.sol`
- preview-to-live routing alignment on buy paths:
  `test/regression/PreviewPayForRouting.t.sol`
- split buys (pool fill plus mint) and the never-below-mint-all fuzz:
  `test/SplitBuy.t.sol`, with Base fork evidence in `test/SplitBuyBaseFork.t.sol`
- sell-path safety under hostile callback conditions:
  `test/regression/SellPathReentrancy.t.sol`

## Source map

- `src/JBUniswapV4Hook.sol`
- `src/interfaces/IGeomeanOracle.sol`
- `src/libraries/Oracle.sol`
- `test/OracleDeepTest.t.sol`
- `test/regression/PreviewPayForRouting.t.sol`
- `test/regression/SellPathReentrancy.t.sol`
