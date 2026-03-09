# univ4-router-v6 — Risks

## Trust Assumptions

1. **Uniswap V4 Pool Manager** — Hook executes within V4's pool manager context. Pool manager bugs affect all hook operations.
2. **TWAP Oracle Integrity** — Oracle accuracy depends on sufficient observation history and pool activity. New or low-activity pools have unreliable TWAPs.
3. **V3 Pool Comparison** — Uses V3 pools as price reference. V3 pool manipulation could affect routing decisions.
4. **Core Protocol** — Relies on JBController for mint pricing (weight) and JBTerminalStore for surplus data.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| TWAP manipulation | Low-liquidity pools are easier to manipulate over time | Minimum TWAP window; only use well-liquid pools |
| V3/V4 price divergence | Arbitrage between V3 and V4 pools during routing decision | Atomic comparison; routing is deterministic |
| Oracle bootstrapping | New pools have no observation history for TWAP | Falls back to spot price initially; grows over time |
| Stale V3 oracle | V3 pool TWAP may be stale if no recent activity | Oracle library handles staleness gracefully |
| Cancun dependency | Uses transient storage and V4 features | Only deployable on Cancun-compatible chains |
| Hook permission flags | Must be deployed at address with correct hook flag bits | Deterministic deployment via CREATE2 |

## Privileged Roles

| Role | Capabilities | Scope |
|------|-------------|-------|
| Pool creator | Registers JBUniswapV4Hook as pool hook | Per-pool |
| Core protocol | Provides mint pricing via weight | Protocol-wide |

## Reentrancy Considerations

| Function | Protection | Risk |
|----------|-----------|------|
| `beforeSwap` | Read-only oracle update + price comparison | LOW |
| `afterSwap` | Oracle state update only | LOW |
| V3 swap callback | Validated by pool address | LOW |
