# Juicebox UniV4 Router Risk Register

This file focuses on the routing, oracle, and composition risks in `JBUniswapV4Hook`. The main question is whether the hook chooses the right path and keeps its oracle trustworthy enough for downstream users.

## How to use this file

- Read `Priority risks` first.
- Use the detailed sections to separate oracle-quality problems from route-selection problems.
- Treat `Accepted behaviors` and `Invariants to verify` as the line between intentional fallback and actual defects.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong route selection | The hook can send users through a worse path and lose value. | Buys fill from the pool only while it beats issuance and mint the rest, so a buyer gets at least issuance; sells take the best of the pool alone, cashing out everything and a split, each quoted exactly; slippage checks and routing-edge tests. |
| P1 | Oracle warmup for external readers | New or thin pools have little TWAP history, so `observe` readers (such as the buyback hook) get a short window. Routing reads no oracle. | Coverage views (`hasObservationCoverage`, `observationCoverageOf`) and each reader's own checks. |
| P1 | Buyback-hook recursion | Same-pool composition with `nana-buyback-hook-v6` can recurse if the routing guard breaks. | Reentrancy guard plus fail-closed fallback into minting. |

## 1. Trust assumptions

- **PoolManager and V4 callbacks.** The hook trusts Uniswap V4 callback ordering and signed-delta semantics.
- **Juicebox preview surfaces.** Buy-side routing trusts `previewPayFor(...)` when available, and the ruleset weight when the preview mints nothing for the payer while forwarding funds to a pay hook (the buy's output floor enforces it). The weight is priced with the primary terminal's accounting context for the input token, as the terminal store prices it; a rate that cannot be priced (no terminal or context, or a missing feed) leaves the buy a plain V4 swap, as in 1.2.0. The split also assumes issuance is linear in the amount paid: a pay data hook whose rate depends on the payment size, or a dust input V4 rounds to zero, can make a split buy revert where 1.2.0 minted the whole input (a revert, never an underpayment). A pay hook that forwards nothing but mints extra project tokens is not counted, which only lowers the floor. Sell-side routing trusts `previewCashOutFrom(...)` when available, called with the same buyback-skip metadata the cash-out uses. A cash-out data hook whose execution differs from its preview makes the leg revert at the terminal's minimum, as the 1.2.0 Juicebox route did. The cash-out leg runs inside the swap before the pool leg; liquidity changes to any pool of this hook revert while a terminal leg runs (the same scope as the swap guard), so a project's hooks cannot move the pool under the quote; a pay or cash-out hook that adds liquidity to such a pool reverts the swap instead. A project controller that returns malformed ruleset data reverts its own sells (1.2.0 left them in the pool); the controller already governs the project.
- **Project-selected terminals.** The hook trusts the project's primary terminal as the protocol-side execution target.
- **Oracle readers.** Downstream systems may treat `observe(...)` as a real guardrail even though this is still pool-local oracle state.

## 2. Oracle risks

- **Warmup history.** Early in a pool's life, `observe` readers get only the retained window. Routing reads no oracle.
- **Observation cardinality growth is lazy.** When the buffer fills, the hook raises `cardinalityNext` (doubling, up to `MAX_TWAP_CARDINALITY = 1801`) without touching storage; each slot is written when the ring first reaches it. 1.2.x initialized the new slots in bulk inside the swap or liquidity change that crossed the boundary: growing from 1,024 to 1,801 slots costs about 17.3M gas, over Ethereum's 16,777,216 per-transaction cap (EIP-7825), so once a pool reached 1,024 observations every swap and liquidity removal there would revert.
- **The retained window is at most 1,801 observations.** At most one observation per block, so a pool written every block keeps `1,801 x block time` of history: an hour on Base, but about 7.5 minutes at 0.25-second blocks. `observe` reverts past the retained window (§ Partial history).
- **Fixed TWAP period.** The 30-minute lookback is compile-time behavior. If conditions change, the fix is redeployment, not admin retuning.

## 3. Routing risks

- **Buys split between the pool and minting.** A buy swaps the pool itself, limited at the price where the pool's output after LP and protocol fees equals issuance, and mints the leftover input. A caller limit at or inside the fee-free issuance price keeps a plain V4 swap (this is how the buyback hook's swaps stay plain). A swap between two project tokens is such a buy when paying the output's project mints at least what cashing out the input reclaims, and a sell of the input otherwise.
- **Buy rounding margin.** The issuance floor is reduced by `issuance / 1e6 + 3` units so a buyback limit derived from a slightly smaller count still reads as inside the issuance price. V4 also rounds each step's input and fee up, so on thin or dust liquidity a pool leg can deliver less than minting its input would. Before swapping, the hook quotes the pool leg with `_quoteSwapOf` and mints the whole input when the leg's rate is below issuance, so dust ladders cannot make buys revert. Without this, a 0.25 USDC buy reverted when the pool beat minting by 1%.
- **Sells take the best of three exact quotes.** Before executing, a sell quotes the pool alone and a split with `quoteSwap` (the same swaps on the same state, reverted), and the cash-outs with the terminal preview: everything in the pool, everything cashed out, or a pool leg limited where the pool's output after fees equals the marginal reclaim rate (`3 J(n) - 4 J(n/2)` for a taxed cash-out, the average rate when that is lower) with the rest cashed out. The rate only places the leg, so the reclaim curve's rounding cannot put the seller below the pool alone, or below cashing out everything when the PoolManager holds the whole input. The two quotes cost about two pool swaps of gas. Sells of the fee project's own token stay in the pool, because its cash-out fee mints that token back to the hook. So do sells of a revnet whose fee hook pays its fee to the same revnet (`FEE_REVNET_ID() == projectId`, as REV's does): REVOwner pays that fee with the hook as beneficiary, which would mint the sold token back mid-sell.
- **Quotes add gas.** A routed buy traverses its pool leg twice (quote, then swap), and a sell up to three times. An LP who seeds hundreds of dust positions between the price and the issuance or reclaim rate (practical only at small tick spacings) makes each traversal cost millions of gas, for plain swaps too, and gains nothing. When one traversal fits the transaction gas cap but two or three do not, the routed swap reverts where the plain swap fills. The `FEE_REVNET_ID` probe calls a project's own cash-out hook with all remaining gas, so that hook can make the project's sells fail, the same exposure as its other hooks.
- **Cash-out legs respect the caller's price limit on average.** A cash-out leg (whole or split) is used only when its net average price, `cashOutAmountOut / cashOutCount`, is not past the caller's `sqrtPriceLimitX96`. The comparison reuses `_sqrtPriceX96Of`, whose Q128 branch quantizes to multiples of `2^32`, so a cash-out within that step of the limit can be rejected (it never admits a worse price).
- **Exact-output swaps are plain V4 swaps.** Juicebox routing prices exact inputs only; 1.2.x reverted them.
- **Dynamic-fee pools are rejected.** `_afterInitialize` reverts `JBUniswapV4Hook_DynamicFeeNotSupported`, because this hook never sets an LP fee and such a pool would charge none.
- **Terminal legs take input from PoolManager reserves.** Callers settle their input after the swap. A buy's mint leg `take`s the leftover input before the caller settles, so a buy larger than the PoolManager's balance of the input token is a plain V4 swap (1.2.x reverted). The check compares the whole input, though only the mint leg needs reserves, so a buy just over the balance can lose a split that was executable; this is rare for ETH and stablecoins, which the PoolManager holds across all pools. A sell's cash-out leg takes at most what the PoolManager holds of the token, and the outer swap sells the rest in the pool; `_afterSwap` adds the legs' output (held in a transient slot) to the pool's output for a tagged minimum. A thin pool of a token the PoolManager barely holds therefore gives most of a large sell to the pool, as 1.2.0 does. When the pool cannot take that rest (a pool already at its price bound), the sell reverts, as 1.2.0's did. The all-reclaim comparison is also skipped, leaving a plain swap, when the marginal reclaim rate is within the issuance-style rounding margin (dust), and it reads the standard fee, so a hook registered as feeless on the terminal is underquoted (see §5).
- **Slippage protection is tag-gated.** A minimum is enforced only when `hookData` begins with `JB_HOOK_DATA_TAG` followed by a 32-byte `amountOutMin` (an explicit zero is a deliberate opt-out). Any other payload — empty, or a generic router's own metadata — carries no minimum: its first word is never mis-decoded as one, so neither a large word (DoS) nor a small word (silent skip) is possible. The hook imposes no floor of its own; an untagged swap proceeds under the caller's own protection (its router min-out or `sqrtPriceLimitX96`).
- **Buy-side issuance depends on preview availability.** If the terminal cannot provide a usable preview, the buy stays a plain V4 swap.
- **Sell-side estimates are conservative.** If `previewCashOutFrom(...)` is unavailable or reverts, or if the selected
  terminal cannot locally settle the previewed gross reclaim plus cash-out hook amounts, the hook intentionally declines
  JB sell routing instead of reviving older static reclaim math.
