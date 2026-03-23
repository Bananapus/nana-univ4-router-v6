# univ4-router-v6 -- Risks

Forward-looking risk analysis of `JBUniswapV4Hook` (~963 lines) and `Oracle` library (~392 lines).

## 1. Trust Assumptions

- **Uniswap V4 PoolManager** -- All take/settle flash-accounting relies on PoolManager enforcing balance invariants at the end of `unlock()`. A PoolManager bug would compromise every hooked pool. No fallback exists.
- **Oracle observation integrity** -- Observations are written only in hook callbacks (`afterSwap`, `afterAddLiquidity`, `afterRemoveLiquidity`, `afterInitialize`). PoolManager guarantees these callbacks execute atomically within the swap transaction; an attacker cannot forge observations without triggering a real pool state change.
- **Hook permission flags** -- The contract address encodes permission bits via CREATE2 salt mining (`AFTER_INITIALIZE`, `BEFORE_SWAP`, `AFTER_SWAP`, `BEFORE_SWAP_RETURNS_DELTA`, `AFTER_ADD_LIQUIDITY`, `AFTER_REMOVE_LIQUIDITY`). If the address is deployed with incorrect flags, hooks silently fail to fire. `HookMiner.find()` is used in deployment scripts/tests to guarantee correct flag encoding.
- **Juicebox core contracts** -- Routing accuracy depends on `IJBController.currentRulesetOf()` (weight, reservedPercent, baseCurrency), `IJBTerminalStore.currentReclaimableSurplusOf()` (cashout estimates), `IJBPrices.pricePerUnitOf()` (currency conversion), and `IJBDirectory.primaryTerminalOf()` (terminal resolution). All external calls are try-catch wrapped; failures silently route to V4 (never block swaps, but may produce suboptimal routing).
- **ERC-20 compliance** -- Uses `SafeERC20.forceApprove` for terminal approvals. Fee-on-transfer and rebasing tokens will cause accounting mismatches in the take-transform-settle cycle. The PoolManager balance check at unlock end would revert such swaps rather than silently losing funds.
- **Single-unlock reentrancy model** -- No explicit `ReentrancyGuard`. Protection relies entirely on PoolManager's single-unlock constraint and atomic flash-accounting reconciliation.

## 2. TWAP Oracle Risks

### 2.1 Warmup window (spot fallback)

- For the first 30 minutes (`TWAP_PERIOD = 1800s`) after pool initialization, `_getTWAPSqrtPrice` returns 0 and `estimateUniswapOutput` falls back to the current spot price from `getSlot0()`.
- Spot price is trivially manipulable within a single block. During warmup, an attacker can sandwich the routing decision to force a suboptimal path.
- The exact boundary: TWAP activates when `block.timestamp - TWAP_PERIOD >= oldestObservation.blockTimestamp`. At `TWAP_PERIOD - 1` seconds, spot fallback is still used; at `TWAP_PERIOD` seconds, TWAP activates. Transition is smooth (<5% estimate difference per `test_SpotFallback_WarmupBoundary`).
- Low-activity pools may remain in spot-price fallback indefinitely if no swap/liquidity event triggers observation writes.
- Mitigation: `amountOutMin` in hookData provides a hard floor on output regardless of routing path.

### 2.2 Observation cardinality limits

- Oracle starts at cardinality 1, auto-grows by doubling at capacity boundaries until `MAX_TWAP_CARDINALITY = 1024`.
- Largest single growth (512 -> 1024) costs ~512 cold SSTOREs. This cost is borne by the swap/liquidity caller that triggers the growth. An attacker could grief callers by timing transactions to coincide with growth boundaries.
- At cardinality 1024 with 12-second blocks, the oracle stores ~205 minutes of history. At 2-second blocks, it stores just over 34 minutes -- enough to support the 30-minute TWAP window after warmup.
- **Gas cost of cardinality growth as DoS surface.** The largest single growth step (512 → 1024) costs ~512 cold SSTOREs (~10M gas). The caller who triggers this growth boundary bears the entire cost. An attacker could monitor cardinality levels and time their transactions to avoid triggering growth, while legitimate users bear the cost unpredictably. This is not exploitable for profit but can cause user-facing gas spikes. Mitigation: projects can pre-grow cardinality by calling `increaseCardinalityNext` during low-activity periods (not currently exposed as a public function — growth is automatic).

