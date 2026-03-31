# Architecture

## Purpose

`univ4-router-v6` is a Uniswap V4 hook that compares the live pool route against Juicebox-native mint or cash-out routes whenever a project token is traded. It also maintains the TWAP oracle that other repos, especially `nana-buyback-hook-v6`, rely on.

## Boundaries

- The hook owns V4-side route selection and oracle observation storage.
- Juicebox still owns minting and cash-out execution when the hook chooses the protocol path.
- The repo is intentionally immutable after deployment; there is no admin control plane.

## Main Components

| Component | Responsibility |
| --- | --- |
| `JBUniswapV4Hook` | Uniswap V4 `BaseHook` implementation with routing and settlement overrides |
| `Oracle` | Ring-buffer observation logic for TWAP queries and interpolation |

## Runtime Model

```text
swap involving a project token
  -> beforeSwap identifies whether Juicebox routing is relevant
  -> hook estimates the pool route using its TWAP oracle
  -> hook estimates the Juicebox route using current protocol state
  -> if Juicebox wins, the hook takes over settlement and routes through the protocol
  -> if the pool wins, the AMM swap proceeds normally
  -> afterSwap and liquidity callbacks record new observations
```

## Critical Invariants

- The oracle must remain queryable and manipulation-resistant enough for routing decisions.
- Routing recursion with buyback integrations must stay impossible; the reentrancy guard is part of the design, not optional hardening.
- If Juicebox estimation fails, the hook should degrade predictably instead of inventing a fallback path with different semantics.
- Hook permissions exposed to the V4 pool manager must match the behavior the contract actually implements.

## Where Complexity Lives

- Oracle upkeep and routing are coupled because the contract both measures the market and overrides it.
- Warmup behavior, low-observation history, and buyback-hook composition are the review hotspots.
- The contract is intentionally immutable, so mistakes are more expensive than in registry-governed repos.

## Dependencies

- `nana-core-v6` directory, prices, and token lookup
- Uniswap V4 hook and pool-manager interfaces
- Downstream consumers such as `nana-buyback-hook-v6`

## Safe Change Guide

- Treat routing logic and oracle logic as one system. A quote is only useful if the corresponding execution path honors its assumptions.
- Review changes under three compositions: standalone swaps, buyback-hook integration, and low-history oracle warmup.
- Avoid mutable config creep; this repo is strongest when it stays constructor-configured and predictable.