- **Sell-side routing is ERC-20 only, with credit normalization.** The hook only routes sell-side Juicebox cash-outs for
  registered project ERC-20s. Before measuring its exact-input ERC-20 balance, it claims any internal project-token
  credits it already holds into that ERC-20 so core's credit-first burn ordering cannot leave the user's routed input
  stranded.
- **Zero-tax sell previews rely on terminal/data-hook semantics.** Cash-out hooks receive `beneficiaryIsFeeless` in
  their preview context, and the hook does not apply a blanket protocol-fee haircut to zero-tax previews. Final
  settlement still measures the actual token balance delivered by the terminal.

## 4. MEV surface

- **Buy-side sandwiches: the hook's floor is mint-all; the swapper's minimum protects the surplus.** The hook only guarantees a buyer at least minting the whole input. The pool's surplus above issuance is protected by the swapper's own minimum output (a router `amountOutMinimum`, such as Uniswap's default slippage, or a tagged `amountOutMin`), checked on both legs together. A buy sent with **no minimum** can be sandwiched down to issuance, as on 1.2.0, where the same buy had no floor at all. Base fork, block 52,922,000, project 7 (pool about 50x above issuance), best of the attacks searched in `test/SplitBuyBaseFork.t.sol`:
  - 1 ETH buy, victim sets no minimum: attacker nets 0.92 ETH on 2.0.0 (0.96 ETH on 1.2.0); the victim gets 7,750 tokens (issuance) instead of 80,738.
  - Same buy with a 0.5% minimum: attacker nets 0.022 ETH on both versions; with 1%, 0.040 ETH on both. The victim loses at most its slippage in tokens; the attacker's ETH gain is about that token loss valued at the pool's post-trade price, which a large buy moves far.
  - 10 ETH buy with a 1% minimum: 0.17 ETH on 2.0.0 against 1.75 ETH on 1.2.0, because 2.0.0 stops the pool leg at issuance.
  - With a minimum, the test asserts the victim loses at most its slippage and the attacker nets no more than the same attack nets on 1.2.0 wherever 1.2.0 fills the buy.
- **Why the pool leg is limited at issuance, not at the TWAP.** A pool-leg limit anchored to the TWAP would make a sandwich of a no-minimum buy unprofitable, but any genuine price move inside the TWAP window would send honest buys to minting while the pool still beats issuance. Derived from the fork table (no anchored variant was built; this assumes the TWAP still sits at the pre-move price and the anchor's tolerance is narrower than the move): after a genuine 1 ETH buy moves project 7's pool (the table's "pumped" state), a 1 ETH buy gets 10,088 tokens from the split but would get 7,750 if the pool were skipped (23% less); a 0.1 ETH buy, 1,590 against 775 (51% less). The swapper's minimum covers the attack case without that cost.
- **TWAP manipulation cost (readers of `observe`).** Sustained manipulation is much more expensive than single-block spot manipulation, but it is not impossible. Routing does not read the TWAP.

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

### 8.2 Routing reads no oracle

Buys and sells swap the pool itself and compare routes with `quoteSwap`, so no TWAP or spot estimate chooses a route, during warmup or after.

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
sell-side cash-out leg, its terminal minimum is the leg's own net preview.

### 8.6 Buyback hook metadata is not a route-scoring source

The hook deliberately ignores buyback hook metadata when choosing between Juicebox and V4. Buyback metadata can describe a route that reaches the same pool through another hook layer, which is not a better direct route for a swapper. The live comparison therefore trusts only terminal-reported direct preview amounts.

### 8.7 The hook offers no quote view

The hook has no view that quotes a swap. Integrators quote through Uniswap's V4 Quoter, which simulates the hook's routing. Routing reads no TWAP: buys and sells swap the pool itself, and a sell compares routes with `quoteSwap`, which runs the real pool.

### 8.8 TWAP warmup best-effort fallback

When the TWAP oracle has some observation history but not enough for the preferred 30-minute window, readers of `observe` get only the retained window; `observationCoverageOf` reports it. Routing does not depend on it.

---

## 9. Accepted risks and notes

These are standing properties of the system. They describe behavior that is intentional, bounded, or otherwise tolerated, along with the reasoning that makes each one acceptable.

### Oracle behavior

#### Post-action observations backfill TWAP with the post-swap tick

`Oracle.transform` records the post-swap tick as `tickCumulative` for the entire elapsed time since the last observation, projecting the post-swap price backwards across that interval. For large swaps with infrequent observations, this skews the TWAP. The behavior mirrors Uniswap V3's native oracle; splitting observations would double gas cost and diverge from V3 semantics. Downstream consumers apply their own slippage and oracle-quality checks.

#### A single observation returns the spot tick as the TWAP

With fewer than two observations, `observeTWAP` returns the current spot tick as the TWAP. Routing does not read the TWAP; it affects only external readers. External callers check the observation count before trusting the TWAP value.

#### Partial history returns only the retained window

`observe` reverts when the requested lookback is older than the retained history; the hook picks no fallback. External consumers can call `hasObservationCoverage(...)` or `observationCoverageOf(...)` before relying on a quote. The hook does not derive a slippage floor of its own from the TWAP; protection is the caller's tagged `amountOutMin` (when supplied) or their own router-level minimum.

#### Observation growth is lazy

The hook grows a full buffer by raising `cardinalityNext` only; a slot is written the first time the ring reaches it, so no swap or liquidity change pays for a block of slots. Growth is bounded by `MAX_TWAP_CARDINALITY = 1801`.

### Swap routing behavior

#### `_beforeSwap` uses the caller's `sqrtPriceLimitX96` only to choose a plain buy

A caller limit at or inside the fee-free price of the Juicebox rate (issuance on buys, the marginal reclaim rate on sells) keeps a plain V4 swap; any other limit lets the pool leg run to the rate limit, which is tighter. The terminal leg crosses no ticks; a cash-out leg is checked against the limit on its average price (§3), and a sell's `quoteSwap` and the outer swap's remainder use the limit directly. A sell limited that tightly stays a plain V4 swap even where cashing out everything pays more; 1.2.0 cashed out regardless of the limit there. For V4-path swaps, the PoolManager applies the limit normally. The hook's own slippage protection via `amountOutMin` governs the Juicebox path.

#### Fee-project tokens from cash-out fees stay in the hook

A taxed cash-out leg (or a zero-tax one charged against fee-free surplus) pays the terminal fee into project 1 with the hook as beneficiary, so the hook receives project 1 tokens it never sells or forwards (and, on a revnet, the fee revnet's tokens from REVOwner's fee). The seller's output is already net of the fee; the stranded tokens are the fee's issuance, which a direct cash-out would give the holder. 1.2.0's Juicebox sell route did the same, less often.

#### A terminal fee above `MAX_FEE` makes the sell-side estimate ineligible

`calculateExpectedOutputFromSelling` returns `0` when the terminal reports a fee above `JBConstants.MAX_FEE`, treating the Juicebox sell path as ineligible so the swap degrades to V4 rather than reverting on underflow. The `_settleOutput` path wraps terminal calls in try/catch, so the estimation path and the settlement path agree on degrading to V4.

### Other notes

#### The buy helper reads the terminal's accounting context

`calculateExpectedTokensWithCurrency` takes the payment currency and decimals from the primary terminal's `accountingContextForTokenOf`, the values the terminal store prices the payment with, so it does not derive currency IDs from token addresses.