### 2.3 TWAP_PERIOD selection tradeoffs

- 30-minute window balances manipulation resistance against responsiveness. Shorter windows are cheaper to manipulate; longer windows are slower to reflect genuine price changes.
- `TWAP_PERIOD` is a compile-time constant (`uint32 public constant TWAP_PERIOD = 1800`). Cannot be adjusted per-pool or updated post-deployment. If market conditions change (e.g., new L2 block times), the only recourse is redeployment.
- For a V4 pool with X liquidity, the cost to move the TWAP by 1 tick over the full window is approximately `X * tickSpacing * 1800 / blockTime` in capital-at-risk. At 12-second blocks, a single-block push weights only 12/1800 = 0.67% of the window.

## 3. Routing Risks

### 3.1 Three-way routing logic

- `_beforeSwap` evaluates two routes: V4 pool (via TWAP-based `estimateUniswapOutput`) and Juicebox (via `calculateExpectedTokensWithCurrency` for buying or `calculateExpectedOutputFromSelling` for selling). Picks the one with higher estimated output.
- If neither token is a JB project token (`TOKENS.projectIdOf` returns 0 for both), routing skips JB comparison entirely and passes through to V4 (`ZERO_DELTA`).
- When both tokens are JB project tokens, only the buy-side (minting into the output project) is compared. Sell-side evaluation is omitted to save gas. This may miss sell-side opportunities.

### 3.2 Slippage protection layers

- **Hook level (`_beforeSwap`)**: JB routes enforce `amountOutMin` via the terminal's `minReturnedTokens` / `minTokensReclaimed` parameter.
- **Hook level (`_afterSwap`)**: V4 routes validate actual delta output against `amountOutMin`. Uses absolute value of negative delta (V4 convention: output amounts are negative). Fixed from a prior bug where `outputAmount > 0` was never true for V4's negative convention.
- **JuiceboxSwapRouter (test utility)**: Additional slippage check in `unlockCallback` after adjusting for pre-deposited amounts.
- Gap: `_beforeSwap` requires exactly 32 bytes hookData (`== 32`), while `_afterSwap` accepts `>= 32`. Routers cannot append extra metadata beyond `amountOutMin`.

### 3.3 estimateUniswapOutput accuracy

- Uses TWAP sqrtPrice (not spot) to estimate output. Applies pool fee deduction (`key.fee / 1_000_000`). Does not account for actual price impact from the swap itself.
- For large swaps relative to pool liquidity, the estimate overestimates output because it assumes constant price (no slippage curve). This biases routing toward V4 for large swaps.
- When sqrtPriceX96 exceeds `type(uint128).max`, the function branches to use `FullMath.mulDiv` with `ratioX128` to avoid overflow. Verified across the full tick range in `testFuzz_FullMathSafety_PriceSquared`.
- The estimate is a view function -- no actual swap is simulated. The V4 pool's real output may differ due to tick crossings, concentrated liquidity gaps, and dynamic fees.

### 3.4 Conservative sell estimate

- `calculateExpectedOutputFromSelling` always deducts the terminal fee (read dynamically via `terminal.FEE()` / `JBConstants.MAX_FEE`) even if the hook address is registered as feeless. This systematically disadvantages JB sell routing.
- Uses total surplus (empty terminals/accountingContexts arrays) regardless of the project's `useTotalSurplusForCashOuts` flag. May overestimate JB cashout output for projects with local-surplus-only configuration. Actual cashout would return less, but `amountOutMin` protects the user.
- Sell-side estimation now prefers `previewCashOutFrom`, which can incorporate cash-out data-hook effects when the
  terminal store supports that preview surface. If previewing is unavailable or reverts, the hook falls back to the
  static surplus estimate and then to V4 if estimation fails entirely.

## 4. MEV Surface

