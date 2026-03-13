# univ4-router-v6 -- Risks

Deep implementation-level risk analysis of `JBUniswapV4Hook` and `Oracle`.

## Trust Assumptions

1. **Uniswap V4 PoolManager** -- The hook executes within V4's PoolManager context. All take/settle flash-accounting relies on PoolManager enforcing balance invariants. A PoolManager bug would compromise all hooked pools.
2. **TWAP Oracle Integrity** -- Oracle accuracy depends on sufficient observation history and pool activity. New or low-activity pools have unreliable TWAPs. The hook falls back to spot price when TWAP is unavailable (`_getTWAPSqrtPrice` returns 0).
3. **Juicebox Core Protocol** -- Relies on `IJBController.currentRulesetOf()` for weight/reserved rate, `IJBTerminalStore.currentReclaimableSurplusOf()` for cashout estimates, and `IJBPrices.pricePerUnitOf()` for currency conversion. Bugs in any of these affect routing accuracy.
4. **ERC-20 Token Compliance** -- Uses `SafeERC20` (OpenZeppelin) and `forceApprove` for all token interactions. Non-standard tokens (fee-on-transfer, rebasing) may cause accounting mismatches in the take/settle cycle.

## Risk Inventory

### CRITICAL -- None Found

The Nemesis audit (2 passes, 34 functions, ~1,780 lines) found no critical or high-severity issues. All 11 findings were LOW severity.

### HIGH -- Flash-Accounting Balance Mismatch

**Severity:** HIGH (theoretical) | **Status:** Mitigated by design | **Tested:** Yes

**Location:** `_routeThroughJuicebox`

**Description:** The routing function follows a take-then-settle pattern:
1. `poolManager.take()` -- withdraws input tokens from PoolManager
2. External call (JB terminal) -- transforms tokens via pay/cashOut
3. `_settleOutput()` -- deposits output tokens back to PoolManager

If the external call in step 2 reverts, tokens taken in step 1 would be stranded in the hook contract. However, because this all happens inside a V4 hook callback, the entire swap transaction reverts atomically, restoring PoolManager's balance.

**Attack scenario:** An attacker deploys a malicious JB terminal that reverts after partial token consumption. Result: the entire swap reverts (PoolManager enforces flash-accounting balance at the end of `unlock()`). No funds lost.

**Concrete risk:** If a JB terminal silently consumes tokens without returning them and does NOT revert, the hook would attempt `_settleOutput()` with 0 tokens, causing a PoolManager balance check failure and a revert. The `forceApprove` fix prevents allowance accumulation from such partial-consumption scenarios.

**Test coverage:**
- `JBUniswapV4Hook.t.sol`: `testJuiceboxRoutingExecution` -- verifies complete JB routing cycle

### MEDIUM -- TWAP Oracle Manipulation

**Severity:** MEDIUM | **Status:** Mitigated | **Tested:** Partially

**Location:** `_getTWAPSqrtPrice`, `_recordObservation`

**Description:** The V4 TWAP oracle uses a 30-minute window (`TWAP_PERIOD = 1800`). An attacker with sufficient capital could manipulate the TWAP over this window by:
1. Making large swaps to move the tick over multiple blocks
2. Sustaining the manipulated price for 30+ minutes
3. Swapping at the now-biased TWAP price

**Why mitigated:** Sustaining price manipulation for 30 minutes costs the attacker significant capital in arbitrage losses. The two-way comparison (V4 TWAP vs JB weight) means an attacker would need to manipulate the TWAP to be worse than JB minting, which is bounded by ruleset weight.

**Residual risk:** Low-liquidity pools where the cost of TWAP manipulation is low. Pools with < 2 observations fall back to spot price, which is trivially manipulable.

**Test coverage:**
- `OracleDeepTest.t.sol`: 14 tests covering oracle initialization, writes, cardinality growth, TWAP calculation, and warmup behavior
- No test directly simulates a multi-block TWAP manipulation attack

### MEDIUM -- Spot Price Fallback Window

**Severity:** MEDIUM | **Status:** Known, by design | **Tested:** Yes

