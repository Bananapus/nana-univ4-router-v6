# Juicebox UniV4 Router

`@bananapus/univ4-router-v6` provides the Uniswap V4 hook and oracle surface used to compare market execution with Juicebox-native execution. It is a routing primitive for projects that want protocol-aware swaps instead of blind pool usage.

Docs: <https://docs.juicebox.money>
Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)

## Overview

The hook intercepts swaps involving a Juicebox project token and decides whether the better path is:

- the current Uniswap V4 pool
- minting through the Juicebox terminal on buys
- cashing out through the Juicebox terminal on sells

It also maintains a per-pool TWAP oracle that other contracts can query through an `observe()`-style interface.

Use this repo when swap routing should be aware of Juicebox-native issuance and redemption. Do not use it as a generic Uniswap utility package divorced from Juicebox project-token semantics.

If the issue is "should the project use market execution or protocol execution?" you may need `nana-buyback-hook-v6`. This repo supplies the hook-level swap and oracle primitive that decision can depend on.

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
3. `nana-buyback-hook-v6/src/JBBuybackHook.sol` if reviewing the composed buyback path

## Install

```bash
npm install @bananapus/univ4-router-v6
```

## Development

```bash
npm install
forge build
forge test
```

## Deployment Notes

This repo is commonly paired with the buyback hook and the UniV4 LP split hook. It is immutable after deployment, so constructor configuration should be treated as final.

## Repository Layout

```text
src/
  JBUniswapV4Hook.sol
  libraries/
test/
  routing, oracle, fork, invariant, audit, and regression coverage
script/
  Deploy.s.sol
  helpers/
```

## Risks And Notes

- early pools may not have enough oracle history, which weakens TWAP-based protection
- buy-side routing prefers `previewPayFor(...)` when a terminal is available and only falls back to static weight math if previewing fails
- the hook falls back when Juicebox-side estimation fails, so liveness and perfect observability are traded against each other
- spot-price fallback is intentionally allowed but materially weaker than a mature TWAP
- every Juicebox-routed swap expects `hookData` to encode exactly one `uint256 amountOutMin`
- composition with `nana-buyback-hook-v6` depends on the router's reentrancy guard to fail closed into minting
- because the deployment is immutable, bad constructor wiring is operationally expensive to fix
