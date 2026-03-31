# Administration

Admin privileges and their scope in univ4-router-v6.

## At A Glance

| Item | Details |
|------|---------|
| Scope | Autonomous Uniswap V4 routing hook with no mutable admin surface after deployment. |
| Operators | Pool creators, swap callers, liquidity providers, the external Juicebox project owners whose economics the hook reads, and the V4 PoolManager. |
| Highest-risk actions | Creating a pool with the wrong hook address, supplying bad `hookData`, or assuming there is an admin who can pause or retune the router later. |
| Recovery posture | Fixes require a new hook deployment and new hooked pools; the existing deployment is intentionally immutable. |

## Routine Operations

- Verify pool initialization parameters and the hooked address before creating production pools.
- Ensure integrations always supply exactly the `amountOutMin`-encoded `hookData` the hook expects.
- Treat external Juicebox project economics as an input the hook reads, not an admin surface the hook controls.

## One-Way Or High-Risk Actions

- There is no owner, pause, or upgrade path after deployment.
- Hook behavior depends on constructor immutables and hardcoded constants only.
- Pool creators permanently bind this hook to the pools they initialize with it.

## Recovery Notes

- If the routing behavior or immutable references are wrong, deploy a replacement hook and migrate liquidity to new pools that use it.
- There is no privileged operator who can hotfix the existing deployment.

## Roles

### No Admin Roles

JBUniswapV4Hook has **zero privileged functions**. There is no owner, no admin, no governance, no permission-gated function, no `onlyOwner`, no `requirePermission`, no access control of any kind.

The contract is fully autonomous once deployed. All routing decisions are made algorithmically by comparing V4 and Juicebox prices. All oracle updates happen automatically through Uniswap V4 hook callbacks.

### Implicit Roles (External)

| Role | How Assigned | Scope | What They Can Do |
|------|-------------|-------|-----------------|
| Pool creator | Anyone who calls `poolManager.initialize()` with this hook | Per-pool | Registers JBUniswapV4Hook as the hook for a V4 pool. Once set, the hook cannot be changed. |
| Swap caller | Anyone who swaps through a hooked pool | Per-swap | Provides `amountOutMin` in hookData (exactly 32 bytes). This is the only user-supplied parameter that influences hook behavior. |
| Liquidity provider | Anyone who adds/removes liquidity | Per-pool | Triggers oracle observation recording via `afterAddLiquidity` / `afterRemoveLiquidity`. |
| Juicebox project owner | Set via nana-core-v6 (`JBProjects` ERC-721) | Per-project | Controls project weight, reserved rate, terminal configuration -- all of which affect the hook's JB price estimates. The hook reads these values but cannot change them. |
| Uniswap V4 PoolManager | Immutable at deploy | Global | Only entity that can call hook functions (`_beforeSwap`, `_afterSwap`, etc.). Enforced by `BaseHook`'s `onlyPoolManager` modifier. |

## Privileged Functions

### JBUniswapV4Hook

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `_beforeSwap` | PoolManager only | None | Per-swap | Routes swap to best of V4/JB. Called exclusively by PoolManager. |
| `_afterSwap` | PoolManager only | None | Per-swap | Validates slippage for V4 swaps, records oracle observation. |
| `_afterInitialize` | PoolManager only | None | Per-pool | Initializes oracle ring buffer for a new pool. |
| `_afterAddLiquidity` | PoolManager only | None | Per-pool | Records oracle observation. |
| `_afterRemoveLiquidity` | PoolManager only | None | Per-pool | Records oracle observation. |

**Note:** All hook functions are gated by Uniswap V4's PoolManager infrastructure (only PoolManager can invoke hooks).

### Oracle Library

| Function | Required Role | Permission ID | Scope | What It Does |
|----------|--------------|---------------|-------|-------------|
| `Oracle.grow()` | Called internally by `_recordObservation` | None | Per-pool | Expands observation buffer. Triggered automatically when capacity is reached. Anyone who triggers a swap/liquidity event indirectly causes growth. |

## Immutable Configuration

Set at deploy time in the constructor. Cannot be changed after deployment.

