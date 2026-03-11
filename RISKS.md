# univ4-router-v6 -- Risks

Deep implementation-level risk analysis of `JBUniswapV4Hook` and `Oracle`.

## Trust Assumptions

1. **Uniswap V4 PoolManager** -- The hook executes within V4's PoolManager context. All take/settle flash-accounting relies on PoolManager enforcing balance invariants. A PoolManager bug would compromise all hooked pools.
2. **TWAP Oracle Integrity** -- Oracle accuracy depends on sufficient observation history and pool activity. New or low-activity pools have unreliable TWAPs. The hook falls back to spot price when TWAP is unavailable (`_getTWAPSqrtPrice` returns 0, line 1026-1056).
3. **Juicebox Core Protocol** -- Relies on `IJBController.currentRulesetOf()` for weight/reserved rate, `IJBTerminalStore.currentReclaimableSurplusOf()` for cashout estimates, and `IJBPrices.pricePerUnitOf()` for currency conversion. Bugs in any of these affect routing accuracy.
4. **ERC-20 Token Compliance** -- Uses `SafeERC20` (OpenZeppelin) and `forceApprove` for all token interactions. Non-standard tokens (fee-on-transfer, rebasing) may cause accounting mismatches in the take/settle cycle.

## Risk Inventory

### CRITICAL -- None Found

The Nemesis audit (2 passes, 34 functions, ~1,780 lines) found no critical or high-severity issues. All 11 findings were LOW severity.

### HIGH -- Flash-Accounting Balance Mismatch

**Severity:** HIGH (theoretical) | **Status:** Mitigated by design | **Tested:** Yes

**Location:** `_routeThroughJuicebox` (lines 1178-1242), `_routeThroughV3` (lines 1254-1324)

**Description:** Both routing functions follow a take-then-settle pattern:
1. `poolManager.take()` -- withdraws input tokens from PoolManager
2. External call (JB terminal or V3 pool) -- transforms tokens
3. `_settleOutput()` -- deposits output tokens back to PoolManager

If the external call in step 2 reverts, tokens taken in step 1 would be stranded in the hook contract. However, because this all happens inside a V4 hook callback, the entire swap transaction reverts atomically, restoring PoolManager's balance.

**Attack scenario:** An attacker deploys a malicious JB terminal that reverts after partial token consumption. Result: the entire swap reverts (PoolManager enforces flash-accounting balance at the end of `unlock()`). No funds lost.

**Concrete risk:** If a JB terminal silently consumes tokens without returning them and does NOT revert, the hook would attempt `_settleOutput()` with 0 tokens, causing a PoolManager balance check failure and a revert. The `forceApprove` fix (regression L43, line 1205) prevents allowance accumulation from such partial-consumption scenarios.

**Test coverage:**
- `JBUniswapV4Hook.t.sol`: `testJuiceboxRoutingExecution` -- verifies complete JB routing cycle
- `V3RoutingEdgeCases.t.sol`: `test_V3Callback_ValidPool_Succeeds` -- verifies V3 callback payment
- `L43_ForceApprove.t.sol`: regression test for allowance accumulation

### MEDIUM -- TWAP Oracle Manipulation

**Severity:** MEDIUM | **Status:** Mitigated | **Tested:** Partially

**Location:** `_getTWAPSqrtPrice` (lines 1026-1070), `_recordObservation` (lines 1127-1166)

**Description:** The V4 TWAP oracle uses a 30-minute window (`TWAP_PERIOD = 1800`, line 129). An attacker with sufficient capital could manipulate the TWAP over this window by:
1. Making large swaps to move the tick over multiple blocks
2. Sustaining the manipulated price for 30+ minutes
3. Swapping at the now-biased TWAP price

**Why mitigated:** Sustaining price manipulation for 30 minutes costs the attacker significant capital in arbitrage losses. The two-way comparison (V4 TWAP vs JB weight) means an attacker would need to manipulate the TWAP to be worse than JB minting, which is bounded by ruleset weight.

**Residual risk:** Low-liquidity pools where the cost of TWAP manipulation is low. Pools with < 2 observations fall back to spot price (line 1030), which is trivially manipulable.

**Test coverage:**
- `OracleDeepTest.t.sol`: 14 tests covering oracle initialization, writes, cardinality growth, TWAP calculation, and warmup behavior
- No test directly simulates a multi-block TWAP manipulation attack

### MEDIUM -- Spot Price Fallback Window

**Severity:** MEDIUM | **Status:** Known, by design | **Tested:** Yes

**Location:** `estimateUniswapOutput` (lines 329-375), `_getTWAPSqrtPrice` (lines 1030-1032, 1054)

**Description:** When a pool's oracle has fewer than 2 observations (line 1030) or the oldest observation is too recent (line 1054), `_getTWAPSqrtPrice` returns 0. The V4 price estimate then falls back to the current spot price (`poolManager.getSlot0()`, line 346), which can be manipulated within a single block.

