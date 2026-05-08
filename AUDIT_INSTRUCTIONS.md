# Audit Instructions

This repo is the Uniswap V4 hook that compares V4 execution against Juicebox execution and routes to the better outcome. It also maintains the TWAP oracle used by other repos.

## Audit Objective

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

Suggestions of where to look:

- mis-estimate V4 or Juicebox outputs
- choose the wrong path and lose user value
- break swap settlement through sign, delta, or slippage mistakes
- let oracle state become manipulable or stale in ways downstream repos trust
- recurse unsafely when composed with the buyback hook

## Scope

In scope:

- `src/JBUniswapV4Hook.sol`
- `src/libraries/Oracle.sol`
- deployment scripts in `script/`

Key dependencies:

- `nana-core-v6`
- Uniswap V4
- consumers such as `nana-buyback-hook-v6` and `univ4-lp-split-hook-v6`

## Start Here

1. `src/JBUniswapV4Hook.sol`
2. `src/libraries/Oracle.sol`
3. deployment wiring in `script/`

## Security Model

On swaps involving a Juicebox project token, the hook:

- estimates the V4 path
- estimates the Juicebox path
- routes through the better option
- records observations for future TWAP queries

It is also an oracle surface:

- pools using it depend on its observation ring buffer
- other repos may call `observe()` and trust its output as a pricing guardrail

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Swapper | Supply exact-input order and minimum-out guardrail | Must not receive a worse route than the hook believes it selected |
| Hook contract | Override V4 execution and maintain oracle state | Must satisfy Uniswap flash-accounting and slippage semantics |
| Downstream consumer | Trust TWAP observations for routing or bounds | Must tolerate conservative or fail-closed behavior |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| `nana-core-v6` previews | Pay and cash-out previews are coherent enough to compare with V4 | The hook chooses the wrong path |
| Uniswap V4 pool manager | Delta conventions and callback lifecycle are honored | Settlement or flash accounting breaks |
| `nana-buyback-hook-v6` | Recursive composition expects a fail-closed routing guard | Infinite recursion or unsafe fallback |

## Critical Invariants

1. Route selection is honest. The hook must compare like-for-like outputs.
2. Settlement deltas are signed correctly. Override paths must satisfy Uniswap delta conventions and the user's minimum-out expectation.
3. Oracle writes remain usable. Observation history must stay queryable for downstream TWAP readers.
4. Warmup behavior stays explicit. Spot fallback must remain distinguishable from mature TWAP behavior.
5. Composition with the buyback hook remains recursion-safe.

## Attack Surfaces

- TWAP warmup and spot fallback
- route-comparison math
- exact-input slippage checks
- signed delta handling in V4 callbacks
- recursive composition with buyback routing
- hook-address mining and permission-bit deployment

## Accepted Risks Or Behaviors

- Some quote paths intentionally degrade to V4 rather than block trading when Juicebox-side estimation fails.
- Warmup-period spot fallback is an accepted but weaker safety window.

## Verification

- `npm install`
- `forge build --deny notes`
- `forge test --deny notes`
