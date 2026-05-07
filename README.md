# Juicebox UniV4 Router

`@bananapus/univ4-router-v6` provides the Uniswap V4 hook and oracle surface used to compare market execution with Juicebox-native execution. It is a routing primitive for projects that want protocol-aware swaps instead of blind pool usage.

Docs: <https://docs.juicebox.money>  
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)  
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)  
Skills: [SKILLS.md](./SKILLS.md)  
Risks: [RISKS.md](./RISKS.md)  
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)  
Review instructions: [REVIEW_GUIDE.md](./REVIEW_GUIDE.md)

## Overview

The hook intercepts swaps involving a Juicebox project token and can route through:

- the current Uniswap V4 pool
- minting through the Juicebox terminal on buys
- cashing out through the Juicebox terminal on sells

It also maintains per-pool observation history that other contracts can query through an `observe()`-compatible interface for TWAP-style calculations.

Use this repo when swap routing should be aware of Juicebox-native issuance and redemption. Do not use it as a generic Uniswap utility package.

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBUniswapV4Hook` | Main Uniswap V4 hook that performs routing decisions and records oracle observations. |
| `Oracle` | Observation-ring library used for TWAP accounting and lookup. |

## Mental Model

This repo owns two things:

1. route-aware Uniswap V4 hook behavior for Juicebox project tokens
2. the observation history needed to make that behavior oracle-aware

It is infrastructure, but infrastructure with direct economic consequences.

## Read These Files First

1. `src/JBUniswapV4Hook.sol`
2. `src/libraries/Oracle.sol`
3. `nana-buyback-hook-v6/src/JBBuybackHook.sol` if you are reviewing the composed buyback path

## Integration Traps

- this hook can choose between market and protocol-native execution, so pool state alone does not determine the path
- oracle maturity matters; early or thin pools weaken protection even if swaps still execute
- hook-data encoding is part of the trusted interface
- the composed buyback path inherits assumptions from both this repo and `nana-buyback-hook-v6`

## Where State Lives

- routing and swap decision logic live in `JBUniswapV4Hook`
- observation history and TWAP support live in `Oracle`
- composed buyback selection state lives outside this repo in `nana-buyback-hook-v6`

## Install

```bash
npm install @bananapus/univ4-router-v6
```

## Development

```bash
npm install
forge build --deny notes
forge test --deny notes
```

## Deployment Notes

This repo is commonly paired with the buyback hook and the UniV4 LP split hook. Hook instances are constructor-configured and non-upgradeable, so bad deployment wiring is expensive to fix.

## Repository Layout

```text
src/
  JBUniswapV4Hook.sol
  libraries/
test/
  routing, oracle, fork, invariant, review, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- early pools may not have enough oracle history, which weakens TWAP-based protection
- buy-side routing prefers `previewPayFor(...)` when a terminal is available and only falls back to static weight math in helper contexts
- the hook falls back when Juicebox-side estimation fails, so liveness and perfect observability are traded against each other
- spot-price fallback is intentionally allowed but materially weaker than a mature TWAP
- every Juicebox-routed swap expects `hookData` to encode at least one `uint256 amountOutMin`
- composition with `nana-buyback-hook-v6` depends on the router's recursion guard to fail closed into minting

## For AI Agents

- Describe this repo as the Uniswap V4 hook and oracle primitive for Juicebox-aware routing.
- Read the routing, oracle, and slippage tests before claiming a path is preferred or safe.
- If the question is about per-project hook selection, move to `nana-buyback-hook-v6`.
