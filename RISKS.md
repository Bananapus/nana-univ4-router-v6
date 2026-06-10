# Juicebox UniV4 Router Risk Register

This file focuses on the routing, oracle, and composition risks in `JBUniswapV4Hook`. The main question is whether the hook chooses the right path and keeps its oracle trustworthy enough for downstream users.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections to separate oracle-quality problems from route-selection problems.
- Treat `Accepted behaviors` and `Invariants to verify` as the line between intentional fallback and actual defects.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong route selection | The hook can send users through a worse path and lose value. | Compare like-for-like previews, keep slippage checks sound, and test routing edges. |
| P1 | Oracle warmup and low-history fallback | New or thin pools weaken TWAP-based protection and can fall back to spot pricing. | Operational warmup guidance, explicit fallback behavior, and `amountOutMin` enforcement. |
| P1 | Buyback-hook recursion | Same-pool composition with `nana-buyback-hook-v6` can recurse if the routing guard breaks. | Reentrancy guard plus fail-closed fallback into minting. |

## 1. Trust assumptions

- **PoolManager and V4 callbacks.** The hook trusts Uniswap V4 callback ordering and signed-delta semantics.
- **Juicebox preview surfaces.** Buy-side routing trusts `previewPayFor(...)` when available. Sell-side routing trusts `previewCashOutFrom(...)` when available.
- **Project-selected terminals.** The hook trusts the project's primary terminal as the protocol-side execution target.
- **Oracle readers.** Downstream systems may treat `observe(...)` as a real guardrail even though this is still pool-local oracle state.

## 2. Oracle risks

- **Warmup spot fallback.** During the early life of a pool, routing can rely on spot price instead of a mature TWAP.
- **Observation cardinality growth.** Oracle growth costs are borne by the caller that crosses a capacity boundary.
- **Fixed TWAP period.** The 30-minute lookback is compile-time behavior. If conditions change, the fix is redeployment, not admin retuning.
- **Mature-oracle failures are fail-closed.** Once the hook expects TWAP to be available, broken observation reads can revert the swap instead of degrading back to spot.

## 3. Routing risks

- **Three-way routing.** The hook may compare V4 with minting, cash out, or both, depending on which side is the project token.
- **Slippage protection is tag-gated.** A minimum is enforced only when `hookData` begins with `JB_HOOK_DATA_TAG` followed by a 32-byte `amountOutMin` (an explicit zero is a deliberate opt-out). Any other payload — empty, or a generic router's own metadata — carries no minimum: its first word is never mis-decoded as one, so neither a large word (DoS) nor a small word (silent skip) is possible. The hook imposes no floor of its own; an untagged swap proceeds under the caller's own protection (its router min-out or `sqrtPriceLimitX96`).
- **V4 estimates are approximate.** Large trades can diverge materially from the linearized V4 quote.
- **Buy-side estimates depend on preview availability.** If the terminal cannot provide a usable preview, the hook intentionally makes the Juicebox buy path ineligible.
- **Sell-side estimates are conservative.** If `previewCashOutFrom(...)` is unavailable or reverts, the hook intentionally declines JB sell routing instead of reviving older static reclaim math.
- **Sell-side routing is ERC-20 only, with credit normalization.** The hook only routes sell-side Juicebox cash-outs for
  registered project ERC-20s. Before measuring its exact-input ERC-20 balance, it claims any internal project-token
  credits it already holds into that ERC-20 so core's credit-first burn ordering cannot leave the user's routed input
  stranded.
- **Zero-tax sell previews rely on terminal/data-hook semantics.** Cash-out hooks receive `beneficiaryIsFeeless` in
  their preview context, and the hook does not apply a blanket protocol-fee haircut to zero-tax previews. Final
  settlement still measures the actual token balance delivered by the terminal.

## 4. MEV surface

- **Spot-fallback sandwich window.** During warmup, attackers can manipulate spot price to influence route choice.
- **TWAP manipulation cost.** Sustained manipulation is much more expensive than single-block spot manipulation, but it is not impossible.

## 5. Composition risks

- **Same-pool composition with `JBBuybackHook`.** The hook is meant to serve as both V4 pool hook and oracle source for the buyback hook. If recursion guards break, the composition becomes unsafe.
- **Static-helper versus live-routing differences.** Some helper functions remain more permissive than the live routing path. Documentation and integrator expectations must keep that distinction clear.
- **Feeless hook deployment would be dangerous on sells.** If the hook were ever registered as feeless on a terminal, traders routing sells through it would inherit that fee exemption.

## 6. Deployment risks

- **Hook-address mining.** V4 hooks encode permission flags in their address bits. A bad deployment means callbacks silently do not fire as intended.
- **Immutable constructor wiring.** Wrong directory, prices, or token assumptions require redeployment and pool migration.
- **Singleton blast radius.** One hook contract can serve many pools. A bug in the hook affects all of them.

## 7. Invariants to verify

- TWAP dampens manipulation more than spot once the oracle is mature.
- Observation timestamps progress correctly and same-block writes remain no-ops.
- Flash-accounting conservation holds across take and settle flows.
- External Juicebox-call failures usually degrade to V4 instead of inventing new routing semantics.
- Mature-oracle failures are intentionally distinct from early warmup fallback.

## 8. Accepted behaviors

### 8.1 JB routing can bypass V4 price discovery

When the hook routes through Juicebox, the V4 pool is not touched. That can create cross-route arbitrage, and that is by design.

### 8.2 Spot fallback during oracle warmup is accepted

The hook uses spot price before enough history exists for the configured TWAP lookback. This is weaker than mature TWAP protection, but the alternative would be blocking swaps during pool warmup.

### 8.3 Sell-side beneficiary substitution is accepted under the documented fee model

