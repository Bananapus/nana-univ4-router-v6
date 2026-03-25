// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
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
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBFeeTerminal} from "@bananapus/core-v6/src/interfaces/IJBFeeTerminal.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";

import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";

import {Oracle} from "./libraries/Oracle.sol";

/// @title JBUniswapV4Hook
/// @notice Official Juicebox integration for Uniswap v4 that provides intelligent price comparison and optimal routing
/// @dev This hook compares prices between Uniswap V4 pools and Juicebox projects, then routes to the option that gives
/// users the most tokens. It uses TWAP (Time-Weighted Average Price) oracles to protect against manipulation.
///      Provides IGeomeanOracle-compatible `observe()` for TWAP queries by external contracts.
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
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using Oracle for Oracle.Observation[65_535];

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Reverts when amountOutMin is not provided in hookData.
    error JBUniswapV4Hook_AmountOutMinRequired();

    /// @notice Reverts when an exact-output swap is attempted.
    /// @dev Only exact-input swaps are supported.
    error JBUniswapV4Hook_ExactOutputSwapsNotSupported();

    /// @notice Reverts when swap output is below minimum required amount.
    error JBUniswapV4Hook_InsufficientOutput();

    /// @notice Reverts when a reentrant swap is detected during Juicebox routing.
    error JBUniswapV4Hook_ReentrantRouting();

    /// @notice Reverts when secondsAgo is zero in observeTWAP().
    error JBUniswapV4Hook_SecondsAgoCannotBeZero();

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
    // --------------------- immutable properties  ----------------------- //
    //*********************************************************************//

    /// @notice The Juicebox tokens contract for project token lookup
    IJBTokens public immutable TOKENS;

    /// @notice The Juicebox directory for terminal lookup
    IJBDirectory public immutable DIRECTORY;

    /// @notice The Juicebox prices contract for currency conversion
    IJBPrices public immutable PRICES;

    /// @notice Native ETH address representation
    address public constant UNISWAP_NATIVE_ETH = address(0);

    /// @notice Juicebox native token address
    address public constant JB_NATIVE_TOKEN = address(0x000000000000000000000000000000000000EEEe);

    /// @notice TWAP period in seconds (30 minutes by default)
    uint32 public constant TWAP_PERIOD = 1800;

    /// @notice The denominator used when calculating TWAP slippage percent values.
    uint256 public constant TWAP_SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice Maximum retained observation cardinality for a pool oracle.
    /// @dev 1024 observations cover just over 34 minutes at 2-second block times, keeping a 30-minute TWAP
    /// window available on fast-block L2s while staying well below the storage array's 65,535 hard limit.
    uint16 public constant MAX_TWAP_CARDINALITY = 1024;

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
        TOKENS = tokens;
        DIRECTORY = directory;
        PRICES = prices;
    }

    /// @notice Receive function to accept ETH during swap settlement with the PoolManager.
    /// @dev No withdrawal mechanism is needed — ETH received here is consumed during the same transaction
    /// as part of CurrencySettler.settle() for native-ETH output routing.
    receive() external payable {}

    //*********************************************************************//
    // ------------------------- public views ---------------------------- //
    //*********************************************************************//

    /// @notice Calculate expected output from selling JB tokens
    /// @dev Prefers the terminal store's `previewCashOutFrom` simulation so sell-side estimates can incorporate
    /// cash-out data-hook effects when the underlying store supports that surface. Falls back to a static surplus
    /// estimate if previewing is unavailable or reverts.
    /// The estimate also conservatively deducts fees even for feeless addresses, which may underestimate output.
    /// @dev NOTE: The `FEE()` call casts the terminal to `IJBFeeTerminal`. If the terminal is a non-standard
    /// implementation that does not implement `IJBFeeTerminal`, this call will propagate a revert. The standard
    /// `JBMultiTerminal` is NOT affected since it implements `IJBFeeTerminal`.
    /// @param projectId The Juicebox project ID
    /// @param tokenAmountIn The amount of JB tokens being sold
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
        // slither-disable-next-line unused-return
        try IJBCashOutTerminal(address(terminal))
            .previewCashOutFrom({
                holder: address(this),
                projectId: projectId,
                cashOutCount: tokenAmountIn,
                tokenToReclaim: outputToken,
                beneficiary: payable(address(this)),
                metadata: bytes("")
            }) returns (
            JBRuleset memory, uint256 grossReclaim, uint256, JBCashOutHookSpecification[] memory
        ) {
            // Deduct JB protocol fee. Conservative: assumes fee even for feeless addresses, which may
            // underestimate output and bias toward pool swaps. Intentional trade-off.
            uint256 fee = IJBFeeTerminal(address(terminal)).FEE();
            return grossReclaim - FullMath.mulDiv({a: grossReclaim, b: fee, denominator: JBConstants.MAX_FEE});
        } catch {
            return 0;
        }
    }

    /// @notice Calculate expected tokens for a given payment amount in any currency
    /// @dev WARNING: This estimate uses the ruleset's static weight. If the project has a data hook (such as a
    /// buyback hook) that overrides the weight at payment time, the actual token issuance may differ from this
    /// estimate, causing the swap-vs-mint routing decision to diverge. Deployers must ensure weight compatibility.
    /// @param projectId The Juicebox project ID
    /// @param paymentToken The token being used for payment
    /// @param paymentAmount The amount being paid (in the token's native decimals)
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

    /// @notice Estimate expected output tokens from a Uniswap swap using TWAP
    /// @dev Uses time-weighted average price to prevent manipulation
    // Pool selection by highest liquidity is a heuristic. A pool with less liquidity but better tick
    // distribution could produce better output for a given swap size. Full simulation of all pools would be
    // gas-prohibitive on-chain. Off-chain routers can provide optimal pool selection via metadata.
    /// @param poolId The pool ID
    /// @param key The pool key
    /// @param amountIn The input amount
    /// @param zeroForOne Whether swapping token0 for token1
    /// @return estimatedOut The estimated output amount
    // slither-disable-next-line incorrect-equality
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
        // forge-lint: disable-next-line(mixed-case-variable)
        uint160 sqrtPriceX96TWAP = _getTWAPSqrtPrice(poolId);

        // If TWAP is not available (not enough observations), fallback to spot price.
        // NOTE: Spot price is used as a fallback for newly created pools that lack sufficient TWAP history.
        // In this state, the estimate is susceptible to spot-price manipulation. Once the pool accumulates
        // enough observations for TWAP, this fallback is no longer used.
        // slither-disable-next-line incorrect-equality
        if (sqrtPriceX96TWAP == 0) {
            // slither-disable-next-line unused-return
            (sqrtPriceX96TWAP,,,) = poolManager.getSlot0(poolId);
        }

        // Calculate price ratio from sqrtPriceX96, handling overflow for large values.
        // When sqrtPriceX96 <= type(uint128).max, we can square it directly (fits in uint256).
        // Otherwise, use FullMath.mulDiv to avoid overflow, at the cost of reduced precision.
        if (sqrtPriceX96TWAP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96TWAP) * sqrtPriceX96TWAP;
            if (zeroForOne) {
                estimatedOut = FullMath.mulDiv({a: amountIn, b: ratioX192, denominator: 1 << 192});
            } else {
                estimatedOut = FullMath.mulDiv({a: amountIn, b: 1 << 192, denominator: ratioX192});
            }
        } else {
            uint256 ratioX128 = FullMath.mulDiv({a: sqrtPriceX96TWAP, b: sqrtPriceX96TWAP, denominator: 1 << 64});
            if (zeroForOne) {
                estimatedOut = FullMath.mulDiv({a: amountIn, b: ratioX128, denominator: 1 << 128});
            } else {
                estimatedOut = FullMath.mulDiv({a: amountIn, b: 1 << 128, denominator: ratioX128});
            }
        }

        // Apply fee from pool key
        // fee is in hundredths of a bip, so 3000 = 0.3%
        if (key.fee > 0 && !LPFeeLibrary.isDynamicFee(key.fee)) {
            estimatedOut = estimatedOut - FullMath.mulDiv({a: estimatedOut, b: key.fee, denominator: 1_000_000});
        } else if (LPFeeLibrary.isDynamicFee(key.fee)) {
            // For dynamic fee pools, key.fee is set to DYNAMIC_FEE_FLAG (0x800000), a sentinel value
            // that is not a valid fee. Read the current LP fee from the pool's slot0 instead.
            // slither-disable-next-line unused-return
            (,,, uint24 lpFee) = poolManager.getSlot0(PoolIdLibrary.toId(key));
            estimatedOut = estimatedOut - FullMath.mulDiv({a: estimatedOut, b: lpFee, denominator: 1_000_000});
        }

        return estimatedOut;
    }

    /// @notice Get the hook permissions for Uniswap v4
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

    /// @notice Returns TWAP tick and liquidity data for specified time periods (IGeomeanOracle-compatible)
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

        // slither-disable-next-line unused-return
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

    /// @notice Observe TWAP tick
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
        if (secondsAgo == 0) {
            revert JBUniswapV4Hook_SecondsAgoCannotBeZero();
        }

        // Batch both observations into a single call to avoid redundant binary searches.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0;
        secondsAgos[1] = secondsAgo;

        // slither-disable-next-line unused-return
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

    //*********************************************************************//
    // ---------------------- internal functions ---------------------- //
    //*********************************************************************//

    /// @notice Hook called after liquidity is added to record price observations
    /// @param key The pool key
    /// @return selector The function selector
    /// @return delta The delta to return (zero in our case)
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

    /// @notice Hook called after pool initialization to set up oracle
    /// @param key The pool key
    /// @return selector The function selector
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        // Initialize oracle with first observation
        (uint16 cardinality, uint16 cardinalityNext) = observations[poolId].initialize({time: uint32(block.timestamp)});

        states[poolId] = ObservationState({index: 0, cardinality: cardinality, cardinalityNext: cardinalityNext});

        return BaseHook.afterInitialize.selector;
    }

    /// @notice Hook called after liquidity is removed to record price observations
    /// @param key The pool key
    /// @return selector The function selector
    /// @return delta The delta to return (zero in our case)
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

    /// @notice Hook called after swap to record price observations and validate slippage for V4 swaps
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

                // Only validate if there is a real V4 swap (non-zero output).
                // For Juicebox-routed swaps, delta is zero and slippage was already validated in _beforeSwap.
                if (rawOutput != 0) {
                    // Output is negative in V4 convention; negate to get the positive amount received.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    uint256 outputAmount = rawOutput < 0 ? uint256(int256(-rawOutput)) : uint256(int256(rawOutput));
                    if (outputAmount < amountOutMin) {
                        revert JBUniswapV4Hook_InsufficientOutput();
                    }
                }
            }
        }

        _recordObservation(key.toId());
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Routes swaps to the best option among V4, V3, and Juicebox
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
        if (_routing) revert JBUniswapV4Hook_ReentrantRouting();

        // Decode amountOutMin from hookData (required: uint256)
        // hookData must be exactly 32 bytes, encoding a single uint256 amountOutMin (the minimum
        // acceptable output amount). This strict check prevents malformed metadata from reaching hook contracts.
        // Callers must format hookData as abi.encode(uint256).
        uint256 amountOutMin;
        if (hookData.length == 32) {
            amountOutMin = abi.decode(hookData, (uint256));
        } else {
            revert JBUniswapV4Hook_AmountOutMinRequired();
        }
        PoolId poolId = key.toId();

        // Only support exact-input swaps (amountSpecified < 0)
        // Exact-output swaps (amountSpecified > 0) are not supported as they require
        // different handling of specified/unspecified tokens and delta signs
        if (params.amountSpecified > 0) {
            revert JBUniswapV4Hook_ExactOutputSwapsNotSupported();
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
        // forge-lint: disable-next-line(mixed-case-variable)
        bool isSellingJBToken = tokenInProjectId != 0;
        // forge-lint: disable-next-line(mixed-case-variable)
        bool isBuyingJBToken = tokenOutProjectId != 0;

        // When both tokens are JB tokens, each side has its own project ID.
        // Use separate variables to avoid confusing buy-side and sell-side contexts.
        // Buying uses tokenOutProjectId (the project whose token we're acquiring).
        // Selling uses tokenInProjectId (the project whose token we're cashing out).
        uint256 buyProjectId = isBuyingJBToken ? tokenOutProjectId : 0;
        uint256 sellProjectId = isSellingJBToken ? tokenInProjectId : 0;

        // Use the appropriate project ID for Juicebox operations.
        // Buying takes priority: if both are JB tokens, we compare buying via Juicebox vs Uniswap.
        // When both tokens are JB project tokens, only the buy-side (minting) is evaluated for routing.
        // The sell-side token is the project token being sold and is intentionally not evaluated separately —
        // evaluating both sides would double gas costs. The buy-side heuristic is conservative: it may miss
        // sell-side opportunities where cash-out yields more, but never overpays.
        uint256 projectId = isBuyingJBToken ? buyProjectId : sellProjectId;

        uint256 juiceboxExpectedOutput;

        // Check if Juicebox is better than the best Uniswap option
        // Only consider Juicebox if a valid terminal exists for the appropriate token
        // For buying: terminal must support the payment token (tokenIn), projectId is the buy-side project
        // For selling: terminal must have the output token (tokenOut), projectId is the sell-side project
        address terminalToken = isBuyingJBToken ? tokenIn : tokenOut;
        IJBTerminal jbTerminal = _getPrimaryTerminal({projectId: projectId, token: terminalToken});

        if (isBuyingJBToken) {
            // Buying JB tokens: compare Juicebox vs Uniswap for getting JB tokens.
            // Prefer previewPayFor (accounts for data hooks like buyback hooks) over static weight estimation.
            // Guard: terminal must exist for preview. Fall back to static estimation if not.
            if (address(jbTerminal) != address(0)) {
                // slither-disable-next-line unused-return
                try jbTerminal.previewPayFor({
                    projectId: buyProjectId,
                    token: _normalizeToken(tokenIn),
                    amount: amountIn,
                    beneficiary: address(this),
                    metadata: bytes("")
                }) returns (
                    JBRuleset memory, uint256 beneficiaryTokenCount, uint256, JBPayHookSpecification[] memory
                ) {
                    juiceboxExpectedOutput = beneficiaryTokenCount;
                } catch {
                    // Fall back to static weight estimation if preview reverts.
                    juiceboxExpectedOutput = calculateExpectedTokensWithCurrency({
                        projectId: buyProjectId, paymentToken: tokenIn, paymentAmount: amountIn
                    });
                }
            } else {
                // No terminal available — use static weight estimation.
                juiceboxExpectedOutput = calculateExpectedTokensWithCurrency({
                    projectId: buyProjectId, paymentToken: tokenIn, paymentAmount: amountIn
                });
            }
        } else if (isSellingJBToken) {
            // Selling JB tokens: compare Juicebox vs Uniswap for getting output tokens
            // NOTE: When cashOutTaxRate == 0, the bonding curve is linear — each token redeems for its
            // exact proportional share of surplus. The hook will repeatedly prefer JB cashout over V4
            // because per-token value doesn't decrease, and the V4 pool price doesn't move (tokens bypass
            // the AMM). This is accepted behavior: token holders are redeeming their fair share of surplus.
            // The V4 pool loses its sell-side price-discovery role while JB cashout offers better rates,
            // but no value is extracted beyond what the token holders are entitled to.
            // See RISKS.md for full analysis.
            juiceboxExpectedOutput = calculateExpectedOutputFromSelling({
                projectId: sellProjectId, tokenAmountIn: amountIn, outputToken: tokenOut, terminal: jbTerminal
            });
        } else {
            // No JB token involved, proceed with normal Uniswap swap
            emit RouteSelected(poolId, false, 0, msg.sender);
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Calculate how many tokens we'd get from Uniswap v4
        uint256 uniswapV4ExpectedTokens =
            estimateUniswapOutput({poolId: poolId, key: key, amountIn: amountIn, zeroForOne: params.zeroForOne});

        // Compare V4 vs Juicebox
        bool jbTerminalAvailable = address(jbTerminal) != address(0) && address(jbTerminal).code.length > 0;
        bool juiceboxBetterThanV4 =
            jbTerminalAvailable && juiceboxExpectedOutput > uniswapV4ExpectedTokens && juiceboxExpectedOutput > 0;

        emit BestRouteSelected(
            poolId,
            juiceboxBetterThanV4 ? 1 : 0,
            juiceboxBetterThanV4 ? juiceboxExpectedOutput : uniswapV4ExpectedTokens,
            msg.sender
        );

        // If Juicebox gives better output, route through Juicebox
        if (juiceboxBetterThanV4) {
            emit RouteSelected(poolId, true, juiceboxExpectedOutput, msg.sender);

            uint256 outputReceived = _routeThroughJuicebox({
                projectId: projectId,
                inputCurrency: inputCurrency,
                outputCurrency: outputCurrency,
                amountIn: amountIn,
                isBuying: isBuyingJBToken,
                terminal: jbTerminal,
                amountOutMin: amountOutMin
            });

            return (BaseHook.beforeSwap.selector, _createSwapDelta({amountIn: amountIn, amountOut: outputReceived}), 0);
        }

        // Proceed with normal v4 swap
        // Note: Slippage protection for V4 swaps is enforced in _afterSwap hook
        emit RouteSelected(poolId, false, uniswapV4ExpectedTokens, msg.sender);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Calculates expected tokens with currency conversion
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

    /// @notice Creates a BeforeSwapDelta from input and output amounts
    /// @param amountIn The input amount
    /// @param amountOut The output amount
    /// @return delta The BeforeSwapDelta representing the swap
    function _createSwapDelta(uint256 amountIn, uint256 amountOut) internal pure returns (BeforeSwapDelta) {
        // The hook takes the input amount and settles the output amount
        // For both buying and selling: take inputCurrency, settle outputCurrency
        return toBeforeSwapDelta({
            // forge-lint: disable-next-line(unsafe-typecast)
            deltaSpecified: int128(uint128(amountIn)),
            // Safe: amountOut is a swap output bounded by pool liquidity, fits in uint128/int128.
            // forge-lint: disable-next-line(unsafe-typecast)
            deltaUnspecified: -int128(uint128(amountOut))
        });
    }

    /// @notice Gets the primary terminal for a project and token
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

    /// @notice Gets token decimals, defaulting to 18 if unavailable
    /// @param token The token address
    /// @return decimals The token decimals (defaults to 18)
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == JB_NATIVE_TOKEN) {
            return 18; // Native ETH has 18 decimals
        }
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18; // Default to 18 if unavailable
        }
    }

    /// @notice Get the TWAP sqrt price for a pool
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
        // slither-disable-next-line unused-return
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        // Get current liquidity from the dedicated accessor
        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint32 currentTime = uint32(block.timestamp);

        // Calculate the target time (TWAP_PERIOD seconds ago)
        uint32 oldestAllowedTime = currentTime > TWAP_PERIOD ? currentTime - TWAP_PERIOD : 0;

        // Get oldest observation timestamp
        // slither-disable-next-line weak-prng
        Oracle.Observation memory oldestObs = observations[poolId][(state.index + 1) % state.cardinality];
        if (!oldestObs.initialized) {
            oldestObs = observations[poolId][0];
        }

        // If we don't have observations old enough, return 0
        if (oldestObs.blockTimestamp > oldestAllowedTime) {
            return 0;
        }

        // Observe the TWAP
        // this.observeTWAP() is called without try-catch. If the oracle observation fails (e.g.,
        // insufficient history), the entire transaction reverts. This is intentional — a failed TWAP observation
        // means no reliable price reference exists, and proceeding without one would expose the swap to manipulation.
        int24 arithmeticMeanTick = this.observeTWAP({
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

    /// @notice Records an oracle observation and grows cardinality if needed
    /// @param poolId The pool ID
    function _recordObservation(PoolId poolId) internal {
        // Get current pool state
        // getSlot0 returns: sqrtPriceX96, tick, protocolFee, lpFee (no liquidity)
        // slither-disable-next-line unused-return
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        // Get current liquidity from the dedicated accessor
        uint128 liquidity = poolManager.getLiquidity(poolId);

        ObservationState memory state = states[poolId];

        // Auto-grow cardinality when at capacity to enable TWAP functionality
        // Grow when we're about to wrap around (index == cardinality - 1) and cardinality == cardinalityNext
        uint16 newCardinalityNext = state.cardinalityNext;
        // slither-disable-next-line incorrect-equality
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

    /// @notice Routes a swap through Juicebox terminal instead of Uniswap
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
    // slither-disable-next-line arbitrary-send-eth
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

        address tokenIn = Currency.unwrap(inputCurrency);
        address tokenOut = Currency.unwrap(outputCurrency);

        // Terminal is already validated by caller
        // Take input from PoolManager (pre-deposited by JuiceboxSwapRouter)
        poolManager.take({currency: inputCurrency, to: address(this), amount: amountIn});

        // Normalize token for Juicebox terminal interaction
        address normalizedTokenIn = _normalizeToken(tokenIn);

        if (isBuying) {
            // Approve the terminal to spend the input tokens for payment.
            // Use forceApprove to set an exact allowance, avoiding accumulation from safeIncreaseAllowance
            // if a previous terminal call reverted after partial token consumption.
            // Only needed on the buy path — sell path uses cashOutTokensOf which burns JB tokens
            // via the controller, not ERC20 transferFrom.
            if (!inputCurrency.isAddressZero()) {
                IERC20(tokenIn).forceApprove({spender: address(terminal), value: amountIn});
            }

            // Buying JB tokens: Pay to Juicebox and receive JB tokens
            // Normalize native ETH to JB_NATIVE_TOKEN for terminal interaction
            uint256 payValue = inputCurrency.isAddressZero() ? amountIn : 0;
            outputReceived = terminal.pay{value: payValue}({
                projectId: projectId,
                token: normalizedTokenIn, // Native ETH → JB_NATIVE_TOKEN
                amount: amountIn,
                beneficiary: address(this), // Tokens come to hook
                minReturnedTokens: amountOutMin, // Minimum tokens required (enforced by JB terminal)
                memo: "", // Empty memo
                metadata: bytes("") // Empty metadata
            });
        } else {
            // Selling JB tokens: Cash out JB tokens and receive output currency
            // Only normalize native ETH to JB_NATIVE_TOKEN (WETH only appears when routing through v3)
            address normalizedTokenOut = _normalizeToken(tokenOut);
            // Call the terminal's cash out function to get the output tokens
            outputReceived = IJBMultiTerminal(address(terminal))
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

        // Settle output back to PoolManager.
        _settleOutput({outputCurrency: outputCurrency, amount: outputReceived});

        // Reset the routing flag after the swap completes.
        _routing = false;

        return outputReceived;
    }

    /// @notice Settles output tokens back to PoolManager
    /// @param outputCurrency The output currency to settle
    /// @param amount The amount to settle
    /// @dev Uses OpenZeppelin's CurrencySettler library to ensure correct settlement order
    /// @dev This handles sync -> transfer -> settle in the correct order for flash-accounting safety
    function _settleOutput(Currency outputCurrency, uint256 amount) internal {
        // Use CurrencySettler library to ensure correct settlement order and flash-accounting safety
        // payer = address(this) since we're settling tokens we received
        // burn = false since we're transferring ERC-20 tokens, not burning ERC-6909 tokens
        CurrencySettler.settle({
            currency: outputCurrency, poolManager: poolManager, payer: address(this), amount: amount, burn: false
        });
    }
}