| Parameter | Type | Set By | What It Controls |
|-----------|------|--------|-----------------|
| `poolManager` | `IPoolManager` | Constructor (inherited from `BaseHook`) | The V4 PoolManager this hook interacts with |
| `TOKENS` | `IJBTokens` | Constructor | Juicebox token registry for project token lookup |
| `DIRECTORY` | `IJBDirectory` | Constructor | Juicebox directory for terminal/controller resolution |
| `PRICES` | `IJBPrices` | Constructor | Juicebox price feed registry for currency conversion |
| `TWAP_PERIOD` | `uint32` (constant: 1800) | Hardcoded | 30-minute TWAP window for V4 oracle |
| `TWAP_SLIPPAGE_DENOMINATOR` | `uint256` (constant: 10,000) | Hardcoded | Basis-point denominator for slippage calculations |
| Hook address flags | Encoded in contract address | CREATE2 deployment | `afterInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterAddLiquidity`, `afterRemoveLiquidity` |

## Oracle Security

The hook uses a geometric mean TWAP oracle (30-minute window) to estimate V4 pool prices for routing decisions. This introduces specific trust assumptions:

- **TWAP manipulation.** A well-capitalized attacker could shift the TWAP by executing large swaps over the observation window. The 30-minute window makes this expensive but not impossible. The hook mitigates this by comparing against the JB issuance price (an independent price source). A manipulated TWAP that exceeds the JB price simply causes the hook to route through JB instead of V4.
- **Observation buffer growth.** The oracle ring buffer starts small and grows automatically (up to `MAX_TWAP_CARDINALITY = 1024`). During the initial growth period, the TWAP has fewer data points and is more susceptible to manipulation. This risk decreases as more observations accumulate.
- **hookData trust.** The swap caller provides `amountOutMin` as exactly 32 bytes of hookData. This is the only user-supplied parameter that influences hook behavior. If hookData is empty or not exactly 32 bytes, the swap reverts with `JBUniswapV4Hook_AmountOutMinRequired()`. Frontends should always encode a meaningful minimum to protect users.

## Admin Boundaries

What **nobody** can do after deployment:

- **Cannot change routing logic.** The price comparison algorithm (V4 vs JB) is hardcoded. No parameter can alter which route is selected.
- **Cannot change TWAP window.** The V4 TWAP period (30 min) is a constant.
- **Cannot pause the hook.** There is no pause mechanism. The hook processes every swap on every hooked pool.
- **Cannot upgrade the contract.** No proxy pattern. No upgradeability.
- **Cannot change immutable references.** The PoolManager, JB directory, JB tokens, and JB prices addresses are all immutable.
- **Cannot modify oracle state directly.** Oracle observations can only be written through V4 hook callbacks triggered by legitimate pool operations.
- **Cannot extract funds.** The hook holds no persistent balances between transactions. All take/settle operations are atomic within a single swap.
- **Cannot force a specific route.** Route selection is purely algorithmic -- the route with the highest estimated output wins.
- **Cannot change the observation buffer cap.** Auto-growth caps at `MAX_TWAP_CARDINALITY = 1024` observations and cannot be reconfigured.

## Design Implications

The complete absence of admin functions means:

1. **No emergency shutdown.** If a bug is found, the hook cannot be paused. Pool creators would need to migrate to new pools with a different hook.
2. **No parameter tuning.** TWAP windows and other parameters cannot be adjusted in response to market conditions.
3. **No upgrade path.** Bug fixes require deploying a new hook contract and migrating pools.
4. **Maximum trust minimization.** Users can verify the deployed bytecode and know that behavior will never change. No admin key risk.
5. **Single user trust parameter.** The `amountOutMin` in hookData is the only defense against sandwich attacks on V4-routed swaps. If a frontend fails to provide exactly 32 bytes of hookData, the swap reverts (`JBUniswapV4Hook_AmountOutMinRequired()`). Callers that encode `amountOutMin = 0` opt out of slippage protection on the V4 leg. The JB leg is not affected (JB issuance prices are not market-manipulable).
