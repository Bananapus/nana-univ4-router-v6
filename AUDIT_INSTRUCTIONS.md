# Audit Instructions -- univ4-router-v6

You are auditing a Uniswap V4 hook that provides intelligent price comparison and routing between V4 pool swaps and Juicebox protocol operations (minting via `pay()` or redeeming via `cashOutTokensOf()`). It also provides a TWAP oracle for all pools using this hook. Read [RISKS.md](./RISKS.md) first -- it documents all known risks, Nemesis audit findings, and trust assumptions. Then come back here.

## Scope

**In scope -- all Solidity in `src/`:**
```
src/JBUniswapV4Hook.sol     # Hook + router (~960 lines)
src/libraries/Oracle.sol    # TWAP oracle ring buffer (~394 lines)
```

**Out of scope:** Test files, OpenZeppelin/Uniswap/JB Core dependencies (assume correct), forge-std.

## Architecture

### JBUniswapV4Hook

A Uniswap V4 hook (`BaseHook`) that intercepts swaps to compare prices between the V4 pool and the Juicebox protocol. For every swap involving a JB project token, it:

1. Estimates the output from the V4 pool (using TWAP or spot price)
2. Estimates the output from Juicebox (minting or cashing out)
3. Routes to whichever gives the user more tokens
4. Records oracle observations for TWAP computation

The hook uses these V4 hook permissions:
- `afterInitialize` -- set up oracle on pool creation
- `beforeSwap` + `beforeSwapReturnDelta` -- intercept swaps, compare routes, optionally override with JB route
- `afterSwap` -- record oracle observation, enforce slippage for V4 routes
- `afterAddLiquidity` / `afterRemoveLiquidity` -- record oracle observations

Immutable dependencies: `TOKENS` (IJBTokens), `DIRECTORY` (IJBDirectory), `PRICES` (IJBPrices).

### Oracle Library

A ring buffer implementation for TWAP price tracking, adapted from Uniswap V3's oracle design. Stores `Observation` structs packed into 256 bits: `blockTimestamp` (uint32) + `tickCumulative` (int56) + `secondsPerLiquidityCumulativeX128` (uint160) + `initialized` (bool).

Key properties:
- Array size: `65_535` observations per pool
- Auto-growth: cardinality doubles at capacity (1 -> 2 -> 4 -> ... -> 256 cap)
- At most one observation per block (same-block writes are no-ops)
- Binary search for historical lookups
- Handles uint32 timestamp overflow (safe for 0 or 1 overflows)
- `tickCumulative` uses int56, good for ~1.4 years at max tick (887,272)

## Key Flows

### 1. Price Comparison and Routing (`_beforeSwap`)

Called by V4 PoolManager on every swap. The routing logic:

```
Swap initiated
  |
  v
Decode hookData -> amountOutMin (exactly 32 bytes, uint256)
  |
  v
Reject exact-output swaps (amountSpecified > 0)
  |
  v
Identify token roles via TOKENS.projectIdOf()
  |
  +-- tokenIn is JB token  -> isSellingJBToken = true
  +-- tokenOut is JB token -> isBuyingJBToken = true
  +-- neither              -> passthrough to V4 (ZERO_DELTA)
  |
  v
Calculate Juicebox expected output:
  +-- Buying:  calculateExpectedTokensWithCurrency(buyProjectId, tokenIn, amountIn)
  +-- Selling: calculateExpectedOutputFromSelling(sellProjectId, amountIn, tokenOut, terminal)
  |
  v
Calculate V4 expected output:
  estimateUniswapOutput(poolId, key, amountIn, zeroForOne)
    -> Uses TWAP price if available (>= 2 observations, oldest > 30min ago)
    -> Falls back to spot price if TWAP unavailable
  |
  v
Compare: JB output > V4 output AND terminal is available?
  +-- YES: _routeThroughJuicebox() -> return custom BeforeSwapDelta
  +-- NO:  return ZERO_DELTA (let V4 execute normally)
```