**Location:** `estimateUniswapOutput`, `_getTWAPSqrtPrice`

**Description:** When a pool's oracle has fewer than 2 observations or the oldest observation is too recent, `_getTWAPSqrtPrice` returns 0. The V4 price estimate then falls back to the current spot price (`poolManager.getSlot0()`), which can be manipulated within a single block.

During this fallback window, an attacker could:
1. Sandwich the spot-price-based routing decision
2. Manipulate spot price to force routing through a worse path
3. Profit from the price discrepancy

**Duration of vulnerability:** From pool initialization until the oracle accumulates sufficient observations spanning the TWAP_PERIOD (1800 seconds). With regular swaps, this resolves within ~30 minutes. Low-activity pools may remain in spot-price fallback indefinitely.

**Test coverage:**
- `OracleDeepTest.t.sol`: `test_TWAPSqrtPrice_InsufficientObservations_ReturnsZero` -- verifies fallback
- `OracleDeepTest.t.sol`: `test_TWAPSqrtPrice_OldestObsTooRecent_ReturnsZero` -- verifies transient window
- `OracleDeepTest.t.sol`: `test_TWAPSqrtPrice_SufficientAge_ReturnsNonZero` -- verifies resolution

### LOW -- Surplus Estimation Uses Total Surplus

**Severity:** LOW | **Status:** By design | **Tested:** Yes

**Location:** `calculateExpectedOutputFromSelling`

**Description:** The sell-side estimate calls `store.currentReclaimableSurplusOf()` with empty `terminals[]` and `accountingContexts[]`. When terminals is empty, the store falls back to `DIRECTORY.terminalsOf(projectId)` -- aggregating surplus across ALL terminals.

This means the estimate always uses **total surplus** regardless of the project's `useTotalSurplusForCashOuts` flag. For projects where this flag is `false` (local surplus only), the estimate overestimates what a real cashout would return, potentially routing through JB when V4 would give a better rate.

**Why acceptable:** This is a routing estimate, not an execution guarantee. The actual cashout enforces the correct surplus scope. If the estimate overestimates JB, the cashout may return less than expected, but the `amountOutMin` slippage check protects the user.

**Test coverage:**
- `JBUniswapV4Hook.t.sol`: `testCalculateExpectedOutputFromSelling` -- verifies surplus calculation with fee deduction
- `ThreeWayRouting.t.sol`: `test_TwoWay_SellingJBToken_JBWins` -- verifies sell routing through JB

### LOW -- Sell Estimation Silently Returns Zero on Failure

**Severity:** LOW | **Status:** By design | **Tested:** Yes

**Location:** `calculateExpectedOutputFromSelling`

**Description:** Both `terminal.STORE()` and `store.currentReclaimableSurplusOf()` are wrapped in try-catch blocks. If any external call reverts (misconfigured project, no ruleset, store bug, etc.), the function returns 0 instead of propagating the revert. This causes the swap to fall back to V4 routing silently.

**Why designed this way:** Without try-catch, a revert from any JB protocol call would bubble up through the `_beforeSwap` hook and **fail the entire swap**. The try-catch ensures that JB protocol issues never block V4 swaps. The inner try-catch is specifically needed because Solidity try-catch only catches the try expression's revert, not reverts from code within the try body.

**Test coverage:**
- `JBUniswapV4Hook.t.sol`: `testCalculateExpectedOutputFromSelling_StoreReverts_ReturnsZero` -- verifies graceful fallback when store reverts
- `JBUniswapV4Hook.t.sol`: `testCalculateExpectedOutputFromSelling_NoStore_ReturnsZero` -- verifies graceful fallback when STORE() reverts

## MEV / Sandwich Attack Vectors

### Vector 1: Sandwich on JB Routing Decision

**Risk:** LOW-MEDIUM | **Tested:** No

An attacker observing a pending swap through a hooked pool could:
1. Front-run with a large swap to move the V4 pool price
2. This changes the V4 TWAP estimate, potentially forcing the victim's swap to route through JB (minting) instead of V4
3. Back-run by swapping in the opposite direction on V4

