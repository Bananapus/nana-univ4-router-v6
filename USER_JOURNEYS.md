# User Journeys

## Who This Repo Serves

- teams building protocol-aware project-token markets on Uniswap V4
- traders swapping against pools that may be outperformed by Juicebox-native execution
- integrators and hooks that need a queryable TWAP surface for those pools

## Journey 1: Deploy The V4 Routing Hook For A Juicebox-Aware Pool

**Starting state:** you know the pool manager, token registry, directory, and price-feed dependencies for the environment.

**Success:** a pool hook exists that is able to compare V4 execution against Juicebox-native execution for the supported routing cases.

**Flow**
1. Deploy `JBUniswapV4Hook` with its constructor dependencies.
2. Attach it to the intended pool setup.
3. Treat the deployment as immutable. If constructor wiring is wrong, the remedy is redeployment, not admin repair.

## Journey 2: Let Traders Swap Through The Better Route

**Starting state:** a Uniswap V4 pool involving a Juicebox project token is using this hook.

**Success:** swaps involving supported Juicebox project-token cases can either proceed through the pool or be rerouted through Juicebox under the hook's protections.

**Flow**
1. A trader initiates a swap.
2. `beforeSwap` detects whether a Juicebox project token is involved.
3. The hook estimates the V4 path from TWAP-protected pool data and estimates the Juicebox-native path from terminal state.
4. If the pool is better, it returns control to normal V4 execution.
5. If the Juicebox path is better, it settles the swap through Juicebox instead.

## Journey 3: Provide Oracle Data To Other Protocol Components

**Starting state:** the hook has been recording observations over time.

**Success:** other contracts can query a TWAP-compatible oracle surface backed by the same routing-aware pool history.

**Flow**
1. Swaps and liquidity events record observations into the ring buffer.
2. External contracts call `observe()`-style queries.
3. Those callers use the returned history for protected pricing, often inside buyback or liquidity-management flows.

**Important limitation:** early pools or sparse activity weaken TWAP quality and may force weaker fallbacks.

## Hand-Offs

- Use [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md) for project-level buy and sell routing decisions built on top of this pool-hook primitive.
- Use [univ4-lp-split-hook-v6](../univ4-lp-split-hook-v6/USER_JOURNEYS.md) for treasury-managed liquidity that relies on the same oracle surface.