### 2. JB Buy Route (Minting)

When buying JB tokens and JB gives a better rate:

```
_routeThroughJuicebox(isBuying = true)
  |
  v
poolManager.take(inputCurrency, amountIn)  -- withdraw input from PoolManager
  |
  v
IERC20.forceApprove(terminal, amountIn)    -- approve terminal to pull tokens
  |
  v
terminal.pay(projectId, token, amountIn,   -- pay into JB project
             beneficiary=address(this),
             minReturnedTokens=amountOutMin)
  |
  v
outputReceived = tokens minted to hook
  |
  v
_settleOutput(outputCurrency, outputReceived)  -- deposit output back to PoolManager
  |
  v
return BeforeSwapDelta(+amountIn, -outputReceived)
```

### 3. JB Sell Route (Cashing Out)

When selling JB tokens and JB gives a better rate:

```
_routeThroughJuicebox(isBuying = false)
  |
  v
poolManager.take(inputCurrency, amountIn)  -- withdraw JB tokens from PoolManager
  |
  v
terminal.cashOutTokensOf(
    holder=address(this),
    projectId, cashOutCount=amountIn,
    tokenToReclaim=normalizedTokenOut,
    minTokensReclaimed=amountOutMin,
    beneficiary=address(this))
  |
  v
outputReceived = terminal tokens received
  |
  v
_settleOutput(outputCurrency, outputReceived)  -- deposit output back to PoolManager
  |
  v
return BeforeSwapDelta(+amountIn, -outputReceived)
```

### 4. V4 Route (Passthrough)

When V4 gives a better rate or no JB token is involved:

```
_beforeSwap returns ZERO_DELTA
  |
  v
V4 PoolManager executes the swap normally (AMM)
  |
  v
_afterSwap:
  - Validates amountOutMin against actual swap delta
  - Records oracle observation
```

### 5. Oracle Observation Recording (`_recordObservation`)

Called after every swap, liquidity add, and liquidity remove:

```
Read current tick and liquidity from poolManager.getSlot0/getLiquidity
  |
  v
Check if cardinality growth needed:
  (cardinality == cardinalityNext AND index == cardinality - 1)
  -> Double cardinality (cap at 256)
  -> Oracle.grow() pre-allocates storage slots
  |
  v
Oracle.write():
  - Skip if same block as last observation
  - Transform: tickCumulative += tick * timeDelta
  - Advance index (wrapping around ring buffer)
```

### 6. TWAP Computation (`_getTWAPSqrtPrice`)

```
Read observation state for pool
  |
  v
Need >= 2 observations? No -> return 0 (spot fallback)
  |
  v
Oldest observation old enough (> 30min ago)? No -> return 0 (spot fallback)
  |
  v
observeTWAP(poolId, TWAP_PERIOD=1800, tick, index, liquidity, cardinality)
  -> Oracle.observeSingle(0 secondsAgo) for current tickCumulative
  -> Oracle.observeSingle(1800 secondsAgo) for past tickCumulative
  -> arithmeticMeanTick = (current - past) / secondsAgo
  -> Round toward negative infinity for negative ticks
  |
  v
TickMath.getSqrtPriceAtTick(arithmeticMeanTick) -> sqrtPriceX96
```

## Oracle Mechanics

The oracle is critical to routing security. Understand these properties:

**Ring buffer**: Fixed-size array per pool (`observations[poolId][65_535]`). Observations overwrite the oldest when the buffer is full. The `states[poolId]` struct tracks `index`, `cardinality`, and `cardinalityNext`.

**Auto-growth**: When the buffer fills (`index == cardinality - 1` and `cardinality == cardinalityNext`), `_recordObservation` doubles `cardinalityNext` up to 256. `Oracle.grow()` pre-allocates storage slots. Actual cardinality increases when new writes reach the expanded region.

**Warmup period**: A new pool starts with cardinality 1. The first swap adds a second observation. TWAP becomes available only after the oldest observation is at least `TWAP_PERIOD` (1800) seconds old AND cardinality >= 2.

