# Juicebox UniV4 Router

Uniswap V4 hook that intelligently routes swaps involving Juicebox project tokens to the best price between two sources -- the V4 pool and Juicebox's native minting/cash-out mechanism -- with TWAP oracle protection against manipulation. Includes a built-in `observe()` function (IGeomeanOracle-compatible) for external TWAP queries. Ensures project tokens always trade at or above their intrinsic treasury-backed value.

[Docs](https://docs.juicebox.money) | [Discord](https://discord.gg/juicebox)

## Conceptual Overview

When a Juicebox project token is traded on Uniswap V4, the `JBUniswapV4Hook` intercepts the swap in `beforeSwap` and compares the output from two routes:

1. **V4 pool** -- the pool the user is swapping in, priced via 30-minute TWAP
2. **Juicebox protocol** -- minting tokens via `terminal.pay()` (buying) or cashing out via `terminal.cashOutTokensOf()` (selling), priced from the project's ruleset weight and surplus

Whichever route yields the most output tokens wins. If Juicebox is chosen, the hook takes the input from the V4 PoolManager, executes the pay/cashout, and settles the output back -- all within the same transaction. If V4 wins, it returns `ZERO_DELTA` and lets the V4 AMM execute normally.

The contract is fully immutable after deployment -- no admin functions, no upgradeability. All configuration is set via constructor arguments and constants.

### How It Works

```
User initiates swap in V4 pool
  |
beforeSwap() fires
  |
  +-- Is a Juicebox project token involved?
  |     NO --> proceed with normal V4 swap
  |     YES --> compare both routes:
  |
  +-- V4 estimate (TWAP-based, 30-min window, falls back to spot)
  +-- JB estimate (weight * price - reserved rate, or cashOut surplus - fee)
  |
  +-- Pick highest output
  |     JB  --> take from PoolManager, pay/cashOut via terminal, settle back
  |     V4  --> return ZERO_DELTA, let V4 AMM execute normally
  |
afterSwap() records oracle observation, validates slippage for V4 swaps
```

### Composition with JBBuybackHook

This hook is designed to serve as both the V4 pool hook and the `ORACLE_HOOK` for `JBBuybackHook` on the same pool. The buyback hook queries `observe()` for TWAP data and executes swaps through this hook. When the routing logic tries to route back through Juicebox (re-entering the buyback hook), a `_routing` reentrancy guard prevents infinite recursion. The buyback hook's try/catch catches the revert and falls back to minting.

### TWAP Oracle

The hook maintains its own TWAP oracle per pool, recording observations on every swap, liquidity change, and pool initialization. This protects price estimates from single-block manipulation.

- **V4**: 30-minute lookback (`TWAP_PERIOD = 1800`). Falls back to spot price if fewer than 2 observations or less than 30 minutes of history.

The oracle is a ring buffer of up to 65,535 observations per pool. Cardinality auto-grows (doubling up to `MAX_TWAP_CARDINALITY = 1024`) when the buffer fills. That keeps a 30-minute TWAP available even on fast-block L2s with roughly 2-second block times. The hook exposes an `observe()` function (IGeomeanOracle-compatible) so external contracts can query TWAP data.

### Juicebox Price Estimation

**Buying project tokens** (paying into the project):
1. Get current ruleset weight (tokens minted per unit paid)
2. Convert payment currency to base currency via `JBPrices`
3. Deduct reserved rate (tokens reserved for splits, not given to payer)
4. Return user-receivable token count

**Selling project tokens** (cashing out):
1. Query `terminal.STORE().currentReclaimableSurplusOf()` with empty terminals/accountingContexts so the store uses total surplus across all terminals
2. Deduct protocol fee (read dynamically from terminal via `IJBFeeTerminal.FEE()`)
3. Return net output
4. All external calls are wrapped in try-catch -- if any call reverts, the estimate returns 0 and the swap falls back to V4

## Architecture

| Contract | Description |
|----------|-------------|
| `JBUniswapV4Hook` | Uniswap V4 `BaseHook` that compares prices across V4 and Juicebox for every swap involving a project token, then routes to the best option. Maintains its own TWAP oracle with IGeomeanOracle-compatible `observe()`. |
| `Oracle` (library) | Ring-buffer observation array (up to 65,535 slots) storing tick cumulatives and seconds-per-liquidity. Supports `observe`, `observeSingle`, `write`, `grow`, and binary search over the circular buffer. |

## Hook Permissions

```
afterInitialize:          true   -- initialize oracle ring buffer
beforeSwap:               true   -- price comparison and routing
beforeSwapReturnDelta:    true   -- override swap when routing via JB
afterSwap:                true   -- record observation, enforce slippage
afterAddLiquidity:        true   -- record observation
afterRemoveLiquidity:     true   -- record observation
```

## Install

```bash
npm install
```

If using Forge directly:

```bash
forge install
```

## Develop

| Command | Description |
|---------|-------------|
| `forge build` | Compile contracts (requires solc ^0.8.24, Cancun EVM) |
| `forge test` | Run all tests |
| `forge test --match-contract JuiceboxHookTest` | Run unit tests only |
| `forge test --match-contract ThreeWayRoutingTest` | Run routing comparison tests |
| `forge test --match-contract JBUniswapV4HookForkTest` | Run fork tests (needs `MAINNET_RPC_URL`) |
| `forge test -vvv` | Run tests with full trace |
| `forge test --gas-report` | Gas profiling |

### Settings

```toml
# foundry.toml
[profile.default]
solc = '0.8.26'
evm_version = 'cancun'
optimizer_runs = 200
via_ir = true

[fuzz]
runs = 4096
```

## Repository Layout

```
src/
  JBUniswapV4Hook.sol                  # Main hook contract
  libraries/
    Oracle.sol                         # Ring-buffer TWAP oracle
test/
  JBUniswapV4Hook.t.sol                # Unit tests
  JBUniswapV4HookFork.t.sol            # Fork tests against mainnet
  ThreeWayRouting.t.sol                # V4 vs JB routing tests
  StressAndOrderOfMagnitude.t.sol      # Large swaps, deep liquidity
  OracleDeepTest.t.sol                 # Ring buffer, cardinality, interpolation
  SlippageTolerance.t.sol              # amountOutMin enforcement
script/
  Deploy.s.sol                         # Deployment (HookMiner for address, per-chain PoolManager)
```

## Constructor

```solidity
constructor(
    IPoolManager poolManager,       // Uniswap V4 singleton PoolManager
    IJBTokens tokens,               // Juicebox token registry (project token lookup)
    IJBDirectory directory,         // Juicebox directory (terminal routing)
    IJBPrices prices                // Juicebox price feeds (currency conversion)
)
```

## Supported Networks

Deployment scripts support:

| Network | Chain ID |
|---------|----------|
| Ethereum Mainnet | 1 |
| Ethereum Sepolia | 11155111 |
| Optimism Mainnet | 10 |
| Optimism Sepolia | 11155420 |
| Base Mainnet | 8453 |
| Base Sepolia | 84532 |
| Arbitrum Mainnet | 42161 |
| Arbitrum Sepolia | 421614 |

## Risks

- **TWAP manipulation**: With low cardinality (few observations), the TWAP window may be shorter than intended. The auto-grow mechanism now expands to 1024 observations so the full 30-minute window remains available on fast-block L2s after warmup, but early pools are still more vulnerable.
- **Spot price fallback**: When TWAP data is insufficient, spot price is used silently. This removes manipulation protection for that swap.
- **Juicebox route depends on terminal availability**: If `DIRECTORY.primaryTerminalOf()` returns address(0), the JB route is skipped entirely.
- **Surplus estimation uses total surplus**: The sell-side estimate always uses total surplus across all terminals (empty arrays to `currentReclaimableSurplusOf`). This may overestimate reclaim value for projects that don't use `useTotalSurplusForCashOuts`.
- **External call failures are silent**: If the terminal store or any JB protocol call reverts during sell estimation, the hook returns 0 and falls back to V4 routing. No event is emitted for the failure.

## License

MIT
