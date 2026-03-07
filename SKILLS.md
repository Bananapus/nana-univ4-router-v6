# nana-univ4-router

## Purpose

Uniswap V4 hook that automatically routes swaps involving Juicebox project tokens to the best price among V4, V3, and Juicebox protocol, with built-in TWAP oracle protection.

## Contracts

| Contract | Role |
|----------|------|
| `JBUniswapV4Hook` | V4 BaseHook: `beforeSwap` compares three routes and overrides the swap when V3 or Juicebox is better; `afterSwap`/`afterAddLiquidity`/`afterRemoveLiquidity` record TWAP observations; `afterInitialize` bootstraps the oracle. Implements `IUniswapV3SwapCallback` for V3 routing. |
| `Oracle` (library) | Circular observation buffer storing `(blockTimestamp, prevTick, tickCumulative, secondsPerLiquidityCumulativeX128)`. Supports `observe`, `observeSingle`, `write`, `grow`, and binary search. |

## Key Functions

### Routing (Hook Lifecycle)

| Function | What it does |
|----------|-------------|
| `_beforeSwap(sender, key, params, hookData)` | Core routing: detects if swap involves a JB token, estimates V4/V3/JB outputs, picks best, executes via `_routeThroughJuicebox` or `_routeThroughV3` or returns `ZERO_DELTA` for V4. Requires `hookData` to contain `uint256 amountOutMin` (exactly 32 bytes). Only supports exact-input swaps. |
| `_afterSwap(sender, key, params, delta, hookData)` | Records oracle observation; auto-grows cardinality when buffer fills; validates `amountOutMin` slippage for V4 swaps (V3/JB validate in beforeSwap). |
| `_afterInitialize(sender, key, sqrtPriceX96, tick)` | Initializes oracle ring buffer with first observation for new pool. |
| `_afterAddLiquidity(...)` | Records oracle observation on liquidity adds. |
| `_afterRemoveLiquidity(...)` | Records oracle observation on liquidity removes. |

### Price Estimation (Views)

| Function | What it does |
|----------|-------------|
| `calculateExpectedTokensWithCurrency(projectId, paymentToken, paymentAmount)` | Estimates project tokens from paying `paymentAmount` of `paymentToken`. Accounts for ruleset weight, currency conversion via `JBPrices`, and reserved rate deduction. |
| `calculateExpectedOutputFromSelling(projectId, tokenAmountIn, outputToken, terminal)` | Estimates terminal tokens from cashing out `tokenAmountIn` project tokens. Uses `terminal.STORE().currentReclaimableSurplusOf()` and deducts 2.5% protocol fee. |
| `estimateUniswapOutput(poolId, key, amountIn, zeroForOne)` | Estimates V4 swap output using TWAP sqrtPrice (30-min window). Falls back to spot price if TWAP unavailable. Deducts pool fee. |
| `estimateUniswapV3Output(token0, token1, amountIn, zeroForOne)` | Estimates V3 swap output. Discovers best pool via `_findBestV3Pool` across all 4 fee tiers, uses 1-hour TWAP. |
| `observeTWAP(poolId, secondsAgo, tick, index, liquidity, cardinality)` | Returns arithmetic mean tick over `secondsAgo` for a V4 pool's oracle. |

### Internal Routing

| Function | What it does |
|----------|-------------|
| `_routeThroughJuicebox(projectId, inputCurrency, outputCurrency, amountIn, isBuying, terminal, amountOutMin)` | Takes input from PoolManager, calls `terminal.pay()` (buying) or `terminal.cashOutTokensOf()` (selling), settles output back. |
| `_routeThroughV3(token0, token1, amountIn, zeroForOne, originalTokenIn, originalTokenOut, fee)` | Takes input from PoolManager, wraps ETH to WETH if needed, executes V3 `swap()`, unwraps WETH if needed, settles output back. |
| `uniswapV3SwapCallback(amount0Delta, amount1Delta, data)` | V3 callback: validates caller is the expected V3 pool via factory lookup, transfers owed tokens. |

### Oracle Internals

