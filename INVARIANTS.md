# Invariants of `@bananapus/univ4-router-v6`

Last updated: 2026-05-28.

Scope: the Uniswap V4 hook surface that serves Juicebox-aware routing and oracle observation history for project-token pools. This document is scoped to one repo — the canonical top-level invariants live in [`../INVARIANTS.md`](../INVARIANTS.md). See also: [`ARCHITECTURE.md`](./ARCHITECTURE.md), [`ADMINISTRATION.md`](./ADMINISTRATION.md), [`RISKS.md`](./RISKS.md), [`USER_JOURNEYS.md`](./USER_JOURNEYS.md), [`SKILLS.md`](./SKILLS.md), [`STYLE_GUIDE.md`](./STYLE_GUIDE.md), [`AUDIT_INSTRUCTIONS.md`](./AUDIT_INSTRUCTIONS.md), [`CHANGELOG.md`](./CHANGELOG.md).

| Contract | Lines | Role |
|----------|-------|------|
| `JBUniswapV4Hook` | 1325 | V4 `BaseHook` that intercepts swaps involving a Juicebox project token, compares V4 quote vs JB terminal pay/cashout quote, routes whichever wins, and records oracle observations. |
| `libraries/Oracle` | 402 | Circular-buffer observation library (Uniswap V3-derived) backing `observe()` / TWAP lookups. |

`JBUniswapV4Hook` is adminless after deployment: there is no owner, governance, pause, upgrade, or one-shot deployer setter. Constructor wiring (`poolManager`, `tokens`, `directory`, `prices`) is the entire control model. Pools opt in permanently by initializing with this hook address.

---

## Section A — Guarantees to paying users (swappers)

## A.0 Routing matrix

| `tokenIn` is JB token? | `tokenOut` is JB token? | Decision |
|---|---|---|
| no | no | Pass-through to V4 (`ZERO_DELTA`); `_afterSwap` enforces the explicit `amountOutMin` when present, else a warm-pool TWAP floor. |
| no | yes | Buy-side route comparison: `previewPayFor` quote vs `estimateUniswapOutput`. |
| yes | no | Sell-side route comparison: `calculateExpectedOutputFromSelling` (uses `previewCashOutFrom`) vs `estimateUniswapOutput`. |
| yes | yes | Both sides evaluated; higher quote wins; ties favor buy side. |

JB-token detection requires the project to have a **registered ERC-20** (`JBTokens.tokenOf(projectId) == token`); credit-only projects never engage JB routing. (`JBUniswapV4Hook.sol:1090-1100`)

## A.1 Routing and best-execution

- Every swap that touches a Juicebox project's registered ERC-20 is route-compared: the hook computes a V4-pool quote (`estimateUniswapOutput`) AND a Juicebox-side quote (`previewPayFor` on buys, `previewCashOutFrom` on sells) and routes through whichever yields more output. (`JBUniswapV4Hook.sol:734-803`)
- The swapper's minimum output is a discriminator on `hookData`. When `hookData.length >= 32`, the first 32 bytes are honored as an **explicit `amountOutMin`** — including an explicit zero (`abi.encode(uint256(0))`), a deliberate take-any-price opt-out — and the swapper **never receives fewer output tokens than that minimum**. When `hookData` is absent (`length < 32`, e.g. a generic aggregator / Universal Router / wallet integration that does not speak JB's encoding), a pure-V4 settlement instead derives a TWAP-based protection floor so it is not left unprotected. The explicit minimum is enforced on the settlement balance delta on both routing paths. (`JBUniswapV4Hook.sol:597-636, 664-673`)
- For Juicebox-routed sells, the internal `routeMinimum` is raised to the previewed reclaim (`juiceboxExpectedOutput`) so the terminal cannot under-fill its own preview and still win the route. (`JBUniswapV4Hook.sol:819-825`)
- For Juicebox-routed buys, `routeMinimum` is raised to `uniswapV4ExpectedTokens + 1`, enforcing the strict "better than V4" floor on actual settlement. (`JBUniswapV4Hook.sol:826-831`)
- Final settlement is measured by **balance delta on the hook's side**, not the terminal's return value. Fee-on-transfer output tokens and over-reporting terminals cannot silently degrade realized output below `amountOutMin`. (`JBUniswapV4Hook.sol:1265-1298`)
- If the Juicebox preview surface reverts or is unavailable, the JB quote degrades to `0` and the swap continues on V4 (conservative degrade rule). (`JBUniswapV4Hook.sol:281-286, 751-754`)
- Buyback-hook metadata-only preview hints are **deliberately ignored** by live routing; only terminal-direct `previewPayFor` / `previewCashOutFrom` amounts count. Prevents same-pool indirect routing via composed hooks.
- Quotes that exceed Uniswap V4's signed-delta capacity (`MAX_V4_DELTA = type(int128).max`) are treated as ineligible so the swap falls back to V4 instead of reverting during settlement. (`JBUniswapV4Hook.sol:135-137, 792-794`)