**Impact:** The victim gets JB tokens at the minting rate (which may be worse than the pre-manipulation V4 rate). The attacker profits from the V4 price movement.

**Mitigation:** The `amountOutMin` parameter (hookData) provides a hard floor. If the routed output falls below `amountOutMin`, the swap reverts (`JBUniswapV4Hook_InsufficientOutput`).

### Vector 2: JB Terminal Interaction Sandwich

**Risk:** LOW | **Tested:** No

When routing through JB (`_routeThroughJuicebox`), the hook calls `terminal.pay()` or `terminal.cashOutTokensOf()`. These JB functions have their own `minReturnedTokens` / `minTokensReclaimed` parameters, set to `amountOutMin`.

The JB minting rate is determined by the project's ruleset weight, which is not manipulable within a single transaction. Cashout rates depend on the bonding curve and total supply, which are harder to sandwich than AMM pools.

## Reentrancy Analysis

| Function | External Calls | State Before Call | Protection | Risk |
|----------|---------------|-------------------|------------|------|
| `_beforeSwap` | `TOKENS.projectIdOf`, `DIRECTORY.controllerOf`, `PRICES.pricePerUnitOf`, JB terminal `pay`/`cashOutTokensOf` | Oracle state NOT yet updated (observation recorded in `_afterSwap`) | V4 PoolManager lock (only one unlock at a time). All external calls wrapped in try-catch for view calls. | LOW -- PoolManager prevents reentrant swaps. |
| `_afterSwap` | `poolManager.getSlot0`, `poolManager.getLiquidity` | Swap fully settled | Internal calls to PoolManager only (trusted) | LOW |
| `_routeThroughJuicebox` | `poolManager.take`, JB `terminal.pay`/`cashOutTokensOf`, `_settleOutput` | Tokens taken from PM | Atomic within V4 unlock. JB terminal call happens after take but before settle. | MEDIUM -- JB terminal is external/untrusted. But PoolManager enforces balance at unlock end. |

