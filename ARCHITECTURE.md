# univ4-router-v6 — Architecture

## Purpose

Official Juicebox integration for Uniswap V4 that provides intelligent price comparison and optimal routing between Uniswap V4 pools and Juicebox project minting/cashout. Uses a built-in TWAP oracle to protect against manipulation. Implements a Uniswap V4 hook (BaseHook) with IGeomeanOracle-compatible `observe()` for external TWAP queries.

## Contract Map

```
src/
├── JBUniswapV4Hook.sol  — BaseHook: price comparison (V4 vs JB), TWAP oracle, swap routing
└── libraries/
    └── Oracle.sol       — V4 TWAP oracle implementation (ring buffer observations)
```

## Key Data Flows

### Price Comparison and Routing
```
Swap arrives → JBUniswapV4Hook._beforeSwap()
  → Is a JB project token involved?
    NO → return ZERO_DELTA (normal V4 swap)
    YES →
      → Buying: calculateExpectedTokensWithCurrency (weight × price - reserved rate)
      → Selling: calculateExpectedOutputFromSelling (total surplus bonding curve - fee)
      → V4: estimateUniswapOutput (TWAP-based, 30-min window)
      → Pick highest output:
        JB → take from PoolManager, pay/cashOut via terminal, settle back
        V4 → return ZERO_DELTA, let V4 AMM execute normally
```

### Selling Estimation (calculateExpectedOutputFromSelling)
```
terminal.STORE() → store  [try-catch: returns 0 on failure]
  → store.currentReclaimableSurplusOf(
      empty terminals[],        // uses total surplus across all terminals
      empty accountingContexts[] // store fetches from directory
    )                           [try-catch: returns 0 on failure]
  → Deduct protocol fee (IJBFeeTerminal.FEE() / MAX_FEE)
  → Return net reclaim amount
```

### V4 Hook Lifecycle
```
Pool creation → JBUniswapV4Hook registered as hook
  → afterInitialize: Initialize oracle ring buffer
  → beforeSwap: Compare prices, route to best option
  → afterSwap: Record oracle observation, validate V4 slippage
  → afterAddLiquidity: Record oracle observation
  → afterRemoveLiquidity: Record oracle observation
```

### TWAP Oracle
```
Each swap/liquidity event → Oracle.write(tick, liquidity, timestamp)
  → Ring buffer of 65,535 observations
  → TWAP queried via _getTWAPSqrtPrice (30-min window)
  → Falls back to spot price if < 2 observations or < 30 min history
  → Protects against single-block price manipulation
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| V4 Hook | `BaseHook` | Uniswap V4 pool hook (before/after swap, liquidity, initialize) |
| Price oracle | `Oracle` | Built-in TWAP for V4 pools, IGeomeanOracle-compatible `observe()` |

## Composition with JBBuybackHook

This hook is designed to serve as both the V4 pool hook and the `ORACLE_HOOK` for `JBBuybackHook` on the same pool. The buyback hook queries `observe()` for TWAP data and executes swaps through this hook. When the routing logic in `_beforeSwap` tries to route back through Juicebox (re-entering the buyback hook), a `_routing` reentrancy guard prevents infinite recursion. The buyback hook's try/catch catches the revert and falls back to minting.

## Dependencies
- `@bananapus/core-v6` — Core protocol interfaces (IJBTokens, IJBDirectory, IJBController, IJBPrices, IJBTerminalStore, IJBMultiTerminal)
- `@openzeppelin/contracts` — SafeERC20, IERC20Metadata
- `@openzeppelin/uniswap-hooks` — CurrencySettler
- `@prb/math` — FullMath
- `@uniswap/v4-core` — Pool manager, hooks, state library, TickMath
- `@uniswap/v4-periphery` — BaseHook