During this fallback window, an attacker could:
1. Sandwich the spot-price-based routing decision
2. Manipulate spot price to force routing through a worse path
3. Profit from the price discrepancy

**Duration of vulnerability:** From pool initialization until the oracle accumulates sufficient observations spanning the TWAP_PERIOD (1800 seconds). With regular swaps, this resolves within ~30 minutes. Low-activity pools may remain in spot-price fallback indefinitely.

**Test coverage:**
- `OracleDeepTest.t.sol`: `test_TWAPSqrtPrice_InsufficientObservations_ReturnsZero` -- verifies fallback
- `OracleDeepTest.t.sol`: `test_TWAPSqrtPrice_OldestObsTooRecent_ReturnsZero` -- verifies transient window
- `OracleDeepTest.t.sol`: `test_TWAPSqrtPrice_SufficientAge_ReturnsNonZero` -- verifies resolution

## MEV / Sandwich Attack Vectors

### Vector 1: Sandwich on JB Routing Decision

**Risk:** LOW-MEDIUM | **Tested:** No

An attacker observing a pending swap through a hooked pool could:
1. Front-run with a large swap to move the V4 pool price
2. This changes the V4 TWAP estimate, potentially forcing the victim's swap to route through JB (minting) instead of V4
3. Back-run by swapping in the opposite direction on V4

**Impact:** The victim gets JB tokens at the minting rate (which may be worse than the pre-manipulation V4 rate). The attacker profits from the V4 price movement.

**Mitigation:** The `amountOutMin` parameter (hookData, line 795-798) provides a hard floor. If the routed output falls below `amountOutMin`, the swap reverts (`JBUniswapV4Hook_InsufficientOutput`, lines 764-765, 942-943).

### Vector 2: JB Terminal Interaction Sandwich

**Risk:** LOW | **Tested:** No

When routing through JB (`_routeThroughJuicebox`, line 1178), the hook calls `terminal.pay()` or `terminal.cashOutTokensOf()`. These JB functions have their own `minReturnedTokens` / `minTokensReclaimed` parameters (lines 1217, 1232), set to `amountOutMin`.

The JB minting rate is determined by the project's ruleset weight, which is not manipulable within a single transaction. Cashout rates depend on the bonding curve and total supply, which are harder to sandwich than AMM pools.

## Reentrancy Analysis

| Function | External Calls | State Before Call | Protection | Risk |
|----------|---------------|-------------------|------------|------|
| `_beforeSwap` (lines 783-953) | `TOKENS.projectIdOf`, `DIRECTORY.controllerOf`, `PRICES.pricePerUnitOf`, `V3_FACTORY.getPool`, JB terminal `pay`/`cashOutTokensOf`, V3 `pool.swap` | Oracle state NOT yet updated (observation recorded in `_afterSwap`) | V4 PoolManager lock (only one unlock at a time). All external calls wrapped in try-catch for view calls. | LOW -- PoolManager prevents reentrant swaps. |
| `_afterSwap` (lines 736-773) | `poolManager.getSlot0`, `poolManager.getLiquidity` | Swap fully settled | Internal calls to PoolManager only (trusted) | LOW |
| `_routeThroughJuicebox` (lines 1178-1242) | `poolManager.take`, JB `terminal.pay`/`cashOutTokensOf`, `_settleOutput` | Tokens taken from PM | Atomic within V4 unlock. JB terminal call happens after take but before settle. | MEDIUM -- JB terminal is external/untrusted. But PoolManager enforces balance at unlock end. |