**No explicit reentrancy guard** (no `ReentrancyGuard`). Protection relies entirely on:
1. V4 PoolManager's single-unlock constraint (cannot re-enter unlock while unlock is active)
2. Atomic flash-accounting (PoolManager reverts if balances don't reconcile)

## Oracle-Specific Risks

### tickCumulative Overflow (int56)

**Severity:** LOW | **Status:** Fixed (was int48) | **Tested:** Yes

**Location:** `Oracle.Observation.tickCumulative` (Oracle.sol)

**Description:** The `tickCumulative` field was widened from int48 to int56 to prevent overflow. At max tick (887,272), int48 overflows after ~44 hours. int56 extends this to ~1.4 years.

### Oracle Cardinality Growth Gas Cost

**Severity:** LOW | **Status:** Bounded | **Tested:** Yes

**Location:** `_recordObservation`, `Oracle.grow`

**Description:** Auto-growth doubles cardinality at capacity boundaries: 1 -> 2 -> 4 -> 8 -> ... -> 128 -> 256 (cap). Each growth calls `Oracle.grow()` which pre-allocates storage slots via SSTORE. The largest single growth (128 -> 256) costs ~128 SSTOREs (~2.56M gas at 20k gas per cold SSTORE). This cost is borne by the swap/liquidity caller who triggers the growth.

**Test coverage:** `OracleDeepTest.t.sol`: `test_OracleCardinality_CapsAt256` -- verifies cap at 256.

### Dead Oracle Fields

**Severity:** INFORMATIONAL | **Status:** Known | **Tested:** N/A

**Location:** `Oracle.Observation.prevTick`, `MIN_ABS_TICK_MOVE` / `LIMIT_ABS_TICK_MOVE`

**Description:** `prevTick` is written but never read. The two tick-move constants are never referenced. These are remnants of a backrun-protection feature that was removed. They waste no runtime gas (constants are inlined; `prevTick` fits within the 256-bit storage slot) but add cognitive overhead.

**Audit finding:** NM-001, NM-002 (both LOW).

## Routing Decision Risks

### Conservative JB Sell Estimate

**Severity:** LOW | **Status:** By design | **Tested:** Yes

**Location:** `calculateExpectedOutputFromSelling`

**Description:** The sell estimate always deducts the terminal's protocol fee, even if the hook is registered as a feeless address. This makes JB cashout routing slightly disadvantaged vs. Uniswap. The code explicitly acknowledges this: "Conservative: if hook is feeless, estimate is slightly low -> routes to Uniswap (still good)."

### Both-JB-Tokens Buy-Side Priority

**Severity:** LOW | **Status:** By design | **Tested:** No

**Location:** `_beforeSwap`

**Description:** When both swap tokens are JB project tokens, the hook only evaluates the buy-side JB route (minting into the output project). The sell-side (cashing out the input project) is not compared. This is a design simplification.

**Audit finding:** NM-006 (LOW).

### hookData Length Strictness

**Severity:** LOW | **Status:** Known | **Tested:** Yes

**Location:** `_beforeSwap` (`== 32`) vs `_afterSwap` (`>= 32`)

**Description:** `_beforeSwap` requires exactly 32 bytes of hookData, while `_afterSwap` accepts 32 or more bytes. This inconsistency prevents routers from appending extra metadata after `amountOutMin`. The JuiceboxSwapRouter test utility encodes exactly 32 bytes.

**Audit finding:** NM-007 (LOW).

### Exact-Output Swaps Not Supported

**Severity:** LOW | **Status:** By design | **Tested:** Yes

**Description:** The hook reverts on exact-output swaps (`amountSpecified > 0`). Only exact-input swaps are supported because the routing logic requires knowing the exact input amount upfront to compare routes.

## Slippage Protection

Slippage protection operates at two levels:

| Level | Mechanism | Location | Enforces |
|-------|-----------|----------|----------|
| Hook `_beforeSwap` | `amountOutMin` from hookData | `_beforeSwap` | Minimum output for JB routes |
| Hook `_afterSwap` | `amountOutMin` from hookData | `_afterSwap` | Minimum output for V4 routes (checks actual delta) |
| JB terminal | `minReturnedTokens` / `minTokensReclaimed` | `_routeThroughJuicebox` | JB-level minimum (redundant with hook check) |

## External Dependency Risks

| Dependency | Risk | Impact if Compromised |
|------------|------|-----------------------|
| Uniswap V4 PoolManager | Single point of failure for all hooked pools | Total loss of pool funds |
| JB Directory | Terminal and controller resolution | Attacker could redirect routing to malicious terminal |
| JB Prices | Currency conversion for JB estimates | Incorrect price data leads to suboptimal routing (not fund loss) |
| JB Controller | Ruleset weight and metadata | Incorrect weight leads to overestimating JB minting rate |
| JB Terminal | Payment and cashout execution | Malicious terminal could consume tokens without returning output (but PoolManager flash-accounting would revert the entire swap) |
| JB Terminal Store | Surplus calculation for sell estimates | If store reverts, sell estimate returns 0 (V4 fallback). No fund loss. |
| OpenZeppelin SafeERC20 | Token transfer safety | Standard library -- well-audited, minimal risk |

## Cancun / EVM Dependency

The contract requires Cancun-compatible EVM features:
- **Transient storage** (V4 PoolManager uses `TSTORE`/`TLOAD` for flash-accounting)
- **Uniswap V4 features** (hook permission flags encoded in contract address)

Deployment on pre-Cancun chains will fail. This limits deployment to Ethereum mainnet (post-Dencun), Optimism, Arbitrum, Base, and other Cancun-compatible L2s.

## Audit Results Summary

The Nemesis audit (March 2026) analyzed 34 functions across ~1,780 lines in 2 converged passes:

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | -- |
| HIGH | 0 | -- |
| MEDIUM | 0 | 1 downgraded to LOW (NM-008: unreachable revert path) |
| LOW | 11 | All confirmed as informational / by-design |

**Key audit conclusions:**
- No exploitable vulnerabilities found
- Flash-accounting balance is correct for all routing paths (V4, JB)
- Oracle state management is consistent with atomic updates
- No state persists between transactions (minimal attack surface)
- Multi-transaction journey tracing found no cross-call contamination