## A.2 Reentrancy and recursion safety

- The hook is designed to compose with `JBBuybackHook` on the **same V4 pool**. The transient `_routing` flag is set before `_routeThroughJuicebox` and re-entered swaps revert `JBUniswapV4Hook_ReentrantRouting`. Composed `buyback hook -> V4 pool -> this hook -> JB terminal -> buyback hook` cycles cannot recurse. (`JBUniswapV4Hook.sol:178, 682-683, 1203, 1304`)
- The flag survives across the `poolManager.unlock` boundary because it lives in regular storage with read-then-write semantics inside the same transaction. Custom flag (not OZ `ReentrancyGuard`) avoids colliding with PoolManager's own unlock lock.

## A.3 Settlement integrity

- Exact-output swaps (`params.amountSpecified > 0`) are **not supported** and revert `JBUniswapV4Hook_ExactOutputSwapsNotSupported`. Only exact-input semantics are honored. (`JBUniswapV4Hook.sol:699-701`)
- On sell-side ERC-20 routes, the hook asserts the pre/post input-token balance is unchanged after the JB cash-out. A partial-fill terminal that returns or leaves project tokens behind reverts `JBUniswapV4Hook_SellInputReturned` before PoolManager settlement. (`JBUniswapV4Hook.sol:1209-1212, 1271-1284`)
- A non-zero sell that yields zero output reverts `JBUniswapV4Hook_JuiceboxSellDidNotDeliver` rather than settling a degenerate zero-output swap. (`JBUniswapV4Hook.sol:1286-1292`)
- Temporary ERC-20 allowances granted to the terminal are checked for **exact consumption** post-call. Any leftover allowance reverts `JBUniswapV4Hook_TemporaryAllowanceNotConsumed`, preventing a terminal from holding live spend authority on the hook's residual balance across transactions. (`JBUniswapV4Hook.sol:1163-1174, 1226-1248`)
- Balance-delta accounting means **pre-existing hook balances are never swept into settlement** — only the delta produced by *this* terminal call moves to PoolManager. Stranded-token attacks via dust pre-funding the hook are blocked.
- V4-routed swaps (where the hook returned `ZERO_DELTA`) are validated in `_afterSwap` against the actual swap delta: the explicit `amountOutMin` when `hookData` carries one, otherwise a TWAP-derived floor when the pool's oracle is warm (a cold pool imposes no hook-level floor and the swap proceeds under the caller's own slippage protection). (`JBUniswapV4Hook.sol:585-640`)

## A.4 Oracle protections

- `_beforeSwap` route comparison uses **TWAP-derived** V4 quotes (`_getTWAPSqrtPrice` over `TWAP_PERIOD = 30 minutes`) when sufficient observation history exists, not raw spot price. (`JBUniswapV4Hook.sol:140, 985-1031`)
- When observation history is insufficient (`cardinality < 2` or oldest observation < 30min old), the V4 route-*comparison* quote (`estimateUniswapOutput`) falls back to current spot. This is documented and bounded; an explicit `amountOutMin`, when supplied, provides the absolute execution floor. The settlement *floor* (`_twapProtectionFloor`) never falls back to spot — on a cold pool it returns 0 and no hook-level floor is imposed. (`JBUniswapV4Hook.sol:990-1014, 410-433, 1410-1434`)
- Once TWAP is expected to be available, observation-read failures cause the swap to revert rather than silently degrade to spot pricing. Fail-closed on mature oracles. (`JBUniswapV4Hook.sol:1017-1019`)
- The cap-aware observation guard refuses to overwrite a freshly-stored observation when the new second-oldest entry is younger than `TWAP_PERIOD`, preserving the 30-minute window even under sustained sub-2s block cadence (~1024 slots / 1s would otherwise erase the window in ~17 minutes). (`JBUniswapV4Hook.sol:1114-1133`)
- Swap-fee normalization happens **before** the price-ratio conversion inside `estimateUniswapOutput`, mirroring V4 swap math so the estimator's rounding matches actual execution rounding (avoids off-by-one drift at typical fee tiers for small inputs). (`JBUniswapV4Hook.sol:418-445`)
- The TWAP arithmetic-mean tick is rounded toward negative infinity for negative tick deltas (Uniswap V3 convention), avoiding silent truncation bias on bearish moves. (`JBUniswapV4Hook.sol:1080-1087`)

