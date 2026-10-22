# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. The closest V5 source comparison is `nana-uni-v4-util-v5` in `../../v5/evm`; the current repo is the V6 Uniswap V4 router/oracle hook package.

## Current V6 Surface

- `JBUniswapV4Hook`
- `Oracle`

## 1.3.0

- Buys of a project token fill from the pool while its output after LP and protocol fees beats the payer's issuance rate, and mint the leftover input through the terminal, settled as one swap delta. A buyer gets at least minting the whole input (less `issuance / 1e6 + 3` units of rounding margin), checked on both legs together, and the pool's fills when they beat it; a large buy no longer reverts or stops partway when the pool runs out of liquidity.
- A buy whose price limit is at or inside the fee-free issuance price stays a plain V4 swap. The buyback hook's swaps are such buys, so a terminal pay never mints through this hook from inside its own swap.
- The buy-side TWAP comparison is removed. A tagged `amountOutMin` on a split buy covers both legs together.
- A swap between two project tokens is routed as a sell of the input token.
- Buys whose input arrives short (fee-on-transfer input) now revert instead of routing on the reported amount.
- `calculateExpectedTokensWithCurrency` converts currencies the way the terminal store does (one base-currency unit priced in the payment currency at the payment token's decimals, then `amount * weight / price`), so its count matches what the terminal mints.
- No ABI or storage change; the oracle state of a deployed 1.2.x hook is layout-compatible.

## Summary

- The hook is now built for the V6 core preview model. Buy-side routing relies on `previewPayFor(...)`; sell-side routing relies on `previewCashOutFrom(...)`.
- V5 utility code considered V3, V4, and Juicebox routes. V6 removes V3 factory/WETH constructor dependencies from this package and focuses on V4/Juicebox route selection.
- Route events now use numeric route types and include `caller`.
- The hook adds stronger runtime guards for exact-output swaps, V4 signed-delta limits, temporary allowances, sell-side input handling, and reentrant Juicebox routing.
- The V6 hook also exposes oracle behavior used by other V6 packages such as the buyback hook.

## ABI, Event, and Error Changes

- Constructor inputs changed:
  - V5 took V3 factory and wrapped native token inputs.
  - V6 constructor takes `poolManager`, `tokens`, `directory`, and `prices`.
- Removed V5 assumptions:
  - no V3 swap callback interface on the V6 hook
  - no V3 route type string in `BestRouteSelected`
- Changed events:
  - `RouteSelected(PoolId,bool,uint256,address)`
  - `BestRouteSelected(PoolId,uint8,uint256,address)`
- Added or changed errors:
  - `JBUniswapV4Hook_InputExceedsV4DeltaLimit`
  - `JBUniswapV4Hook_OutputExceedsV4DeltaLimit`
  - `JBUniswapV4Hook_JuiceboxSellDidNotDeliver`
  - `JBUniswapV4Hook_SellInputReturned`
  - `JBUniswapV4Hook_ReentrantRouting`
  - `JBUniswapV4Hook_TemporaryAllowanceNotConsumed`
- Oracle errors are defined in `Oracle` and should be regenerated with the V6 ABI/types.

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: `nana-uni-v4-util-v5`.
- Own-source ABI artifacts compared: V6 `2`, V5 `5`.
- Contract/interface coverage: `0` added, `3` removed, `2` shared names with ABI changes, `0` shared names ABI-identical.
- Shared-name ABI item deltas: `19` added, `25` removed, `2` modified.

Removed V5 ABI artifacts:
- `IUniswapV3Factory` from `src/interfaces/IUniswapV3Factory.sol`: `3` functions, `0` events, `0` errors.
- `IUniswapV3Pool` from `src/interfaces/IUniswapV3Pool.sol`: `13` functions, `0` events, `0` errors.
- `IWETH` from `src/interfaces/IWETH.sol`: `2` functions, `0` events, `0` errors.

Shared ABI artifacts with changes:
- `JBUniswapV4Hook`: `17` added, `23` removed, `2` modified ABI items.
- `Oracle`: `2` added, `2` removed, `0` modified ABI items.

Generated event/error name deltas:
- Event names added:
  - `BestRouteSelected`, `RouteSelected`.
- Event names removed or replaced:
  - `BestRouteSelected`, `RouteSelected`.
- Error names added:
  - `JBUniswapV4Hook_AmountOutMinRequired`, `JBUniswapV4Hook_ExactOutputSwapsNotSupported`, `JBUniswapV4Hook_InputExceedsV4DeltaLimit`, `JBUniswapV4Hook_InsufficientOutput`, `JBUniswapV4Hook_JuiceboxSellDidNotDeliver`, `JBUniswapV4Hook_OutputExceedsV4DeltaLimit`, `JBUniswapV4Hook_ReentrantRouting`, `JBUniswapV4Hook_SecondsAgoCannotBeZero`.
  - `JBUniswapV4Hook_SellInputReturned`, `JBUniswapV4Hook_TemporaryAllowanceNotConsumed`, `Oracle_CardinalityCannotBeZero`, `Oracle_TargetPredatesOldestObservation`.
- Error names removed or replaced:
  - `AddressEmptyCode`, `AddressInsufficientBalance`, `FailedInnerCall`, `JBUniswapV4Hook_AmountOutMinRequired`, `JBUniswapV4Hook_ExactOutputSwapsNotSupported`, `JBUniswapV4Hook_InsufficientOutput`, `JBUniswapV4Hook_InvalidCallback`, `JBUniswapV4Hook_NoSwap`.
  - `JBUniswapV4Hook_ObservationCardinalityZero`, `JBUniswapV4Hook_SecondsAgoCannotBeZero`, `JBUniswapV4Hook_V3PoolLocked`, `JBUniswapV4Hook_V3PoolNotFound`, `OracleCardinalityCannotBeZero`, `TargetPredatesOldestObservation`.

## Migration Notes

- Rebuild hook deployment scripts around the V6 constructor.
- Re-index route events with the V6 payloads; V5 string route-type decoding is no longer correct.
- Use V6 core preview surfaces for route estimates instead of reconstructing V5 static terminal math.