**Same-block dedup**: `Oracle.write()` is a no-op if `last.blockTimestamp == blockTimestamp`. This prevents the same block from overwriting observations.

**Binary search**: `Oracle.binarySearch()` finds the two observations surrounding a target timestamp. `observeSingle()` interpolates between them for intermediate timestamps.

**Timestamp overflow**: `Oracle.lte()` handles uint32 overflow (wraps every ~136 years). Safe for 0 or 1 overflows.

## Key Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `TWAP_PERIOD` | 1,800 | 30-minute TWAP window |
| `TWAP_SLIPPAGE_DENOMINATOR` | 10,000 | Denominator for slippage calculations |
| `UNISWAP_NATIVE_ETH` | `address(0)` | V4's native ETH representation |
| `JB_NATIVE_TOKEN` | `0x...EEEe` | JB's native token constant |

## Priority Audit Areas

### 1. Flash-Accounting Correctness (Highest Priority)

The `_routeThroughJuicebox` function operates within V4's flash-accounting context:
- `poolManager.take()` withdraws tokens (creates a debt the hook must repay)
- External JB terminal call transforms tokens
- `_settleOutput()` deposits output tokens (repays a credit to the swapper)

Verify:
- If the JB terminal call reverts, the entire swap reverts atomically (PoolManager balance check at `unlock()` end)
- If the JB terminal silently consumes tokens without returning output, `_settleOutput(0)` causes a PoolManager balance mismatch and revert
- The `BeforeSwapDelta` returned from `_beforeSwap` correctly represents the hook's token movements: `+amountIn` (hook takes specified token), `-outputReceived` (hook gives unspecified token)
- For V4 routes (ZERO_DELTA), the hook neither takes nor settles anything -- V4 handles the swap normally

### 2. TWAP Manipulation

The TWAP uses a 30-minute window. Verify:
- An attacker sustaining price manipulation for 30 minutes faces significant arbitrage losses (quantify the cost)
- The spot price fallback (when TWAP unavailable) is trivially manipulable. Verify that `amountOutMin` protects users during the warmup window.
- Can an attacker force a pool back into spot-price-only mode by manipulating observation state?
- The auto-growth mechanism: can an attacker cause excessive gas costs by triggering cardinality growth at inopportune times?
- `Oracle.write()` deduplication: can an attacker exploit the same-block no-op to prevent observation recording?

### 3. Spot Price Fallback Window

When `_getTWAPSqrtPrice` returns 0, `estimateUniswapOutput` falls back to `poolManager.getSlot0()` spot price. This window exists:
- From pool initialization until observations span 30 minutes
- On pools with very low trading activity

During this window, an attacker can:
1. Manipulate spot price in a single block
2. Force routing through a worse path
3. Sandwich the victim's swap

Verify that `amountOutMin` (decoded from hookData) provides sufficient protection.

### 4. Routing Decision Accuracy

The hook compares JB expected output vs V4 expected output. Verify:
- `calculateExpectedTokensWithCurrency()`: correctly handles currency conversion via `PRICES.pricePerUnitOf()`, reserved percent deduction, and payment token decimal normalization
- `calculateExpectedOutputFromSelling()`: uses total surplus (all terminals) which may overestimate for projects with `useTotalSurplusForCashOuts = false`. The fee deduction uses `terminal.FEE()` even for feeless addresses (conservative by design).
- `estimateUniswapOutput()`: TWAP-to-price conversion handles overflow correctly (two paths: `sqrtPriceX96 <= uint128.max` and overflow path via `FullMath.mulDiv`). V4 pool fee is deducted from estimate.
- Both-JB-tokens case: only buy-side is evaluated. Can an attacker exploit the missing sell-side comparison?

### 5. BeforeSwapDelta Sign Convention

V4 uses a specific sign convention for `BeforeSwapDelta`:
- `deltaSpecified > 0` means the hook takes the specified (input) token
- `deltaUnspecified < 0` means the hook provides the unspecified (output) token