## A.5 Currency and token handling

- Native ETH is normalized via `_normalizeToken`: Uniswap's `address(0)` maps to Juicebox's `JB_NATIVE_TOKEN` (`0xEEee...EEeE`) before terminal lookup and preview calls. Both sides of the swap are normalized consistently. (`JBUniswapV4Hook.sol:1033-1039`)
- Token decimals are read with `try IERC20Metadata.decimals()`; failures default to `18`. Tokens advertising more than `77` decimals are treated as unsupported (would overflow `10**decimals`) and the route degrades to `0`. (`JBUniswapV4Hook.sol:330-333, 966-979`)
- Currency-ID collisions on `uint32(uint160(token))` are bounded to view-only preview helpers and never affect live execution path selection (collision rate ~0.001% at ~10k active tokens; see `RISKS.md §9 Accepted risks and notes`).

---

## Section B — Guarantees to operators and integrators

## B.1 Powers no party retains

There are no operator powers on this hook. After deployment:

- **No owner.** No `Ownable`, no `_DEPLOYER`, no governance role.
- **No pause.** Swaps cannot be paused, blocked, or fee-switched on hooked pools.
- **No upgrade.** Hook bytecode is fixed; recovery from a bug requires a new hook deployment + pool migration.
- **No retunable parameters.** `TWAP_PERIOD = 1800`, `MAX_TWAP_CARDINALITY = 1024`, `TWAP_SLIPPAGE_DENOMINATOR = 10000`, `TWAP_SLIPPAGE_TOLERANCE = 1500` (the 15% default floor tolerance), `MAX_V4_DELTA = type(int128).max`, `JB_NATIVE_TOKEN`, `UNISWAP_NATIVE_ETH` are all `public constant`. (`JBUniswapV4Hook.sol:124-146`)
- **No registry / mapping.** Pool-to-routing settings, allowlists, blocklists — none exist. The hook applies uniformly to every pool that initializes against it.
- **No setChainSpecificConstants.** Unlike `JBBuybackHook` / `JBRouterTerminal`, this hook has no one-shot deployer-only setter. All chain wiring is in the constructor.

## B.2 Powers pool creators implicitly hold

- **Pool initialization is the act of opting in.** Whoever calls `poolManager.initialize` with this hook's address permanently binds the resulting `PoolId` to this hook's behavior. No on-chain undo.
- **Hook-data interface choice.** `hookData` is optional. When present (`length >= 32`), the first 32 bytes are the caller's explicit `amountOutMin` (an explicit zero is a deliberate opt-out); integrators may append further metadata after that prefix. When absent (`length < 32`), the caller gives no minimum and a pure-V4 settlement is floored against the warm-pool TWAP instead. (`JBUniswapV4Hook.sol:596-640`)

## B.3 Powers integrators trust the hook for

- **IGeomeanOracle-compatible `observe()`.** Downstream consumers (notably `JBBuybackHook`) read TWAP via `observe(key, secondsAgos[])` and `observeTWAP(...)`. Both are `view` and never mutate state. (`JBUniswapV4Hook.sol:498-552`)
- **Observation recording on liquidity events and swaps.** `_afterInitialize`, `_afterAddLiquidity`, `_afterRemoveLiquidity`, `_afterSwap` each call `_recordObservation` exactly once per call (idempotent within a block — `Oracle.write` is a no-op when `blockTimestamp` matches the last observation). (`JBUniswapV4Hook.sol:472-489, 562-661`)
- **Hook permission bits match implementation.** `getHookPermissions()` exposes the exact callbacks the hook implements; mismatched address-encoded permission bits would cause Uniswap V4 to silently skip callbacks. (`JBUniswapV4Hook.sol:472-489`)

