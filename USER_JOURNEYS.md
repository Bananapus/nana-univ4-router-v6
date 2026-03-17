# User Journeys -- univ4-router-v6

Concrete end-to-end flows through the V4 routing hook. Each journey traces the exact function calls, state changes, and external interactions.

## Journey 1: Swap Through Hooked Pool -- V4 Route Wins

**Actor:** User swapping tokens through a Uniswap V4 pool that uses JBUniswapV4Hook.
**Goal:** Swap token A for token B where the V4 pool gives a better rate than Juicebox.

### Precondition

A V4 pool exists with `hooks = JBUniswapV4Hook`. One of the pool's tokens is a JB project token. The oracle has sufficient observations for TWAP (cardinality >= 2, oldest observation > 30 minutes old). The V4 pool has enough liquidity to offer a better rate than JB minting/cashing out.

### Steps

1. **User initiates a swap via a router contract (e.g., Universal Router or custom JuiceboxSwapRouter)**

   - The router calls `poolManager.swap()` with `hookData = abi.encode(amountOutMin)`
   - `hookData` must be exactly 32 bytes encoding a uint256

2. **PoolManager calls `_beforeSwap(sender, key, params, hookData)`**

   - Decodes `amountOutMin` from hookData
   - Rejects exact-output swaps (`params.amountSpecified > 0` reverts)
   - Computes `amountIn = uint256(-params.amountSpecified)`
   - Identifies which token is a JB project token via `TOKENS.projectIdOf()`
   - Determines if buying or selling JB tokens

3. **JB route estimation**

   - Buying: `calculateExpectedTokensWithCurrency(projectId, tokenIn, amountIn)`
     - Reads ruleset weight, reserved percent, and base currency
     - Converts payment amount to 18 decimals
     - Applies price conversion if payment currency differs from base currency
     - Deducts reserved percent
   - Selling: `calculateExpectedOutputFromSelling(projectId, amountIn, tokenOut, terminal)`
     - Reads reclaimable surplus from terminal store
     - Deducts protocol fee (2.5%)

4. **V4 route estimation via `estimateUniswapOutput()`**

   - Calls `_getTWAPSqrtPrice(poolId)`:
     - Reads observation state, verifies cardinality >= 2
     - Checks oldest observation is old enough for 30-minute TWAP
     - Calls `observeTWAP()` to get arithmetic mean tick over TWAP_PERIOD
     - Converts to `sqrtPriceX96TWAP`
   - Calculates expected output from TWAP price
   - Deducts V4 pool fee from estimate

5. **Comparison: V4 wins**

   - `juiceboxBetterThanV4 = false` (V4 gives more output)
   - Emits `BestRouteSelected(poolId, 0, uniswapV4ExpectedTokens, caller)`
   - Returns `(BaseHook.beforeSwap.selector, ZERO_DELTA, 0)`

6. **V4 PoolManager executes the swap normally (AMM mechanics)**

7. **PoolManager calls `_afterSwap(sender, key, params, delta, hookData)`**

   - Decodes `amountOutMin` from hookData
   - Extracts output amount from `delta` based on swap direction
   - Checks: `rawOutput != 0` (this is a real V4 swap, not JB-routed)
   - Verifies `outputAmount >= amountOutMin`, reverts with `InsufficientOutput` if not
   - Calls `_recordObservation(poolId)` to update the oracle

### Result

User receives tokens from the V4 AMM swap. Slippage protection is enforced in `_afterSwap`. A new oracle observation is recorded.

### What to verify

- The TWAP estimate accurately predicts V4 output (not systematically over- or under-estimating).
- Slippage check in `_afterSwap` correctly interprets V4's sign convention (output is negative in delta).
- The oracle observation uses the post-swap tick and liquidity values.
- If `amountOutMin = 0`, the swap proceeds without slippage protection (by design).

---

## Journey 2: Swap Through Hooked Pool -- JB Route Wins (Mint)