| Function | What it does |
|----------|-------------|
| `_getTWAPSqrtPrice(poolId)` | Returns TWAP sqrtPriceX96 for V4 pool (30-min window). Returns 0 if insufficient data (< 2 observations or < 30 min). |
| `_recordObservation(poolId)` | Writes new observation to ring buffer. Auto-grows cardinality: doubles up to 128, then jumps to 256 max. |
| `_consult(pool, secondsAgo)` | **Declared `external`** for try/catch usage. Computes V3 TWAP tick and harmonic mean liquidity via `pool.observe()`. Called as `this._consult()`. |
| `_getOldestObservationSecondsAgo(pool)` | **Declared `external`** for try/catch usage. Returns age of oldest V3 observation. Called as `this._getOldestObservationSecondsAgo()`. |
| `_findBestV3Pool(tokenA, tokenB)` | Scans V3 factory across 4 fee tiers `[3000, 500, 10000, 100]`, returns pool with highest in-range liquidity. |

### Oracle Library

| Function | What it does |
|----------|-------------|
| `Oracle.initialize(self, time, tick)` | Initializes ring buffer with first observation. Returns `cardinality=1, cardinalityNext=1`. |
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
| `@bananapus/core-v6` | `IJBTokens`, `IJBDirectory`, `IJBController`, `IJBPrices`, `IJBTerminalStore`, `IJBMultiTerminal`, `IJBTerminal`, `JBRuleset`, `JBRulesetMetadataResolver`, `JBConstants` | Project token lookup, terminal routing, weight/price queries, pay/cashOut |
| `@openzeppelin/contracts` | `IERC20`, `IERC20Metadata`, `SafeERC20` | Token transfers and decimal queries |

## Key Types

| Struct | Key Fields | Used In |
|--------|------------|---------|
| `Oracle.Observation` | `uint32 blockTimestamp`, `int24 prevTick`, `int48 tickCumulative`, `uint144 secondsPerLiquidityCumulativeX128`, `bool initialized` | `observations` mapping (per PoolId, ring buffer of 65,535) |
| `ObservationState` | `uint16 index`, `uint16 cardinality`, `uint16 cardinalityNext` | `states` mapping (per PoolId), tracks write position and buffer capacity |

## Events

| Event | When |
|-------|------|
| `BestRouteSelected(PoolId indexed poolId, uint8 routeType, uint256 expectedTokens)` | Emitted in `_beforeSwap` when a JB token swap is routed. `routeType`: 0=V4, 1=V3, 2=JB. |

## Errors

| Error | When |
|-------|------|
| `JBUniswapV4Hook_ExactOutputSwapsNotSupported` | `amountSpecified > 0` (only exact-input supported) |
| `JBUniswapV4Hook_AmountOutMinRequired` | `hookData` is empty or not exactly 32 bytes |
| `JBUniswapV4Hook_InsufficientOutput` | V4 swap output < `amountOutMin` (slippage check in `_afterSwap`) |
| `JBUniswapV4Hook_SecondsAgoCannotBeZero` | Oracle queried with `secondsAgo == 0` |
| `JBUniswapV4Hook_ObservationCardinalityZero` | Oracle queried before initialization |
| `JBUniswapV4Hook_V3PoolNotFound` | V3 routing attempted but pool doesn't exist |
| `JBUniswapV4Hook_V3PoolLocked` | V3 pool reentrancy guard is active |
| `JBUniswapV4Hook_NoSwap` | V3 swap callback triggered with zero deltas |
| `JBUniswapV4Hook_InvalidCallback` | V3 callback called by unexpected address |

## Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `TWAP_PERIOD` | 1800 (30 min) | V4 TWAP lookback window |
| `STANDARD_TWAP_WINDOW` | 3600 (1 hour) | V3 TWAP lookback window |
| `JB_NATIVE_TOKEN` | `0x...EEEe` | Juicebox native ETH sentinel |
| `UNISWAP_NATIVE_ETH` | `address(0)` | Uniswap native ETH sentinel |
| `_FEE_TIERS` | `[3000, 500, 10000, 100]` | V3 fee tiers scanned (0.3%, 0.05%, 1%, 0.01%) |
| `V3_MIN_SQRT_RATIO` | `4295128739` | V3 min sqrtPriceX96 for swap bounds |
| `V3_MAX_SQRT_RATIO` | `1461446703485210103287273052203988822378723970342` | V3 max sqrtPriceX96 |
| `TWAP_SLIPPAGE_DENOMINATOR` | 10000 | Basis point divisor |
| Max cardinality | 256 | Oracle auto-grow cap |
| Max observation slots | 65,535 | Ring buffer size per pool |

