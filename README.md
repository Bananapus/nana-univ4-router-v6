# nana-univ4-router

Uniswap V4 hook that intelligently routes swaps involving Juicebox project tokens to the best price among three sources -- the V4 pool, V3 pools, and Juicebox's native minting/cash-out mechanism -- with TWAP oracle protection against manipulation. Ensures project tokens always trade at or above their intrinsic treasury-backed value.

[Docs](https://docs.juicebox.money) | [Discord](https://discord.gg/juicebox)

## Conceptual Overview

When a Juicebox project token is traded on Uniswap V4, the `JBUniswapV4Hook` intercepts the swap in `beforeSwap` and compares the output from three routes:

1. **V4 pool** -- the pool the user is swapping in, priced via 30-minute TWAP
2. **V3 pool** -- the highest-liquidity V3 pool for the same pair (scans all 4 fee tiers), priced via 1-hour TWAP
3. **Juicebox protocol** -- minting tokens via `terminal.pay()` (buying) or cashing out via `terminal.cashOutTokensOf()` (selling), priced from the project's ruleset weight and surplus

Whichever route yields the most output tokens wins. If V3 or Juicebox is chosen, the hook takes the input from the V4 PoolManager, executes the swap/pay/cashout, and settles the output back -- all within the same transaction. If V4 wins, it returns `ZERO_DELTA` and lets the V4 AMM execute normally.

The contract is fully immutable after deployment -- no admin functions, no upgradeability. All configuration is set via constructor arguments and constants.

### How It Works

```
User initiates swap in V4 pool
  |
beforeSwap() fires
  |
  +-- Is a Juicebox project token involved?
  |     NO --> proceed with normal V4 swap
  |     YES --> compare all three routes:
  |
  +-- V4 estimate (TWAP-based, 30-min window, falls back to spot)
  +-- V3 estimate (best liquidity across 4 fee tiers, 1-hour TWAP)
  +-- JB estimate (weight * price - reserved rate, or cashOut surplus - 2.5% fee)
  |
  +-- Pick highest output
  |     JB  --> take from PoolManager, pay/cashOut via terminal, settle back
  |     V3  --> take from PoolManager, wrap ETH if needed, swap via V3, settle back
  |     V4  --> return ZERO_DELTA, let V4 AMM execute normally
  |
afterSwap() records oracle observation, validates slippage for V4 swaps
```

### TWAP Oracle

The hook maintains its own TWAP oracle per pool, recording observations on every swap, liquidity change, and pool initialization. This protects price estimates from single-block manipulation.

- **V4**: 30-minute lookback (`TWAP_PERIOD = 1800`). Falls back to spot price if fewer than 2 observations or less than 30 minutes of history.
- **V3**: 1-hour lookback (`STANDARD_TWAP_WINDOW = 3600`). Falls back to oldest available observation or spot price.

The oracle is a ring buffer of up to 65,535 observations per pool. Cardinality auto-grows (doubling up to 256) when the buffer fills. No manual management needed.

### Juicebox Price Estimation

**Buying project tokens** (paying into the project):
1. Get current ruleset weight (tokens minted per unit paid)
2. Convert payment currency to base currency via `JBPrices`
3. Deduct reserved rate (tokens reserved for splits, not given to payer)
4. Return user-receivable token count

**Selling project tokens** (cashing out):
1. Query `terminal.STORE().currentReclaimableSurplusOf()` for the bonding curve reclaim amount
2. Deduct 2.5% protocol fee (25/1000)
3. Return net output

### V3 Pool Discovery

The hook scans all 4 standard fee tiers in order of commonality: `[3000 (0.3%), 500 (0.05%), 10000 (1%), 100 (0.01%)]`. It picks the pool with the highest in-range liquidity. If no V3 pool exists, V3 routing is skipped.

## Architecture

| Contract | Description |
|----------|-------------|
| `JBUniswapV4Hook` | Uniswap V4 `BaseHook` that compares prices across V4, V3, and Juicebox for every swap involving a project token, then routes to the best option. Maintains its own TWAP oracle. Implements `IUniswapV3SwapCallback` for V3 routing. |
| `Oracle` (library) | Ring-buffer observation array (up to 65,535 slots) storing tick cumulatives, seconds-per-liquidity, and `prevTick`. Supports `observe`, `observeSingle`, `write`, `grow`, and binary search over the circular buffer. |
| `IUniswapV3Factory` | Minimal V3 factory interface for pool lookups. |
| `IUniswapV3Pool` | Minimal V3 pool interface for `slot0`, `observe`, `swap`, `liquidity`, `token0/token1`. |
| `IWETH` | Minimal WETH `deposit`/`withdraw` interface. |

## Hook Permissions

```
afterInitialize:          true   -- initialize oracle ring buffer
beforeSwap:               true   -- price comparison and routing
beforeSwapReturnDelta:    true   -- override swap when routing via V3 or JB
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
| `forge test` | Run all tests (~9,000 lines across 7 test files) |
| `forge test --match-contract JBUniswapV4HookTest` | Run unit tests only |
| `forge test --match-contract ThreeWayRoutingTest` | Run 3-way routing comparison tests |
| `forge test --match-contract V3RoutingEdgeCases` | Run V3 edge case tests |
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
  JBUniswapV4Hook.sol                  # Main hook contract (1347 lines)
  interfaces/
    IUniswapV3Factory.sol              # V3 factory interface
    IUniswapV3Pool.sol                 # V3 pool interface
    IWETH.sol                          # WETH deposit/withdraw
  libraries/
    Oracle.sol                         # Ring-buffer TWAP oracle (402 lines)
test/
  JBUniswapV4Hook.t.sol                # Unit tests (2778 lines)
  JBUniswapV4HookFork.t.sol            # Fork tests against mainnet (1844 lines)
  ThreeWayRouting.t.sol                # V4 vs V3 vs JB routing tests (1163 lines)
  V3RoutingEdgeCases.t.sol             # V3 locked/missing pool handling (991 lines)
  StressAndOrderOfMagnitude.t.sol      # Large swaps, deep liquidity (1069 lines)
  OracleDeepTest.t.sol                 # Ring buffer, cardinality, interpolation (1000 lines)
  SlippageTolerance.t.sol              # amountOutMin enforcement (213 lines)
script/
  Deploy.s.sol                         # Main deployment (HookMiner for address)
  DeployJBUniswapV4Hook.s.sol          # Alternative deployment script
  01_CreatePoolAndAddLiquidity.s.sol   # Pool initialization
  02_AddLiquidity.s.sol                # Add liquidity to existing pool
  03_Swap.s.sol                        # Test swap execution
```

## Constructor

```solidity
constructor(
    IPoolManager poolManager,       // Uniswap V4 singleton PoolManager
    IJBTokens tokens,               // Juicebox token registry (project token lookup)
    IJBDirectory directory,         // Juicebox directory (terminal routing)
    IJBPrices prices,               // Juicebox price feeds (currency conversion)
    IUniswapV3Factory v3Factory,    // Uniswap V3 factory (V3 pool discovery)
    address wrappedNativeEth        // WETH address (chain-specific)
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

- **TWAP manipulation**: With low cardinality (few observations), the TWAP window may be shorter than intended. The auto-grow mechanism mitigates this over time, but early pools are more vulnerable.
- **V3 pool liquidity fragmentation**: The hook picks the single highest-liquidity V3 pool. If liquidity is split across fee tiers, the estimate may be suboptimal.
- **Spot price fallback**: When TWAP data is insufficient, spot price is used silently. This removes manipulation protection for that swap.
- **Juicebox route depends on terminal availability**: If `DIRECTORY.primaryTerminalOf()` returns address(0), the JB route is skipped entirely.
- **Gas cost**: Three-way price comparison adds gas overhead to every swap involving a project token (~100-200k gas for V3 quoting + JB estimation on top of base V4 swap).

## License

MIT