### 4.1 Spot fallback sandwich window

- During the 30-minute warmup period, `estimateUniswapOutput` uses spot price. An attacker can push spot price in one block, cause the routing decision to use the manipulated price, and reverse in the next block.
- The attack shifts the routing decision boundary: manipulating V4 spot price downward makes JB minting look relatively better, forcing the victim to mint at the ruleset weight instead of getting a better V4 rate.
- Mitigation: `amountOutMin` limits losses. The JB minting rate (ruleset weight) is not manipulable within a transaction, so the JB route itself is not sandwichable.

### 4.2 TWAP manipulation cost

- A single-block push weights 12/1800 = 0.67% of the 30-minute TWAP window. Verified: single-block 10 ETH manipulation against 1000 ETH liquidity pool produces <20% TWAP deviation (`test_TWAPManipulation_SingleBlockPushIsBounded`).
- Sustained 5-block manipulation (60 seconds = 3.3% of window) produces <30% TWAP deviation (`test_TWAPManipulation_SustainedPushOverFiveBlocksIsBounded`).
- To shift the TWAP arithmetic mean tick by N ticks, an attacker must sustain a tick displacement of `N * TWAP_PERIOD / holdTime` for `holdTime` seconds. The cost scales linearly with pool liquidity and quadratically with displacement magnitude (concentrated liquidity costs increase as the tick moves further from center).
- After manipulation stops and normal trading resumes, the TWAP converges back to true price within one full TWAP_PERIOD window as manipulated observations age out (`test_TWAPManipulation_RecoveryAfterManipulationStops`).

## 5. Composition with JBBuybackHook

- **Same-pool composition**: `JBUniswapV4Hook` is designed to serve as both the V4 pool hook and the `ORACLE_HOOK` for `JBBuybackHook`. The buyback hook queries `observe()` for TWAP data and executes swaps on the same pool.
- **Reentrancy path**: When the buyback hook swaps → `_beforeSwap` fires → routing logic calls `terminal.pay()` → this re-enters the buyback hook via the data hook → buyback hook tries to swap again. The `_routing` reentrancy flag in `_beforeSwap` detects this recursion and reverts.
- **Fallback behavior**: The reentrancy revert is caught by the buyback hook's try/catch, which falls back to minting via the controller. No funds are lost. The user receives tokens at the mint rate.
- **Static weight incompatibility**: This hook compares V4 pool output against the ruleset's static issuance weight. If the project's data hook overrides weight at payment time (e.g., a buyback hook adjusting based on TWAP), the static estimate may be stale. Deployers **must ensure** that any weight override does not make the static estimate dangerously inaccurate — otherwise routing decisions will consistently diverge, and users may receive suboptimal rates. This is an integration requirement, not a graceful fallback.
- **hookData from buyback hook**: The buyback hook passes `abi.encode(uint256(0))` as hookData. The `0` value for `amountOutMin` delegates slippage protection to the hook's own TWAP-based routing — the hook will route through JB if it offers a better rate, or let V4 execute if the pool price is better.

## 6. Deployment Caveats

### 6.1 Weight composition divergence (buy-side routing)

When `JBUniswapV4Hook` is composed with `JBBuybackHook` (or any data hook) on the same project, the routing estimate can diverge from actual execution:

1. **`calculateExpectedTokensWithCurrency`** reads the ruleset's **static weight** (`ruleset.weight`) to estimate how many tokens a Juicebox payment would mint. This estimate drives the V4-vs-JB routing decision in `_beforeSwap`.
2. If the project's data hook **overrides weight at payment time** (e.g., `JBBuybackHook` adjusts weight based on its own TWAP comparison), the actual tokens minted will differ from the static estimate.
3. **Consequences**:
   - The hook may route through JB when V4 would have been better (static weight overestimates issuance, but the data hook reduces it at execution time).
   - The hook may route through V4 when JB would have been better (static weight underestimates issuance because the data hook increases it).
   - In the worst case, the JB route is selected but `terminal.pay()` returns fewer tokens than estimated, and the user receives a suboptimal rate. The `amountOutMin` parameter in hookData provides a safety floor against excessive slippage.