`_createSwapDelta` returns `toBeforeSwapDelta(+int128(amountIn), -int128(amountOut))`. Verify this is correct for both swap directions (`zeroForOne = true` and `false`).

### 6. Slippage Protection

Slippage is enforced at two points:
- `_beforeSwap`: For JB routes, `amountOutMin` is passed to `terminal.pay()` / `terminal.cashOutTokensOf()` as `minReturnedTokens` / `minTokensReclaimed`
- `_afterSwap`: For V4 routes, the actual swap delta is checked against `amountOutMin`

Verify:
- `_afterSwap` correctly extracts the output amount from `BalanceDelta` for both swap directions
- The `rawOutput != 0` check correctly skips validation for JB-routed swaps (where delta is zero)
- Both positive and negative `rawOutput` values are handled (`rawOutput < 0 ? uint256(-rawOutput) : uint256(rawOutput)`)
- `hookData.length == 32` requirement in `_beforeSwap` vs `hookData.length >= 32` in `_afterSwap` -- is the inconsistency safe?

### 7. Token Normalization

The hook maps between V4's native ETH (`address(0)`) and JB's native token constant (`0x...EEEe`) via `_normalizeToken()`. Verify:
- All JB terminal calls use normalized tokens
- `TOKENS.projectIdOf()` is called with raw token addresses (V4 convention) -- does this work for native ETH?
- `_getPrimaryTerminal()` normalizes before lookup
- `_settleOutput()` uses the V4 currency (not normalized) -- correct for PoolManager interaction

### 8. Oracle State Consistency

- `_afterInitialize` sets up the first observation. Verify the initial state (`index=0, cardinality=1, cardinalityNext=1`) is correct.
- `_recordObservation` reads pool state (`getSlot0`, `getLiquidity`) and writes to the observation array. These are not atomic with the swap/liquidity change. Is there a window where the recorded tick/liquidity is stale?
- Can the oracle state diverge between `states[poolId]` and the actual `observations[poolId]` array?
- What happens if `observations[poolId].grow()` is called with `current == 0`? (Reverts with `Oracle_CardinalityCannotBeZero`)

## Invariants to Verify

1. **Flash-accounting balance**: After every swap (whether V4 or JB routed), PoolManager's balance check succeeds. No tokens are created or destroyed.
2. **TWAP monotonicity**: `tickCumulative` is monotonically non-decreasing for non-negative ticks and correctly accumulates for all tick values.
3. **Oracle cardinality**: `cardinality <= cardinalityNext <= 256` always holds. `index < cardinality` always holds.
4. **Observation ordering**: The ring buffer maintains chronological order within the active window.
5. **Route selection**: If JB gives strictly more output than V4, JB route is selected. If V4 gives equal or more, V4 route is selected.
6. **Slippage enforcement**: No swap completes with output below `amountOutMin` (for both V4 and JB routes).
7. **No token leakage**: The hook never retains tokens between transactions (all taken tokens are either settled back or cause a revert).

## Testing Setup

```bash
cd univ4-router-v6
npm install
forge build
forge test

# Run specific test suites
forge test --match-contract JBUniswapV4Hook -vvv
forge test --match-contract OracleDeepTest -vvv
forge test --match-contract ThreeWayRouting -vvv
forge test --match-contract SlippageTolerance -vvv
forge test --match-contract StressAndOrderOfMagnitude -vvv

# Run fork tests (requires RPC)
forge test --match-contract Fork -vvv

# Write a PoC
forge test --match-path test/audit/ExploitPoC.t.sol -vvv
```

The test suite includes:
- Unit tests for routing decisions, oracle mechanics, and slippage protection
- Three-way routing tests (V4 vs JB buy vs JB sell)
- Oracle deep tests (14 tests: init, write, cardinality growth, TWAP, warmup)
- Stress tests for extreme amounts and edge cases
- Regression tests for previously found issues

Go break it.
