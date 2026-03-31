# User Journeys

## Who This Repo Serves

- projects that want UniV4 swaps to respect Juicebox mint and cash-out economics
- traders whose best route may be the pool or the protocol depending on direction and price
- integrators reading the per-pool TWAP oracle this hook maintains

## Journey 1: Deploy The V4 Routing Hook For A Juicebox-Aware Pool

**Starting state:** a project token is expected to trade against some paired asset in UniV4.

**Success:** the pool uses `JBUniswapV4Hook` so buy and sell routing can compare market execution with protocol execution.

**Flow**
1. Deploy the hook with the project-token and terminal assumptions it needs.
2. Create or attach the relevant UniV4 pool using that hook.
3. Confirm the hook can reach the Juicebox terminal and accounting context required for buy-versus-mint and sell-versus-cash-out decisions.

## Journey 2: Let Traders Swap Through The Better Route

**Starting state:** a trade is about to cross the pool and the hook must decide whether the market or the protocol offers the better outcome.

**Success:** the user gets the better execution path without being forced through the pool by default.

**Flow**
1. On buys, compare the current pool trade against minting through the Juicebox terminal.
2. On sells, compare the pool trade against the project's cash-out path.
3. Route through the better option while preserving the slippage and reentrancy protections the hook expects.

**Failure cases that matter:** dust swaps, dynamic pool or protocol fees, sign-convention errors around slippage, and reentrancy on the sell path.

## Journey 3: Provide Oracle Data To Other Protocol Components

**Starting state:** another contract needs a TWAP-style view of pool behavior rather than a one-shot spot price.

**Success:** the contract can read observations from the hook's oracle layer instead of maintaining its own pool-history logic.

**Flow**
1. Let `JBUniswapV4Hook` record the observations relevant to the pool.
2. Query the `Oracle` library through the hook's `observe()`-style surface.
3. Use that output for routing, safety checks, or external integrations that need time-weighted data.

## Journey 4: Warm Up The Oracle Before Trusting It For Safety-Critical Routing

**Starting state:** the pool and hook were just initialized or have too little recent history for a meaningful TWAP.

**Success:** operators and integrators know when the system is still relying on spot-like behavior and wait for enough history before treating the oracle as protective.

**Flow**
1. Initialize the pool and begin recording observations through live activity over time.
2. Treat the earliest period as oracle warmup, not as fully mature TWAP protection.
3. Expect `estimateUniswapOutput(...)` to fall back to spot pricing until there are at least two observations and the oldest one is old enough for the 30-minute lookback.
4. Only rely on the hook's time-weighted routing assumptions once the pool has accumulated enough history for the configured lookback window.

**Failure cases that matter:** single-block or short-window spot manipulation during warmup, assuming cardinality alone means the oracle is mature, and building downstream safety assumptions that ignore the hook's fallback behavior.

## Hand-Offs

- Use [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md) when the question is project-level buyback routing rather than the hook-level swap primitive.
- Use [univ4-lp-split-hook-v6](../univ4-lp-split-hook-v6/USER_JOURNEYS.md) when the question is about deploying reserved tokens into liquidity instead of choosing swap execution paths.