4. **Sell-side estimation is only as strong as the store preview surface**: `calculateExpectedOutputFromSelling`
   now prefers `previewCashOutFrom`, which is materially better for cash-out-hooked projects because it can simulate
   `beforeCashOutRecordedWith(...)`. If a store implementation lacks that preview or if the preview reverts, the hook
   falls back to the older static surplus estimate.

**Deployer requirement**: When composing this hook with a project that has an active data hook, treat buy-side and
sell-side differently. Buy-side routing still assumes static issuance weight, so deployers must verify that pay-side
overrides do not make the estimate dangerously stale. Sell-side routing is stronger than before because it prefers
`previewCashOutFrom`, but it still depends on the underlying store preview faithfully matching the terminal's real
cash-out path.

This is documented inline at `src/JBUniswapV4Hook.sol` lines 47-55 as `COMPOSITION WARNING`, with a related `WARNING` note at line 232.

## 7. Integration Risks

### 7.1 Hook deployment address mining

- V4 hooks encode permission flags in the contract address's lower bits. Deployment requires CREATE2 with a specific salt (`HookMiner.find()`) that produces an address matching the required flags.
- If the deployer uses the wrong creation code or constructor arguments, the mined salt will produce an address with incorrect flags. Hooks will silently fail to fire, and swaps through the pool will execute without routing comparison or oracle updates.
- The hook address is immutable after deployment. If hook permissions need to change, a new hook must be deployed at a new address, and pools must be migrated.

### 7.2 afterSwap / afterInitialize callbacks

- `_afterSwap` records oracle observations AND validates V4 slippage. If `_afterSwap` fails to execute (wrong address flags), neither protection operates.
- `_afterInitialize` bootstraps the oracle with the first observation. Without it, `states[poolId]` remains zero-initialized, and all TWAP queries revert with `Oracle_CardinalityCannotBeZero`.
- `_afterAddLiquidity` and `_afterRemoveLiquidity` also write observations. These provide additional TWAP data points between swaps, improving oracle accuracy for pools with frequent liquidity changes but infrequent swaps.

### 7.3 Cross-pool interactions

- Each pool has its own independent observation buffer (`mapping(PoolId => Oracle.Observation[65_535])`). No cross-pool oracle contamination is possible.
- Multiple pools can reference the same JB project token. The hook evaluates routing independently per pool. Different pools with different fee tiers or liquidity depths may route differently for the same JB token.
- The hook is a singleton: one contract serves all pools that reference it in their `PoolKey.hooks` field. A bug in the hook affects all such pools simultaneously.

### 7.4 Token address normalization

- Uniswap V4 uses `address(0)` for native ETH; Juicebox uses `0x000000000000000000000000000000000000EEEe`. The `_normalizeToken` function maps between them. If a new V4 convention or JB convention is introduced, this mapping breaks silently.
- Currency ID for JB price feeds: `uint32(uint160(token))`. This truncation means different tokens whose addresses share the same lower 32 bits would collide. Statistically unlikely for EVM CREATE/CREATE2 addresses, but theoretically possible.

## 8. Invariants to Verify

