# User Journeys -- univ4-router-v6

Concrete end-to-end flows through the V4 routing hook. Each journey traces the exact function calls, state changes, events, and external interactions.

---

## Journey 1: Swap Through Hooked Pool -- V4 Route Wins

**Entry point:** `PoolManager.swap(PoolKey key, SwapParams params, bytes hookData)` (triggers `_beforeSwap` / `_afterSwap` hooks on `JBUniswapV4Hook`)

**Who can call:** Anyone, via a router contract (e.g., Universal Router) that calls `poolManager.swap()`. The hook functions themselves are `internal override` -- only the PoolManager can invoke them through the BaseHook callback mechanism.

**Actor:** User swapping tokens through a Uniswap V4 pool that uses JBUniswapV4Hook.
**Goal:** Swap token A for token B where the V4 pool gives a better rate than Juicebox.

### Parameters

- **`key`** -- `PoolKey` identifying the V4 pool (currency0, currency1, fee, tickSpacing, hooks)
- **`params.zeroForOne`** -- `bool`, swap direction (true = token0 -> token1)
- **`params.amountSpecified`** -- `int256`, must be negative (exact-input). `amountIn = uint256(-params.amountSpecified)`
- **`params.sqrtPriceLimitX96`** -- `uint160`, V4 price limit for the AMM swap
- **`hookData`** -- `bytes`, must be exactly 32 bytes encoding `abi.encode(uint256 amountOutMin)`

### Precondition

A V4 pool exists with `hooks = JBUniswapV4Hook`. One of the pool's tokens is a JB project token. The oracle has sufficient observations for TWAP (cardinality >= 2, oldest observation > 30 minutes old). The V4 pool has enough liquidity to offer a better rate than JB minting/cashing out.

### Steps

1. **User initiates a swap via a router contract (e.g., Universal Router or custom JuiceboxSwapRouter)**

   - The router calls `poolManager.swap()` with `hookData = abi.encode(amountOutMin)`
   - `hookData` must be exactly 32 bytes encoding a uint256

2. **PoolManager calls `_beforeSwap(sender, key, params, hookData)`**

   - Checks `_routing == false` (reverts `JBUniswapV4Hook_ReentrantRouting` if true)
   - Decodes `amountOutMin` from hookData (reverts `JBUniswapV4Hook_AmountOutMinRequired` if `hookData.length != 32`)
   - Rejects exact-output swaps (`params.amountSpecified > 0` reverts `JBUniswapV4Hook_ExactOutputSwapsNotSupported`)
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
     - Uses `previewCashOutFrom` simulation when available; falls back to returning 0 on failure
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
   - Returns `(BaseHook.beforeSwap.selector, ZERO_DELTA, 0)`

6. **V4 PoolManager executes the swap normally (AMM mechanics)**

7. **PoolManager calls `_afterSwap(sender, key, params, delta, hookData)`**

   - Decodes `amountOutMin` from hookData
   - Extracts output amount from `delta` based on swap direction
   - Checks: `rawOutput != 0` (this is a real V4 swap, not JB-routed)
   - Verifies `outputAmount >= amountOutMin`, reverts with `JBUniswapV4Hook_InsufficientOutput` if not
   - Calls `_recordObservation(poolId)` to update the oracle

### State changes

1. `observations[poolId][newIndex]` -- new `Oracle.Observation` written with current `blockTimestamp`, `tickCumulative`, `secondsPerLiquidityCumulativeX128`, `initialized = true`
2. `states[poolId].index` -- updated to `newIndex`
3. `states[poolId].cardinality` -- may increase if `cardinalityNext > cardinality` and index wraps
4. `states[poolId].cardinalityNext` -- may double (up to `MAX_TWAP_CARDINALITY = 1024`) if at capacity

### Events

1. `BestRouteSelected(poolId, 0, uniswapV4ExpectedTokens, msg.sender)` -- route type 0 = V4 selected
2. `RouteSelected(poolId, false, uniswapV4ExpectedTokens, msg.sender)` -- V4 route confirmed

### Edge cases

- `JBUniswapV4Hook_AmountOutMinRequired()` -- hookData is not exactly 32 bytes
- `JBUniswapV4Hook_ExactOutputSwapsNotSupported()` -- `params.amountSpecified > 0`
- `JBUniswapV4Hook_InsufficientOutput()` -- V4 swap output < `amountOutMin`
- `JBUniswapV4Hook_ReentrantRouting()` -- `_routing` flag is already true
- `amountOutMin = 0` -- swap proceeds without slippage protection
- TWAP not available (cardinality < 2 or oldest observation too recent) -- falls back to spot price from `poolManager.getSlot0()`

