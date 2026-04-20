# Audit Instructions

This repo is the Uniswap V4 hook that compares V4 execution against Juicebox execution and routes to the better outcome. It also maintains the TWAP oracle used by other repos.

## Audit Objective

Find issues that:
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

1. Route selection is honest
The hook must compare like-for-like outputs and not mix preview semantics or fee conventions across routes.

2. Settlement deltas are signed correctly
Any override path must satisfy Uniswap’s delta conventions and the user’s minimum-out expectation.

3. Oracle writes remain usable
Observation growth, lookup, and fallback-to-spot behavior must not silently degrade into unsafe values for downstream consumers.

4. Reentrancy guard is effective
Recursive routing through the buyback hook or terminal calls must degrade safely rather than spin or corrupt state.

## Attack Surfaces

- `beforeSwap` and any override-delta return path
- output estimation helpers for both routes
- `afterSwap`, `afterAddLiquidity`, and `afterRemoveLiquidity` oracle writes
- ring-buffer growth and historical lookup in `Oracle.sol`
- recursion guard behavior when composed with buyback logic

Replay these checks:
1. compare buy-side and sell-side route selection against actual execution
2. inspect slippage enforcement on both Juicebox-routed and pure V4-routed swaps
3. review native-token normalization across V4 and Juicebox conventions
4. inspect low-history oracle behavior and spot fallback during warmup
5. inspect recursive composition with `nana-buyback-hook-v6`

## Accepted Risks Or Behaviors

- Low-history oracle behavior intentionally prefers safety or explicit failure over optimistic routing.

## Verification

- `npm install`
- `forge build`
- `forge test`
