# Audit Instructions

This repo is the Uniswap V4 hook that compares V4 execution against Juicebox execution and routes to the better outcome. It also maintains the TWAP oracle used by other repos.

## Objective

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

## System Model

On swaps involving a Juicebox project token, the hook:
- estimates the V4 path
- estimates the Juicebox path
- routes through the better option
- records observations for future TWAP queries

It is also an oracle surface:
- pools using it depend on its observation ring buffer
- other repos may call `observe()` and trust its output as a pricing guardrail

## Critical Invariants

1. Route selection is honest
The hook must compare like-for-like outputs and not mix preview semantics or fee conventions across routes.

2. Settlement deltas are signed correctly
Any override path must satisfy Uniswap’s delta conventions and the user’s minimum-out expectation.

3. Oracle writes remain usable
Observation growth, lookup, and fallback-to-spot behavior must not silently degrade into unsafe values for downstream consumers.

4. Reentrancy guard is effective
Recursive routing through the buyback hook or terminal calls must degrade safely rather than spin or corrupt state.

## Threat Model

Prioritize:
- slippage-sign mismatches
- preview calls that revert or return partial information
- dynamic protocol or pool fees
- low-history or stale-history oracle behavior
- exact-input versus unsupported exact-output assumptions

## Hotspots

- `beforeSwap` and any override-delta return path
- output estimation helpers for both routes
- `afterSwap`, `afterAddLiquidity`, and `afterRemoveLiquidity` oracle writes
- ring-buffer growth and historical lookup in `Oracle.sol`
- recursion guard behavior when composed with buyback logic

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

Current tests focus on:
- route-estimate regressions
- oracle width and observation behavior
- slippage semantics
- three-way routing and structural arbitrage
- sell-path reentrancy

Strong findings here usually show a path-selection bug that downstream repos would treat as economic truth.