The hook routes sell-side cash outs through itself so it can settle back into PoolManager. This is safe only because the hook is not meant to be a feeless address on terminals.

The sell path is still limited to registered project ERC-20s. If the hook address has internal credits for that project,
the hook first claims those credits into the ERC-20 before pulling the user's input from PoolManager. This keeps core's
combined credit/ERC-20 burn ordering from changing the exact-input balance check.

Metadata-only buyback hook previews are not route inputs. If `previewCashOutFrom(...)` reports `reclaimAmount == 0`, the sell-side Juicebox route is ineligible even when hook metadata contains an AMM floor. This avoids routing a user to the same pool indirectly through a buyback hook when they could have used the pool path directly. Standard non-zero reclaim previews are fee-discounted only when the terminal reports a positive cash-out tax rate.

### 8.4 Zero-tax sell-path routing can keep favoring Juicebox

For zero-tax projects, repeated sell-side JB routing may remain structurally preferable because the per-token reclaim value does not decay through tax retention. That is an economic property of the configured project, not a routing bug.

### 8.5 Zero-tax sell-preview assumptions

`previewCashOutFrom(...)` does not expose whether a zero-tax cash-out will be charged against
`JBMultiTerminal._feeFreeSurplusOf`. The router therefore does not try to infer that hidden counter by subtracting a
full standard fee from every zero-tax preview. Instead, it treats the terminal/data-hook preview as the best available
route-comparison quote, and `_routeThroughJuicebox(...)` settles only the actual token balance received from the
terminal.

This avoids under-ranking ordinary zero-tax cash-outs with no fee-free surplus. The residual composition risk is that
a terminal with hidden fee-free-surplus accounting can deliver less than the gross zero-tax preview; callers should use
`amountOutMin` for hard execution floors until a net-after-terminal-fees preview is exposed. When the hook selects the
sell-side Juicebox route, its internal terminal minimum is the stricter of the user's floor and the amount needed to beat
V4, not the gross preview itself.

### 8.6 Buyback hook metadata is not a route-scoring source

The hook deliberately ignores buyback hook metadata when choosing between Juicebox and V4. Buyback metadata can describe a route that reaches the same pool through another hook layer, which is not a better direct route for a swapper. The live comparison therefore trusts only terminal-reported direct preview amounts.

### 8.7 Price impact ignorance in large V4 trades

`estimateUniswapOutput()` uses a linear TWAP quote without liquidity-depth simulation. For large trades in shallow pools, the actual V4 execution price may be worse than the Juicebox issuance path. A full liquidity-depth check was deemed too complex for the routing hot path. `amountOutMin` slippage protection prevents worst-case execution.

### 8.8 TWAP warmup spot-price fallback

When the TWAP oracle has insufficient observation history (newly created pools, first ~30 minutes), `estimateUniswapOutput` falls back to the manipulable spot price. During this window, routing decisions may be suboptimal. Slippage protection (`amountOutMin`) prevents worst-case execution. This is documented in code and is a bounded startup condition.

---

## 9. Accepted risks and notes

These are standing properties of the system. They describe behavior that is intentional, bounded, or otherwise tolerated, along with the reasoning that makes each one acceptable.

### Oracle behavior

#### Post-action observations backfill TWAP with the post-swap tick

`Oracle.transform` records the post-swap tick as `tickCumulative` for the entire elapsed time since the last observation, projecting the post-swap price backwards across that interval. For large swaps with infrequent observations, this skews the TWAP. The behavior mirrors Uniswap V3's native oracle; splitting observations would double gas cost and diverge from V3 semantics. Downstream consumers apply their own slippage and oracle-quality checks.

#### A single observation returns the spot tick as the TWAP

With fewer than two observations, `observeTWAP` returns the current spot tick as the TWAP, and the route comparison may price against it (no tolerance is applied to the comparison itself). A buy-side JB route that leans on this cold-pool spot quote as its `routeMinimum` is only bounded by a tagged `amountOutMin` if the caller supplied one; the mint itself stays ruleset-priced. External callers check the observation count before trusting the TWAP value.

#### Insufficient history falls back to the manipulable spot price

When too few observations exist, the oracle returns the spot price, which is manipulable via JIT liquidity. The route comparison may use it, and external consumers verify TWAP quality before relying on it. The hook does not derive a slippage floor of its own from the TWAP; protection is the caller's tagged `amountOutMin` (when supplied) or their own router-level minimum.

#### Observation growth is synchronous

`increaseOracleCardinalityNext` initializes oracle slots synchronously, so growing by a large amount in one call costs significant gas. Growth is bounded by `MAX_TWAP_CARDINALITY = 1024` and is idempotent: once a slot is grown, it cannot be grown again at the same size, so the cost is paid once.

### Swap routing behavior

#### `_beforeSwap` ignores the caller's `sqrtPriceLimitX96`

When routing through Juicebox, `_beforeSwap` does not apply the caller's `sqrtPriceLimitX96` because no AMM ticks are crossed. For V4-path swaps, the PoolManager applies the limit normally. The hook's own slippage protection via `amountOutMin` governs the Juicebox path.

#### A terminal fee above `MAX_FEE` makes the sell-side estimate ineligible

`calculateExpectedOutputFromSelling` returns `0` when the terminal reports a fee above `JBConstants.MAX_FEE`, treating the Juicebox sell path as ineligible so the swap degrades to V4 rather than reverting on underflow. The `_settleOutput` path wraps terminal calls in try/catch, so the estimation path and the settlement path agree on degrading to V4.

### Other notes

#### The buy helper truncates currency IDs to `uint32`

`_getBuyHelper` uses `uint32(uint160(paymentToken))` for currency comparison. The collision probability (~0.001% with ~10k active tokens) is negligible, and a collision would affect only the view-only preview estimation, not actual swap execution.
