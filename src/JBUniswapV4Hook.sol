// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";

import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

import {Oracle} from "./libraries/Oracle.sol";

/// @title JBUniswapV4Hook
/// @notice A Uniswap V4 hook that automatically routes swaps to whichever venue (V4 pool or Juicebox project) gives
/// the user more tokens. Uses a 30-minute TWAP oracle to resist price manipulation when comparing routes.
/// @dev Compares V4 TWAP-based estimates against Juicebox terminal previews for both buy-side (pay) and sell-side
/// (cash out) swaps. Provides IGeomeanOracle-compatible `observe()` for TWAP queries by external contracts.
/// @dev COMPOSITION WARNING — This hook is designed to serve as the ORACLE_HOOK for JBBuybackHook on the same V4
/// pool.
/// When the buyback hook attempts a swap, it flows through this hook's `_beforeSwap` routing logic. If the routing
/// decision leads back to Juicebox (via `_routeThroughJuicebox`), the `_routing` reentrancy guard prevents infinite
/// recursion and the buyback hook falls back to minting. This weight comparison uses static issuance weight while
/// the buyback hook uses TWAP-derived estimates, so the two may occasionally disagree on routing. Buy-side routing
/// remains incompatible with projects whose data hooks override pay weight, and sell-side routing is intentionally
/// disabled for projects whose data hooks override cash-out economics. Deployers MUST keep those composition limits
/// in mind when choosing this hook for best-execution routing.
contract JBUniswapV4Hook is BaseHook {
    using Oracle for Oracle.Observation[65_535];
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint16;
    using ProtocolFeeLibrary for uint24;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Reverts when amountOutMin is not provided in hookData.
    /// @param hookDataLength The length of the hook data that was provided.
    error JBUniswapV4Hook_AmountOutMinRequired(uint256 hookDataLength);

    /// @notice Reverts when an exact-output swap is attempted.
    /// @dev Only exact-input swaps are supported.
    /// @param amountSpecified The positive exact-output amount that was requested.
    error JBUniswapV4Hook_ExactOutputSwapsNotSupported(int256 amountSpecified);

    /// @notice Reverts when a Juicebox input cannot fit inside Uniswap V4's signed delta accounting.
    /// @param amount The oversized input amount.
    error JBUniswapV4Hook_InputExceedsV4DeltaLimit(uint256 amount);

    /// @notice Reverts when swap output is below minimum required amount.
    /// @param amount The amount that would be delivered.
    /// @param minimum The minimum amount required by the caller.
    error JBUniswapV4Hook_InsufficientOutput(uint256 amount, uint256 minimum);

    /// @notice Reverts when a nonzero Juicebox sell cash-out delivers no reclaim token.
    error JBUniswapV4Hook_JuiceboxSellDidNotDeliver(address inputToken, address outputToken, uint256 amountIn);

    /// @notice Reverts when a Juicebox output cannot fit inside Uniswap V4's signed delta accounting.
    /// @param amount The oversized output amount.
    error JBUniswapV4Hook_OutputExceedsV4DeltaLimit(uint256 amount);

    /// @notice Reverts when a reentrant swap is detected during Juicebox routing.
    /// @param caller The account that attempted the reentrant route.
    error JBUniswapV4Hook_ReentrantRouting(address caller);

    /// @notice Reverts when secondsAgo is zero in observeTWAP().
    /// @param secondsAgo The invalid lookback window.
    error JBUniswapV4Hook_SecondsAgoCannotBeZero(uint32 secondsAgo);

    /// @notice Reverts when a temporary terminal allowance was not fully consumed.
    error JBUniswapV4Hook_TemporaryAllowanceNotConsumed(address token, address spender, uint256 allowance);

    //*********************************************************************//
    // ---------------------------- structs ------------------------------ //
    //*********************************************************************//

    /// @notice Tracks the oracle observation state for a pool
    /// @custom:member index The index of the last written observation for the pool
    /// @custom:member cardinality The cardinality of the observations array for the pool
    /// @custom:member cardinalityNext The cardinality target of the observations array for the pool
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice Juicebox native token address
    address public constant JB_NATIVE_TOKEN = address(0x000000000000000000000000000000000000EEEe);

    /// @notice Maximum retained observation cardinality for a pool oracle.
    /// @dev 1024 observations cover just over 34 minutes at 2-second block times, keeping a 30-minute TWAP
    /// window available on fast-block L2s while staying well below the storage array's 65,535 hard limit.
    uint16 public constant MAX_TWAP_CARDINALITY = 1024;

    /// @notice Largest output amount that Uniswap V4 can represent in flash-accounting deltas.
    /// @dev PoolManager settles against signed `int128` deltas, so larger JB outputs must fall back to V4.
    uint256 public constant MAX_V4_DELTA = uint256(uint128(type(int128).max));

    /// @notice TWAP period in seconds (30 minutes by default)
    uint32 public constant TWAP_PERIOD = 1800;

    /// @notice The denominator used when calculating TWAP slippage percent values.
    uint256 public constant TWAP_SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice Native ETH address representation
    address public constant UNISWAP_NATIVE_ETH = address(0);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The Juicebox directory for terminal lookup
    IJBDirectory public immutable DIRECTORY;

    /// @notice The Juicebox prices contract for currency conversion
    IJBPrices public immutable PRICES;

    /// @notice The Juicebox tokens contract for project token lookup
    IJBTokens public immutable TOKENS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The list of observations for a given pool ID
    mapping(PoolId => Oracle.Observation[65_535]) public observations;

    /// @notice The current observation array state for the given pool ID
    mapping(PoolId => ObservationState) public states;

    //*********************************************************************//
    // -------------------- private stored properties ------------------- //
    //*********************************************************************//

    /// @notice Flag to prevent recursive routing through Juicebox during swap hooks.
    /// @dev Set to true before `_routeThroughJuicebox`, checked at `_beforeSwap` entry.
    ///      Uses a custom flag instead of OZ ReentrancyGuard to avoid conflicts with PoolManager's unlock callback.
    bool private _routing;

    //*********************************************************************//
    // ---------------------------- events ------------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a routing decision is made
    event RouteSelected(PoolId indexed poolId, bool useJuicebox, uint256 expectedTokens, address caller);

    /// @notice Emitted when the best route is selected among v4 and Juicebox
    /// @param routeType 0 = v4, 1 = juicebox
    event BestRouteSelected(PoolId indexed poolId, uint8 routeType, uint256 expectedTokens, address caller);

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param poolManager The Uniswap v4 pool manager
    /// @param tokens The Juicebox tokens contract
    /// @param directory The Juicebox directory
    /// @param prices The Juicebox prices contract for currency conversion
    constructor(
        IPoolManager poolManager,
        IJBTokens tokens,
        IJBDirectory directory,
        IJBPrices prices
    )
        BaseHook(poolManager)
    {
        DIRECTORY = directory;
        PRICES = prices;
        TOKENS = tokens;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Receive function to accept ETH during swap settlement with the PoolManager.
    /// @dev No withdrawal mechanism is needed — ETH received here is consumed during the same transaction
    /// as part of CurrencySettler.settle() for native-ETH output routing.
    receive() external payable {}

    //*********************************************************************//
    // ------------------------- public views ---------------------------- //
    //*********************************************************************//

    /// @notice Calculates how many payment tokens (e.g. ETH or USDC) you'd receive from selling project tokens via
    /// the Juicebox terminal's cash out mechanism.
    /// @dev Prefers the terminal store's `previewCashOutFrom` simulation so sell-side estimates can incorporate
    /// cash-out data-hook effects when the underlying store supports that surface.
    /// If previewing is unavailable or reverts, this helper intentionally returns `0` and makes the JB sell route
    /// ineligible. That conservative degrade rule avoids routing through JB on a stale static reclaim estimate that
    /// may disagree with the terminal's live cash-out path.
    /// Buyback-hook metadata-only swap previews are already expressed as executable minimums.
    /// @dev NOTE: Fee calls are best-effort. If the terminal does not expose `FEE()`, the estimate falls back to the
    /// raw preview.
    /// @param projectId The Juicebox project ID
    /// @param tokenAmountIn The amount of JB tokens to sell
    /// @param outputToken The token to receive (e.g., ETH, USDC)
    /// @param terminal The terminal from which the selling is happening.
    /// @return expectedOutput The expected amount of output tokens received
    function calculateExpectedOutputFromSelling(
        uint256 projectId,
        uint256 tokenAmountIn,
        address outputToken,
        IJBTerminal terminal
    )
        public
        view
        returns (uint256 expectedOutput)
    {
        // Normalize output token to Juicebox's native token representation
        outputToken = _normalizeToken(outputToken);

        // Use the terminal's cash-out preview, which simulates any configured cash-out data hook.
        try IJBCashOutTerminal(address(terminal))
            .previewCashOutFrom({
            holder: address(this),
            projectId: projectId,
            cashOutCount: tokenAmountIn,
            tokenToReclaim: outputToken,
            beneficiary: payable(address(this)),
            metadata: bytes("")
        }) returns (
            JBRuleset memory, uint256 grossReclaim, uint256, JBCashOutHookSpecification[] memory hookSpecifications
        ) {
            uint256 effectiveReclaim =
                _effectivePreviewCashOutAmount({reclaimAmount: grossReclaim, hookSpecifications: hookSpecifications});
            if (effectiveReclaim == 0) return 0;

            // Metadata-only previews carry an executable `minimumSwapAmountOut` inside a buyback hook spec when
            // `grossReclaim == 0`. That amount is the AMM sell-side proceeds, which bypass `_processFee` (the
            // sell-side hook spec is created with `amount = 0`), so the metadata amount is ALREADY net of terminal
            // fees. Subtracting the standard fee again here would double-discount the JB route and silently push it
            // below the V4 quote even when execution would have paid more.
            if (grossReclaim == 0) return effectiveReclaim;

            // Standard reclaim path: deduct the protocol fee regardless of cash-out tax rate. Even at zero tax,
            // the live terminal charges fees on fee-free surplus, so the preview must account for that to stay
            // consistent with executable behavior. The fee numerator is a compile-time constant in `JBConstants`.
            return effectiveReclaim - JBFees.standardFeeAmountFrom(effectiveReclaim);
        } catch {
            // Conservative degrade rule: if the live preview surface is unavailable, do not resurrect the older
            // static reclaim estimate. Cash-out data hooks and terminal-specific logic can make that estimate stale,
            // so the router treats the JB sell path as ineligible and leaves execution to V4 instead.
            return 0;
        }
    }

    /// @notice Estimates how many JB project tokens a user would receive by paying a given amount into the project.
    /// @dev WARNING: This estimate uses the ruleset's static weight. If the project has a data hook (such as a
    /// buyback hook) that overrides the weight at payment time, the actual token issuance may differ from this
    /// estimate, causing the swap-vs-mint routing decision to diverge. Deployers must ensure weight compatibility.
    /// @dev This helper is intentionally more permissive than live routing. `_beforeSwap()` only trusts
    /// `previewPayFor()` for buy-side best-execution decisions and uses this helper as an offchain/reference surface.
    /// @param projectId The Juicebox project ID
    /// @param paymentToken The token to pay with
    /// @param paymentAmount The amount to pay (in the token's native decimals)
    /// @return expectedTokens The expected number of tokens to be received
    function calculateExpectedTokensWithCurrency(
        uint256 projectId,
        address paymentToken,
        uint256 paymentAmount
    )
        public
        view
        returns (uint256 expectedTokens)
    {
        // Get the project's weight (tokens per ETH) and reserved rate
        uint256 tokensPerBaseCurrency;
        // Get the currency Id for the `weight`.
        uint256 baseCurrency;
        uint16 reservedPercent;
        // NOTE: This estimate uses the ruleset's static weight. If the project has a data hook that overrides
        // the weight at payment time, the actual issuance may differ from this estimate, potentially causing
        // the swap-vs-mint routing decision to diverge from what would be optimal.
        try IJBController(address(DIRECTORY.controllerOf(projectId))).currentRulesetOf(projectId) returns (
            JBRuleset memory ruleset, JBRulesetMetadata memory metadata
        ) {
            tokensPerBaseCurrency = ruleset.weight;
            baseCurrency = metadata.baseCurrency;
            // Get reserved percent from ruleset metadata
            reservedPercent = JBRulesetMetadataResolver.reservedPercent(ruleset);
        } catch {
            return 0;
        }

        // Normalize payment token to Juicebox's native token representation
        paymentToken = _normalizeToken(paymentToken);

        // Get the currency ID and decimals for the payment token
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 paymentCurrencyId = uint32(uint160(paymentToken));
        uint8 paymentTokenDecimals = _getTokenDecimals(paymentToken);
        // `10 ** decimals` only fits in uint256 up through 77 decimals. Larger values are treated as
        // unsupported metadata so the caller can degrade to a 0 quote instead of reverting.
        if (paymentTokenDecimals > 77) return 0;

        // Get the price: how much baseCurrency per 1 unit of payment token
        // pricePerUnitOf returns the pricingCurrency cost for one unit of unitCurrency
        uint256 baseCurrencyPerPaymentToken;
        // If payment currency is the same as base currency, use 1:1 conversion
        if (paymentCurrencyId == baseCurrency) {
            // Same currency IDs - direct match
            baseCurrencyPerPaymentToken = 1e18;
        } else if (paymentToken == JB_NATIVE_TOKEN && baseCurrency == 1) {
            // Both represent ETH but have different IDs (0xeeee vs 1)
            baseCurrencyPerPaymentToken = 1e18;
        } else {
            // Different currencies - need price conversion
            try PRICES.pricePerUnitOf({
                projectId: projectId, pricingCurrency: baseCurrency, unitCurrency: paymentCurrencyId, decimals: 18
            }) returns (
                uint256 price
            ) {
                baseCurrencyPerPaymentToken = price;
            } catch {
                return 0;
            }
        }

        // Calculate tokens based on the payment amount and weight.
        uint256 estimatedTokens = _calculateTokensWithCurrency({
            tokensPerBaseCurrency: tokensPerBaseCurrency,
            paymentAmount: paymentAmount,
            paymentTokenDecimals: paymentTokenDecimals,
            baseCurrencyPerPaymentToken: baseCurrencyPerPaymentToken
        });

        // Apply reserved rate: beneficiary only receives (1 - reservedPercent) of tokens
        // Reserved tokens go to team/contributors, not to the payer
        // Formula: actualTokens = estimatedTokens * (MAX_RESERVED_PERCENT - reservedPercent) / MAX_RESERVED_PERCENT
        if (reservedPercent > 0) {
            expectedTokens = FullMath.mulDiv({
                a: estimatedTokens,
                b: uint256(JBConstants.MAX_RESERVED_PERCENT - reservedPercent),
                denominator: uint256(JBConstants.MAX_RESERVED_PERCENT)
            });
        } else {
            expectedTokens = estimatedTokens;
        }
    }

    /// @notice Estimates how many output tokens a swap through the Uniswap V4 pool would produce, based on the
    /// 30-minute TWAP price (or spot price if insufficient oracle history).
    /// @dev Uses time-weighted average price to prevent manipulation
    /// @dev Price impact warning: This estimate does not account for price impact from liquidity depth. The TWAP
    /// price is applied uniformly to the entire `amountIn` regardless of available liquidity at the current tick
    /// range. In shallow pools, large trades will experience significant slippage that this function does not
    /// reflect. As a result, `estimateUniswapOutput` may overquote the V4 route for large amounts relative to
    /// pool liquidity, causing `_beforeSwap` to select the V4 path when the Juicebox mint path would yield more
    /// tokens. Callers processing large amounts relative to pool liquidity should verify the output independently.
    // Pool selection by highest liquidity is a heuristic. A pool with less liquidity but better tick
    // distribution could produce better output for a given swap size. Full simulation of all pools would be
    // gas-prohibitive on-chain. Off-chain routers can provide optimal pool selection via metadata.
    /// @param poolId The pool ID
    /// @param key The pool key
    /// @param amountIn The input amount
    /// @param zeroForOne Whether swapping token0 for token1
    /// @return estimatedOut The estimated output amount
    function estimateUniswapOutput(
        PoolId poolId,
        PoolKey memory key,
        uint256 amountIn,
        bool zeroForOne
    )
        public
        view
        returns (uint256 estimatedOut)
    {
        // Get TWAP price instead of spot price to prevent manipulation
        uint160 sqrtPriceX96TWAP = _getTWAPSqrtPrice(poolId);

        // If TWAP is not available (not enough observations), fallback to spot price.
        // NOTE: Spot price is used as a fallback for newly created pools that lack sufficient TWAP history.
        // In this state, the estimate is susceptible to spot-price manipulation. Once the pool accumulates
        // enough observations for TWAP, this fallback is no longer used.
        if (sqrtPriceX96TWAP == 0) {
            (sqrtPriceX96TWAP,,,) = poolManager.getSlot0(poolId);
        }

        // Apply the combined swap fee (protocol fee + LP fee) to the input amount BEFORE the price-ratio
        // conversion, mirroring Uniswap V4's swap math so this estimator's floor rounding matches V4's
        // execution rounding (small inputs at typical fees would otherwise diverge by one unit).
        uint256 amountInAfterFee = amountIn;
        {
            // Read protocol fee from slot0 (directional: lower 12 bits = zeroForOne, upper 12 bits = oneForZero)
            (,, uint24 protocolFee, uint24 slot0LpFee) = poolManager.getSlot0(PoolIdLibrary.toId(key));

            // Determine the LP fee: use key.fee for static pools, slot0LpFee for dynamic pools
            uint24 lpFee;
            if (LPFeeLibrary.isDynamicFee(key.fee)) {
                lpFee = slot0LpFee;
            } else {
                lpFee = key.fee;
            }

            // Extract the directional protocol fee and compose with LP fee.
            uint16 directionalProtocolFee = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
            uint24 swapFee = directionalProtocolFee == 0 ? lpFee : directionalProtocolFee.calculateSwapFee(lpFee);

            if (swapFee > 0) {
                amountInAfterFee = FullMath.mulDiv({
                    a: amountIn,
                    b: ProtocolFeeLibrary.PIPS_DENOMINATOR - swapFee,
                    denominator: ProtocolFeeLibrary.PIPS_DENOMINATOR
                });
            }
        }

        // Calculate price ratio from sqrtPriceX96, handling overflow for large values.
        // When sqrtPriceX96 <= type(uint128).max, we can square it directly (fits in uint256).
        // Otherwise, use FullMath.mulDiv to avoid overflow, at the cost of reduced precision.
        if (sqrtPriceX96TWAP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96TWAP) * sqrtPriceX96TWAP;
            if (zeroForOne) {
                estimatedOut = FullMath.mulDiv({a: amountInAfterFee, b: ratioX192, denominator: 1 << 192});
            } else {
                estimatedOut = FullMath.mulDiv({a: amountInAfterFee, b: 1 << 192, denominator: ratioX192});
            }
        } else {
            uint256 ratioX128 = FullMath.mulDiv({a: sqrtPriceX96TWAP, b: sqrtPriceX96TWAP, denominator: 1 << 64});
            if (zeroForOne) {
                estimatedOut = FullMath.mulDiv({a: amountInAfterFee, b: ratioX128, denominator: 1 << 128});
            } else {
                estimatedOut = FullMath.mulDiv({a: amountInAfterFee, b: 1 << 128, denominator: ratioX128});
            }
        }

        return estimatedOut;
    }

    /// @notice Declares which Uniswap V4 lifecycle callbacks this hook uses (afterInitialize, afterSwap,
    /// beforeSwap, etc.).
    /// @return permissions The hook permissions struct
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // Initialize oracle observations
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // Record oracle observations
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // Record oracle observations
            beforeSwap: true,
            afterSwap: true, // Record oracle observations
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // Enable to override swap behavior
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Returns cumulative tick and liquidity-time data for specified lookback periods.
    /// @dev Implements the IGeomeanOracle interface so external contracts (e.g. buyback hooks) can query this pool's
    /// TWAP without maintaining their own oracle.
    /// @param key The pool key
    /// @param secondsAgos Array of time periods (in seconds) to look back
    /// @return tickCumulatives Cumulative tick values at each time period
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity at each time period.
    function observe(
        PoolKey calldata key,
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId poolId = key.toId();
        ObservationState memory state = states[poolId];

        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        (tickCumulatives, secondsPerLiquidityCumulativeX128s) = observations[poolId].observe({
            time: uint32(block.timestamp),
            secondsAgos: secondsAgos,
            tick: tick,
            index: state.index,
            liquidity: liquidity,
            cardinality: state.cardinality
        });
    }

    /// @notice Observe the time-weighted average price (TWAP) tick over the specified lookback window for a pool.
    /// @dev External-facing wrapper around `_observeTWAP` for contracts that need the time-weighted average tick.
    /// @param poolId The pool ID
    /// @param secondsAgo Seconds in the past to calculate TWAP from
    /// @param tick Current tick
    /// @param index Current observation index
    /// @param liquidity Current liquidity
    /// @param cardinality Current cardinality
    /// @return arithmeticMeanTick The time-weighted average tick
    // forge-lint: disable-next-line(mixed-case-function)
    function observeTWAP(
        PoolId poolId,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        external
        view
        returns (int24 arithmeticMeanTick)
    {
        return _observeTWAP({
            poolId: poolId,
            secondsAgo: secondsAgo,
            tick: tick,
            index: index,
            liquidity: liquidity,
            cardinality: cardinality
        });
    }

    //*********************************************************************//
    // ---------------------- internal functions ---------------------- //
    //*********************************************************************//

    /// @notice Records a price observation after liquidity is added so the TWAP oracle stays up-to-date.
    /// @param key The pool key
    /// @return selector The function selector
    /// @return delta The delta to return (zero — no balance impact)
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    )
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        _recordObservation(key.toId());
        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Initializes the TWAP oracle array when a new pool is created with this hook attached.
    /// @param key The pool key
    /// @return selector The function selector
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        // Initialize oracle with first observation
        (uint16 cardinality, uint16 cardinalityNext) = observations[poolId].initialize({time: uint32(block.timestamp)});

        states[poolId] = ObservationState({index: 0, cardinality: cardinality, cardinalityNext: cardinalityNext});

        return BaseHook.afterInitialize.selector;
    }

    /// @notice Records a price observation after liquidity is removed so the TWAP oracle stays up-to-date.
    /// @param key The pool key
    /// @return selector The function selector
    /// @return delta The delta to return (zero — no balance impact)
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    )
        internal
        override
        returns (bytes4, BalanceDelta)
    {
        _recordObservation(key.toId());
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Records a price observation after a swap completes and enforces slippage protection for V4-routed swaps.
    /// @param key The pool key
    /// @param params The swap parameters
    /// @param delta The swap delta (represents actual V4 swap output for normal swaps)
    /// @param hookData Contains amountOutMin for slippage validation
    /// @return selector The function selector
    /// @return delta The delta to return (zero in our case)
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    )
        internal
        override
        returns (bytes4, int128)
    {
        // Validate slippage protection for V4 swaps
        // Note: For Juicebox routes, slippage is already validated in _beforeSwap
        // For V4 swaps (where we returned ZERO_DELTA), this validates the actual swap output
        // In _afterSwap, use >= 32 (not == 32 as in _beforeSwap) because external V4 swaps may include
        // additional hookData beyond the amountOutMin prefix. _beforeSwap requires exactly 32 bytes for
        // Juicebox-routed swaps; _afterSwap is more permissive to support arbitrary external swap metadata.
        if (hookData.length >= 32) {
            uint256 amountOutMin = abi.decode(hookData, (uint256));
            if (amountOutMin > 0) {
                // Extract output amount from delta based on swap direction.
                // In V4's convention, output amounts are negative (credits owed to the user),
                // so we negate to get the absolute output amount for comparison.
                int128 rawOutput =
                    params.zeroForOne ? BalanceDeltaLibrary.amount1(delta) : BalanceDeltaLibrary.amount0(delta);

                // Only validate if there is a real V4 swap (non-zero output or non-zero delta).
                // For Juicebox-routed swaps, both rawOutput and delta are zero and slippage was already validated
                // in _beforeSwap. A dust swap may have rawOutput==0 but a non-zero delta (input side is non-zero).
                if (rawOutput != 0 || BalanceDelta.unwrap(delta) != 0) {
                    // Output is negative in V4 convention; negate to get the positive amount received.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    uint256 outputAmount = rawOutput < 0 ? uint256(int256(-rawOutput)) : uint256(int256(rawOutput));
                    if (outputAmount < amountOutMin) {
                        revert JBUniswapV4Hook_InsufficientOutput({amount: outputAmount, minimum: amountOutMin});
                    }
                }
            }
        }

        _recordObservation(key.toId());
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice The main routing engine: compares expected output from V4 and Juicebox, then routes to whichever gives
    /// more tokens. If no JB token is involved, the swap proceeds through V4 normally.
    /// @dev Compares expected outputs and routes to the option with highest output
    /// @param key The pool key identifying the V4 pool
    /// @param params The swap parameters (direction, amount, price limit)
    /// @param hookData Must contain amountOutMin as uint256 (minimum tokens user accepts)
    /// @return selector The function selector (BaseHook.beforeSwap.selector)
    /// @return delta The swap delta (zero for V4, custom for V3/Juicebox routing)
    /// @return protocolFee The protocol fee (always 0)
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Prevent recursive routing: if we're already routing through Juicebox, block reentrant swaps.
        if (_routing) revert JBUniswapV4Hook_ReentrantRouting(msg.sender);

        // Decode amountOutMin from the first 32-byte word of hookData.
        // Pure V4 integrations may append extra metadata after this prefix, so `_beforeSwap` must accept the same
        // payload family that `_afterSwap` already supports.
        uint256 amountOutMin;
        if (hookData.length >= 32) {
            amountOutMin = abi.decode(hookData[:32], (uint256));
        } else {
            revert JBUniswapV4Hook_AmountOutMinRequired({hookDataLength: hookData.length});
        }
        PoolId poolId = key.toId();

        // Only support exact-input swaps (amountSpecified < 0)
        // Exact-output swaps (amountSpecified > 0) are not supported as they require
        // different handling of specified/unspecified tokens and delta signs
        if (params.amountSpecified > 0) {
            revert JBUniswapV4Hook_ExactOutputSwapsNotSupported({amountSpecified: params.amountSpecified});
        }

        // Determine input and output currencies based on swap direction
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        address tokenIn = Currency.unwrap(inputCurrency);
        address tokenOut = Currency.unwrap(outputCurrency);

        // Get input amount (amountSpecified is negative for exact input)
        uint256 amountIn = uint256(-params.amountSpecified);

        // Check if either token is a JB token by looking up projectId dynamically
        uint256 tokenInProjectId = TOKENS.projectIdOf(IJBToken(tokenIn));
        uint256 tokenOutProjectId = TOKENS.projectIdOf(IJBToken(tokenOut));

        // Determine if we're buying or selling JB tokens
        bool isSellingJBToken = tokenInProjectId != 0;
        bool isBuyingJBToken = tokenOutProjectId != 0;

        // When both tokens are JB tokens, each side has its own project ID.
        // Use separate variables to avoid confusing buy-side and sell-side contexts.
        // Buying uses tokenOutProjectId (the project whose token we're acquiring).
        // Selling uses tokenInProjectId (the project whose token we're cashing out).
        uint256 buyProjectId = isBuyingJBToken ? tokenOutProjectId : 0;
        uint256 sellProjectId = isSellingJBToken ? tokenInProjectId : 0;

        uint256 buySideExpectedOutput;
        uint256 sellSideExpectedOutput;
        IJBTerminal buySideTerminal;
        IJBTerminal sellSideTerminal;

        if (isBuyingJBToken) {
            buySideTerminal = _getPrimaryTerminal({projectId: buyProjectId, token: tokenIn});
            // Buying JB tokens: compare Juicebox vs Uniswap for getting JB tokens.
            // Prefer previewPayFor because it reflects live terminal execution semantics.
            // If previewing is unavailable, treat the JB buy path as ineligible so swaps can fall back to V4
            // instead of relying on static weight math that may ignore runtime terminal constraints.
            if (address(buySideTerminal) != address(0)) {
                try buySideTerminal.previewPayFor({
                    projectId: buyProjectId,
                    token: _normalizeToken(tokenIn),
                    amount: amountIn,
                    beneficiary: address(this),
                    metadata: bytes("")
                }) returns (
                    JBRuleset memory,
                    uint256 beneficiaryTokenCount,
                    uint256,
                    JBPayHookSpecification[] memory hookSpecifications
                ) {
                    buySideExpectedOutput = _effectivePreviewPayBeneficiaryTokenCount({
                        beneficiaryTokenCount: beneficiaryTokenCount, hookSpecifications: hookSpecifications
                    });
                } catch {
                    // Preview failure means the live JB buy path is not trustworthy enough for best execution.
                    // Leave the quote at 0 so V4 remains available.
                    buySideExpectedOutput = 0;
                }
            } else {
                // No live terminal means no executable JB buy path.
                buySideExpectedOutput = 0;
            }
        }

        if (isSellingJBToken) {
            sellSideTerminal = _getPrimaryTerminal({projectId: sellProjectId, token: tokenOut});
            // Selling JB tokens: compare Juicebox vs Uniswap for getting output tokens
            // NOTE: When cashOutTaxRate == 0, the bonding curve is linear — each token redeems for its
            // exact proportional share of surplus. The hook will repeatedly prefer JB cashout over V4
            // because per-token value doesn't decrease, and the V4 pool price doesn't move (tokens bypass
            // the AMM). This is accepted behavior: token holders are redeeming their fair share of surplus.
            // The V4 pool loses its sell-side price-discovery role while JB cashout offers better rates,
            // but no value is extracted beyond what the token holders are entitled to.
            // See RISKS.md for full analysis.
            sellSideExpectedOutput = calculateExpectedOutputFromSelling({
                projectId: sellProjectId, tokenAmountIn: amountIn, outputToken: tokenOut, terminal: sellSideTerminal
            });
        }

        if (!isBuyingJBToken && !isSellingJBToken) {
            // No JB token involved, proceed with normal Uniswap swap
            emit RouteSelected({poolId: poolId, useJuicebox: false, expectedTokens: 0, caller: msg.sender});
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Calculate how many tokens we'd get from Uniswap v4
        uint256 uniswapV4ExpectedTokens =
            estimateUniswapOutput({poolId: poolId, key: key, amountIn: amountIn, zeroForOne: params.zeroForOne});

        // Compare V4 vs Juicebox
        bool buySideAvailable = address(buySideTerminal) != address(0) && address(buySideTerminal).code.length > 0;
        bool sellSideAvailable = address(sellSideTerminal) != address(0) && address(sellSideTerminal).code.length > 0;
        // When both sides are JB-aware, prefer the side with the strictly better expected Juicebox output.
        // Ties fall toward the buy side so the router stays deterministic and avoids evaluating both paths twice.
        bool routeViaBuySide =
            buySideAvailable && buySideExpectedOutput >= sellSideExpectedOutput && buySideExpectedOutput > 0;
        bool routeViaSellSide =
            sellSideAvailable && sellSideExpectedOutput > buySideExpectedOutput && sellSideExpectedOutput > 0;
        // Collapse the selected Juicebox side back into the single route payload consumed by _routeThroughJuicebox.
        uint256 juiceboxExpectedOutput = routeViaSellSide ? sellSideExpectedOutput : buySideExpectedOutput;
        IJBTerminal jbTerminal = routeViaSellSide ? sellSideTerminal : buySideTerminal;
        uint256 projectId = routeViaSellSide ? sellProjectId : buyProjectId;
        // Uniswap V4 deltas are signed int128 values. Even if Juicebox would return more,
        // the hook must treat over-cap quotes as ineligible and let the swap continue through V4.
        bool juiceboxFitsV4Delta = juiceboxExpectedOutput <= MAX_V4_DELTA;
        // Only route through Juicebox if the chosen JB side beats the best Uniswap quote
        // and can still be represented by the downstream V4 accounting domain.
        bool juiceboxBetterThanV4 = (routeViaBuySide || routeViaSellSide) && juiceboxFitsV4Delta
            && juiceboxExpectedOutput > uniswapV4ExpectedTokens;

        emit BestRouteSelected({
            poolId: poolId,
            routeType: juiceboxBetterThanV4 ? 1 : 0,
            expectedTokens: juiceboxBetterThanV4 ? juiceboxExpectedOutput : uniswapV4ExpectedTokens,
            caller: msg.sender
        });

        // If Juicebox gives better output, route through Juicebox
        if (juiceboxBetterThanV4) {
            emit RouteSelected({
                poolId: poolId, useJuicebox: true, expectedTokens: juiceboxExpectedOutput, caller: msg.sender
            });

            uint256 outputReceived = _routeThroughJuicebox({
                projectId: projectId,
                inputCurrency: inputCurrency,
                outputCurrency: outputCurrency,
                amountIn: amountIn,
                isBuying: routeViaBuySide,
                terminal: jbTerminal,
                amountOutMin: amountOutMin
            });

            return (BaseHook.beforeSwap.selector, _createSwapDelta({amountIn: amountIn, amountOut: outputReceived}), 0);
        }

        // Proceed with normal v4 swap
        // Note: Slippage protection for V4 swaps is enforced in _afterSwap hook
        emit RouteSelected({
            poolId: poolId, useJuicebox: false, expectedTokens: uniswapV4ExpectedTokens, caller: msg.sender
        });
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Converts a payment amount (in any token decimals) into the expected number of project tokens using the
    /// ruleset weight and a price-oracle conversion factor.
    /// @dev Normalizes payment amount to 18 decimals, then calculates tokens based on weight and price conversion
    /// @param tokensPerBaseCurrency The project's weight (tokens per base currency unit)
    /// @param paymentAmount The payment amount in the token's native decimals
    /// @param paymentTokenDecimals The decimals of the payment token
    /// @param baseCurrencyPerPaymentToken The price conversion rate (base currency per payment token, scaled by 1e18)
    /// @return expectedTokens The expected number of tokens to be received
    function _calculateTokensWithCurrency(
        uint256 tokensPerBaseCurrency,
        uint256 paymentAmount,
        uint8 paymentTokenDecimals,
        uint256 baseCurrencyPerPaymentToken
    )
        internal
        pure
        returns (uint256 expectedTokens)
    {
        // Normalize payment amount to 18 decimals
        uint256 paymentAmount18 =
            paymentTokenDecimals == 18 ? paymentAmount : (paymentAmount * 1e18) / (10 ** paymentTokenDecimals);

        // Calculate tokens: if price conversion is 1:1, simplify; otherwise apply price conversion
        if (baseCurrencyPerPaymentToken == 1e18) {
            // Direct calculation: (weight * paymentAmount18) / 1e18
            expectedTokens = FullMath.mulDiv({a: tokensPerBaseCurrency, b: paymentAmount18, denominator: 1e18});
        } else {
            // Two-step calculation: first multiply by weight, then apply price conversion
            uint256 intermediate = FullMath.mulDiv({a: tokensPerBaseCurrency, b: paymentAmount18, denominator: 1e18});
            expectedTokens = FullMath.mulDiv({a: intermediate, b: baseCurrencyPerPaymentToken, denominator: 1e18});
        }
    }

    /// @notice Packs the input/output amounts into the BeforeSwapDelta format that tells PoolManager how this hook has
    /// already settled the swap (input taken, output provided).
    /// @dev Used when routing through Juicebox to inform PoolManager that no further AMM execution is needed.
    /// @param amountIn The input amount
    /// @param amountOut The output amount
    /// @return delta The BeforeSwapDelta representing the swap
    function _createSwapDelta(uint256 amountIn, uint256 amountOut) internal pure returns (BeforeSwapDelta) {
        // The hook takes the input amount and settles the output amount
        // For both buying and selling: take inputCurrency, settle outputCurrency
        if (amountIn > MAX_V4_DELTA) revert JBUniswapV4Hook_InputExceedsV4DeltaLimit(amountIn);
        if (amountOut > MAX_V4_DELTA) revert JBUniswapV4Hook_OutputExceedsV4DeltaLimit(amountOut);
        return toBeforeSwapDelta({
            // forge-lint: disable-next-line(unsafe-typecast)
            deltaSpecified: int128(uint128(amountIn)),
            // Safe: the caller already rejected outputs above Uniswap V4's signed delta capacity.
            // forge-lint: disable-next-line(unsafe-typecast)
            deltaUnspecified: -int128(uint128(amountOut))
        });
    }

    /// @notice Normalize a cash-out preview into the reclaim amount used for route comparison.
    /// @dev Standard cash-out previews return `reclaimAmount` directly. Metadata-only buyback previews can return
    /// zero reclaim amount while carrying their executable `minimumSwapAmountOut` inside hook metadata. This matters
    /// for programmatic callers that cannot supply an offchain quote: the router can still compare the executable
    /// buyback floor that the terminal preview already committed to.
    /// @param reclaimAmount The terminal-reported reclaim amount.
    /// @param hookSpecifications The cash-out hook specifications returned by the terminal preview.
    /// @return effectiveReclaimAmount The amount the router should compare against the Uniswap quote.
    function _effectivePreviewCashOutAmount(
        uint256 reclaimAmount,
        JBCashOutHookSpecification[] memory hookSpecifications
    )
        internal
        pure
        returns (uint256 effectiveReclaimAmount)
    {
        // Nonzero terminal output is already the executable reclaim amount.
        effectiveReclaimAmount = reclaimAmount;
        if (reclaimAmount != 0) return effectiveReclaimAmount;

        for (uint256 i; i < hookSpecifications.length;) {
            JBCashOutHookSpecification memory specification = hookSpecifications[i];

            // Buyback cash-out metadata is seven words. Word 0 is the executable floor; word 6 is a diagnostic raw
            // quote that can overstate what execution can prove, so it is not used for route scoring.
            // Ignore every other payload shape so unrelated hooks cannot accidentally influence routing.
            if (!specification.noop && specification.metadata.length == 7 * 32) {
                (uint256 minimumSwapAmountOut,,,,,,) =
                    abi.decode(specification.metadata, (uint256, uint256, uint256, int24, uint128, bytes32, uint256));

                // Multiple hook specs are possible; keep the strongest executable output.
                if (minimumSwapAmountOut > effectiveReclaimAmount) effectiveReclaimAmount = minimumSwapAmountOut;
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Normalize a pay preview into the beneficiary token count used for route comparison.
    /// @dev Standard pay previews return `beneficiaryTokenCount` directly. Metadata-only buyback previews can return
    /// zero beneficiary tokens while carrying their executable `minimumBeneficiaryTokenCount` inside hook metadata.
    /// This keeps contract-to-contract pay flows usable when no offchain quote was prepared.
    /// @param beneficiaryTokenCount The terminal-reported beneficiary token count.
    /// @param hookSpecifications The pay hook specifications returned by the terminal preview.
    /// @return effectiveBeneficiaryTokenCount The token count the router should compare against the Uniswap quote.
    function _effectivePreviewPayBeneficiaryTokenCount(
        uint256 beneficiaryTokenCount,
        JBPayHookSpecification[] memory hookSpecifications
    )
        internal
        pure
        returns (uint256 effectiveBeneficiaryTokenCount)
    {
        // Nonzero terminal output is already the executable beneficiary token count.
        effectiveBeneficiaryTokenCount = beneficiaryTokenCount;
        if (beneficiaryTokenCount != 0) return effectiveBeneficiaryTokenCount;

        for (uint256 i; i < hookSpecifications.length;) {
            JBPayHookSpecification memory specification = hookSpecifications[i];

            // Buyback pay metadata is thirteen words; word 10 is the minimum beneficiary token count.
            // Treat shorter, longer, or noop hook payloads as unrelated metadata.
            if (!specification.noop && specification.metadata.length == 13 * 32) {
                (,,,,,,,,,, uint256 minimumBeneficiaryTokenCount,,) = abi.decode(
                    specification.metadata,
                    (
                        bool,
                        uint256,
                        uint256,
                        bool,
                        address,
                        uint256,
                        uint256,
                        int24,
                        uint128,
                        bytes32,
                        uint256,
                        uint256,
                        uint256
                    )
                );

                // Multiple hook specs are possible; the strongest executable minimum is the safest route estimate.
                if (minimumBeneficiaryTokenCount > effectiveBeneficiaryTokenCount) {
                    effectiveBeneficiaryTokenCount = minimumBeneficiaryTokenCount;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Looks up the Juicebox terminal that handles a specific token for a project. Returns address(0) if the
    /// project has no terminal configured for that token.
    /// @param projectId The project ID
    /// @param token The token address
    /// @return terminal The primary terminal, or address(0) if not found
    function _getPrimaryTerminal(uint256 projectId, address token) internal view returns (IJBTerminal) {
        // Normalize native ETH to JB_NATIVE_TOKEN for terminal lookup
        address normalized = _normalizeToken(token);
        try DIRECTORY.primaryTerminalOf({projectId: projectId, token: normalized}) returns (IJBTerminal t) {
            return t;
        } catch {
            return IJBTerminal(address(0));
        }
    }

    /// @notice Gets token decimals, defaulting to 18 if unavailable.
    /// @dev 18 is the standard for ETH and most ERC-20 tokens.
    /// @param token The token address.
    /// @return decimals The token decimals (defaults to 18).
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == JB_NATIVE_TOKEN) {
            return 18; // Native ETH has 18 decimals.
        }
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18; // 18 is standard.
        }
    }

    /// @notice Computes the TWAP sqrt price over the configured lookback window. Returns 0 if the pool lacks
    /// sufficient observation history (fewer than 2 observations or none old enough).
    /// @param poolId The pool ID
    /// @return sqrtPriceX96 The TWAP sqrt price, or 0 if not enough observations
    // forge-lint: disable-next-line(mixed-case-function)
    function _getTWAPSqrtPrice(PoolId poolId) internal view returns (uint160) {
        ObservationState memory state = states[poolId];

        // Need at least 2 observations for TWAP
        if (state.cardinality < 2) {
            return 0;
        }

        // Get current pool state for observation
        // getSlot0 returns: sqrtPriceX96, tick, protocolFee, lpFee (no liquidity)
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        // Get current liquidity from the dedicated accessor
        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint32 currentTime = uint32(block.timestamp);

        // Calculate the target time (TWAP_PERIOD seconds ago)
        uint32 oldestAllowedTime = currentTime > TWAP_PERIOD ? currentTime - TWAP_PERIOD : 0;

        // Get oldest observation timestamp
        Oracle.Observation memory oldestObs = observations[poolId][(state.index + 1) % state.cardinality];
        if (!oldestObs.initialized) {
            oldestObs = observations[poolId][0];
        }

        // If we don't have observations old enough, return 0
        if (oldestObs.blockTimestamp > oldestAllowedTime) {
            return 0;
        }

        // Observe the TWAP
        // _observeTWAP() is called without try-catch. If the oracle observation fails (e.g.,
        // insufficient history), the entire transaction reverts. This is intentional — a failed TWAP observation
        // means no reliable price reference exists, and proceeding without one would expose the swap to manipulation.
        int24 arithmeticMeanTick = _observeTWAP({
            poolId: poolId,
            secondsAgo: TWAP_PERIOD,
            tick: tick,
            index: state.index,
            liquidity: liquidity,
            cardinality: state.cardinality
        });

        // Convert tick to sqrtPriceX96
        return TickMath.getSqrtPriceAtTick(arithmeticMeanTick);
    }

    /// @notice Normalizes a token address to Juicebox's native token representation
    /// @dev Maps Uniswap's native ETH (address(0)) to Juicebox's native token constant
    /// @param token The token address to normalize
    /// @return The normalized token address (JB_NATIVE_TOKEN for native ETH, unchanged otherwise)
    function _normalizeToken(address token) internal pure returns (address) {
        return token == UNISWAP_NATIVE_ETH ? JB_NATIVE_TOKEN : token;
    }

    /// @notice Internal TWAP tick computation, avoiding external self-call overhead.
    /// @param poolId The pool ID
    /// @param secondsAgo Seconds in the past to calculate TWAP from
    /// @param tick Current tick
    /// @param index Current observation index
    /// @param liquidity Current liquidity
    /// @param cardinality Current cardinality
    /// @return arithmeticMeanTick The time-weighted average tick
    // forge-lint: disable-next-line(mixed-case-function)
    function _observeTWAP(
        PoolId poolId,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        internal
        view
        returns (int24 arithmeticMeanTick)
    {
        if (secondsAgo == 0) {
            revert JBUniswapV4Hook_SecondsAgoCannotBeZero({secondsAgo: secondsAgo});
        }

        // Batch both observations into a single call to avoid redundant binary searches.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0;
        secondsAgos[1] = secondsAgo;

        (int56[] memory tickCumulatives,) = observations[poolId].observe({
            time: uint32(block.timestamp),
            secondsAgos: secondsAgos,
            tick: tick,
            index: index,
            liquidity: liquidity,
            cardinality: cardinality
        });

        // Calculate arithmetic mean tick
        int56 tickCumulativeDelta = tickCumulatives[0] - tickCumulatives[1];
        // forge-lint: disable-next-line(unsafe-typecast)
        arithmeticMeanTick = int24(tickCumulativeDelta / int56(uint56(secondsAgo)));
        // Round toward negative infinity for negative ticks (Solidity truncates toward zero).
        if (tickCumulativeDelta < 0 && (tickCumulativeDelta % int56(uint56(secondsAgo)) != 0)) {
            arithmeticMeanTick--;
        }
    }

    /// @notice Writes a new tick/liquidity observation to the oracle array. Automatically doubles the array capacity
    /// (up to MAX_TWAP_CARDINALITY) when the buffer is full so the TWAP window can grow over time.
    /// @param poolId The pool ID
    function _recordObservation(PoolId poolId) internal {
        // Get current pool state
        // getSlot0 returns: sqrtPriceX96, tick, protocolFee, lpFee (no liquidity)
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        // Get current liquidity from the dedicated accessor
        uint128 liquidity = poolManager.getLiquidity(poolId);

        ObservationState memory state = states[poolId];

        // Preserve the 30-minute TWAP window when the buffer is at the configured cap. A fresh
        // write would overwrite the current oldest slot, promoting the second-oldest into the new
        // oldest position — so the window stays intact only when that second-oldest is at least
        // TWAP_PERIOD old at the moment of the write. Without this guard, sustained sub-2s swap
        // cadence (1024 slots / 1s) erases the entire window in under 17 minutes and forces
        // `observeTWAP` into the predates-oldest revert, collapsing routing back to spot pricing
        // exactly when TWAP protection matters most.
        if (state.cardinality == MAX_TWAP_CARDINALITY) {
            uint16 newOldestIndex;
            unchecked {
                newOldestIndex = (state.index + 2) % state.cardinality;
            }
            Oracle.Observation memory newOldest = observations[poolId][newOldestIndex];
            // Only enforce the guard once that slot has been written for real — newly grown slots
            // carry a sentinel `blockTimestamp = 1` and `initialized = false` until first written.
            // forge-lint: disable-next-line(block-timestamp)
            if (newOldest.initialized && uint32(block.timestamp) - newOldest.blockTimestamp < TWAP_PERIOD) {
                return;
            }
        }

        // Auto-grow cardinality when at capacity to enable TWAP functionality
        // Grow when we're about to wrap around (index == cardinality - 1) and cardinality == cardinalityNext
        uint16 newCardinalityNext = state.cardinalityNext;
        if (state.cardinality == state.cardinalityNext && state.index == state.cardinality - 1) {
            // Double the cardinality until the configured cap is reached.
            uint16 targetCardinality =
                state.cardinalityNext * 2 > MAX_TWAP_CARDINALITY ? MAX_TWAP_CARDINALITY : state.cardinalityNext * 2;

            // Grow the oracle array
            newCardinalityNext = observations[poolId].grow({current: state.cardinalityNext, next: targetCardinality});
        }

        // Write new observation
        (uint16 indexUpdated, uint16 cardinalityUpdated) = observations[poolId].write({
            index: state.index,
            blockTimestamp: uint32(block.timestamp),
            tick: tick,
            liquidity: liquidity,
            cardinality: state.cardinality,
            cardinalityNext: newCardinalityNext
        });

        // Update state
        states[poolId] = ObservationState({
            index: indexUpdated, cardinality: cardinalityUpdated, cardinalityNext: newCardinalityNext
        });
    }

    /// @notice Revert if `spender` still has any temporary ERC-20 allowance from this hook.
    /// @dev The hook grants exact-use allowances before external terminal calls. A leftover allowance means the
    /// downstream contract did not consume the approval as expected, leaving token spend authority live.
    /// @param token The ERC-20 token whose allowance was temporarily granted.
    /// @param spender The contract that was expected to consume the allowance.
    function _requireTemporaryAllowanceConsumed(address token, address spender) internal view {
        // Check after the external call returns, when a well-behaved terminal should have spent the full allowance.
        uint256 allowance = IERC20(token).allowance({owner: address(this), spender: spender});
        if (allowance != 0) {
            revert JBUniswapV4Hook_TemporaryAllowanceNotConsumed({token: token, spender: spender, allowance: allowance});
        }
    }

    /// @notice Executes a swap by paying into (buy) or cashing out of (sell) a Juicebox project terminal, bypassing the
    /// V4 AMM entirely. The input is taken from PoolManager and the output is settled back to PoolManager.
    /// @param projectId The Juicebox project ID
    /// @param inputCurrency The input currency (native ETH or ERC20)
    /// @param outputCurrency The output currency (native ETH or ERC20)
    /// @param amountIn The input amount
    /// @dev STRUCTURAL ARBITRAGE BOUND: This function routes swaps through Juicebox pay/cashOut which bypasses
    /// the V4 pool's price movement. However, the bonding curve's concavity naturally bounds arbitrage:
    /// each cashOut reduces both surplus AND supply, so each subsequent cashOut yields less until the
    /// JB price drops below the V4 pool price, at which point arbitrage becomes unprofitable.
    /// This convergence makes sustained extraction self-limiting.
    /// @param isBuying Whether we're buying (true) or selling (false) JB tokens
    /// @param terminal The Juicebox terminal to use
    /// @param amountOutMin Minimum tokens user accepts (enforced by JB terminal)
    /// @return outputReceived The amount of output tokens received
    function _routeThroughJuicebox(
        uint256 projectId,
        Currency inputCurrency,
        Currency outputCurrency,
        uint256 amountIn,
        bool isBuying,
        IJBTerminal terminal,
        uint256 amountOutMin
    )
        internal
        returns (uint256 outputReceived)
    {
        _routing = true;

        // Convert Uniswap's currency wrappers into raw token addresses for ERC-20 balance and allowance checks.
        address tokenIn = Currency.unwrap(inputCurrency);
        address tokenOut = Currency.unwrap(outputCurrency);

        // Pull the input that PoolManager already escrowed for this swap; the router can then pay or cash out in JB.
        poolManager.take({currency: inputCurrency, to: address(this), amount: amountIn});

        // Juicebox terminals use JB_NATIVE_TOKEN for native ETH while Uniswap V4 uses address(0).
        address normalizedTokenIn = _normalizeToken(tokenIn);

        // Snapshot this hook's output-token balance before the terminal call. The post-call delta is the only amount
        // that can safely be settled back to PoolManager.
        uint256 balanceBefore =
            outputCurrency.isAddressZero() ? address(this).balance : IERC20(tokenOut).balanceOf(address(this));

        if (isBuying) {
            // Buy-side ERC-20 payments need an exact temporary allowance so the terminal can pull the swap input.
            // Sell-side cash-outs burn project tokens through the controller instead of transferFrom.
            if (!inputCurrency.isAddressZero()) {
                IERC20(tokenIn).forceApprove({spender: address(terminal), value: amountIn});
            }

            // Route the buy through JB. The terminal enforces `amountOutMin` against issued project tokens.
            uint256 payValue = inputCurrency.isAddressZero() ? amountIn : 0;
            terminal.pay{value: payValue}({
                projectId: projectId,
                token: normalizedTokenIn, // Native ETH → JB_NATIVE_TOKEN
                amount: amountIn,
                beneficiary: address(this), // Tokens come to hook
                minReturnedTokens: amountOutMin, // Minimum tokens required (enforced by JB terminal)
                memo: "", // Empty memo
                metadata: bytes("") // Empty metadata
            });

            if (!inputCurrency.isAddressZero()) {
                // The allowance is single-use. Leaving it open would let the terminal spend future router balances,
                // which is worse than reverting here because the PoolManager settlement has not completed yet.
                _requireTemporaryAllowanceConsumed({token: tokenIn, spender: address(terminal)});
            }
        } else {
            // Route the sell through JB. Native ETH is normalized for terminal accounting.
            address normalizedTokenOut = _normalizeToken(tokenOut);
            IJBMultiTerminal(address(terminal))
                .cashOutTokensOf({
                holder: address(this), // holder (hook owns the JB tokens)
                projectId: projectId,
                cashOutCount: amountIn, // Amount of JB tokens to cash out
                tokenToReclaim: normalizedTokenOut, // Native ETH → JB_NATIVE_TOKEN
                minTokensReclaimed: amountOutMin, // Minimum tokens required (enforced by JB terminal)
                beneficiary: payable(address(this)), // beneficiary (hook)
                metadata: bytes("") // Empty metadata
            });
        }

        // Measure what the hook actually received. This handles fee-on-transfer tokens and nonstandard terminals whose
        // return value can differ from the balance that is available for PoolManager settlement.
        uint256 balanceAfter =
            outputCurrency.isAddressZero() ? address(this).balance : IERC20(tokenOut).balanceOf(address(this));
        outputReceived = balanceAfter - balanceBefore;

        // A nonzero sell that delivers no reclaim token is not a valid JB route. Revert instead of settling a
        // zero-output swap that appeared executable during preview.
        if (!isBuying && amountIn != 0 && outputReceived == 0) {
            revert JBUniswapV4Hook_JuiceboxSellDidNotDeliver({
                inputToken: tokenIn, outputToken: tokenOut, amountIn: amountIn
            });
        }

        // Enforce the user or router minimum on the reconciled balance delta, not on the terminal return value. This
        // catches fee-on-transfer output tokens and terminals that over-report how much the hook actually received.
        if (outputReceived < amountOutMin) {
            revert JBUniswapV4Hook_InsufficientOutput({amount: outputReceived, minimum: amountOutMin});
        }

        // Settle output back to PoolManager.
        _settleOutput({outputCurrency: outputCurrency, amount: outputReceived});

        // Reset the routing flag after the swap completes.
        _routing = false;

        return outputReceived;
    }

    /// @notice Transfers the Juicebox-received output tokens into PoolManager's flash-accounting system, completing the
    /// hook's side of the swap settlement.
    /// @param outputCurrency The output currency to settle
    /// @param amount The amount to settle
    /// @dev Uses OpenZeppelin's CurrencySettler library to ensure correct settlement order (sync -> transfer ->
    /// settle).
    function _settleOutput(Currency outputCurrency, uint256 amount) internal {
        // PoolManager settlement is expressed through signed `int128` deltas, so oversized JB outputs must stop here.
        if (amount > MAX_V4_DELTA) revert JBUniswapV4Hook_OutputExceedsV4DeltaLimit(amount);
        // Use CurrencySettler library to ensure correct settlement order and flash-accounting safety
        // payer = address(this) since we're settling tokens we received
        // burn = false since we're transferring ERC-20 tokens, not burning ERC-6909 tokens
        CurrencySettler.settle({
            currency: outputCurrency, poolManager: poolManager, payer: address(this), amount: amount, burn: false
        });
    }
}
