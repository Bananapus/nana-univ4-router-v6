# Juicebox UniV4 Router Risk Register

This file focuses on the routing, oracle, and composition risks in `JBUniswapV4Hook`. The main question is whether the hook chooses the right path and keeps its oracle trustworthy enough for downstream users.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections to separate oracle-quality problems from route-selection problems.
- Treat `Accepted Behaviors` and `Invariants to Verify` as the line between intentional fallback and actual defects.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong route selection | The hook can send users through a worse path and lose value. | Compare like-for-like previews, keep slippage checks sound, and test routing edges. |
| P1 | Oracle warmup and low-history fallback | New or thin pools weaken TWAP-based protection and can fall back to spot pricing. | Operational warmup guidance, explicit fallback behavior, and `amountOutMin` enforcement. |
| P1 | Buyback-hook recursion | Same-pool composition with `nana-buyback-hook-v6` can recurse if the routing guard breaks. | Reentrancy guard plus fail-closed fallback into minting. |

## 1. Trust Assumptions

- **PoolManager and V4 callbacks.** The hook trusts Uniswap V4 callback ordering and signed-delta semantics.
- **Juicebox preview surfaces.** Buy-side routing trusts `previewPayFor(...)` when available. Sell-side routing trusts `previewCashOutFrom(...)` when available.
- **Project-selected terminals.** The hook trusts the project's primary terminal as the protocol-side execution target.
- **Oracle readers.** Downstream systems may treat `observe(...)` as a real guardrail even though this is still pool-local oracle state.

## 2. Oracle Risks

- **Warmup spot fallback.** During the early life of a pool, routing can rely on spot price instead of a mature TWAP.
- **Observation cardinality growth.** Oracle growth costs are borne by the caller that crosses a capacity boundary.
- **Fixed TWAP period.** The 30-minute lookback is compile-time behavior. If conditions change, the fix is redeployment, not admin retuning.
- **Mature-oracle failures are fail-closed.** Once the hook expects TWAP to be available, broken observation reads can revert the swap instead of degrading back to spot.

## 3. Routing Risks

- **Three-way routing.** The hook may compare V4 with minting, cash out, or both, depending on which side is the project token.
- **Slippage protection depends on `hookData`.** The first 32 bytes must encode `amountOutMin`.
- **V4 estimates are approximate.** Large trades can diverge materially from the linearized V4 quote.
- **Buy-side estimates depend on preview availability.** If the terminal cannot provide a usable preview, the hook intentionally makes the Juicebox buy path ineligible.
- **Sell-side estimates are conservative.** If `previewCashOutFrom(...)` is unavailable or reverts, the hook intentionally declines JB sell routing instead of reviving older static reclaim math.

## 4. MEV Surface

- **Spot-fallback sandwich window.** During warmup, attackers can manipulate spot price to influence route choice.
- **TWAP manipulation cost.** Sustained manipulation is much more expensive than single-block spot manipulation, but it is not impossible.

## 5. Composition Risks

- **Same-pool composition with `JBBuybackHook`.** The hook is meant to serve as both V4 pool hook and oracle source for the buyback hook. If recursion guards break, the composition becomes unsafe.
- **Static-helper versus live-routing differences.** Some helper functions remain more permissive than the live routing path. Documentation and integrator expectations must keep that distinction clear.
- **Feeless hook deployment would be dangerous on sells.** If the hook were ever registered as feeless on a terminal, traders routing sells through it would inherit that fee exemption.

## 6. Deployment Risks

- **Hook-address mining.** V4 hooks encode permission flags in their address bits. A bad deployment means callbacks silently do not fire as intended.
- **Immutable constructor wiring.** Wrong directory, prices, or token assumptions require redeployment and pool migration.
- **Singleton blast radius.** One hook contract can serve many pools. A bug in the hook affects all of them.

## 7. Invariants to Verify

- TWAP dampens manipulation more than spot once the oracle is mature.
- Observation timestamps progress correctly and same-block writes remain no-ops.
- Flash-accounting conservation holds across take and settle flows.
- External Juicebox-call failures usually degrade to V4 instead of inventing new routing semantics.
- Mature-oracle failures are intentionally distinct from early warmup fallback.

## 8. Accepted Behaviors

### 8.1 JB routing can bypass V4 price discovery

When the hook routes through Juicebox, the V4 pool is not touched. That can create cross-route arbitrage, and that is by design.

### 8.2 Spot fallback during oracle warmup is accepted

The hook uses spot price before enough history exists for the configured TWAP lookback. This is weaker than mature TWAP protection, but the alternative would be blocking swaps during pool warmup.

### 8.3 Sell-side beneficiary substitution is accepted under the documented fee model

The hook routes sell-side cash outs through itself so it can settle back into PoolManager. This is safe only because the hook is not meant to be a feeless address on terminals.

### 8.4 Zero-tax sell-path routing can keep favoring Juicebox

For zero-tax projects, repeated sell-side JB routing may remain structurally preferable because the per-token reclaim value does not decay through tax retention. That is an economic property of the configured project, not a routing bug.