**No explicit reentrancy guard** (no `ReentrancyGuard`). Protection relies entirely on:
1. V4 PoolManager's single-unlock constraint (cannot re-enter unlock while unlock is active)
2. Atomic flash-accounting (PoolManager reverts if balances don't reconcile)

## Oracle-Specific Risks

### tickCumulative Overflow (int56)

**Severity:** LOW | **Status:** Fixed (was int48) | **Tested:** Yes

**Location:** `Oracle.Observation.tickCumulative` (Oracle.sol line 37)

**Description:** The `tickCumulative` field was widened from int48 to int56 to prevent overflow. At max tick (887,272), int48 overflows after ~44 hours. int56 extends this to ~1.4 years.

**Test coverage:** `L40_OracleTickCumulativeWidth.t.sol` -- regression test proving int56 handles 500,000 seconds at max tick.

### Oracle Cardinality Growth Gas Cost

**Severity:** LOW | **Status:** Bounded | **Tested:** Yes

**Location:** `_recordObservation` (lines 1138-1150), `Oracle.grow` (Oracle.sol lines 150-162)

**Description:** Auto-growth doubles cardinality at capacity boundaries: 1 -> 2 -> 4 -> 8 -> ... -> 128 -> 256 (cap). Each growth calls `Oracle.grow()` which pre-allocates storage slots via SSTORE. The largest single growth (128 -> 256) costs ~128 SSTOREs (~2.56M gas at 20k gas per cold SSTORE). This cost is borne by the swap/liquidity caller who triggers the growth.

**Test coverage:** `OracleDeepTest.t.sol`: `test_OracleCardinality_CapsAt256` -- verifies cap at 256.

### Dead Oracle Fields

**Severity:** INFORMATIONAL | **Status:** Known | **Tested:** N/A

**Location:** `Oracle.Observation.prevTick` (Oracle.sol line 35), `MIN_ABS_TICK_MOVE` / `LIMIT_ABS_TICK_MOVE` (Oracle.sol lines 22-24)

**Description:** `prevTick` is written but never read. The two tick-move constants are never referenced. These are remnants of a backrun-protection feature that was removed. They waste no runtime gas (constants are inlined; `prevTick` fits within the 256-bit storage slot) but add cognitive overhead.

**Audit finding:** NM-001, NM-002 (both LOW).

## Routing Decision Risks

### Conservative JB Sell Estimate

**Severity:** LOW | **Status:** By design | **Tested:** Yes

**Location:** `calculateExpectedOutputFromSelling` (lines 208-237)

**Description:** The sell estimate always deducts the terminal's protocol fee (line 232-233), even if the hook is registered as a feeless address. This makes JB cashout routing slightly disadvantaged vs. Uniswap. The comment at line 231 explicitly acknowledges this: "Conservative: if hook is feeless, estimate is slightly low -> routes to Uniswap (still good)."

**Test coverage:** `L41_DynamicProtocolFee.t.sol` -- regression test for dynamic fee reading.

### Both-JB-Tokens Buy-Side Priority

**Severity:** LOW | **Status:** By design | **Tested:** No

**Location:** `_beforeSwap` (lines 831-836)

**Description:** When both swap tokens are JB project tokens, the hook only evaluates the buy-side JB route (minting into the output project). The sell-side (cashing out the input project) is not compared. This is a design simplification.

**Audit finding:** NM-006 (LOW).

### hookData Length Strictness

**Severity:** LOW | **Status:** Known | **Tested:** Yes

**Location:** `_beforeSwap` line 795 (`== 32`) vs `_afterSwap` line 750 (`>= 32`)

**Description:** `_beforeSwap` requires exactly 32 bytes of hookData, while `_afterSwap` accepts 32 or more bytes. This inconsistency prevents routers from appending extra metadata after `amountOutMin`. The JuiceboxSwapRouter test utility (line 59) encodes exactly 32 bytes.

**Audit finding:** NM-007 (LOW).

### Exact-Output Swaps Not Supported

**Severity:** LOW | **Status:** By design | **Tested:** Yes

**Location:** `_beforeSwap` (lines 805-807)

**Description:** The hook reverts on exact-output swaps (`amountSpecified > 0`). Only exact-input swaps are supported because the routing logic requires knowing the exact input amount upfront to compare routes.

**Test coverage:** `V3RoutingEdgeCases.t.sol`: `test_V3Routing_PositiveAmountSpecified_Reverts`

## Slippage Protection

Slippage protection operates at three levels:

| Level | Mechanism | Location | Enforces |
|-------|-----------|----------|----------|
| Hook `_beforeSwap` | `amountOutMin` from hookData | Lines 795-798, 942-943 | Minimum output for V3 and JB routes |
| Hook `_afterSwap` | `amountOutMin` from hookData | Lines 750-769 | Minimum output for V4 routes (checks actual delta) |
| JB terminal | `minReturnedTokens` / `minTokensReclaimed` | Lines 1217, 1232 | JB-level minimum (redundant with hook check) |
| JuiceboxSwapRouter | `amountOutMin` in unlockCallback | Router lines 114-129 | Router-level minimum (defense in depth) |

**Regression fix:** The slippage check in `_afterSwap` was fixed to handle V4's negative-output convention. The old code checked `outputAmount > 0`, which was never true for V4 swaps (output amounts are negative in V4 convention). The fix negates the raw output before comparison (lines 762-763).

**Test coverage:** `H18_SlippageSignConvention.t.sol` -- regression test proving the fix catches insufficient output with negative amounts.

## External Dependency Risks

| Dependency | Risk | Impact if Compromised |
|------------|------|-----------------------|
| Uniswap V4 PoolManager | Single point of failure for all hooked pools | Total loss of pool funds |
| JB Directory | Terminal and controller resolution | Attacker could redirect routing to malicious terminal |
| JB Prices | Currency conversion for JB estimates | Incorrect price data leads to suboptimal routing (not fund loss) |
| JB Controller | Ruleset weight and metadata | Incorrect weight leads to overestimating JB minting rate |
| JB Terminal | Payment and cashout execution | Malicious terminal could consume tokens without returning output (but PoolManager flash-accounting would revert the entire swap) |
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
