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
terminal.previewCashOutFrom(holder, projectId, tokenAmountIn, outputToken, beneficiary, metadata)
  [try-catch: returns 0 on failure]
  → grossReclaim from the terminal's cash-out preview (incorporates data-hook effects)
  → Deduct protocol fee: grossReclaim - grossReclaim * FEE / MAX_FEE
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
  → Ring buffer of 65,535 observations, auto-growing up to 1024 retained entries per pool
  → TWAP queried via _getTWAPSqrtPrice (30-min window)
  → Falls back to spot price (returns 0 → caller reads slot0) when:
    1. cardinality < 2 (pool just initialized, only one observation exists), OR
    2. oldest observation is newer than (block.timestamp - TWAP_PERIOD),
       i.e., the pool has not accumulated 30 minutes of history yet
  → Once both conditions are satisfied, TWAP is always used
  → Protects against single-block price manipulation
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| V4 Hook | `BaseHook` | Uniswap V4 pool hook (before/after swap, liquidity, initialize) |
| Price oracle | `Oracle` | Built-in TWAP for V4 pools, IGeomeanOracle-compatible `observe()` |

## Composition with JBBuybackHook

This hook is designed to serve as both the V4 pool hook and the `ORACLE_HOOK` for `JBBuybackHook` on the same pool. The buyback hook queries `observe()` for TWAP data and executes swaps through this hook. When the routing logic in `_beforeSwap` tries to route back through Juicebox (re-entering the buyback hook), a `_routing` reentrancy guard prevents infinite recursion. The buyback hook's try/catch catches the revert and falls back to minting.

## Design Decisions

**30-minute TWAP window.** A 30-minute window (`TWAP_PERIOD = 1800`) makes single-block or short-duration price manipulation prohibitively expensive for an attacker while remaining responsive enough to track genuine market moves. Shorter windows (e.g., 5 minutes) are cheaper to manipulate; longer windows (e.g., 2 hours) would lag real price changes and produce suboptimal routing decisions.

**Ring buffer: 65,535 max slots, 1,024 retained observations.** The `Observation[65_535]` storage array matches Uniswap V3's proven oracle design. The `MAX_TWAP_CARDINALITY = 1024` cap keeps auto-growth bounded — 1,024 observations at 2-second block times covers ~34 minutes, enough to keep a full 30-minute TWAP window available even on fast-block L2s, without unbounded SSTORE costs. The buffer doubles on demand (1 → 2 → 4 → ... → 1024) so new pools pay only for what they need.

**Spot price fallback for new pools.** `_getTWAPSqrtPrice` returns 0 when the pool has fewer than 2 observations or less than 30 minutes of history. The caller (`estimateUniswapOutput`) then reads the current spot price from `poolManager.getSlot0()`. This allows newly created pools to participate in routing immediately rather than being permanently excluded until they accumulate history. The trade-off — spot price is manipulable — is acceptable because new pools typically have low liquidity and low routing volume, limiting the economic impact.

**Custom `_routing` flag vs. OpenZeppelin `ReentrancyGuard`.** The `_routing` boolean prevents infinite recursion when `_beforeSwap` routes through Juicebox, which may trigger the buyback hook to swap back through this hook. OpenZeppelin's `ReentrancyGuard` was not used because the hook already executes inside the PoolManager's `unlock` callback, which has its own reentrancy control. Mixing OZ's `_status` slot with the PoolManager's transient-storage lock can create false positives (legitimate unlock callbacks rejected) or mask real issues. A single-purpose flag scoped to Juicebox routing is simpler, cheaper (one SSTORE vs. two), and makes the protected code path explicit.

**Sell-side data-hook awareness.** `calculateExpectedOutputFromSelling` calls `previewCashOutFrom` on the terminal rather than computing a static bonding-curve estimate. This allows sell-side estimates to incorporate any configured cash-out data-hook effects, producing more accurate routing when projects have custom cash-out logic. Falls back to returning 0 if previewing is unavailable, which conservatively biases toward the V4 pool swap.

## Dependencies
- `@bananapus/core-v6` — Core protocol interfaces (IJBTokens, IJBDirectory, IJBController, IJBPrices, IJBTerminalStore, IJBMultiTerminal)
- `@openzeppelin/contracts` — SafeERC20, IERC20Metadata
- `@openzeppelin/uniswap-hooks` — CurrencySettler
- `@prb/math` — FullMath
- `@uniswap/v4-core` — Pool manager, hooks, state library, TickMath
- `@uniswap/v4-periphery` — BaseHook
