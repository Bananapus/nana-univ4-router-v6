# Audit Instructions

This repo is the Uniswap V4 hook that compares V4 execution against Juicebox execution and routes to the better outcome. It also maintains the TWAP oracle used by other repos.

## Objective

Find issues that:
- mis-estimate V4 or Juicebox outputs
- choose the wrong path and lose user value
- break swap settlement through sign, delta, or slippage mistakes
- let oracle state become manipulable or stale in ways downstream repos trust
- recurse unsafely when composed with the buyback hook

## Scope

In scope:
- `src/JBUniswapV4Hook.sol`
- `src/libraries/Oracle.sol`
- deployment scripts in `script/`

Key dependencies:
- `nana-core-v6`
- Uniswap V4
- consumers such as `nana-buyback-hook-v6` and `univ4-lp-split-hook-v6`

## System Model

On swaps involving a Juicebox project token, the hook:
- estimates the V4 path
- estimates the Juicebox path
- routes through the better option
- records observations for future TWAP queries

It is also an oracle surface:
- pools using it depend on its observation ring buffer
- other repos may call `observe()` and trust its output as a pricing guardrail

## Critical Invariants

1. Route selection is honest
The hook must compare like-for-like outputs and not mix preview semantics or fee conventions across routes.

2. Settlement deltas are signed correctly
Any override path must satisfy Uniswap’s delta conventions and the user’s minimum-out expectation.

3. Oracle writes remain usable
Observation growth, lookup, and fallback-to-spot behavior must not silently degrade into unsafe values for downstream consumers.

4. Reentrancy guard is effective
Recursive routing through the buyback hook or terminal calls must degrade safely rather than spin or corrupt state.

## Threat Model

Prioritize:
- slippage-sign mismatches
- preview calls that revert or return partial information
- dynamic protocol or pool fees
- low-history or stale-history oracle behavior
- exact-input versus unsupported exact-output assumptions

## Hotspots

- `beforeSwap` and any override-delta return path
- output estimation helpers for both routes
- `afterSwap`, `afterAddLiquidity`, and `afterRemoveLiquidity` oracle writes
- ring-buffer growth and historical lookup in `Oracle.sol`
- recursion guard behavior when composed with buyback logic

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

Current tests focus on:
- route-estimate regressions
- oracle width and observation behavior
- slippage semantics
- three-way routing and structural arbitrage
- sell-path reentrancy

Strong findings here usually show a path-selection bug that downstream repos would treat as economic truth.
Additional source-specific checks worth doing:
- confirm buy-side estimation still prefers `previewPayFor(...)` before static weight math
- confirm sell-side estimation still uses `previewCashOutFrom(...)` and deducts terminal fee only when it can read one
- confirm `hookData` semantics remain split: `_beforeSwap` requires exactly one encoded `uint256 amountOutMin`, while `_afterSwap` tolerates extra metadata for pure V4 routes
- confirm spot fallback is still the only low-history escape hatch and not an accidental bypass of routing safeguards
The hook compares JB expected output vs V4 expected output. Verify:
- `calculateExpectedTokensWithCurrency()`: correctly handles currency conversion via `PRICES.pricePerUnitOf()`, reserved percent deduction, and payment token decimal normalization
- `calculateExpectedOutputFromSelling()`: uses total surplus (all terminals) which may overestimate for projects with `useTotalSurplusForCashOuts = false`. The fee deduction uses `terminal.FEE()` (wrapped in try-catch; defaults to 0 if the terminal does not implement `IJBFeeTerminal`) even for feeless addresses (conservative by design for standard terminals).
- `estimateUniswapOutput()`: TWAP-to-price conversion handles overflow correctly (two paths: `sqrtPriceX96 <= uint128.max` and overflow path via `FullMath.mulDiv`). V4 pool fee is deducted from estimate. Dynamic fee pools (`key.fee == DYNAMIC_FEE_FLAG`) read the actual LP fee from `slot0` via `LPFeeLibrary.isDynamicFee()` detection.
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

### 8. Composition with JBBuybackHook

This hook serves as both the V4 pool hook and the `ORACLE_HOOK` for `JBBuybackHook`. Verify:
- The `_routing` reentrancy guard prevents infinite recursion when the buyback hook swaps → `_beforeSwap` routes through JB → `terminal.pay()` re-enters the buyback hook → tries to swap again
- `hookData: abi.encode(uint256(0))` from the buyback hook is correctly decoded as `amountOutMin = 0`
- With `amountOutMin = 0`, the hook still provides meaningful protection via TWAP-based routing (picking the better of V4 vs JB)
- The reentrancy revert is clean — no partial state changes, no token loss

### 9. Oracle State Consistency

- `_afterInitialize` sets up the first observation. Verify the initial state (`index=0, cardinality=1, cardinalityNext=1`) is correct.
- `_recordObservation` reads pool state (`getSlot0`, `getLiquidity`) and writes to the observation array. These are not atomic with the swap/liquidity change. Is there a window where the recorded tick/liquidity is stale?
- Can the oracle state diverge between `states[poolId]` and the actual `observations[poolId]` array?
- What happens if `observations[poolId].grow()` is called with `current == 0`? (Reverts with `Oracle_CardinalityCannotBeZero`)

## Invariants to Verify

1. **Flash-accounting balance**: After every swap (whether V4 or JB routed), PoolManager's balance check succeeds. No tokens are created or destroyed.
2. **TWAP monotonicity**: `tickCumulative` is monotonically non-decreasing for non-negative ticks and correctly accumulates for all tick values.
3. **Oracle cardinality**: `cardinality <= cardinalityNext <= 1024` always holds. `index < cardinality` always holds.
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
- Oracle deep tests (15 tests: init, write, cardinality growth, TWAP, warmup)
- Stress tests for extreme amounts and edge cases
- Regression tests for previously found issues

