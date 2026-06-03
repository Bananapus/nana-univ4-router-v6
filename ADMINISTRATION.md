# Administration

## At a glance

| Item | Details |
| --- | --- |
| Scope | Uniswap V4 hook behavior for router-assisted pool swaps |
| Control posture | Adminless after deployment apart from PoolManager-only callback routing |
| Highest-risk actions | Deploying with the wrong constructor wiring or initializing pools with the wrong hook assumptions |
| Recovery posture | Requires replacement hooks and new pools; there is no in-place admin repair |

## Purpose

`univ4-router-v6` is intentionally almost adminless. The important fact is not who owns it, but that nobody can retune or pause it after deployment and that pool creators permanently opt into it when they initialize hooked pools.

## Control model

- No owner
- No governance
- No pause
- No upgrade
- Immutable constructor dependencies
- PoolManager-only hook callbacks

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Pool creator | Pool initialization with this hook | Per pool | Opts a pool into this hook permanently |
| Swap caller | Per swap | Per transaction | Supplies `hookData` and participates in routing |
| PoolManager | Constructor immutable | Global | The only caller of hook callbacks |

## Privileged surfaces

There are no owner-only or governance-only functions.

The only effectively privileged runtime paths are the Uniswap V4 hook callbacks, which are callable only by the configured `PoolManager`.

## Immutable and one-way

- Constructor references to pool manager, tokens, directory, and prices are immutable.
- Hook behavior is fixed at deployment.
- Pools that initialize with this hook are permanently bound to it.

## Operational notes

- Validate constructor wiring before deployment because there is no later patch surface.
- Validate `hookData` expectations in integrators because callers supply the swap-level minimum-output encoding.
- Treat pool initialization as the real administrative commitment for using this hook.
- Be explicit about quote quality for newly initialized or shallow pools.

## Machine notes

- Do not search for owner or governance roles; there are none.
- Treat constructor args and PoolManager-only callback guards as the full control model.
- If a pool was initialized with the wrong hook expectations, recovery means new pools, not admin intervention.
- If TWAP history is insufficient, do not overstate oracle robustness for that pool.

## Recovery

- Recovery means a new hook deployment and new pools using that replacement.
- There is no emergency shutdown path on the live hook.

## Admin boundaries

- Nobody can retune oracle windows or routing logic after deployment.
- Nobody can pause swaps on already hooked pools through this contract.
- Nobody can extract persistent balances because the hook is not a treasury surface.

## Source map

- `src/JBUniswapV4Hook.sol`
- `src/libraries/Oracle.sol`
- `test/`