### What to verify

- The TWAP estimate accurately predicts V4 output (not systematically over- or under-estimating).
- Slippage check in `_afterSwap` correctly interprets V4's sign convention (output is negative in delta).
- The oracle observation uses the post-swap tick and liquidity values.
- If `amountOutMin = 0`, the swap proceeds without slippage protection (by design).

---

## Journey 2: Swap Through Hooked Pool -- JB Route Wins (Mint)

**Entry point:** `PoolManager.swap(PoolKey key, SwapParams params, bytes hookData)` (triggers `_beforeSwap` / `_afterSwap` hooks on `JBUniswapV4Hook`)

**Who can call:** Anyone, via a router contract that calls `poolManager.swap()`. The hook functions are `internal override` -- only the PoolManager invokes them.

**Actor:** User swapping a payment token (ETH, USDC) for a JB project token.
**Goal:** Get more JB project tokens by routing through JB minting instead of the V4 pool.

### Parameters

- **`key`** -- `PoolKey` identifying the V4 pool
- **`params.zeroForOne`** -- `bool`, swap direction
- **`params.amountSpecified`** -- `int256`, must be negative (exact-input)
- **`hookData`** -- `bytes`, exactly 32 bytes: `abi.encode(uint256 amountOutMin)`

### Precondition

The JB project has a favorable minting rate (high weight, low reserved percent) that exceeds what the V4 pool offers. The project has a valid terminal for the payment token.

### Steps

1. **Same as Journey 1, Steps 1-4**

2. **Comparison: JB wins (buying)**

   - `juiceboxBetterThanV4 = true` (JB gives more tokens)

3. **`_routeThroughJuicebox(projectId, inputCurrency, outputCurrency, amountIn, isBuying=true, terminal, amountOutMin)`**

   a. **Set reentrancy guard**: `_routing = true`

   b. **Take input from PoolManager**: `poolManager.take(inputCurrency, address(this), amountIn)`
      - PoolManager transfers input tokens to the hook
      - Creates a flash-accounting debt

   c. **Approve terminal**: `IERC20(tokenIn).forceApprove(terminal, amountIn)` (skipped for native ETH)

   d. **Pay into JB project**:
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

   e. **Settle output to PoolManager**: `CurrencySettler.settle(outputCurrency, poolManager, address(this), outputReceived, false)`
      - Transfers project tokens from hook to PoolManager
      - Resolves the flash-accounting credit

   f. **Clear reentrancy guard**: `_routing = false`

4. **Return `BeforeSwapDelta(+amountIn, -outputReceived)`**

   - `+amountIn`: hook took the specified (input) tokens
   - `-outputReceived`: hook provided the unspecified (output) tokens
   - PoolManager uses this delta instead of executing the AMM swap

5. **`_afterSwap` is called but delta is zero for the AMM portion**

   - `rawOutput == 0` for the AMM delta (the hook handled everything)
   - Slippage check is skipped (was already enforced by `terminal.pay(minReturnedTokens)`)
   - Oracle observation is still recorded

### State changes

1. `_routing` -- set to `true` before JB interaction, reset to `false` after
2. `observations[poolId][newIndex]` -- new oracle observation written in `_afterSwap`
3. `states[poolId].index` -- updated to new observation index
4. `states[poolId].cardinality` -- may increase if at capacity
5. `states[poolId].cardinalityNext` -- may double (up to 1024) if at capacity
6. PoolManager flash-accounting balances -- debt created by `take()`, resolved by `settle()`
7. JB project token balance of hook -- temporarily holds minted tokens, then settled to PoolManager

### Events

1. `BestRouteSelected(poolId, 1, juiceboxExpectedOutput, msg.sender)` -- route type 1 = JB selected
2. `RouteSelected(poolId, true, juiceboxExpectedOutput, msg.sender)` -- JB route confirmed
3. JB terminal events (emitted by the terminal, not by this hook): `Pay(...)`, token mint events

### Edge cases