---

## Section C — Per-contract operation inventory

## C.1 `JBUniswapV4Hook` — `src/JBUniswapV4Hook.sol`

V4 `BaseHook`. Holds no persistent project funds — only transient swap-in-flight balances inside a single PoolManager unlock. All callbacks gated by `BaseHook`'s `onlyPoolManager` modifier.

**PoolManager-only callbacks (the only state-mutating external surface):**

- **`_beforeSwap(_, key, params, hookData) → (selector, BeforeSwapDelta, uint24)`** — PoolManager only. Reads the explicit `amountOutMin` from `hookData[:32]` when present (`0` when absent), rejects exact-output, identifies JB project tokens via `_projectIdForRegisteredToken`, queries both terminals' previews, compares against `estimateUniswapOutput`, routes the winning side.
  - **Invariants:** Recursive routing reverts (`_routing` flag); exact-output rejected; quotes above `MAX_V4_DELTA` ineligible; JB-routed buys must beat V4 strictly (`> uniswapV4ExpectedTokens`); JB-routed sells must deliver `>= juiceboxExpectedOutput`. (`JBUniswapV4Hook.sol:672-851`)

- **`_afterSwap(_, key, params, delta, hookData) → (selector, int128)`** — PoolManager only. For V4-routed swaps (where `_beforeSwap` returned `ZERO_DELTA`), validates the actual output delta against the explicit `amountOutMin` from `hookData[:32]` when present, otherwise against a warm-pool TWAP floor derived from the actually-consumed input (a cold pool imposes no floor). Records a fresh oracle observation.
  - **Invariants:** explicit minimum (when present) enforced on real V4 swaps, else a warm-pool TWAP floor; absent/short `hookData` is allowed (no revert); observation written exactly once. (`JBUniswapV4Hook.sol:585-640`)

- **`_afterInitialize(_, key, _, _) → selector`** — PoolManager only. Initializes the per-pool `Oracle.Observation` array via `Oracle.initialize`, sets `ObservationState{index:0, cardinality:1, cardinalityNext:1}`.
  - **Invariants:** one-shot per pool; first observation timestamp is `block.timestamp`. (`JBUniswapV4Hook.sol:581-590`)

- **`_afterAddLiquidity(_, key, _, _, _, _) → (selector, BalanceDelta)`** — PoolManager only. Records an observation; returns zero balance delta. (`JBUniswapV4Hook.sol:562-576`)

- **`_afterRemoveLiquidity(_, key, _, _, _, _) → (selector, BalanceDelta)`** — PoolManager only. Records an observation; returns zero balance delta. (`JBUniswapV4Hook.sol:596-610`)

**Public views (anyone):**

- **`calculateExpectedOutputFromSelling(projectId, tokenAmountIn, outputToken, terminal) view → uint256`** — Quotes a JB cash-out using `terminal.previewCashOutFrom`. Computes exact zero-tax net via `_exactZeroTaxNet`; for positive tax, subtracts `JBFees.standardFeeAmountFrom(gross)`. Returns `0` on any catch (conservative degrade). (`JBUniswapV4Hook.sol:239-287`)

- **`calculateExpectedTokensWithCurrency(projectId, paymentToken, paymentAmount) view → uint256`** — Reference helper using **static ruleset weight** (not preview). Intentionally more permissive than live routing. Live `_beforeSwap` does not use this for buy decisions. Returns `0` on controller revert, price-feed revert, or `decimals > 77`. (`JBUniswapV4Hook.sol:298-378`)

- **`estimateUniswapOutput(poolId, key, amountIn, zeroForOne) view → uint256`** — TWAP-quote estimator. Falls back to spot when `_getTWAPSqrtPrice == 0`. Applies combined protocol+LP swap fee BEFORE the price-ratio conversion to mirror V4 swap math. Linear (no liquidity-depth simulation). (`JBUniswapV4Hook.sol:397-467`)

- **`observe(key, secondsAgos[]) view → (int56[], uint160[])`** — IGeomeanOracle-compatible. Reads slot0 + liquidity from PoolManager, delegates to `Oracle.observe`. (`JBUniswapV4Hook.sol:498-520`)