**Actor:** User swapping a payment token (ETH, USDC) for a JB project token.
**Goal:** Get more JB project tokens by routing through JB minting instead of the V4 pool.

### Precondition

The JB project has a favorable minting rate (high weight, low reserved percent) that exceeds what the V4 pool offers. The project has a valid terminal for the payment token.

### Steps

1. **Same as Journey 1, Steps 1-4**

2. **Comparison: JB wins (buying)**

   - `juiceboxBetterThanV4 = true` (JB gives more tokens)
   - Emits `BestRouteSelected(poolId, 1, juiceboxExpectedOutput, caller)`

3. **`_routeThroughJuicebox(projectId, inputCurrency, outputCurrency, amountIn, isBuying=true, terminal, amountOutMin)`**

   a. **Take input from PoolManager**: `poolManager.take(inputCurrency, address(this), amountIn)`
      - PoolManager transfers input tokens to the hook
      - Creates a flash-accounting debt

   b. **Approve terminal**: `IERC20(tokenIn).forceApprove(terminal, amountIn)` (skipped for native ETH)

   c. **Pay into JB project**:
      ```
      terminal.pay{value: payValue}(
          projectId, token, amountIn,
          beneficiary = address(this),
          minReturnedTokens = amountOutMin,
          memo = "", metadata = ""
      )
      ```
      - Terminal records the payment, JB controller mints project tokens to `address(this)`
      - Returns `outputReceived` (number of tokens minted)

   d. **Settle output to PoolManager**: `CurrencySettler.settle(outputCurrency, poolManager, address(this), outputReceived, false)`
      - Transfers project tokens from hook to PoolManager
      - Resolves the flash-accounting credit

4. **Return `BeforeSwapDelta(+amountIn, -outputReceived)`**

   - `+amountIn`: hook took the specified (input) tokens
   - `-outputReceived`: hook provided the unspecified (output) tokens
   - PoolManager uses this delta instead of executing the AMM swap

5. **`_afterSwap` is called but delta is zero for the AMM portion**

   - `rawOutput == 0` for the AMM delta (the hook handled everything)
   - Slippage check is skipped (was already enforced by `terminal.pay(minReturnedTokens)`)
   - Oracle observation is still recorded

### Result

User receives JB project tokens minted by paying into the project. The V4 pool is bypassed entirely. The oracle still records the current pool state.

### What to verify

- The flash-accounting cycle is complete: take + settle balances correctly.
- `terminal.pay()` receives the correct token and amount (especially for native ETH vs ERC-20).
- If `terminal.pay()` reverts, the entire swap reverts (PoolManager balance check fails).
- The `BeforeSwapDelta` correctly represents the hook's token movements for both `zeroForOne = true` and `false`.
- JB minting respects `amountOutMin` via `minReturnedTokens`.
- No tokens are retained by the hook after the swap completes.

---

## Journey 3: Swap Through Hooked Pool -- JB Route Wins (Cashout)

**Actor:** User swapping JB project tokens for a payment token (ETH, USDC).
**Goal:** Get more payment tokens by routing through JB cashout instead of the V4 pool.

### Precondition

The JB project has favorable cashout conditions (low tax rate, high surplus) that exceed what the V4 pool offers. The project's terminal holds enough of the output token.

### Steps

1. **Same as Journey 1, Steps 1-4** (but `isSellingJBToken = true`)

   - `calculateExpectedOutputFromSelling()` queries `currentReclaimableSurplusOf()` and deducts protocol fee

2. **Comparison: JB wins (selling)**

   - `juiceboxBetterThanV4 = true`