- `JBUniswapV4Hook_ReentrantRouting()` -- if a JB pay hook triggers another swap through this pool, the `_routing` guard blocks it
- Terminal has no liquidity or reverts -- entire swap reverts (PoolManager balance check fails)
- `amountOutMin` enforced by `terminal.pay(minReturnedTokens)` -- reverts inside the terminal if output is insufficient
- Native ETH: `inputCurrency.isAddressZero()` skips `forceApprove`, sends ETH via `{value: payValue}`
- Token normalization: Uniswap `address(0)` mapped to `JB_NATIVE_TOKEN (0x...EEEe)` for terminal calls

### What to verify

- The flash-accounting cycle is complete: take + settle balances correctly.
- `terminal.pay()` receives the correct token and amount (especially for native ETH vs ERC-20).
- If `terminal.pay()` reverts, the entire swap reverts (PoolManager balance check fails).
- The `BeforeSwapDelta` correctly represents the hook's token movements for both `zeroForOne = true` and `false`.
- JB minting respects `amountOutMin` via `minReturnedTokens`.
- No tokens are retained by the hook after the swap completes.

---

## Journey 3: Swap Through Hooked Pool -- JB Route Wins (Cashout)

**Entry point:** `PoolManager.swap(PoolKey key, SwapParams params, bytes hookData)` (triggers `_beforeSwap` / `_afterSwap` hooks on `JBUniswapV4Hook`)

**Who can call:** Anyone, via a router contract that calls `poolManager.swap()`. The hook functions are `internal override` -- only the PoolManager invokes them.

**Actor:** User swapping JB project tokens for a payment token (ETH, USDC).
**Goal:** Get more payment tokens by routing through JB cashout instead of the V4 pool.

### Parameters

- **`key`** -- `PoolKey` identifying the V4 pool
- **`params.zeroForOne`** -- `bool`, swap direction (JB token is on the input side)
- **`params.amountSpecified`** -- `int256`, must be negative (exact-input)
- **`hookData`** -- `bytes`, exactly 32 bytes: `abi.encode(uint256 amountOutMin)`

### Precondition

The JB project has favorable cashout conditions (low tax rate, high surplus) that exceed what the V4 pool offers. The project's terminal holds enough of the output token.

### Steps

1. **Same as Journey 1, Steps 1-4** (but `isSellingJBToken = true`)

   - `calculateExpectedOutputFromSelling()` uses `previewCashOutFrom()` and deducts protocol fee

2. **Comparison: JB wins (selling)**

   - `juiceboxBetterThanV4 = true`

