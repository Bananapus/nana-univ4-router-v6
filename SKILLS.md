# Juicebox UniV4 Router

## Purpose

Uniswap V4 hook that automatically routes swaps involving Juicebox project tokens to the best price between V4 and Juicebox protocol, with built-in TWAP oracle protection. Exposes an `observe()` function (IGeomeanOracle-compatible) for external TWAP queries.

## Contracts

| Contract | Role |
|----------|------|
| `JBUniswapV4Hook` | V4 BaseHook: `beforeSwap` compares two routes (V4 pool vs Juicebox) and overrides the swap when Juicebox is better; `afterSwap`/`afterAddLiquidity`/`afterRemoveLiquidity` record TWAP observations; `afterInitialize` bootstraps the oracle. Exposes `observe()` for IGeomeanOracle-compatible TWAP queries. |
| `Oracle` (library) | Circular observation buffer storing `(blockTimestamp, tickCumulative, secondsPerLiquidityCumulativeX128)`. Supports `observe`, `observeSingle`, `write`, `grow`, and binary search. |

## Key Functions

### Routing (Hook Lifecycle)

| Function | What it does |
|----------|-------------|
| `_beforeSwap(sender, key, params, hookData)` | Core routing: detects if swap involves a JB token, estimates V4/JB outputs, picks best, executes via `_routeThroughJuicebox` or returns `ZERO_DELTA` for V4. Requires `hookData` to contain `uint256 amountOutMin` (exactly 32 bytes). Only supports exact-input swaps. |
| `_afterSwap(sender, key, params, delta, hookData)` | Records oracle observation; auto-grows cardinality when buffer fills; validates `amountOutMin` slippage for V4 swaps. |
| `_afterInitialize(sender, key, sqrtPriceX96, tick)` | Initializes oracle ring buffer with first observation for new pool. |
| `_afterAddLiquidity(...)` | Records oracle observation on liquidity adds. |
| `_afterRemoveLiquidity(...)` | Records oracle observation on liquidity removes. |

### Price Estimation (Views)

| Function | What it does |
|----------|-------------|
| `calculateExpectedTokensWithCurrency(uint256 projectId, address paymentToken, uint256 paymentAmount) -> uint256 expectedTokens` | Estimates project tokens from paying `paymentAmount` of `paymentToken`. Normalizes to 18 decimals, converts currency via `PRICES.pricePerUnitOf()`, applies ruleset weight, deducts reserved rate. Returns 0 on any try-catch failure (missing ruleset, price feed, `_getTokenDecimals` revert). |
| `calculateExpectedOutputFromSelling(uint256 projectId, uint256 tokenAmountIn, address outputToken, IJBTerminal terminal) -> uint256 expectedOutput` | Estimates terminal tokens from cashing out `tokenAmountIn` project tokens. Calls `IJBCashOutTerminal(terminal).previewCashOutFrom()` which simulates the full cash-out path including any configured cash-out data hook. Deducts protocol fee read dynamically via `IJBFeeTerminal(terminal).FEE()`. Returns 0 on any try-catch failure (swap falls back to V4). |
| `estimateUniswapOutput(poolId, key, amountIn, zeroForOne)` | Estimates V4 swap output using TWAP sqrtPrice (30-min window). Falls back to spot price if TWAP unavailable. Deducts pool fee (reads LP fee from `slot0` for dynamic fee pools instead of using the `DYNAMIC_FEE_FLAG` sentinel). |
| `observeTWAP(poolId, secondsAgo, tick, index, liquidity, cardinality)` | Returns arithmetic mean tick over `secondsAgo` for a V4 pool's oracle. |
| `observe(key, secondsAgos)` | IGeomeanOracle-compatible TWAP query. Takes `PoolKey calldata key` (not a PoolId). Returns tick cumulatives and seconds-per-liquidity for the requested time points. |

### Internal Routing

| Function | What it does |
|----------|-------------|
| `_routeThroughJuicebox(projectId, inputCurrency, outputCurrency, amountIn, isBuying, terminal, amountOutMin)` | Takes input from PoolManager, calls `terminal.pay()` (buying) or `terminal.cashOutTokensOf()` (selling), settles output back. |

### Oracle Internals

