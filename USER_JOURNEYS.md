# User Journeys

## Repo Purpose

This repo is the UniV4 hook and oracle primitive for Juicebox-aware swaps. It owns hook-level best-execution decisions and observation history for project-token pools. It does not decide whether a project should use market-aware routing in the first place.

## Primary Actors

- projects that want UniV4 swaps to respect Juicebox mint and cash-out economics
- traders whose best route may be the pool or the protocol depending on direction and price
- integrators reading the per-pool oracle this hook maintains
- auditors reviewing oracle maturity, reentrancy, and path-selection assumptions

## Key Surfaces

- `JBUniswapV4Hook`: hook-level routing and oracle observation recording
- `Oracle`: observation ring and TWAP lookup logic
- `observe(...)`: time-weighted observation surface
- `estimateUniswapOutput(...)`: estimation path used during route comparison
- buy-versus-mint and sell-versus-cash-out routing inside the hook's swap callbacks

## Journey 1: Deploy The V4 Routing Hook For A Juicebox-Aware Pool

**Actor:** deployer or operator.

**Intent:** create a Juicebox-aware UniV4 pool with the correct constructor assumptions.

**Preconditions**

- a project token is expected to trade against some paired asset
- the deployer knows the terminal and accounting assumptions the hook must call back into

**Main Flow**

1. Deploy `JBUniswapV4Hook` with the intended project-token and terminal assumptions.
2. Create or attach the target UniV4 pool using that hook.
3. Confirm the hook can reach the Juicebox surfaces needed for buy-versus-mint and sell-versus-cash-out logic.

**Failure Modes**

- constructor wiring is wrong and expensive to recover
- the pool exists but cannot query the intended Juicebox surfaces correctly

**Postconditions**

- a Juicebox-aware V4 hook and pool exist with the intended constructor assumptions

## Journey 2: Let Traders Swap Through The Better Route

**Actor:** trader or integrator routing a trade.

**Intent:** get best execution between the pool and Juicebox-native alternatives.

**Preconditions**

- the pool is live
- the hook has enough information to compare the pool route with the Juicebox route
- `hookData` is shaped as the hook expects

**Main Flow**

1. On buys, compare the pool trade against terminal minting.
2. On sells, compare the pool trade against the project's cash-out path.
3. Route through the better option while preserving the hook's slippage and reentrancy protections.

**Failure Modes**

- dust swaps or dynamic fees distort route comparison
- sign-convention mistakes around slippage
- reentrancy on the sell path changes assumptions
- callers encode malformed `hookData`

**Postconditions**

- the trade uses whichever route the hook judges superior under current pool and Juicebox conditions

## Journey 3: Provide Oracle Data To Other Protocol Components

**Actor:** downstream contract or integrator.

**Intent:** query time-weighted pool data instead of relying on a spot quote.

**Preconditions**

- the hook has already been recording observations for the pool

**Main Flow**

1. Let `JBUniswapV4Hook` record observations over live trading activity.
2. Query `observe(...)` through the hook.
3. Use the result for routing or safety checks that need time-weighted data.

**Failure Modes**

- downstream systems treat `observe(...)` as mature protection before the pool has enough history
- integrators confuse the hook's oracle with an external trust-minimized price source

**Postconditions**

- downstream components can read time-weighted observation history instead of relying on spot only

## Journey 4: Warm Up The Oracle Before Trusting It For Safety-Critical Routing

**Actor:** operator or auditor.

**Intent:** understand when the hook still behaves like spot routing rather than mature TWAP routing.

**Preconditions**

- the pool and hook were recently initialized or have limited recent observation history

**Main Flow**

1. Initialize the pool and let observations accumulate through real activity.
2. Treat the early period as warmup, not fully mature protection.
3. Expect `estimateUniswapOutput(...)` to fall back to spot pricing until enough history exists for the configured lookback.
4. Only treat the oracle as protective once the lookback window is genuinely populated.

**Failure Modes**

- single-block or short-window manipulation during warmup
- observers assume cardinality alone means the oracle is mature
- downstream safety checks ignore fallback-to-spot behavior

**Postconditions**

- operators know whether the oracle is still in warmup or can be trusted for the configured lookback window

## Trust Boundaries

- this repo trusts Juicebox terminal previews and cash-out semantics for protocol-side comparison
- this repo is itself part of the market-side trust surface for buyback and LP integrations
- immutable constructor wiring makes deployment correctness operationally critical

## Hand-Offs

- Use [nana-buyback-hook-v6](../nana-buyback-hook-v6/USER_JOURNEYS.md) when the question is project-level buyback routing rather than the hook-level swap primitive.
- Use [univ4-lp-split-hook-v6](../univ4-lp-split-hook-v6/USER_JOURNEYS.md) when the question is about deploying reserved tokens into liquidity instead of choosing swap execution paths.
