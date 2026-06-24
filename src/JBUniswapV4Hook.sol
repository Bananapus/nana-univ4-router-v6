// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBFeeTerminal} from "@bananapus/core-v6/src/interfaces/IJBFeeTerminal.sol";
import {IJBFeelessAddresses} from "@bananapus/core-v6/src/interfaces/IJBFeelessAddresses.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBFees} from "@bananapus/core-v6/src/libraries/JBFees.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
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

import {IGeomeanOracle} from "./interfaces/IGeomeanOracle.sol";
import {JBUniswapV4HookData} from "./libraries/JBUniswapV4HookData.sol";
import {Oracle} from "./libraries/Oracle.sol";

/// @title JBUniswapV4Hook
/// @notice A Uniswap V4 hook that automatically routes swaps to whichever venue (V4 pool or Juicebox project) gives
/// the user more tokens. Uses a 30-minute TWAP oracle to resist price manipulation when comparing routes.
/// @dev Compares V4 TWAP-based estimates against Juicebox terminal previews for both buy-side (pay) and sell-side
/// (cash out) swaps. Provides IGeomeanOracle-compatible `observe()` for TWAP queries by external contracts.
/// @dev COMPOSITION WARNING — This hook can serve as JBBuybackHook's ORACLE_HOOK for the same V4 pool.
/// When the buyback hook attempts a swap, it flows through this hook's `_beforeSwap` routing logic. Live routing only
/// trusts direct terminal preview outputs. Buyback-hook metadata is ignored because it can send users through the same
/// pool indirectly. Static weight math remains only an offchain/reference helper, so deployers must not treat it as
/// proof that data-hook-adjusted projects are safe for live best-execution routing.
contract JBUniswapV4Hook is BaseHook, IGeomeanOracle {
    using Oracle for Oracle.Observation[65_535];
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint16;
    using ProtocolFeeLibrary for uint24;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when an exact-output swap is attempted.
    /// @dev Only exact-input swaps are supported.
    /// @param amountSpecified The positive exact-output amount that was requested.
    error JBUniswapV4Hook_ExactOutputSwapsNotSupported(int256 amountSpecified);

    /// @notice Thrown when a Juicebox input cannot fit inside Uniswap V4's signed delta accounting.
    /// @param amount The oversized input amount.
    error JBUniswapV4Hook_InputExceedsV4DeltaLimit(uint256 amount);

    /// @notice Thrown when swap output is below minimum required amount.
    /// @param amount The amount that would be delivered.
    /// @param minimum The minimum amount required by the caller.
    error JBUniswapV4Hook_InsufficientOutput(uint256 amount, uint256 minimum);

    /// @notice Thrown when a nonzero Juicebox sell cash-out delivers no reclaim token.
    error JBUniswapV4Hook_JuiceboxSellDidNotDeliver(address inputToken, address outputToken, uint256 amountIn);

    /// @notice Thrown when a Juicebox sell route returns or fails to consume exact-input project tokens.
    error JBUniswapV4Hook_SellInputReturned(address token, uint256 balanceBefore, uint256 balanceAfter);

    /// @notice Thrown when a Juicebox output cannot fit inside Uniswap V4's signed delta accounting.
    /// @param amount The oversized output amount.
    error JBUniswapV4Hook_OutputExceedsV4DeltaLimit(uint256 amount);

    /// @notice Thrown when a reentrant swap is detected during Juicebox routing.
    /// @param caller The account that attempted the reentrant route.
    error JBUniswapV4Hook_ReentrantRouting(address caller);

    /// @notice Thrown when secondsAgo is zero in observeTWAP().
    /// @param secondsAgo The invalid lookback window.
    error JBUniswapV4Hook_SecondsAgoCannotBeZero(uint32 secondsAgo);

    /// @notice Thrown when a temporary terminal allowance was not fully consumed.
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
    /// @dev 1801 observations retain a full 30-minute TWAP at one observation per second, including both endpoints,
    /// while staying well below the storage array's 65,535 hard limit.
    uint16 public constant MAX_TWAP_CARDINALITY = 1801;

    /// @notice Largest output amount that Uniswap V4 can represent in flash-accounting deltas.
    /// @dev PoolManager settles against signed `int128` deltas, so larger JB outputs must fall back to V4.
    uint256 public constant MAX_V4_DELTA = uint256(uint128(type(int128).max));

    /// @notice TWAP period in seconds (30 minutes by default)
    uint32 public constant TWAP_PERIOD = 1800;

    /// @notice The denominator used when calculating TWAP slippage percent values.
    uint256 public constant TWAP_SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice The 4-byte prefix that marks `hookData` as carrying a Juicebox `amountOutMin`.
    /// @dev Mirrors `JBUniswapV4HookData.TAG` (the canonical source, importable by downstream contracts at compile
    /// time). `hookData` is only read as an explicit minimum when it begins with this tag and is at least 36 bytes
    /// (`tag ++ abi.encode(amountOutMin)`). Any other payload — empty, or another protocol's metadata forwarded by a
    /// generic router — carries no minimum, so its first word is never mis-decoded as one. A JB-aware caller prefixes
    /// it: `abi.encodePacked(JBUniswapV4HookData.TAG, abi.encode(amountOutMin))`.
    bytes4 public constant JB_HOOK_DATA_TAG = JBUniswapV4HookData.TAG;

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
    /// @custom:param poolId The ID of the pool the observations belong to.
    mapping(PoolId => Oracle.Observation[65_535]) public observations;

    /// @notice The current observation array state for the given pool ID
    /// @custom:param poolId The ID of the pool the observation state belongs to.
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
    /// @param poolId The ID of the pool the swap is routed through.
    /// @param useJuicebox Whether the swap is routed through Juicebox (true) or settled on Uniswap v4 (false).
    /// @param expectedTokens The expected output token amount for the chosen route.
    /// @param caller The address that initiated the swap.
    event RouteSelected(PoolId indexed poolId, bool useJuicebox, uint256 expectedTokens, address caller);

    /// @notice Emitted when the best route is selected among v4 and Juicebox
    /// @param poolId The ID of the pool the swap is routed through.
    /// @param routeType 0 = v4, 1 = juicebox
    /// @param expectedTokens The expected output token amount for the selected best route.
    /// @param caller The address that initiated the swap.
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
    /// @dev NOTE: Fee calls are best-effort. If the terminal does not expose `FEE()`, this falls back to raw preview.
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
            JBRuleset memory,
            uint256 grossReclaim,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        ) {
            if (grossReclaim == 0) {
                return 0;
            }

            // Core previews price cash-outs against aggregate project surplus, but execution must subtract the gross
            // reclaim plus any cash-out hook amounts from the selected terminal's local balance. If that local
            // settlement check cannot pass, leave this sell leg ineligible so the swap can use V4 instead.
            if (!_cashOutCanSettleLocally({
                    terminal: terminal,
                    projectId: projectId,
                    outputToken: outputToken,
                    reclaimAmount: grossReclaim,
                    hookSpecifications: hookSpecifications
                })) {
                return 0;
            }

            // Zero tax: terminal charges the standard fee only up to its `feeFreeSurplusOf` counter, and only
            // for non-feeless beneficiaries. Read both pieces of state to compute the exact net the terminal
            // would settle. Fall back to gross on either read failure (terminals without the getters)
            // to bias toward JB rather than under-ranking it.
            if (cashOutTaxRate == 0) {
                return _exactZeroTaxNet({
                    terminal: terminal, projectId: projectId, outputToken: outputToken, grossReclaim: grossReclaim
                });
            }

            // Positive-tax standard reclaim path: core terminals charge the standard protocol fee on the full reclaim
            // amount for non-feeless beneficiaries. Use the conservative fee-discounted quote for route comparison.
            return grossReclaim - JBFees.standardFeeAmountFrom(grossReclaim);
        } catch {
            // Conservative degrade rule: if the live preview surface is unavailable, do not resurrect the older
            // static reclaim estimate. Cash-out data hooks and terminal-specific logic can make that estimate stale,
            // so the router treats the JB sell path as ineligible and leaves execution to V4 instead.
            return 0;
        }
    }

    /// @notice Estimates how many JB project tokens a user would receive by paying a given amount into the project.
    /// @dev WARNING: This estimate uses the ruleset's static weight. If the project has a data hook that overrides the
    /// weight at payment time, actual token issuance may differ from this helper's output.
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
        // This reference estimate uses static ruleset weight. Live routing uses previewPayFor instead.
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
    /// 30-minute TWAP price, the longest retained best-effort TWAP, or spot price if no oracle history is available.
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
        uint160 sqrtPriceX96twap = _getTWAPSqrtPrice(poolId);

        // If TWAP is not available (not enough observations), fall back to spot price for the route comparison.
        // A newly created pool that lacks sufficient TWAP history is priced at spot here, which is susceptible to
        // spot-price manipulation; once the pool accumulates enough observations the TWAP is used instead. A buy-side
        // route that leans on this cold-pool spot quote as its floor is bounded by a tagged `amountOutMin` if the
        // caller supplied one (see the buy-side note in `_beforeSwap`).
        if (sqrtPriceX96twap == 0) {
            (sqrtPriceX96twap,,,) = poolManager.getSlot0(poolId);
        }

        return
            _outputForSqrtPrice({key: key, amountIn: amountIn, zeroForOne: zeroForOne, sqrtPriceX96: sqrtPriceX96twap});
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

    /// @notice Whether the oracle has stored observations covering `secondsAgo` for `key`.
    /// @dev Consumers should require this before trusting `observe([secondsAgo, 0])` as a manipulation-resistant TWAP.
    /// @param key The pool key.
    /// @param secondsAgo The requested lookback window.
    /// @return True if the oldest retained observation is at least `secondsAgo` old.
    function hasObservationCoverage(PoolKey calldata key, uint32 secondsAgo) external view override returns (bool) {
        return _hasObservationCoverage({poolId: key.toId(), secondsAgo: secondsAgo});
    }

    /// @notice The oldest retained observation age for `key`.
    /// @dev Consumers can use this to quote against the longest retained best-effort window when the preferred window
    /// is not fully covered.
    /// @param key The pool key.
    /// @return oldestSecondsAgo The age of the oldest retained initialized observation, or 0 if unavailable.
    function observationCoverageOf(PoolKey calldata key) external view override returns (uint32 oldestSecondsAgo) {
        return _observationCoverageOf({poolId: key.toId()});
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
        override
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
        // Slippage protection for the V4-settled portion of a swap. A JB-routed swap returns its custom delta in
        // `_beforeSwap` and is validated there, so it is skipped here. A minimum is enforced only when the caller
        // tagged one into `hookData` (`_amountOutMinFrom`); an untagged payload — empty, or a generic integration's
        // own metadata — carries no minimum, and the swap proceeds under the caller's own protection (its router
        // min-out or `sqrtPriceLimitX96`). The hook imposes no floor of its own.
        (bool hasExplicitMin, uint256 amountOutMin) = _amountOutMinFrom(hookData);
        PoolId poolId = key.toId();

        // Only a real V4 settlement (an output owed to the swapper, or any non-zero delta) is validated; a JB-routed
        // swap leaves the delta at zero. The minimum, when tagged, is enforced against the actual settled output.
        if (hasExplicitMin) {
            int128 rawOutput =
                params.zeroForOne ? BalanceDeltaLibrary.amount1(delta) : BalanceDeltaLibrary.amount0(delta);
            if (rawOutput != 0 || BalanceDelta.unwrap(delta) != 0) {
                // The output leg's delta is positive in V4's convention (a credit owed to the swapper); take the
                // magnitude defensively so the comparison holds regardless of sign.
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 outputAmount = rawOutput < 0 ? uint256(int256(-rawOutput)) : uint256(int256(rawOutput));
                if (outputAmount < amountOutMin) {
                    revert JBUniswapV4Hook_InsufficientOutput({amount: outputAmount, minimum: amountOutMin});
                }
            }
        }

        _recordObservation(poolId);
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
        // Close the previous time interval before any swap can move the price. Writing post-swap would attribute the
        // entire elapsed interval since the previous observation to the new tick.
        PoolId poolId = key.toId();
        _recordObservation(poolId);

        // Prevent recursive routing: if we're already routing through Juicebox, block reentrant swaps.
        if (_routing) revert JBUniswapV4Hook_ReentrantRouting(msg.sender);

        // Read the caller's explicit minimum only from tagged hookData (`_amountOutMinFrom`). An untagged payload —
        // empty, or a generic integration's own metadata — carries no minimum (`amountOutMin == 0`); a generic swap
        // is
        // never reverted for omitting JB's encoding, and a JB-routed leg falls back to the routing floor derived below
        // (`routeMinimum`). The minimum is not re-interpreted as a hook-imposed floor here.
        (, uint256 amountOutMin) = _amountOutMinFrom(hookData);

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

        // Check if either token is the ERC-20 that Juicebox has registered for a project.
        // Credit-only project balances are intentionally out of scope for V4 pool routing.
        uint256 tokenInProjectId = _projectIdForRegisteredToken(tokenIn);
        uint256 tokenOutProjectId = _projectIdForRegisteredToken(tokenOut);

        // Determine if we're buying or selling JB tokens
        bool isSellingJbToken = tokenInProjectId != 0;
        bool isBuyingJbToken = tokenOutProjectId != 0;

        // When both tokens are JB tokens, each side has its own project ID.
        // Use separate variables to avoid confusing buy-side and sell-side contexts.
        // Buying uses tokenOutProjectId (the project whose token we're acquiring).
        // Selling uses tokenInProjectId (the project whose token we're cashing out).
        uint256 buyProjectId = isBuyingJbToken ? tokenOutProjectId : 0;
        uint256 sellProjectId = isSellingJbToken ? tokenInProjectId : 0;

        uint256 buySideExpectedOutput;
        uint256 sellSideExpectedOutput;
        IJBTerminal buySideTerminal;
        IJBTerminal sellSideTerminal;

        if (isBuyingJbToken) {
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
                    JBRuleset memory, uint256 beneficiaryTokenCount, uint256, JBPayHookSpecification[] memory
                ) {
                    buySideExpectedOutput = beneficiaryTokenCount;
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

        if (isSellingJbToken) {
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

        if (!isBuyingJbToken && !isSellingJbToken) {
            // No JB token involved, proceed with normal Uniswap swap.
            // Slippage (explicit or TWAP-derived) is enforced for this V4 settlement in `_afterSwap`.
            emit RouteSelected({poolId: poolId, useJuicebox: false, expectedTokens: 0, caller: msg.sender});
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Calculate how many tokens we'd get from Uniswap v4
        uint256 uniswapV4ExpectedTokens =
            estimateUniswapOutput({poolId: poolId, key: key, amountIn: amountIn, zeroForOne: params.zeroForOne});

        // Compare V4 vs Juicebox
        bool buySideAvailable = address(buySideTerminal) != address(0) && address(buySideTerminal).code.length > 0;
        bool sellSideAvailable = address(sellSideTerminal) != address(0) && address(sellSideTerminal).code.length > 0;
        // When both sides are JB-aware, compare only quotes that fit V4's signed-delta accounting domain.
        // Ties fall toward the buy side so the router stays deterministic and avoids evaluating both paths twice.
        bool buySideEligible = buySideAvailable && buySideExpectedOutput > 0 && buySideExpectedOutput <= MAX_V4_DELTA;
        bool sellSideEligible =
            sellSideAvailable && sellSideExpectedOutput > 0 && sellSideExpectedOutput <= MAX_V4_DELTA;
        bool routeViaBuySide = buySideEligible && (!sellSideEligible || buySideExpectedOutput >= sellSideExpectedOutput);
        bool routeViaSellSide = sellSideEligible && (!buySideEligible || sellSideExpectedOutput > buySideExpectedOutput);
        // Collapse the selected Juicebox side back into the single route payload consumed by _routeThroughJuicebox.
        uint256 juiceboxExpectedOutput = routeViaSellSide ? sellSideExpectedOutput : buySideExpectedOutput;
        IJBTerminal jbTerminal = routeViaSellSide ? sellSideTerminal : buySideTerminal;
        uint256 projectId = routeViaSellSide ? sellProjectId : buyProjectId;
        // Only route through Juicebox if the chosen eligible JB side beats the best Uniswap quote.
        bool juiceboxBetterThanV4 =
            (routeViaBuySide || routeViaSellSide) && juiceboxExpectedOutput > uniswapV4ExpectedTokens;

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

            // The JB-routed leg carries its own floor (a tagged explicit `amountOutMin`, raised as below). The mint /
            // cash-out itself is ruleset-deterministic, so it is not sandwichable; the only manipulable input is the
            // V4 quote used as the buy-side floor, and only while the pool's TWAP is cold (see the buy-side note).
            uint256 routeMinimum = amountOutMin;
            if (routeViaSellSide && juiceboxExpectedOutput > routeMinimum) {
                // Sell-side cash-outs must deliver at least what the terminal's `previewCashOutFrom` reported (a
                // ruleset-deterministic amount). Anything less is the terminal under-filling its own preview
                // (fee-on-transfer behavior, a misconfigured data hook, etc.) — accepting it would let a malicious or
                // buggy terminal win routing by over-quoting and then settling lower. The terminal enforces this floor
                // inside `cashOutTokensOf`, so an underfilled cash-out reverts before the hook settles output.
                routeMinimum = juiceboxExpectedOutput;
            } else if (routeViaBuySide && uniswapV4ExpectedTokens + 1 > routeMinimum) {
                // Buy-side previews decide whether JB beats V4, but live payment can still mint fewer project tokens
                // than previewed. Require the realized JB output to at least beat the V4 quote it displaced.
                // The `+ 1` is the strict better-than-V4 floor; eligible quotes are already bounded below MAX_V4_DELTA.
                // NOTE: `uniswapV4ExpectedTokens` comes from `estimateUniswapOutput`, which falls back to spot when the
                // pool's TWAP is cold. On a cold pool an in-block spot crash can drive this floor toward 0, so a
                // tagged `amountOutMin` is the only manipulation-resistant buy-side floor until the TWAP warms; the
                // mint itself is still ruleset-priced, so the loss is opportunity cost, not principal.
                routeMinimum = uniswapV4ExpectedTokens + 1;
            }
            uint256 outputReceived = _routeThroughJuicebox({
                projectId: projectId,
                inputCurrency: inputCurrency,
                outputCurrency: outputCurrency,
                amountIn: amountIn,
                isBuying: routeViaBuySide,
                terminal: jbTerminal,
                amountOutMin: routeMinimum
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

    /// @notice Reads an explicit `amountOutMin` from `hookData` when it carries the Juicebox tag.
    /// @dev Returns `(false, 0)` for empty, short, or untagged `hookData` (a generic integration's own payload), so a
    /// foreign first word is never mis-decoded as a minimum. Returns `(true, min)` only for tagged data
    /// (`JB_HOOK_DATA_TAG ++ abi.encode(min)`, length >= 36); any trailing bytes after the minimum are ignored.
    /// @param hookData The swap's hook data.
    /// @return present Whether the caller supplied a tagged explicit minimum.
    /// @return amountOutMin The explicit minimum output (0 when none is present).
    function _amountOutMinFrom(bytes calldata hookData) internal pure returns (bool present, uint256 amountOutMin) {
        if (hookData.length >= 36 && bytes4(hookData[:4]) == JB_HOOK_DATA_TAG) {
            return (true, uint256(bytes32(hookData[4:36])));
        }
    }

    /// @notice Checks whether the selected terminal can locally settle a cash-out preview.
    /// @dev `previewCashOutFrom` can price against aggregate project surplus, but `recordCashOutFor` subtracts
    /// `reclaimAmount + hookSpecification amounts` from this terminal's local balance.
    /// @param terminal The terminal that would execute the cash-out.
    /// @param projectId The Juicebox project ID.
    /// @param outputToken The terminal token being reclaimed, normalized to Juicebox's token representation.
    /// @param reclaimAmount The gross reclaim amount returned by `previewCashOutFrom`.
    /// @param hookSpecifications Cash-out hook specifications returned by `previewCashOutFrom`.
    /// @return True if the terminal reports enough local surplus to settle the preview.
    function _cashOutCanSettleLocally(
        IJBTerminal terminal,
        uint256 projectId,
        address outputToken,
        uint256 reclaimAmount,
        JBCashOutHookSpecification[] memory hookSpecifications
    )
        internal
        view
        returns (bool)
    {
        // Start with the gross reclaim because this is the terminal-token amount `recordCashOutFor` must pay
        // directly from the selected terminal during execution.
        uint256 settlementDemand = reclaimAmount;

        // Cash-out hook specifications can reserve additional terminal-token amounts. These amounts are also paid
        // from the selected terminal, so they must be included in the local balance demand.
        for (uint256 i; i < hookSpecifications.length;) {
            // Cache the hook amount so the overflow check and the addition use the same specification value.
            uint256 amount = hookSpecifications[i].amount;

            // If adding this hook amount would overflow, the demand cannot be represented safely. Treat the preview
            // as locally unfulfillable instead of risking an understated settlement requirement.
            if (amount > type(uint256).max - settlementDemand) return false;

            // Add this hook's terminal-token draw to the amount the selected terminal must be able to settle.
            settlementDemand += amount;

            unchecked {
                // The loop bound guarantees `i` cannot overflow before termination, so skip checked-add gas here.
                ++i;
            }
        }

        // Ask the selected terminal for the accounting context of the exact reclaimed token. `currentSurplusOf`
        // needs this context so the returned surplus is denominated in the same units as `settlementDemand`.
        try terminal.accountingContextForTokenOf({projectId: projectId, token: outputToken}) returns (
            JBAccountingContext memory context
        ) {
            // If the terminal does not report a context for the exact output token, its surplus result cannot prove
            // that this token's local balance can settle the cash-out.
            if (context.token != outputToken) return false;

            // `currentSurplusOf` accepts a token list. Query only `outputToken` so the result is this terminal's
            // local surplus for the reclaimed token, not a broader project-level or multi-token value.
            address[] memory tokens = new address[](1);
            tokens[0] = outputToken;

            // Read the selected terminal's local surplus using the token's own accounting context. If this call
            // reverts, the hook cannot prove local settlement and should leave the JB sell route ineligible.
            try terminal.currentSurplusOf({
                projectId: projectId, tokens: tokens, decimals: context.decimals, currency: context.currency
            }) returns (
                uint256 localSurplus
            ) {
                // The preview is safe to compete with V4 only if execution demand fits inside local surplus.
                return settlementDemand <= localSurplus;
            } catch {
                // A terminal that cannot report local surplus cannot prove that the selected cash-out route settles.
                return false;
            }
        } catch {
            // A terminal that cannot report accounting context cannot produce a trustworthy local-surplus check.
            return false;
        }
    }

    /// @notice Converts this hook's internal project-token credits into the registered ERC-20 before a sell route.
    /// @dev Core burns holder credits before ERC-20 balances. Normalizing first keeps the sell-side input-balance
    /// invariant scoped to transferable tokens already visible to Uniswap V4.
    /// @param projectId The Juicebox project whose tokens are being sold.
    function _claimHookCreditsFor(uint256 projectId) internal {
        uint256 creditCount = TOKENS.creditBalanceOf({holder: address(this), projectId: projectId});
        if (creditCount == 0) return;

        IJBController controller = IJBController(address(DIRECTORY.controllerOf(projectId)));
        controller.claimTokensFor({
            holder: address(this), projectId: projectId, tokenCount: creditCount, beneficiary: address(this)
        });
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

    /// @notice Computes the exact net the terminal would settle for a zero-tax cash-out by `address(this)` —
    /// i.e., `gross - standardFee(min(gross, feeFreeSurplusOf))` for non-feeless beneficiaries, or `gross` if
    /// the router is registered as feeless on the terminal's feeless-addresses registry.
    /// @dev Each external read is guarded by try/catch so the routing helper degrades gracefully on terminals
    /// that don't expose the relevant public getters — in those cases we fall back to `grossReclaim`, which
    /// biases toward JB rather than under-ranking executable cash-outs.
    /// @param terminal The terminal whose cash-out path is being previewed.
    /// @param projectId The Juicebox project ID being cashed out from.
    /// @param outputToken The token being reclaimed (already normalized to the terminal's accounting form).
    /// @param grossReclaim The gross reclaim amount returned by `previewCashOutFrom`.
    /// @return The exact net the terminal would deliver to the router for this cash-out under zero tax.
    function _exactZeroTaxNet(
        IJBTerminal terminal,
        uint256 projectId,
        address outputToken,
        uint256 grossReclaim
    )
        internal
        view
        returns (uint256)
    {
        // If the router is registered as feeless on this terminal's registry, no fee is charged at all.
        try IJBFeeTerminal(address(terminal)).FEELESS_ADDRESSES() returns (IJBFeelessAddresses feeless) {
            try feeless.isFeelessFor({addr: address(this), projectId: projectId, caller: address(this)}) returns (
                bool isFeeless
            ) {
                if (isFeeless) return grossReclaim;
            } catch {
                return grossReclaim;
            }
        } catch {
            return grossReclaim;
        }

        // Non-feeless zero-tax: terminal charges the standard fee only up to `feeFreeSurplusOf` for this pair.
        try IJBMultiTerminal(address(terminal)).feeFreeSurplusOf({projectId: projectId, token: outputToken}) returns (
            uint256 feeFreeSurplus
        ) {
            uint256 feeable = grossReclaim < feeFreeSurplus ? grossReclaim : feeFreeSurplus;
            return grossReclaim - JBFees.standardFeeAmountFrom(feeable);
        } catch {
            return grossReclaim;
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

    /// @notice Computes the TWAP sqrt price over the configured lookback window, or the longest retained best-effort
    /// window. Returns 0 if the pool lacks usable observation history.
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

        uint32 oldestSecondsAgo = _observationCoverageOf({poolId: poolId});
        uint32 secondsAgo = oldestSecondsAgo < TWAP_PERIOD ? oldestSecondsAgo : TWAP_PERIOD;
        if (secondsAgo == 0) return 0;

        // Observe the TWAP
        // _observeTWAP() is called without try-catch. If the oracle observation fails (e.g.,
        // insufficient history), the entire transaction reverts. This is intentional — a failed TWAP observation
        // means no reliable price reference exists, and proceeding without one would expose the swap to manipulation.
        int24 arithmeticMeanTick = _observeTWAP({
            poolId: poolId,
            secondsAgo: secondsAgo,
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

    /// @notice Converts an input amount into an expected V4 output using a given sqrt price, mirroring V4 swap math.
    /// @dev Used by `estimateUniswapOutput` to value a swap at a chosen price. Applies the combined swap fee
    /// (protocol fee + LP fee) to the input BEFORE the price-ratio conversion so the estimate's floor rounding matches
    /// V4's execution rounding. The fee is read for `key.toId()` so the fee always matches the priced pool.
    /// @param key The pool key
    /// @param amountIn The input amount
    /// @param zeroForOne Whether swapping token0 for token1
    /// @param sqrtPriceX96 The price (spot or TWAP) to value the swap at
    /// @return estimatedOut The estimated output amount
    function _outputForSqrtPrice(
        PoolKey memory key,
        uint256 amountIn,
        bool zeroForOne,
        uint160 sqrtPriceX96
    )
        internal
        view
        returns (uint256 estimatedOut)
    {
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
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            if (zeroForOne) {
                estimatedOut = FullMath.mulDiv({a: amountInAfterFee, b: ratioX192, denominator: 1 << 192});
            } else {
                estimatedOut = FullMath.mulDiv({a: amountInAfterFee, b: 1 << 192, denominator: ratioX192});
            }
        } else {
            uint256 ratioX128 = FullMath.mulDiv({a: sqrtPriceX96, b: sqrtPriceX96, denominator: 1 << 64});
            if (zeroForOne) {
                estimatedOut = FullMath.mulDiv({a: amountInAfterFee, b: ratioX128, denominator: 1 << 128});
            } else {
                estimatedOut = FullMath.mulDiv({a: amountInAfterFee, b: 1 << 128, denominator: ratioX128});
            }
        }
    }

    /// @notice Returns the project ID only when `token` is the project's registered ERC-20.
    /// @dev V4 pools can only custody transferable tokens. Internal Juicebox credits are not a routable pool asset,
    /// so a project with no registered ERC-20 should fall back to the normal V4 swap path.
    /// @param token The token to check.
    /// @return projectId The token's project ID, or 0 if the token is not the project's registered ERC-20.
    function _projectIdForRegisteredToken(address token) internal view returns (uint256 projectId) {
        projectId = TOKENS.projectIdOf(IJBToken(token));
        if (projectId == 0) return 0;

        return address(TOKENS.tokenOf(projectId)) == token ? projectId : 0;
    }

    /// @notice Writes a new tick/liquidity observation to the oracle array. Automatically doubles the array capacity
    /// (up to MAX_TWAP_CARDINALITY) when the buffer is full so the TWAP window can grow over time.
    /// @param poolId The pool ID
    function _recordObservation(PoolId poolId) internal {
        ObservationState memory state = states[poolId];
        if (state.cardinality == 0) return;

        // Get current pool state
        // getSlot0 returns: sqrtPriceX96, tick, protocolFee, lpFee (no liquidity)
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        // Get current liquidity from the dedicated accessor
        uint128 liquidity = poolManager.getLiquidity(poolId);

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

    /// @notice Whether the retained oracle ring buffer covers a requested lookback.
    /// @param poolId The pool ID.
    /// @param secondsAgo The requested lookback window.
    /// @return True if an observation at least `secondsAgo` old is retained.
    function _hasObservationCoverage(PoolId poolId, uint32 secondsAgo) internal view returns (bool) {
        ObservationState memory state = states[poolId];
        if (state.cardinality == 0) return false;
        if (secondsAgo == 0) return true;

        uint32 oldestSecondsAgo = _observationCoverageOf({poolId: poolId});
        return oldestSecondsAgo >= secondsAgo;
    }

    /// @notice The age of the oldest initialized retained observation.
    /// @param poolId The pool ID.
    /// @return oldestSecondsAgo The retained lookback window, or 0 if fewer than two observations are usable.
    function _observationCoverageOf(PoolId poolId) internal view returns (uint32 oldestSecondsAgo) {
        ObservationState memory state = states[poolId];
        uint16 cardinality = state.cardinality;
        if (cardinality < 2) return 0;

        Oracle.Observation memory oldest = observations[poolId][(state.index + 1) % cardinality];
        if (!oldest.initialized) oldest = observations[poolId][0];
        if (!oldest.initialized) return 0;

        uint32 currentTime = uint32(block.timestamp);
        if (oldest.blockTimestamp >= currentTime) return 0;

        unchecked {
            // forge-lint: disable-next-line(block-timestamp)
            oldestSecondsAgo = currentTime - oldest.blockTimestamp;
        }
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

        if (!isBuying) _claimHookCreditsFor(projectId);

        // On sell-side routes the hook takes exact-input project tokens from PoolManager. Those tokens must be fully
        // consumed by the cash-out; otherwise a partial-fill hook can leave unsold project tokens stranded here.
        uint256 inputBalanceBefore =
            !isBuying && !inputCurrency.isAddressZero() ? IERC20(tokenIn).balanceOf(address(this)) : 0;

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

        // ERC-20 sell routes should end with the hook holding the same amount of input token it held before the swap.
        // `poolManager.take()` temporarily moves the exact input project tokens here, and a valid JB cash-out burns or
        // otherwise consumes all of them. Native ETH cannot be stranded as project-token input, so it is skipped.
        if (!isBuying && !inputCurrency.isAddressZero()) {
            uint256 inputBalanceAfter = IERC20(tokenIn).balanceOf(address(this));

            // A changed balance means the terminal returned or failed to consume some exact-input project tokens while
            // still delivering output. Revert before settlement so a partial-fill sell route cannot strand tokens here.
            if (inputBalanceAfter != inputBalanceBefore) {
                revert JBUniswapV4Hook_SellInputReturned({
                    token: tokenIn, balanceBefore: inputBalanceBefore, balanceAfter: inputBalanceAfter
                });
            }
        }

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