3. **`_routeThroughJuicebox(projectId, inputCurrency, outputCurrency, amountIn, isBuying=false, terminal, amountOutMin)`**

   a. **Take JB tokens from PoolManager**: `poolManager.take(inputCurrency, address(this), amountIn)`

   b. **No approval needed** -- the hook is the token holder and will call `cashOutTokensOf` as the holder

   c. **Cash out JB tokens**:
      ```
      terminal.cashOutTokensOf(
          holder = address(this),
          projectId, cashOutCount = amountIn,
          tokenToReclaim = normalizedTokenOut,
          minTokensReclaimed = amountOutMin,
          beneficiary = payable(address(this)),
          metadata = ""
      )
      ```
      - Terminal burns JB tokens, calculates reclaim via bonding curve, transfers output tokens to hook
      - Returns `outputReceived` (payment tokens received)

   d. **Settle output to PoolManager**: `CurrencySettler.settle(outputCurrency, poolManager, address(this), outputReceived, false)`

4. **Return `BeforeSwapDelta(+amountIn, -outputReceived)`**

5. **`_afterSwap` records oracle observation (slippage already enforced)**

### Result

User receives payment tokens from JB cashout. JB tokens are burned. The V4 pool is bypassed.

### What to verify

- The hook is recognized as a valid holder of JB tokens for `cashOutTokensOf()`.
- Token normalization: `tokenOut = address(0)` (V4 native ETH) is mapped to `JB_NATIVE_TOKEN` for the terminal call.
- The cashout route correctly accounts for the 2.5% JB protocol fee in its estimate.
- If the estimate overestimates (e.g., due to total surplus vs local surplus mismatch), `minTokensReclaimed = amountOutMin` prevents the swap from completing at a bad rate.
- For native ETH output: the terminal sends ETH to the hook, and the hook settles it to PoolManager correctly.

---

## Journey 4: Pool Initialization with Oracle

**Actor:** Anyone initializing a V4 pool with this hook (typically the LP split hook deployer or a direct call to PoolManager/PositionManager).
**Goal:** Create a new pool and initialize its TWAP oracle.

### Steps

1. **Pool is initialized via `PositionManager.initializePool(key, sqrtPriceX96)` or `PoolManager.initialize(key, sqrtPriceX96)`**

   - `key.hooks = address(JBUniswapV4Hook)`

2. **PoolManager calls `_afterInitialize(sender, key, sqrtPriceX96, tick)`**

   - Computes `poolId = key.toId()`
   - Initializes the oracle: `observations[poolId].initialize(uint32(block.timestamp))`
     - Writes first observation at slot 0: `{blockTimestamp, tickCumulative=0, secondsPerLiquidityCumulativeX128=0, initialized=true}`
     - Returns `cardinality = 1, cardinalityNext = 1`
   - Stores initial state: `states[poolId] = {index: 0, cardinality: 1, cardinalityNext: 1}`

3. **Oracle warmup begins**

   - The pool now has 1 observation. TWAP requires >= 2 observations AND the oldest must be > 30 minutes old.
   - First swap/liquidity event will add a second observation (if in a different block).
   - After 30 minutes of observations, TWAP becomes available.
   - Until then, `_getTWAPSqrtPrice` returns 0 and `estimateUniswapOutput` falls back to spot price.

### Result

Pool is created with a single oracle observation. TWAP is not yet available -- all routing decisions use spot price during the warmup period.

### What to verify

- The initial observation is correctly written with zeroed cumulatives.
- The warmup period is exactly `TWAP_PERIOD` (1800 seconds) from the first observation.
- During warmup, the spot price fallback works correctly for routing decisions.
- If the pool was already initialized (e.g., by another call), `_afterInitialize` is not called again (V4 only calls `afterInitialize` once).
- Cardinality growth happens correctly after the first observation: second observation triggers growth from 1 to 2.

---

## Journey 5: Slippage Protection via hookData

**Actor:** User submitting a swap with a minimum output requirement.
**Goal:** Ensure the swap reverts if the output falls below the specified minimum.

### Encoding

```solidity
bytes memory hookData = abi.encode(uint256(amountOutMin));
// hookData is exactly 32 bytes
```

### JB Route Slippage

When JB routing is selected:

