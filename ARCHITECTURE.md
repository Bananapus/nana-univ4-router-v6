# univ4-router-v6 — Architecture

## Purpose

Official Juicebox integration for Uniswap V4 that provides intelligent price comparison and optimal routing between Uniswap V4 pools, Uniswap V3 pools, and Juicebox project minting. Uses TWAP oracles to protect against manipulation. Implements a Uniswap V4 hook (BaseHook) with a built-in V4 TWAP oracle.

## Contract Map

```
src/
├── JBUniswapV4Hook.sol  — BaseHook: price comparison (V3 vs V4 vs JB mint), TWAP oracle, swap routing
├── interfaces/
│   ├── IWETH.sol
│   ├── IUniswapV3Factory.sol
│   └── IUniswapV3Pool.sol
└── libraries/
    └── Oracle.sol       — V4 TWAP oracle implementation (ring buffer observations)
```

## Key Data Flows

### Price Comparison and Routing
```
Payment arrives → JBUniswapV4Hook consulted
  → Calculate tokens from JB minting (weight-based)
  → Query V4 pool TWAP price
  → Query V3 pool TWAP price (if available)
  → Select route with highest token output:
    1. JB direct mint (if weight gives best rate)
    2. V4 swap (if V4 pool has best price)
    3. V3 swap (if V3 pool has best price)
  → Execute selected route
```

### V4 Hook Lifecycle
```
Pool creation → JBUniswapV4Hook registered as hook
  → beforeSwap: Record TWAP observation, compare prices
  → afterSwap: Update oracle state
  → beforeInitialize / afterInitialize: Pool setup
```

### TWAP Oracle
```
Each swap → Oracle.write(tick, liquidity, timestamp)
  → Ring buffer of 65,535 observations
  → TWAP queried via Oracle.consult(secondsAgo)
  → Protects against single-block price manipulation
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| V4 Hook | `BaseHook` | Uniswap V4 pool hook (before/after swap) |
| V3 callback | `IUniswapV3SwapCallback` | V3 swap execution |
| Price oracle | `Oracle` | Built-in TWAP for V4 pools |

## Dependencies
- `@bananapus/core-v6` — Core protocol interfaces
- `@openzeppelin/contracts` — SafeERC20
- `@openzeppelin/uniswap-hooks` — CurrencySettler
- `@prb/math` — FullMath
- `@uniswap/v3-core` — V3 pool interfaces
- `@uniswap/v3-periphery` — V3 oracle library
- `@uniswap/v4-core` — Pool manager, hooks, state library
- `@uniswap/v4-periphery` — BaseHook
- `solmate` — Utility contracts