## Previous Audit Findings

An automated audit was conducted. All known risks, trust assumptions, and previously identified issues are documented in [RISKS.md](./RISKS.md). Key areas that emerged from prior review:

- **Spot price fallback during TWAP warmup** (Section 2.1) -- manipulable routing window for the first 30 minutes after pool creation.
- **tickCumulative int56 overflow** (Section 2.4) -- silent overflow after ~1.4 years at max tick. Widened from int48 (which overflowed after ~44 hours) as a direct result of prior findings.
- **Conservative sell-side estimation** (Section 3.4) -- fee always deducted even for feeless addresses; total surplus used regardless of project config.
- **Static weight composition divergence** (Section 6.1) -- routing estimate uses static ruleset weight, diverges when a data hook overrides weight at execution time.
- **Zero-tax sell-path bypass** (Section 4.4) -- V4 pool sell-side liquidity permanently bypassed for zero-tax projects. Accepted behavior.
- **hookData length inconsistency** (Section 3.2) -- `_beforeSwap` requires exactly 32 bytes, `_afterSwap` accepts >= 32.

See [RISKS.md](./RISKS.md) for the complete set of documented risks and trust assumptions.

## Anti-Patterns to Hunt

| Pattern | Where to Look | Why It's Dangerous |
|---------|--------------|-------------------|
| Spot price fallback during TWAP warmup | `estimateUniswapOutput` | When TWAP returns 0, falls back to manipulable spot price. Users rely on `amountOutMin` for protection during this window. |
| `_routing` reentrancy flag | `_beforeSwap` | Simple boolean flag to prevent recursive routing. Verify it's reset on all exit paths (including reverts). |
| `hookData.length == 32` vs `>= 32` | `_beforeSwap` vs `_afterSwap` | Inconsistent length check. `_beforeSwap` requires exactly 32 bytes, `_afterSwap` allows 32+. Can this be exploited? |
| `forceApprove` before terminal call | `_routeThroughJuicebox` (buy path) | Approval set before `terminal.pay()`. If pay reverts, approval persists. If pay succeeds but returns fewer tokens than approved, dangling approval exists. |
| Both-tokens-are-JB case | `_beforeSwap` | Only buy-side evaluated when both tokens are JB tokens. Sell-side comparison is skipped. Can an attacker exploit this asymmetry? |
| `calculateExpectedOutputFromSelling` surplus assumption | `calculateExpectedOutputFromSelling` | Uses total surplus even when `useTotalSurplusForCashOuts = false`. This overestimates JB output, potentially routing through JB when V4 would be better. |
| int56 tickCumulative overflow | `Oracle.write` | `tickCumulative += int56(tick) * int56(timeDelta)`. At max tick (887,272), overflows after ~1.4 years. |

## Error Reference

| Error | Trigger |
|-------|---------|
| `JBUniswapV4Hook_AmountOutMinRequired()` | `hookData` is not exactly 32 bytes in `_beforeSwap`. Callers must encode `uint256 amountOutMin`. |
| `JBUniswapV4Hook_ExactOutputSwapsNotSupported()` | `params.amountSpecified > 0` in `_beforeSwap`. Only exact-input swaps are supported. |
| `JBUniswapV4Hook_InsufficientOutput()` | V4 route swap output is below `amountOutMin` in `_afterSwap`. |
| `JBUniswapV4Hook_ReentrantRouting()` | `_routing` flag is already set when `_beforeSwap` is entered. Prevents recursive routing through JB terminal. |
| `JBUniswapV4Hook_SecondsAgoCannotBeZero()` | `secondsAgo == 0` in `observeTWAP()`. TWAP requires a non-zero lookback period. |
| `Oracle_CardinalityCannotBeZero()` | `Oracle.grow()` or `Oracle.observeSingle()` called with `cardinality == 0`. Pool not initialized. |
| `Oracle_TargetPredatesOldestObservation(uint32, uint32)` | `Oracle.binarySearch()` target timestamp is older than the oldest observation in the ring buffer. |

## Compiler and Version Info

- **Solidity**: 0.8.28
- **EVM target**: Cancun
- **Optimizer**: via-IR, 200 runs
- **Fuzz runs**: 4,096 (invariant: 1,024 runs, depth 100)
- **Dependencies**: Uniswap V4 core + periphery, OpenZeppelin, nana-core-v6
- **Build**: `forge build` (Foundry)

## How to Report Findings

For each finding:

1. **Title** -- one line, starts with severity (CRITICAL/HIGH/MEDIUM/LOW)
2. **Affected contract(s)** -- exact file path and line numbers
3. **Description** -- what is wrong, in plain language
4. **Trigger sequence** -- step-by-step, minimal steps to reproduce
5. **Impact** -- what an attacker gains, what a user loses (with numbers if possible)
6. **Proof** -- code trace showing the exact execution path, or a Foundry test
7. **Fix** -- minimal code change that resolves the issue

**Severity guide:**
- **CRITICAL**: Flash-accounting violation, oracle manipulation enabling fund theft, or permanent routing DoS.
- **HIGH**: Conditional fund loss, systematic routing to worse path, or broken invariant.
- **MEDIUM**: Value leakage, suboptimal routing under specific conditions, griefing.
- **LOW**: Informational, edge-case-only with no material impact.

Go break it.