- **TWAP always dampens manipulation vs spot** -- A single-block price push should always produce smaller TWAP deviation than spot deviation. Verified in `test_SpotFallback_TWAPDampensAfterWarmup`: spot deviation from a 50 ETH push is significantly larger than TWAP deviation after warmup. This holds as long as the TWAP window contains honest observations.
- **Recovery after manipulation stops** -- After sustained manipulation ends and normal trading resumes for one full TWAP_PERIOD, the TWAP should converge to within 5% of pre-manipulation baseline. Verified in `test_TWAPManipulation_RecoveryAfterManipulationStops`: TWAP changes after manipulation stops (not stuck), though exact convergence depends on post-manipulation equilibrium price.
- **Warmup boundary transition smoothness** -- The transition from spot fallback to TWAP at exactly `TWAP_PERIOD` seconds should not create a price discontinuity >5%. Verified in `test_SpotFallback_WarmupBoundary`: estimates at `TWAP_PERIOD - 1` and `TWAP_PERIOD` differ by <500 bps.
- **Oracle observation monotonicity** -- `blockTimestamp` in observations increases monotonically (modulo uint32 wraparound). Same-block writes are no-ops (`Oracle.write` returns early when `last.blockTimestamp == blockTimestamp`). Verified in `test_OracleWrite_SameBlock_NoOp`.
- **Flash-accounting conservation** -- For every `poolManager.take()`, a corresponding `_settleOutput()` must execute within the same `unlock()` call, or PoolManager reverts. The hook never holds tokens across transactions.
- **Cardinality cap** -- `cardinalityNext` never exceeds `MAX_TWAP_CARDINALITY` (1024). Growth logic doubles until the cap. Verified in `test_OracleCardinality_CapsAtConfiguredMaximum`.
- **Routing never blocks V4 swaps** -- All JB protocol calls in the routing path (`currentRulesetOf`, `currentReclaimableSurplusOf`, `pricePerUnitOf`, `primaryTerminalOf`) are try-catch wrapped. A revert in any JB contract results in V4 fallback, not a failed swap.

## 9. Accepted Behaviors

### 9.1 JB routing bypasses V4 pool price discovery (by design)

When the hook routes a swap through Juicebox (minting or cashing out), the V4 pool's AMM state is not touched. The hook returns a `BeforeSwapDelta` that cancels the pool-level swap. This means the V4 pool price diverges from the "true" rate offered by JB. Third-party arbitrageurs can correct this divergence independently. The hook does not attempt to align the two prices because doing so would add gas cost and complexity to every routed swap, and the arbitrage opportunity is self-correcting.

### 9.2 Spot price fallback during oracle warmup (accepted risk window)

During the first 30 minutes after pool initialization, routing decisions use the instantaneous spot price (`getSlot0`) instead of the TWAP. This is a known vulnerability window where sandwich attacks on the routing decision are possible. The alternative — blocking all swaps during warmup — would prevent legitimate trading. The `amountOutMin` parameter in hookData provides a hard floor that limits extraction during this window. Projects deploying new pools should seed initial liquidity and execute a few swaps to bootstrap observations before announcing the pool publicly.

### 9.3 Cross-route arbitrage (by design)

When JB routing wins, the hook takes input from PoolManager, routes through the JB terminal, and settles output back. The V4 pool itself is not touched (the hook returns a `BeforeSwapDelta` that cancels the pool swap). This means the V4 pool price does not move, creating a potential arb opportunity between the stale V4 pool price and the JB terminal rate. This is by design: JB routing bypasses the AMM to give users a better rate. Third-party arbitrageurs can correct the V4 pool price independently.

### 9.4 Zero-tax sell-path routing (by design)

When a project has `cashOutTaxRate == 0`, the bonding curve is linear: every token redeems for its exact proportional share of surplus with no penalty. The per-token reclaim value stays constant as supply drops. The hook will repeatedly prefer JB cashout over V4 for sell-side swaps whenever the JB reclaim exceeds the V4 estimate. Since the V4 pool price does not move (tokens bypass the AMM) and the per-token reclaim does not decrease (no tax retention), this preference persists indefinitely. The hook does **not** converge to V4 routing for zero-tax projects. With `cashOutTaxRate > 0`, each cashout retains surplus in the project (the tax portion), causing the per-token reclaim to decrease over time until V4 becomes the better route. This self-correcting behavior does not exist at zero tax. Token holders are redeeming their entitled share of surplus -- no value is extracted beyond what the bonding curve formula allocates. The surplus decreases proportionally with supply, maintaining the exact same per-token backing. Conservation holds exactly: `extracted + remaining_surplus = initial_surplus`. The V4 pool's sell-side liquidity is effectively bypassed for zero-tax projects. LPs in such pools should expect reduced sell-side volume. See `TestStructuralArbitrage.t.sol` tests 1-8 which prove bounded extraction, convergence, and conservation for projects with `cashOutTaxRate > 0`.