1. `amountOutMin` is decoded in `_beforeSwap`
2. Passed to `terminal.pay(minReturnedTokens = amountOutMin)` for buy routes
3. Passed to `terminal.cashOutTokensOf(minTokensReclaimed = amountOutMin)` for sell routes
4. JB terminal enforces the minimum internally -- reverts if output is insufficient
5. `_afterSwap` sees `rawOutput == 0` (no AMM delta) and skips its own check

### V4 Route Slippage

When V4 routing is selected:

1. `_beforeSwap` returns `ZERO_DELTA` -- V4 executes the swap normally
2. `_afterSwap` decodes `amountOutMin` from hookData
3. Extracts actual output from `delta`:
   - `zeroForOne`: output is `BalanceDeltaLibrary.amount1(delta)`
   - `!zeroForOne`: output is `BalanceDeltaLibrary.amount0(delta)`
4. Checks `rawOutput != 0` (confirms this is a real V4 swap)
5. Converts to absolute value: `outputAmount = rawOutput < 0 ? uint256(-rawOutput) : uint256(rawOutput)`
6. Reverts with `InsufficientOutput` if `outputAmount < amountOutMin`

### Edge Cases

- `amountOutMin = 0`: No slippage protection. JB terminal still executes, V4 slippage check passes trivially.
- `hookData.length != 32`: `_beforeSwap` reverts with `AmountOutMinRequired`. Swaps through this pool require hookData.
- `hookData.length >= 32` in `_afterSwap`: Only first 32 bytes are decoded. Extra bytes are ignored.
- Neither token is a JB token: `_beforeSwap` returns `ZERO_DELTA` immediately (no hookData check for non-JB tokens). Wait -- actually `hookData.length == 32` is checked before token identification. All swaps through this hook require exactly 32 bytes of hookData regardless of whether JB tokens are involved.

### What to verify

- The hookData length check happens before any routing logic. All swaps through hooked pools require `amountOutMin`.
- V4's sign convention is correctly handled in `_afterSwap`: output amounts should be negative (credits to user). The code handles both signs.
- For JB routes, slippage is enforced twice (terminal + potentially afterSwap). Verify the afterSwap check correctly skips for JB routes (rawOutput == 0).
- An attacker cannot bypass slippage by providing hookData longer than 32 bytes to `_beforeSwap` (it requires `== 32`).

---

## Journey 6: No JB Token Involved -- Pure V4 Swap

**Actor:** User swapping two non-JB tokens through a pool that happens to use this hook.
**Goal:** Swap normally through V4 while the oracle records observations.

### Steps

1. **Swap initiated with `hookData = abi.encode(uint256(0))` or any 32-byte hookData**

2. **`_beforeSwap` executes**

   - Decodes `amountOutMin`
   - Looks up `TOKENS.projectIdOf()` for both tokens -- returns 0 for both
   - `isSellingJBToken = false`, `isBuyingJBToken = false`
   - Enters the `else` branch: emits `RouteSelected(poolId, false, 0, caller)`
   - Returns `ZERO_DELTA` -- V4 handles the swap normally

3. **V4 AMM executes the swap**

4. **`_afterSwap` executes**

   - If `amountOutMin > 0`: validates actual output against minimum
   - Records oracle observation

### Result

A normal V4 swap. The hook is transparent except for oracle recording and optional slippage enforcement.

### What to verify

- `TOKENS.projectIdOf()` does not revert for non-JB tokens. If the token address does not implement `IJBToken`, the call could revert. The code does NOT wrap this in try-catch.
- This is a potential issue: if `tokenIn` or `tokenOut` is a plain ERC-20 that does not implement `IJBToken`, calling `TOKENS.projectIdOf(IJBToken(tokenIn))` may revert, breaking all swaps through the pool. Verify that `JBTokens.projectIdOf()` handles unknown tokens gracefully (returns 0 without reverting).
- Oracle observations are recorded even for non-JB swaps (correct behavior).