| Function | What it does |
|----------|-------------|
| `_getTWAPSqrtPrice(poolId)` | Returns TWAP sqrtPriceX96 for V4 pool (30-min window). Returns 0 if insufficient data (< 2 observations or < 30 min). |
| `_recordObservation(poolId)` | Writes new observation to ring buffer. Auto-grows cardinality by doubling until `MAX_TWAP_CARDINALITY = 1024`. |

### Oracle Library

| Function | What it does |
|----------|-------------|
| `Oracle.initialize(self, time)` | Initializes ring buffer with first observation. Takes only the storage array and a `uint32 time` — no tick parameter. Returns `cardinality=1, cardinalityNext=1`. |
| `Oracle.write(self, index, blockTimestamp, tick, liquidity, cardinality, cardinalityNext)` | Appends observation. Skips if already written in current block. Auto-bumps cardinality when wrapping. |
| `Oracle.observe(self, time, secondsAgos, tick, index, liquidity, cardinality)` | Returns tick cumulatives and seconds-per-liquidity for multiple time points. Interpolates between observations. |
| `Oracle.observeSingle(self, time, secondsAgo, tick, index, liquidity, cardinality)` | Returns single observation at specific time point. |
| `Oracle.grow(self, current, next)` | Pre-allocates storage slots to expand buffer capacity. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@uniswap/v4-core` | `IPoolManager`, `PoolKey`, `PoolId`, `StateLibrary`, `TickMath`, `FullMath`, `Currency`, `SwapParams`, `BeforeSwapDelta`, `BalanceDelta`, `Hooks` | V4 pool interaction, price math, hook framework |
| `@uniswap/v4-periphery` | `BaseHook` | Hook base class with permission flags |
| `@openzeppelin/uniswap-hooks` | `CurrencySettler` | Safe `settle()` / `take()` wrappers for V4 flash accounting |
| `@bananapus/core-v6` | `IJBTokens`, `IJBDirectory`, `IJBController`, `IJBPrices`, `IJBTerminalStore`, `IJBMultiTerminal`, `IJBTerminal`, `JBRuleset`, `JBRulesetMetadataResolver`, `JBConstants`, `JBAccountingContext` | Project token lookup, terminal routing, weight/price queries, pay/cashOut, surplus estimation |
| `@openzeppelin/contracts` | `IERC20`, `IERC20Metadata`, `SafeERC20` | Token transfers and decimal queries |

## Key Types

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `Oracle.Observation` | `uint32 blockTimestamp`, `int56 tickCumulative`, `uint160 secondsPerLiquidityCumulativeX128`, `bool initialized` | `observations` mapping (per PoolId, ring buffer of 65,535) |
| `ObservationState` | `uint16 index`, `uint16 cardinality`, `uint16 cardinalityNext` | `states` mapping (per PoolId), tracks write position and buffer capacity |

## Events

| Event | When |
|-------|------|
| `BestRouteSelected(PoolId indexed poolId, uint8 routeType, uint256 expectedTokens, address caller)` | Emitted once per swap in `_beforeSwap` after comparing V4 and JB outputs. `routeType`: 0=V4, 1=JB. Always fires when at least one JB token is involved. Fires before the route is executed. |
| `RouteSelected(PoolId indexed poolId, bool useJuicebox, uint256 expectedTokens, address caller)` | Emitted once per swap in `_beforeSwap` after the routing decision is finalized. For non-JB swaps, fires immediately with `useJuicebox=false, expectedTokens=0`. For JB swaps, fires after `BestRouteSelected` with the chosen route. |

## Errors

| Error | When |
|-------|------|
| `JBUniswapV4Hook_ExactOutputSwapsNotSupported` | `amountSpecified > 0` (only exact-input supported) |
| `JBUniswapV4Hook_AmountOutMinRequired` | `hookData` is empty or not exactly 32 bytes |
| `JBUniswapV4Hook_InsufficientOutput` | V4 swap output < `amountOutMin` (slippage check in `_afterSwap`) |
| `JBUniswapV4Hook_SecondsAgoCannotBeZero` | Oracle queried with `secondsAgo == 0` |
| `JBUniswapV4Hook_ReentrantRouting` | Recursive routing detected — fires when `_routing` is already true at `_beforeSwap` entry |

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `TWAP_PERIOD` | 1800 (30 min) | V4 TWAP lookback window |
| `JB_NATIVE_TOKEN` | `0x000000000000000000000000000000000000EEEe` | Juicebox native ETH sentinel |
| `UNISWAP_NATIVE_ETH` | `address(0)` | Uniswap native ETH sentinel |
| `TWAP_SLIPPAGE_DENOMINATOR` | 10000 | Basis point divisor |
| Max cardinality | 1024 | Oracle auto-grow cap |
| Max observation slots | 65,535 | Ring buffer size per pool |

## Required Hook Flags

The hook's `getHookPermissions()` returns the following V4 permission bits. All other flags are `false`.

| Flag | Value | Purpose |
|------|-------|---------|
| `afterInitialize` | `true` | Bootstrap oracle ring buffer with first observation on pool creation |
| `beforeSwap` | `true` | Core routing: compare V4 vs Juicebox and override swap when JB is better |
| `beforeSwapReturnDelta` | `true` | Enable `_beforeSwap` to return a non-zero `BeforeSwapDelta` (takes input, settles output) |
| `afterSwap` | `true` | Record oracle observation; validate `amountOutMin` slippage for V4 swaps |
| `afterAddLiquidity` | `true` | Record oracle observation on liquidity additions |
| `afterRemoveLiquidity` | `true` | Record oracle observation on liquidity removals |

Deployment requires `HookMiner.find()` to discover a CREATE2 salt that produces an address with these flag bits set.

## Gotchas

1. **Exact-output swaps are not supported.** `_beforeSwap` reverts with `JBUniswapV4Hook_ExactOutputSwapsNotSupported` if `params.amountSpecified > 0`. Only exact-input (negative `amountSpecified`) is handled.
2. **`hookData` must encode `uint256 amountOutMin`.** Exactly 32 bytes required; otherwise reverts with `JBUniswapV4Hook_AmountOutMinRequired`. This is NOT optional -- every swap through this hook needs it. `abi.encode(uint256(0))` delegates slippage protection to the hook's own TWAP oracle. The buyback hook uses this value when composing on the same pool.
3. **TWAP falls back to spot price silently.** If fewer than 2 observations or less than `TWAP_PERIOD` seconds of data exist, `_getTWAPSqrtPrice` returns 0 and the estimator uses `getSlot0` spot price. No revert, no event.
4. **Native ETH normalization.** For Juicebox terminal calls, `address(0)` maps to `JB_NATIVE_TOKEN` (`0x000000000000000000000000000000000000EEEe`).
5. **Oracle auto-grows cardinality** when the buffer fills: doubles until the `MAX_TWAP_CARDINALITY = 1024` cap. The gas cost is paid by whoever triggers the observation write that fills the buffer.
6. **Slippage validation differs by route.** V4 swaps validate `amountOutMin` in `_afterSwap`. JB routes validate during execution in `_beforeSwap` (via the pay/cashOut call itself or explicit checks).
7. **The hook has `receive() external payable {}`** to accept ETH during terminal cash outs.
8. **Deployment requires HookMiner.** The hook address must have specific bits set to match the permission flags. Use `HookMiner.find()` to discover a valid salt.
9. **Selling estimation uses `previewCashOutFrom`.** `calculateExpectedOutputFromSelling` calls `IJBCashOutTerminal(terminal).previewCashOutFrom()` which simulates the full cash-out path, including any configured cash-out data hook. This gives a more accurate estimate than raw surplus math, but the preview may differ from actual execution if on-chain state changes between the estimate and the swap.
10. **Selling estimation deducts fee conservatively.** The protocol fee is always deducted (`IJBFeeTerminal(terminal).FEE()`). If the hook is feeless, the estimate is slightly low, routing to V4 instead.
11. **The `previewCashOutFrom()` call is try-caught.** The `IJBCashOutTerminal(terminal).previewCashOutFrom()` call is wrapped in try-catch. If it reverts (misconfigured project, missing ruleset, etc.), the function returns 0 and the swap falls back to V4.
12. **If `DIRECTORY.primaryTerminalOf()` returns address(0)** for a project token, the Juicebox route is skipped silently. This happens when a project hasn't set up a terminal for the swap's input/output token.
13. **`via_ir = true` is required** in foundry.toml due to stack depth from V4 core dependencies. Without it, compilation may fail with "stack too deep" errors.
14. **The hook is fully immutable.** No admin functions, no upgrade path. All parameters are constants or immutable constructor arguments. Changing behavior requires deploying a new hook and migrating pools.
15. **Non-JB token swaps pass through unchanged.** If neither token in the pair is a registered JB project token (via `TOKENS.projectIdOf()`), the hook returns `ZERO_DELTA` and the V4 AMM executes normally. No routing overhead.
16. **Composition with JBBuybackHook.** This hook is designed to serve as both the pool hook and the oracle (`ORACLE_HOOK`) for `JBBuybackHook` on the same pool. When the buyback hook swaps, `_beforeSwap` fires and may route through JB, re-entering the buyback hook. The `_routing` reentrancy guard prevents infinite recursion — the inner swap reverts, and the buyback hook's try/catch falls back to minting.
17. **`_getTokenDecimals` reverts for non-standard tokens.** `_getTokenDecimals` reverts if the token does not implement `decimals()` instead of silently returning 18. `calculateExpectedTokensWithCurrency` is called via `this.` (external call) wrapped in try-catch, so a revert causes it to return 0 and the router prefers V4 rather than producing a wrong estimate based on an assumed 18-decimal default.

## Composition with JBBuybackHook

This hook is designed to serve as both the V4 pool hook **and** the TWAP oracle (`ORACLE_HOOK`) for a `JBBuybackHook` operating on the same pool. The interaction flow:

1. A payment arrives at the project's terminal. The buyback hook (configured as a data hook) queries this hook's `observe()` to get a TWAP quote.
2. The buyback hook determines that swapping on the V4 pool yields more tokens than minting, so it initiates a swap on the pool.
3. The swap enters `_beforeSwap` on this hook. The hook compares V4 pool output vs. Juicebox minting output. If Juicebox is better, it calls `_routeThroughJuicebox`, which sets `_routing = true` and calls `terminal.pay()`.
4. The `terminal.pay()` call re-enters the buyback hook (since it is the project's data hook). The buyback hook attempts another swap on the same pool.
5. The inner swap enters `_beforeSwap` again, but `_routing` is already `true`, so it reverts with `JBUniswapV4Hook_ReentrantRouting`.
6. The buyback hook's `try-catch` catches the revert and falls back to minting tokens directly at the ruleset weight.

The `_routing` flag is a custom `bool` (not OpenZeppelin `ReentrancyGuard`) to avoid conflicts with the PoolManager's unlock callback pattern. It is set before `_routeThroughJuicebox` and cleared after, scoped to a single transaction.

## Permissions

This hook has no admin functions and requires no permissions. All parameters are constants or immutable constructor arguments. There is no owner, no access control, and no upgrade path. Changing behavior requires deploying a new hook and migrating pools to it.

## Example Integration

```solidity
import {JBUniswapV4Hook} from "univ4-router-v6/src/JBUniswapV4Hook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/utils/HookMiner.sol";

// --- Deploy the hook ---

// Find a valid address that satisfies the hook permission flags.
uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

(address hookAddress, bytes32 salt) = HookMiner.find(
    CREATE2_DEPLOYER, flags, type(JBUniswapV4Hook).creationCode,
    abi.encode(poolManager, jbTokens, jbDirectory, jbPrices)
);

JBUniswapV4Hook hook = new JBUniswapV4Hook{salt: salt}(
    poolManager, jbTokens, jbDirectory, jbPrices
);

// --- Initialize a pool with the hook ---

PoolKey memory key = PoolKey({
    currency0: Currency.wrap(address(projectToken)),
    currency1: Currency.wrap(address(0)), // native ETH
    fee: 3000,
    tickSpacing: 60,
    hooks: IHooks(address(hook))
});

poolManager.initialize(key, sqrtPriceX96);

// --- Swap through the pool ---

// hookData MUST contain uint256 amountOutMin (exactly 32 bytes).
// The hook will auto-route to the best price between V4 and Juicebox.
bytes memory hookData = abi.encode(uint256(minTokensOut));
```