## Gotchas

1. **Exact-output swaps are not supported.** `_beforeSwap` reverts with `JBUniswapV4Hook_ExactOutputSwapsNotSupported` if `params.amountSpecified > 0`. Only exact-input (negative `amountSpecified`) is handled.
2. **`hookData` must encode `uint256 amountOutMin`.** Exactly 32 bytes required; otherwise reverts with `JBUniswapV4Hook_AmountOutMinRequired`. This is NOT optional -- every swap through this hook needs it.
3. **`_consult` and `_getOldestObservationSecondsAgo` are declared `external`, not `internal`.** They are called via `this._consult()` / `this._getOldestObservationSecondsAgo()` so they can be wrapped in try/catch. Test mocks cannot call them as internal helpers.
4. **TWAP falls back to spot price silently.** If fewer than 2 observations or less than `TWAP_PERIOD` seconds of data exist, `_getTWAPSqrtPrice` returns 0 and the estimator uses `getSlot0` spot price. No revert, no event.
5. **V3 routing scans all 4 fee tiers** (`3000, 500, 10000, 100`) and picks the pool with the highest in-range liquidity. If no V3 pool exists for any tier, V3 routing is skipped entirely.
6. **Native ETH vs WETH normalization has distinct paths.** For Juicebox terminal calls, `address(0)` maps to `JB_NATIVE_TOKEN` (`0x...EEEe`). For V3 calls, `address(0)` maps to `WETH`. These are NOT interchangeable. WETH itself is NOT normalized to native -- only `address(0)` is.
7. **Oracle auto-grows cardinality** when the buffer fills: doubles up to 128, then jumps to 256 max. The gas cost is paid by whoever triggers the observation write that fills the buffer.
8. **Slippage validation differs by route.** V4 swaps validate `amountOutMin` in `_afterSwap`. V3 and JB routes validate during execution in `_beforeSwap` (via the swap/pay/cashOut call itself or explicit checks).
9. **The hook has `receive() external payable {}`** to accept ETH during WETH unwrapping and terminal cash outs.
10. **Deployment requires HookMiner.** The hook address must have specific bits set to match the permission flags. Use `HookMiner.find()` to discover a valid salt.
11. **Juicebox cash out estimation deducts 2.5% protocol fee** (`25/1000`). This matches `JBConstants.MAX_FEE = 1000` and the default fee of 25.
12. **If `DIRECTORY.primaryTerminalOf()` returns address(0)** for a project token, the Juicebox route is skipped silently. This happens when a project hasn't set up a terminal for the swap's input/output token.
13. **V3 callback validation uses factory lookup** -- `V3_FACTORY.getPool(token0, token1, fee)` must return the `msg.sender`. This prevents arbitrary contracts from triggering token transfers via the callback.
14. **`via_ir = true` is required** in foundry.toml due to stack depth from V4 core dependencies. Without it, compilation may fail with "stack too deep" errors.
15. **The hook is fully immutable.** No admin functions, no upgrade path. All parameters are constants or immutable constructor arguments. Changing behavior requires deploying a new hook and migrating pools.
16. **Non-JB token swaps pass through unchanged.** If neither token in the pair is a registered JB project token (via `TOKENS.projectIdOf()`), the hook returns `ZERO_DELTA` and the V4 AMM executes normally. No routing overhead.

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
    abi.encode(poolManager, jbTokens, jbDirectory, jbPrices, v3Factory, weth)
);

JBUniswapV4Hook hook = new JBUniswapV4Hook{salt: salt}(
    poolManager, jbTokens, jbDirectory, jbPrices, v3Factory, weth
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
// The hook will auto-route to the best price among V4, V3, and Juicebox.
bytes memory hookData = abi.encode(uint256(minTokensOut));
```