- **`observeTWAP(poolId, secondsAgo, tick, index, liquidity, cardinality) view → int24`** — External wrapper around `_observeTWAP`. Reverts on `secondsAgo == 0`. (`JBUniswapV4Hook.sol:532-552, 1062-1064`)

- **`getHookPermissions() pure → Hooks.Permissions`** — Declares exactly: `afterInitialize`, `afterAddLiquidity`, `afterRemoveLiquidity`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`. All other flags `false`. (`JBUniswapV4Hook.sol:472-489`)

- **`observations(PoolId, uint256) view → Oracle.Observation`** — auto-generated getter on the per-pool ring buffer.
- **`states(PoolId) view → ObservationState`** — auto-generated getter on `{index, cardinality, cardinalityNext}`.

**Receive:**

- **`receive() external payable`** — accepts ETH only during in-transaction settlement via `CurrencySettler.settle`. No withdrawal mechanism exists. Any ETH that arrives outside a swap is **permanently stuck** (intentional — there is no admin extraction surface). (`JBUniswapV4Hook.sol:215-219`)

**Internal-only:**

- `_routeThroughJuicebox`, `_settleOutput`, `_createSwapDelta`, `_calculateTokensWithCurrency`, `_exactZeroTaxNet`, `_getPrimaryTerminal`, `_getTokenDecimals`, `_getTWAPSqrtPrice`, `_normalizeToken`, `_observeTWAP`, `_projectIdForRegisteredToken`, `_recordObservation`, `_requireTemporaryAllowanceConsumed`.

## C.2 `Oracle` — `src/libraries/Oracle.sol`

Library, no external surface. Used only by `JBUniswapV4Hook`.

- **`initialize(self, time) → (cardinality, cardinalityNext)`** — writes slot 0 with `tickCumulative=0`. (`Oracle.sol:71-83`)
- **`write(self, index, blockTimestamp, tick, liquidity, cardinality, cardinalityNext) → (indexUpdated, cardinalityUpdated)`** — appends a new observation. **Same-block writes are no-ops** (returns prior index unchanged).
- **`grow(self, current, next) → uint16`** — initializes new slots with sentinel `{blockTimestamp:1, initialized:false}` so unwritten slots are distinguishable from real observations.
- **`observe(self, time, secondsAgos[], tick, index, liquidity, cardinality) view → (int56[], uint160[])`** — batch lookup with binary search. Reverts `Oracle_TargetPredatesOldestObservation` when the target is older than the oldest stored observation; reverts `Oracle_CardinalityCannotBeZero` if called before initialization.
- **`transform(last, blockTimestamp, tick, liquidity) private pure`** — post-action backfill of `tickCumulative` over `delta = blockTimestamp - last.blockTimestamp` using the post-swap tick. Same behavior as Uniswap V3's native oracle (see `RISKS.md §9 Accepted risks and notes`).

**Library invariants:**
- Observations are append-only and overwrite oldest-first when at capacity.
- `tickCumulative` uses `int56`, which overflows after ~1.4 years at max tick (887272) — inherited from Uniswap V3.
- Same-block writes do not double-count: `Oracle.write` checks `last.blockTimestamp == blockTimestamp` and short-circuits.
- Initialization sentinel (`blockTimestamp = 1`, `initialized = false`) on freshly-grown slots is distinguishable from any real `block.timestamp` value (which is always `> 1` on real chains), so the cap-aware guard in `_recordObservation` does not misfire on uninitialized slots.
- `observe` for `secondsAgo == 0` returns the current cumulative values (no binary search) — used internally by `_observeTWAP` to batch the (now, now-T) pair into a single call.

## C.3 Constructor wiring (`JBUniswapV4Hook` only)

`constructor(IPoolManager poolManager, IJBTokens tokens, IJBDirectory directory, IJBPrices prices)`:

- `poolManager` is passed to `BaseHook`, which stores it as `immutable` and uses its address bits to validate hook permission flags. Mismatched permission bits brick callback dispatch silently — must be CREATE2-mined to encode the bits `getHookPermissions()` declares.
- `DIRECTORY`, `PRICES`, `TOKENS` are stored as `public immutable`. Wrong wiring at construction can only be fixed by deploying a new hook and migrating pools.
- No post-deploy setter accepts replacement addresses. No proxy. No re-init.

There is no `setChainSpecificConstants` one-shot binder pattern on this contract (unlike `JBBuybackHook`, `JBRouterTerminal`, `DefifaDeployer`). The router does not need late-bound chain identifiers because all behavior is derived from `poolManager` + Juicebox dependencies at construction.

---

## Section D — Cross-cutting invariants

1. **Best-execution floor.** An explicit `amountOutMin` (first 32 bytes of `hookData`, when present) is enforced on the actual settlement balance delta — not on the terminal's return value — on both `_beforeSwap` (JB-routed) and `_afterSwap` (V4-routed). A swap that omits `hookData` and settles through V4 is floored against the warm-pool TWAP (a cold pool imposes no floor and the swap proceeds under the caller's own protection). Fee-on-transfer output tokens cannot silently undercut.

2. **Conservative degrade on preview failure.** Whenever `previewPayFor` / `previewCashOutFrom` / `pricePerUnitOf` / `currentRulesetOf` reverts or returns implausible metadata (extreme decimals), the JB quote falls to `0` and V4 wins the route. No path resurrects stale static math for live execution.

3. **Live routing trusts only terminal-direct previews.** Buyback-hook metadata-only quotes are explicitly excluded from `_beforeSwap` route scoring. The static helper `calculateExpectedTokensWithCurrency` is an offchain/reference surface only.

4. **Reentrancy guard composes safely with buyback hooks.** `_routing` is a simple bool that survives across `poolManager.unlock`. Composed `buyback -> V4 -> this -> JB -> buyback` cycles revert at the second `_beforeSwap` entry.

5. **No exact-output, no admin surface, no upgrade path.** The hook's runtime is fully constrained at deployment. The only mutable storage is the per-pool oracle ring buffer + observation state + transient `_routing` flag.

6. **Balance-delta accounting everywhere.** Pre-existing hook balances are never swept into PoolManager settlement; only the delta produced by *this* terminal call moves. Stranded-token griefing blocked.

7. **Temporary allowance hygiene.** ERC-20 allowances granted to terminals are checked for exact consumption post-call. A leftover allowance reverts before settlement.

8. **Sell-input conservation.** On sell-side ERC-20 routes, the hook's input-token balance before and after the terminal call must match exactly. Partial-fill terminals cannot strand project tokens on the hook.

9. **MAX_TWAP_CARDINALITY-bounded oracle work.** Ring buffer capped at 1024 slots. Auto-grows on demand; once at cap, only one fresh write per block (same-block no-op) and a guard avoids overwriting an observation younger than `TWAP_PERIOD` to preserve the 30-minute window under sub-2s block cadence. (`JBUniswapV4Hook.sol:1114-1133`)

10. **TWAP-then-spot fallback chain.** `estimateUniswapOutput` prefers TWAP when `cardinality >= 2` AND oldest observation `>= TWAP_PERIOD` old; otherwise it falls back to slot0 spot. `amountOutMin` is the absolute floor in either mode.

11. **PoolManager-only callbacks.** Every state-mutating function is `internal` and inherits `onlyPoolManager` from `BaseHook`. EOAs cannot invoke `_beforeSwap` / `_afterSwap` / `_afterInitialize` / `_afterAddLiquidity` / `_afterRemoveLiquidity` directly.

12. **Project-token identification is precise.** `_projectIdForRegisteredToken(token)` returns non-zero only when `TOKENS.tokenOf(projectId) == token`. Credit-only projects (no registered ERC-20) and projects with a different registered token both fall through to the normal V4 swap path. (`JBUniswapV4Hook.sol:1090-1100`)

13. **Tie-break determinism.** When both buy-side and sell-side JB routes are eligible (cross-project swap where both tokens are JB project tokens), buy-side wins ties (`routeViaBuySide = ... buySideExpectedOutput >= sellSideExpectedOutput`). The router never evaluates both paths twice. (`JBUniswapV4Hook.sol:795-800`)

14. **No swap-time external configuration.** The hook reads only PoolManager state (`slot0`, `liquidity`) and the per-pool oracle ring buffer during `_beforeSwap` route comparison. No registry lookups, no storage-mutation reads, no off-chain oracle calls. Behavior on a given block is fully determined by on-chain state at that block.

15. **Strict separation between offchain helpers and live routing trust surfaces.** `calculateExpectedTokensWithCurrency` uses static ruleset weight; `calculateExpectedOutputFromSelling` uses the live preview surface. `_beforeSwap` invokes the live preview path directly (not the static helper). This boundary is documented and tested via `test/regression/PreviewPayForRouting.t.sol`.

---

## Section E — Out-of-scope centralization caveats

This repo holds **no privileged role** of its own. All implied centralization flows through dependencies whose authority is documented in the top-level `INVARIANTS.md`:

- **PoolManager (`IPoolManager`).** Uniswap V4 PoolManager is the sole authorized caller of every hook callback. A compromised PoolManager could fabricate `_beforeSwap` / `_afterSwap` calls; this is the trust posture of every V4 hook.
- **Juicebox Directory / Controllers / Terminals.** The hook trusts `DIRECTORY.primaryTerminalOf(...)` for terminal lookup and `terminal.previewPayFor(...)` / `previewCashOutFrom(...)` for live previews. A misconfigured controller or a malicious data hook can return arbitrary preview values; the hook's defenses are (a) conservative degrade to `0` on revert, (b) `amountOutMin` enforced against actual settlement balance delta, (c) sell-input conservation, (d) temporary-allowance consumption check.
- **`JBPrices`.** USD-denominated currency conversion in `calculateExpectedTokensWithCurrency` consults `PRICES.pricePerUnitOf(...)`. A compromised price feed only affects the **reference helper** — live `_beforeSwap` buy decisions use `previewPayFor`, which already accounts for the project's configured feed inside the terminal.
- **`JBTokens`.** `TOKENS.projectIdOf(...)` and `TOKENS.tokenOf(...)` decide which swaps engage JB routing at all. A maliciously registered project token would only force more swaps into JB route-comparison; the comparison still floors at `amountOutMin`.
- **Pool creator's hook choice.** Whoever initializes a V4 pool with this hook permanently binds the pool to this routing logic. There is no admin override.
- **Feeless-address misregistration.** If the protocol owner registers this hook as feeless on a `JBMultiTerminal`, sell-side cash-outs routed through it would inherit fee exemption (see `RISKS.md §5`). This is a registry-side hazard, not a hook-side power.

---

## Section F — Key code references

- Reentrancy guard set/check: `src/JBUniswapV4Hook.sol:178, 682-683, 1203, 1304`
- `amountOutMin` required: `src/JBUniswapV4Hook.sol:688-693`
- Exact-output rejection: `src/JBUniswapV4Hook.sol:699-701`
- Route comparison + eligibility: `src/JBUniswapV4Hook.sol:734-803`
- `routeMinimum` raise for sell: `src/JBUniswapV4Hook.sol:819-825`
- `routeMinimum` raise for buy: `src/JBUniswapV4Hook.sol:826-831`
- `_routeThroughJuicebox` body: `src/JBUniswapV4Hook.sol:1191-1307`
- Sell-input conservation revert: `src/JBUniswapV4Hook.sol:1271-1284`
- Zero-output sell revert: `src/JBUniswapV4Hook.sol:1286-1292`
- Final balance-delta `amountOutMin` enforcement: `src/JBUniswapV4Hook.sol:1294-1298`
- Temporary allowance consumed check: `src/JBUniswapV4Hook.sol:1163-1174, 1247`
- Conservative degrade in sell preview: `src/JBUniswapV4Hook.sol:281-286`
- Buy preview degrade to `0`: `src/JBUniswapV4Hook.sol:751-759`
- `_exactZeroTaxNet` zero-tax fee computation: `src/JBUniswapV4Hook.sol:917-949`
- Oracle initialize: `src/JBUniswapV4Hook.sol:581-590` + `src/libraries/Oracle.sol:71-83`
- Observation recording (cap-aware guard): `src/JBUniswapV4Hook.sol:1105-1161`
- TWAP staleness fallback to spot: `src/JBUniswapV4Hook.sol:410-416, 985-1014`
- `getHookPermissions` declaration: `src/JBUniswapV4Hook.sol:472-489`
- `observe` / `observeTWAP`: `src/JBUniswapV4Hook.sol:498-552`
- `_projectIdForRegisteredToken` precise check: `src/JBUniswapV4Hook.sol:1090-1100`
- Constants (`TWAP_PERIOD`, `MAX_TWAP_CARDINALITY`, `MAX_V4_DELTA`, `JB_NATIVE_TOKEN`, `UNISWAP_NATIVE_ETH`): `src/JBUniswapV4Hook.sol:124-146`