3. **`_routeThroughJuicebox(projectId, inputCurrency, outputCurrency, amountIn, isBuying=false, terminal, amountOutMin)`**

   a. **Set reentrancy guard**: `_routing = true`

   b. **Take JB tokens from PoolManager**: `poolManager.take(inputCurrency, address(this), amountIn)`

   c. **No approval needed** -- the hook is the token holder and will call `cashOutTokensOf` as the holder

   d. **Cash out JB tokens**:
      ```
      IJBMultiTerminal(terminal).cashOutTokensOf(
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

   e. **Settle output to PoolManager**: `CurrencySettler.settle(outputCurrency, poolManager, address(this), outputReceived, false)`

   f. **Clear reentrancy guard**: `_routing = false`

4. **Return `BeforeSwapDelta(+amountIn, -outputReceived)`**

5. **`_afterSwap` records oracle observation (slippage already enforced)**

### State changes

1. `_routing` -- set to `true` before JB interaction, reset to `false` after
2. `observations[poolId][newIndex]` -- new oracle observation written in `_afterSwap`
3. `states[poolId].index` -- updated to new observation index
4. `states[poolId].cardinality` -- may increase if at capacity
5. `states[poolId].cardinalityNext` -- may double (up to 1024) if at capacity
6. PoolManager flash-accounting balances -- debt created by `take()`, resolved by `settle()`
7. JB project token supply -- decreased (tokens burned by terminal during cashout)

### Events

1. `BestRouteSelected(poolId, 1, juiceboxExpectedOutput, msg.sender)` -- route type 1 = JB selected
2. `RouteSelected(poolId, true, juiceboxExpectedOutput, msg.sender)` -- JB route confirmed
3. JB terminal events (emitted by the terminal, not by this hook): `CashOutTokens(...)`, token burn events

### Edge cases

- `JBUniswapV4Hook_ReentrantRouting()` -- if a JB cashout hook triggers another swap through this pool, the `_routing` guard blocks it
- `cashOutTaxRate == 0` -- bonding curve is linear; hook repeatedly prefers JB cashout over V4. Each token redeems proportional surplus. Accepted behavior (see RISKS.md).
- Terminal reverts (insufficient surplus, `minTokensReclaimed` not met) -- entire swap reverts
- Token normalization: `tokenOut = address(0)` mapped to `JB_NATIVE_TOKEN` for terminal calls
- For native ETH output: terminal sends ETH to hook, hook settles via `CurrencySettler`

### What to verify

- The hook is recognized as a valid holder of JB tokens for `cashOutTokensOf()`.
- Token normalization: `tokenOut = address(0)` (V4 native ETH) is mapped to `JB_NATIVE_TOKEN` for the terminal call.
- The cashout route correctly accounts for the 2.5% JB protocol fee in its estimate.
- If the estimate overestimates (e.g., due to total surplus vs local surplus mismatch), `minTokensReclaimed = amountOutMin` prevents the swap from completing at a bad rate.
- For native ETH output: the terminal sends ETH to the hook, and the hook settles it to PoolManager correctly.

---

## Journey 4: Pool Initialization with Oracle

**Entry point:** `PoolManager.initialize(PoolKey key, uint160 sqrtPriceX96)` (triggers `_afterInitialize` hook on `JBUniswapV4Hook`)

**Who can call:** Anyone. Pool initialization is permissionless in V4. The `_afterInitialize` hook is `internal override` -- only the PoolManager invokes it.

**Actor:** Anyone initializing a V4 pool with this hook (typically the LP split hook deployer or a direct call to PoolManager/PositionManager).
**Goal:** Create a new pool and initialize its TWAP oracle.

### Parameters

- **`key`** -- `PoolKey` with `key.hooks = address(JBUniswapV4Hook)`
- **`sqrtPriceX96`** -- `uint160`, initial price of the pool

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

### State changes

1. `observations[poolId][0]` -- initialized with `{blockTimestamp: block.timestamp, tickCumulative: 0, secondsPerLiquidityCumulativeX128: 0, initialized: true}`
2. `states[poolId].index` -- set to `0`
3. `states[poolId].cardinality` -- set to `1`
4. `states[poolId].cardinalityNext` -- set to `1`

### Events

None emitted by `JBUniswapV4Hook`. The PoolManager emits its own `Initialize` event.

### Edge cases

- If the pool was already initialized, `_afterInitialize` is not called again (V4 only calls `afterInitialize` once).
- `Oracle_CardinalityCannotBeZero()` -- cannot occur during initialization (initial cardinality is always 1).

### What to verify

- The initial observation is correctly written with zeroed cumulatives.
- The warmup period is exactly `TWAP_PERIOD` (1800 seconds) from the first observation.
- During warmup, the spot price fallback works correctly for routing decisions.
- Cardinality growth happens correctly after the first observation: second observation triggers growth from 1 to 2.

---

## Journey 5: Slippage Protection via hookData

**Entry point:** Part of every swap through `_beforeSwap` / `_afterSwap` (not a standalone journey)

**Who can call:** Anyone initiating a swap through a hooked pool (indirectly, via the PoolManager).

**Actor:** User submitting a swap with a minimum output requirement.
**Goal:** Ensure the swap reverts if the output falls below the specified minimum.

### Parameters

- **`hookData`** -- `bytes`, exactly 32 bytes: `abi.encode(uint256 amountOutMin)`

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
6. Reverts with `JBUniswapV4Hook_InsufficientOutput()` if `outputAmount < amountOutMin`

### Events

No additional events beyond those in Journey 1/2/3. The `RouteSelected` and `BestRouteSelected` events are emitted during routing decisions, not during slippage checks.

### Edge cases

- `amountOutMin = 0`: No slippage protection. JB terminal still executes, V4 slippage check passes trivially.
- `hookData.length != 32`: `_beforeSwap` reverts with `JBUniswapV4Hook_AmountOutMinRequired()`. Swaps through this pool require hookData.
- `hookData.length >= 32` in `_afterSwap`: Only first 32 bytes are decoded. Extra bytes are ignored.
- All swaps through this hook require exactly 32 bytes of hookData -- the length check happens before any token identification or routing logic.
- For JB routes, slippage is enforced by the terminal (via `minReturnedTokens` / `minTokensReclaimed`). The `_afterSwap` check correctly skips because `rawOutput == 0`.

### What to verify

- The hookData length check happens before any routing logic. All swaps through hooked pools require `amountOutMin`.
- V4's sign convention is correctly handled in `_afterSwap`: output amounts should be negative (credits to user). The code handles both signs.
- For JB routes, slippage is enforced twice (terminal + potentially afterSwap). Verify the afterSwap check correctly skips for JB routes (rawOutput == 0).
- An attacker cannot bypass slippage by providing hookData longer than 32 bytes to `_beforeSwap` (it requires `== 32`).

---

## Journey 6: No JB Token Involved -- Pure V4 Swap

**Entry point:** `PoolManager.swap(PoolKey key, SwapParams params, bytes hookData)` (triggers `_beforeSwap` / `_afterSwap` hooks on `JBUniswapV4Hook`)

**Who can call:** Anyone, via a router contract that calls `poolManager.swap()`. The hook functions are `internal override` -- only the PoolManager invokes them.

**Actor:** User swapping two non-JB tokens through a pool that happens to use this hook.
**Goal:** Swap normally through V4 while the oracle records observations.

### Parameters

- **`key`** -- `PoolKey` identifying the V4 pool
- **`params`** -- `SwapParams` (standard V4 swap parameters)
- **`hookData`** -- `bytes`, exactly 32 bytes: `abi.encode(uint256 amountOutMin)` (required even for non-JB swaps)

### Steps

1. **Swap initiated with `hookData = abi.encode(uint256(0))` or any 32-byte hookData**

2. **`_beforeSwap` executes**

   - Checks `_routing == false`
   - Decodes `amountOutMin`
   - Looks up `TOKENS.projectIdOf()` for both tokens -- returns 0 for both
   - `isSellingJBToken = false`, `isBuyingJBToken = false`
   - Enters the `else` branch: returns `ZERO_DELTA` -- V4 handles the swap normally

3. **V4 AMM executes the swap**

4. **`_afterSwap` executes**

   - If `amountOutMin > 0`: validates actual output against minimum (reverts `JBUniswapV4Hook_InsufficientOutput()` if insufficient)
   - Records oracle observation

### State changes

1. `observations[poolId][newIndex]` -- new oracle observation written
2. `states[poolId].index` -- updated to new observation index
3. `states[poolId].cardinality` -- may increase if at capacity
4. `states[poolId].cardinalityNext` -- may double (up to 1024) if at capacity

### Events

1. `RouteSelected(poolId, false, 0, msg.sender)` -- no JB token involved, V4 route used

### Edge cases

- `TOKENS.projectIdOf()` may revert for non-JB tokens. If `tokenIn` or `tokenOut` is a plain ERC-20 that does not implement `IJBToken`, calling `TOKENS.projectIdOf(IJBToken(tokenIn))` may revert, breaking all swaps through the pool. Verify that `JBTokens.projectIdOf()` handles unknown tokens gracefully (returns 0 without reverting).
- `JBUniswapV4Hook_AmountOutMinRequired()` -- hookData must still be exactly 32 bytes, even for non-JB pools
- `JBUniswapV4Hook_InsufficientOutput()` -- if `amountOutMin > 0` and V4 output is below minimum

### What to verify

- `TOKENS.projectIdOf()` does not revert for non-JB tokens. If the token address does not implement `IJBToken`, the call could revert. The code does NOT wrap this in try-catch.
- This is a potential issue: if `tokenIn` or `tokenOut` is a plain ERC-20 that does not implement `IJBToken`, calling `TOKENS.projectIdOf(IJBToken(tokenIn))` may revert, breaking all swaps through the pool. Verify that `JBTokens.projectIdOf()` handles unknown tokens gracefully (returns 0 without reverting).
- Oracle observations are recorded even for non-JB swaps (correct behavior).

---

## Journey 7: Oracle Observation Recording (Liquidity Events)

**Entry point:** `_afterAddLiquidity(...)` or `_afterRemoveLiquidity(...)` hooks on `JBUniswapV4Hook`

**Who can call:** Only the PoolManager, via BaseHook callback mechanism. Triggered when any user adds or removes liquidity through PositionManager or direct PoolManager calls.

**Actor:** Liquidity provider adding or removing liquidity from a hooked pool.
**Goal:** Keep the TWAP oracle up to date with fresh observations from liquidity events (not just swaps).

### Parameters

- **`key`** -- `PoolKey` identifying the V4 pool (passed by PoolManager)

### Steps

1. **User adds/removes liquidity via PositionManager or PoolManager**

2. **PoolManager calls `_afterAddLiquidity(...)` or `_afterRemoveLiquidity(...)`**

   - Calls `_recordObservation(key.toId())`
   - Reads current tick and liquidity from `poolManager.getSlot0()` and `poolManager.getLiquidity()`
   - Auto-grows cardinality when at capacity: doubles `cardinalityNext` up to `MAX_TWAP_CARDINALITY (1024)`
   - Writes new observation via `Oracle.write()`
   - Updates `states[poolId]` with new index, cardinality, and cardinalityNext

### State changes

1. `observations[poolId][newIndex]` -- new `Oracle.Observation` written with current tick/liquidity cumulatives
2. `states[poolId].index` -- updated to `newIndex`
3. `states[poolId].cardinality` -- may increase when `cardinalityNext > cardinality` and index wraps
4. `states[poolId].cardinalityNext` -- may double (up to 1024) when at capacity (`index == cardinality - 1`)
5. If growing: `observations[poolId][current..next-1].blockTimestamp` -- pre-initialized to `1` (prevents fresh SSTOREs during swaps)

### Events

None emitted by `JBUniswapV4Hook`. Observation writes are silent.

### Edge cases

- Same-block writes are no-ops: `Oracle.write()` returns early if `last.blockTimestamp == blockTimestamp`
- Cardinality growth is bounded: doubles each time but capped at `MAX_TWAP_CARDINALITY = 1024`
- `Oracle_CardinalityCannotBeZero()` -- cannot occur after initialization (grow requires `current > 0`)

### What to verify

- Oracle observations are recorded for both add and remove liquidity events.
- Auto-growth logic correctly doubles cardinality and does not exceed `MAX_TWAP_CARDINALITY`.
- Pre-initialization of observation slots (blockTimestamp = 1) avoids cold SSTORE costs during swaps.

---

## Journey 8: External TWAP Queries

**Entry point:** `observe(PoolKey key, uint32[] secondsAgos)` or `observeTWAP(PoolId poolId, uint32 secondsAgo, int24 tick, uint16 index, uint128 liquidity, uint16 cardinality)`

**Who can call:** Anyone. Both functions are `external view` -- no access restrictions.

**Actor:** External contract (e.g., JBBuybackHook) or off-chain system querying TWAP data.
**Goal:** Read time-weighted average price data from the oracle without modifying state.

### Parameters (`observe`)

- **`key`** -- `PoolKey` identifying the V4 pool
- **`secondsAgos`** -- `uint32[]`, array of time periods (in seconds) to look back

### Parameters (`observeTWAP`)

- **`poolId`** -- `PoolId`, the pool to query
- **`secondsAgo`** -- `uint32`, how far back to calculate TWAP (must be > 0)
- **`tick`** -- `int24`, current tick
- **`index`** -- `uint16`, current observation index
- **`liquidity`** -- `uint128`, current liquidity
- **`cardinality`** -- `uint16`, current cardinality

### Steps

1. **Caller invokes `observe()` or `observeTWAP()`**

2. **For `observe()`:**
   - Computes `poolId` from key
   - Reads current tick and liquidity from PoolManager
   - Delegates to `Oracle.observe()` which calls `observeSingle()` for each `secondsAgo` value
   - Returns `tickCumulatives[]` and `secondsPerLiquidityCumulativeX128s[]`

3. **For `observeTWAP()`:**
   - Validates `secondsAgo != 0` (reverts `JBUniswapV4Hook_SecondsAgoCannotBeZero()`)
   - Observes two points: now (`secondsAgos[0] = 0`) and `secondsAgo` in the past
   - Computes arithmetic mean tick from tick cumulative delta
   - Rounds toward negative infinity for negative ticks

### State changes

None -- both functions are `view`.

### Events

None -- view functions do not emit events.

### Edge cases

- `JBUniswapV4Hook_SecondsAgoCannotBeZero()` -- `observeTWAP` requires `secondsAgo > 0`
- `Oracle_CardinalityCannotBeZero()` -- pool not initialized (cardinality is 0)
- `Oracle_TargetPredatesOldestObservation(oldestTimestamp, targetTimestamp)` -- requested time is older than the oldest stored observation
- Tick rounding: negative ticks are rounded toward negative infinity (Solidity truncates toward zero, so an extra decrement is applied)

### What to verify

- `observe()` returns correct cumulative values for arbitrary `secondsAgos` arrays.
- `observeTWAP()` arithmetic mean tick calculation matches the standard TWAP formula.
- Binary search in `Oracle.binarySearch()` correctly handles wrapped observation arrays.
- `int56` tickCumulative overflow: covers ~1.4 years at max tick (887272) before wrapping.
