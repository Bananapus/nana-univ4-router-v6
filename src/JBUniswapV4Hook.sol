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
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";

import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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
/// @notice A Uniswap V4 hook that routes swaps of Juicebox project tokens between the V4 pool and the Juicebox project.
/// Buys fill from the pool while it beats the payer's issuance rate and mint the rest; sells take the best of the pool,
/// a cash-out, or a split of the two.
/// @dev Buys take the pool's fills with a real swap limited at the issuance price, so the buyer gets at least what
/// minting the whole input gives. Sells quote each route exactly (`quoteSwap` for pool legs, the terminal preview for
/// cash-outs) and run the best. Records a TWAP oracle and provides IGeomeanOracle-compatible `observe()` for external
/// contracts.
/// @dev COMPOSITION WARNING — This hook can serve as JBBuybackHook's ORACLE_HOOK for the same V4 pool.
/// When the buyback hook attempts a swap, it flows through this hook's `_beforeSwap` routing logic. Its swaps carry a
/// price limit at the issuance price, so they stay plain V4 swaps here, and buyback-hook metadata is ignored because it
/// can send users through the same pool indirectly.
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

    /// @notice Thrown by `quoteSwap` to return a pool quote without keeping its swaps.
    /// @param legAmountIn The input the pool leg would use.
    /// @param legAmountOut The output the pool leg would deliver.
    /// @param restAmountOut The output the pool would deliver for the rest beyond what the PoolManager holds.
    error JBUniswapV4Hook_SwapQuote(uint256 legAmountIn, uint256 legAmountOut, uint256 restAmountOut);

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
    // Type(int128).max is positive and fits uint128.
    // forge-lint: disable-next-line(unsafe-typecast)
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

    /// @notice The output a partial split's legs delivered, which `_afterSwap` adds to the pool's output for a tagged
    /// minimum.
    uint256 private transient _splitAmountOut;

    //*********************************************************************//
    // ---------------------------- events ------------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a routing decision is made
    /// @param poolId The ID of the pool the swap is routed through.
    /// @param useJuicebox Whether the swap is routed through Juicebox (true) or settled on Uniswap v4 (false).
    /// @param expectedTokens The expected output token amount for the chosen route.
    /// @param caller The address that initiated the swap.
    event RouteSelected(PoolId indexed poolId, bool useJuicebox, uint256 expectedTokens, address caller);

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
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Quotes a sell for `_routeSell` by running it in this pool and reverting: a pool leg limited at
    /// `legSqrtPriceLimitX96` (none when zero), then whatever input the leg leaves beyond `heldAmount`, limited at the
    /// caller's price.
    /// @dev Always reverts with `JBUniswapV4Hook_SwapQuote`, so it changes nothing for any caller. Its swaps skip this
    /// hook's callbacks.
    /// @param key The pool key.
    /// @param params The caller's swap parameters (exact input).
    /// @param legSqrtPriceLimitX96 The pool leg's price limit, or zero for no pool leg.
    /// @param heldAmount The input left out of the pool after the leg (what a cash-out leg would take).
    function quoteSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        uint160 legSqrtPriceLimitX96,
        uint256 heldAmount
    )
        external
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountIn = uint256(-params.amountSpecified);
        (uint256 legAmountIn, uint256 legAmountOut) = legSqrtPriceLimitX96 == 0
            ? (0, 0)
            : _swapPool({
                key: key, zeroForOne: params.zeroForOne, amountIn: amountIn, sqrtPriceLimitX96: legSqrtPriceLimitX96
            });
        uint256 restAmountOut;
        if (amountIn - legAmountIn > heldAmount) {
            (, restAmountOut) = _swapPool({
                key: key,
                zeroForOne: params.zeroForOne,
                amountIn: amountIn - legAmountIn - heldAmount,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            });
        }
        revert JBUniswapV4Hook_SwapQuote(legAmountIn, legAmountOut, restAmountOut);
    }

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
                metadata: _cashOutMetadataOf(projectId)
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
    /// @dev Live buys use this rate only when the terminal preview forwards the whole payment to a pay hook (see
    /// `_issuanceOf`), and the buy's output floor then enforces it.
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

        // The payment's currency and decimals from the accounting context of the project's primary terminal for the
        // token, which the terminal store prices the payment with.
        paymentToken = _normalizeToken(paymentToken);
        IJBTerminal terminal = _getPrimaryTerminal({projectId: projectId, token: paymentToken});
        if (address(terminal).code.length == 0) return 0;
        JBAccountingContext memory context;
        try terminal.accountingContextForTokenOf({projectId: projectId, token: paymentToken}) returns (
            JBAccountingContext memory accountingContext
        ) {
            context = accountingContext;
        } catch {
            return 0;
        }
        // `10 ** decimals` only fits in uint256 up through 77 decimals. Larger values are treated as
        // unsupported metadata so the caller can degrade to a 0 quote instead of reverting.
        if (context.decimals > 77) return 0;

        // One base-currency unit priced in the payment currency at the payment's decimals, as the terminal store reads
        // it, so this count matches what the terminal mints.
        uint256 weightRatio;
        if (context.currency == baseCurrency) {
            weightRatio = 10 ** context.decimals;
        } else {
            try PRICES.pricePerUnitOf({
                projectId: projectId,
                pricingCurrency: context.currency,
                unitCurrency: baseCurrency,
                decimals: context.decimals
            }) returns (
                uint256 price
            ) {
                weightRatio = price;
            } catch {
                return 0;
            }
            if (weightRatio == 0) return 0;
        }

        uint256 estimatedTokens =
            FullMath.mulDiv({a: paymentAmount, b: tokensPerBaseCurrency, denominator: weightRatio});

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
            // Oracle timestamps are uint32 and wrap, as in Uniswap V3.
            // forge-lint: disable-next-line(unsafe-typecast)
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
        // A terminal leg's hooks cannot move liquidity under a routed swap's quote.
        if (_routing) revert JBUniswapV4Hook_ReentrantRouting(msg.sender);
        _recordObservation(key.toId());
        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Initializes the TWAP oracle array when a new pool is created with this hook attached.
    /// @param key The pool key
    /// @return selector The function selector
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        // Initialize oracle with first observation
        // Oracle timestamps are uint32 and wrap, as in Uniswap V3.
        // forge-lint: disable-next-line(unsafe-typecast)
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
        // A terminal leg's hooks cannot move liquidity under a routed swap's quote.
        if (_routing) revert JBUniswapV4Hook_ReentrantRouting(msg.sender);
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

        // The output a partial split's legs delivered before the pool swapped the rest.
        uint256 splitAmountOut = _splitAmountOut;
        _splitAmountOut = 0;

        // Only a pool settlement or a partial split is validated; a swap the hook's legs consumed whole was checked in
        // `_beforeSwap` and leaves the delta at zero. The minimum, when tagged, is enforced against the settled output.
        if (hasExplicitMin) {
            int128 rawOutput =
                params.zeroForOne ? BalanceDeltaLibrary.amount1(delta) : BalanceDeltaLibrary.amount0(delta);
            if (splitAmountOut != 0 || BalanceDelta.unwrap(delta) != 0) {
                // The output leg's delta is positive in V4's convention (a credit owed to the swapper); take the
                // magnitude defensively so the comparison holds regardless of sign.
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256 outputAmount = rawOutput < 0 ? uint256(int256(-rawOutput)) : uint256(int256(rawOutput));
                outputAmount += splitAmountOut;
                if (outputAmount < amountOutMin) {
                    revert JBUniswapV4Hook_InsufficientOutput({amount: outputAmount, minimum: amountOutMin});
                }
            }
        }

        _recordObservation(poolId);
        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice The main routing engine. Buys of a project token fill from the pool while it beats issuance and mint the
    /// rest; sells fill from the pool while it beats the marginal reclaim rate and cash out the rest (`_routeSplit`).
    /// If no JB token is involved, the swap proceeds through V4 normally.
    /// @dev When both currencies are project tokens, the swap is a buy when paying the output's project mints at least
    /// what cashing out the input reclaims, and a sell of the input otherwise.
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
        // is never reverted for omitting JB's encoding, and a JB-routed leg keeps its own floor (issuance on buys, the
        // cash-out preview on sells). The minimum is not re-interpreted as a hook-imposed floor here.
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
        // Exact-input swaps have a negative amountSpecified, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountIn = uint256(-params.amountSpecified);

        // Check if either token is the ERC-20 that Juicebox has registered for a project.
        // Credit-only project balances are intentionally out of scope for V4 pool routing.
        uint256 projectId = _projectIdForRegisteredToken(tokenIn);
        uint256 buyProjectId = _projectIdForRegisteredToken(tokenOut);

        // Buying a project token: the payer's issuance for the whole input, zero when no mint path is usable.
        IJBTerminal buyTerminal;
        uint256 issuedTokenCount;
        if (buyProjectId != 0) {
            buyTerminal = _getPrimaryTerminal({projectId: buyProjectId, token: tokenIn});
            issuedTokenCount = address(buyTerminal).code.length == 0
                ? 0
                : _issuanceOf({
                    terminal: buyTerminal, projectId: buyProjectId, token: _normalizeToken(tokenIn), amount: amountIn
                });

            // A swap between two project tokens buys the output when paying its project mints at least what cashing
            // out the input reclaims, and is otherwise routed as a sell of the input. A quote V4's signed deltas
            // cannot carry leaves its side ineligible, as in 1.2.0.
            if (projectId != 0) {
                uint256 reclaim = calculateExpectedOutputFromSelling({
                    projectId: projectId,
                    tokenAmountIn: amountIn,
                    outputToken: tokenOut,
                    terminal: _getPrimaryTerminal({projectId: projectId, token: tokenOut})
                });
                if (issuedTokenCount > MAX_V4_DELTA || (reclaim <= MAX_V4_DELTA && issuedTokenCount < reclaim)) {
                    buyProjectId = 0;
                }
            }
        }

        // Fill from the pool while it beats issuance and mint the rest.
        if (buyProjectId != 0) {
            return (
                BaseHook.beforeSwap.selector,
                _routeSplit({
                    key: key,
                    params: params,
                    projectId: buyProjectId,
                    amountIn: amountIn,
                    amountOutMin: amountOutMin,
                    terminal: buyTerminal,
                    isBuying: true,
                    rateAmountOut: issuedTokenCount,
                    floorAmountOut: issuedTokenCount
                }),
                0
            );
        }

        if (projectId == 0) {
            // No JB token involved, proceed with normal Uniswap swap.
            // A tagged minimum is enforced for this V4 settlement in `_afterSwap`.
            // The calls before this event are views, which cannot reenter.
            // forge-lint: disable-next-item(reentrancy-events)
            emit RouteSelected({poolId: poolId, useJuicebox: false, expectedTokens: 0, caller: msg.sender});
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Selling a project token: sell in the pool while it beats the marginal reclaim rate and cash out the rest.
        IJBTerminal terminal = _getPrimaryTerminal({projectId: projectId, token: tokenOut});
        uint256 cashOutAmountOut;
        uint256 halfCashOutAmountOut;
        // The fee project's own cash-outs pay their fee back into it, minting its token to this hook mid-sell, so they
        // stay in the pool.
        if (projectId != JBConstants.FEE_BENEFICIARY_PROJECT_ID && address(terminal).code.length != 0) {
            cashOutAmountOut = calculateExpectedOutputFromSelling({
                projectId: projectId, tokenAmountIn: amountIn, outputToken: tokenOut, terminal: terminal
            });
            // A quote V4's signed deltas cannot carry is ineligible, as in 1.2.0.
            if (cashOutAmountOut > MAX_V4_DELTA) cashOutAmountOut = 0;
            halfCashOutAmountOut = calculateExpectedOutputFromSelling({
                projectId: projectId, tokenAmountIn: amountIn / 2, outputToken: tokenOut, terminal: terminal
            });
        }

        // A taxed reclaim is about quadratic in the count, so 3 J(n) - 4 J(n/2) is about n times its marginal rate at
        // n; a reclaim that is not convex uses its average rate. The rate only places the pool leg's limit:
        // `_routeSell` compares exact quotes.
        return (
            BaseHook.beforeSwap.selector,
            _routeSplit({
                key: key,
                params: params,
                projectId: projectId,
                amountIn: amountIn,
                amountOutMin: amountOutMin,
                terminal: terminal,
                isBuying: false,
                rateAmountOut: halfCashOutAmountOut < cashOutAmountOut / 2
                    ? 3 * cashOutAmountOut - 4 * halfCashOutAmountOut
                    : cashOutAmountOut,
                floorAmountOut: cashOutAmountOut
            }),
            0
        );
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

    /// @notice Cash-out metadata that tells a project's buyback hook not to sell in a V4 pool, which cannot unlock
    /// again inside this swap.
    /// @dev The entry is keyed to the buyback registry a data hook names with `BUYBACK_HOOK()` (a revnet's), or else to
    /// the data hook itself. Data hooks that read no such entry ignore it.
    /// @param projectId The ID of the project whose tokens are cashed out.
    /// @return metadata The cash-out metadata, empty when the ruleset has no data hook or cannot be read.
    function _cashOutMetadataOf(uint256 projectId) internal view returns (bytes memory metadata) {
        address target;
        try IJBController(address(DIRECTORY.controllerOf(projectId))).currentRulesetOf(projectId) returns (
            JBRuleset memory, JBRulesetMetadata memory rulesetMetadata
        ) {
            target = rulesetMetadata.dataHook;
        } catch {}
        if (target.code.length == 0) return metadata;

        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("BUYBACK_HOOK()"));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (success && data.length == 32) target = address(uint160(uint256(bytes32(data))));

        // The reserved word, a one-entry table pointing at word 2, and the entry: no minimum, and skip the pool sale.
        return abi.encodePacked(
            bytes32(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes32(abi.encodePacked(JBMetadataResolver.getId({purpose: "cashOut", target: target}), uint8(2))),
            abi.encode(uint256(0), true)
        );
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

    /// @notice The payer's project tokens from the terminal's mint path for `amount`, or 0 when no mint path is usable.
    /// @dev Reads `previewPayFor` with empty metadata, the metadata the mint leg pays with, and uses its count. A
    /// preview that mints nothing for the payer while a pay hook specification forwards funds is a buyback-style hook
    /// taking the pay to its own swap: paid from inside a pool swap, its `poolManager.unlock` reverts because the
    /// PoolManager is already unlocked, and it falls back to minting at the ruleset's weight, which
    /// `calculateExpectedTokensWithCurrency` prices. A rate above what the terminal delivers makes the buy's output
    /// floor revert, so an unknown hook can fail the swap but not underpay it.
    /// @param terminal The project's primary terminal for `token`.
    /// @param projectId The ID of the project whose tokens are being bought.
    /// @param token The input token, in Juicebox's representation.
    /// @param amount The input amount.
    /// @return tokenCount The beneficiary's project tokens for `amount`.
    function _issuanceOf(
        IJBTerminal terminal,
        uint256 projectId,
        address token,
        uint256 amount
    )
        internal
        view
        returns (uint256 tokenCount)
    {
        try terminal.previewPayFor({
            projectId: projectId, token: token, amount: amount, beneficiary: address(this), metadata: bytes("")
        }) returns (
            JBRuleset memory, uint256 beneficiaryTokenCount, uint256, JBPayHookSpecification[] memory hookSpecifications
        ) {
            if (beneficiaryTokenCount != 0) return beneficiaryTokenCount;

            // Nothing mints for the payer. If a hook takes the funds, it is a buyback-style swap.
            bool forwarded;
            for (uint256 i; i < hookSpecifications.length; i++) {
                if (hookSpecifications[i].amount != 0) forwarded = true;
            }
            if (forwarded) {
                return
                    calculateExpectedTokensWithCurrency({
                        projectId: projectId, paymentToken: token, paymentAmount: amount
                    });
            }
        } catch {
            // Without a preview there is no trustworthy mint rate, so the buy stays a plain pool swap.
            return 0;
        }
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
            // Oracle timestamps are uint32 and wrap, as in Uniswap V3.
            // forge-lint: disable-next-line(unsafe-typecast)
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

    /// @notice Quotes a sell with `quoteSwap`.
    /// @param key The pool key.
    /// @param params The caller's swap parameters.
    /// @param legSqrtPriceLimitX96 The pool leg's price limit, or zero for no pool leg.
    /// @param heldAmount The input left out of the pool after the leg.
    /// @return quoted Whether the quote ran; a pool already at its price bound, for one, cannot.
    /// @return legAmountIn The input the pool leg uses.
    /// @return legAmountOut The output of the pool leg.
    /// @return restAmountOut The output of the pool for the rest.
    function _quoteSwapOf(
        PoolKey calldata key,
        SwapParams calldata params,
        uint160 legSqrtPriceLimitX96,
        uint256 heldAmount
    )
        internal
        returns (bool quoted, uint256 legAmountIn, uint256 legAmountOut, uint256 restAmountOut)
    {
        try this.quoteSwap({
            key: key, params: params, legSqrtPriceLimitX96: legSqrtPriceLimitX96, heldAmount: heldAmount
        }) {}
        catch (bytes memory reason) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (reason.length == 100 && bytes4(reason) == JBUniswapV4Hook_SwapQuote.selector) {
                assembly ("memory-safe") {
                    legAmountIn := mload(add(reason, 36))
                    legAmountOut := mload(add(reason, 68))
                    restAmountOut := mload(add(reason, 100))
                }
                quoted = true;
            }
        }
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
            // Oracle timestamps are uint32 and wrap, as in Uniswap V3.
            // forge-lint: disable-next-line(unsafe-typecast)
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

        // Oracle timestamps are uint32 and wrap, as in Uniswap V3.
        // forge-lint: disable-next-line(unsafe-typecast)
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

    /// @notice Swaps from the pool while the pool beats a Juicebox rate, and routes the rest of the input through the
    /// project's terminal. For a buy the rate is the payer's issuance and the rest mints; a sell, whose rate is the
    /// marginal reclaim rate, goes to `_routeSell` with the limit.
    /// @dev The pool leg is this hook's own exact-input swap on the same pool, which skips this hook's callbacks
    /// (`Hooks.noSelfCall`). Its price limit is the rate limit: the price where the pool's marginal output after the LP
    /// and protocol fees equals the rate, rounded so the pool's marginal price never drops below it; the output floor
    /// on both legs covers V4's per-step rounding. The input the pool leg leaves mints through `_routeThroughJuicebox`.
    /// The returned delta consumes the whole input and delivers both legs, so the outer swap moves nothing, and this
    /// hook's pool-leg deltas and the mint leg's take and settle net against it.
    /// A caller whose own price limit is at or inside the fee-free price of the rate gets a plain V4 swap with no
    /// terminal leg. That keeps partial fills a caller asked for, and keeps the buyback hook's swaps (limited at a
    /// fee-free issuance rate at or above the payer's) plain, so a pay never mints through this hook from inside its
    /// own swap.
    /// @param key The pool key.
    /// @param params The swap parameters.
    /// @param projectId The ID of the project whose terminal routes the rest.
    /// @param amountIn The exact input amount.
    /// @param amountOutMin The caller's tagged minimum output, or 0.
    /// @param terminal The project's primary terminal for the swap's terminal-side token.
    /// @param isBuying Whether the rest pays the terminal (true) or cashes out (false).
    /// @param rateAmountOut The output for the whole input at the rate the pool leg is limited at. Zero means no
    /// usable Juicebox path, so the swap stays a V4 swap.
    /// @param floorAmountOut For a buy, the least output both legs together deliver, less rounding; for a sell, the
    /// preview of cashing out the whole input.
    /// @return delta The swap delta to return to the PoolManager (zero for a plain V4 swap).
    function _routeSplit(
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 projectId,
        uint256 amountIn,
        uint256 amountOutMin,
        IJBTerminal terminal,
        bool isBuying,
        uint256 rateAmountOut,
        uint256 floorAmountOut
    )
        internal
        returns (BeforeSwapDelta delta)
    {
        bool zeroForOne = params.zeroForOne;
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;

        // The issuance count less rounding: callers such as the buyback hook derive their price limit from an issuance
        // count that can round a few units under this one, and the terminal floors the mint leg's count.
        uint256 margin = rateAmountOut / 1_000_000 + 3;

        // The fee-free issuance price, rounded toward the caller's side so a limit derived from it counts as inside.
        uint256 sqrtPriceX96 = rateAmountOut <= margin || rateAmountOut > MAX_V4_DELTA || amountIn > MAX_V4_DELTA
            ? 0
            : zeroForOne
                ? _sqrtPriceX96Of({amount1: rateAmountOut - margin, amount0: amountIn, roundUp: false})
                : _sqrtPriceX96Of({amount1: amountIn, amount0: rateAmountOut - margin, roundUp: true});

        // Split only when the issuance price is inside V4's range and the caller's limit lies beyond it.
        if (
            sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
                || (zeroForOne ? params.sqrtPriceLimitX96 >= sqrtPriceX96 : params.sqrtPriceLimitX96 <= sqrtPriceX96)
        ) {
            // A plain V4 swap; `_afterSwap` enforces any tagged minimum on its output.
            // The calls before this event are views, which cannot reenter.
            // forge-lint: disable-next-item(reentrancy-events)
            emit RouteSelected({poolId: key.toId(), useJuicebox: false, expectedTokens: 0, caller: msg.sender});
            return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }

        // The issuance limit: the pool's marginal output after fees, (1 - fee) * price, equals the issuance rate.
        {
            uint256 feeKept = ProtocolFeeLibrary.PIPS_DENOMINATOR - _swapFeeOf({key: key, zeroForOne: zeroForOne});
            sqrtPriceX96 = zeroForOne
                ? _sqrtPriceX96Of({
                    amount1: rateAmountOut * ProtocolFeeLibrary.PIPS_DENOMINATOR,
                    amount0: amountIn * feeKept,
                    roundUp: true
                })
                : _sqrtPriceX96Of({
                    amount1: amountIn * feeKept,
                    amount0: rateAmountOut * ProtocolFeeLibrary.PIPS_DENOMINATOR,
                    roundUp: false
                });
        }

        // The pool leg runs only while the current price beats the limit. Fees move the limit from the fee-free price
        // checked above toward the current price, so a limit that passes this check is inside V4's range.
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (zeroForOne ? sqrtPriceX96 >= currentSqrtPriceX96 : sqrtPriceX96 <= currentSqrtPriceX96) sqrtPriceX96 = 0;

        if (!isBuying) {
            return _routeSell({
                key: key,
                params: params,
                projectId: projectId,
                amountIn: amountIn,
                amountOutMin: amountOutMin,
                terminal: terminal,
                // forge-lint: disable-next-line(unsafe-typecast)
                legSqrtPriceLimitX96: uint160(sqrtPriceX96),
                reclaimAmountOut: floorAmountOut
            });
        }

        uint256 poolAmountIn;
        uint256 amountOut;
        if (sqrtPriceX96 != 0) {
            (poolAmountIn, amountOut) = _swapPool({
                key: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                // forge-lint: disable-next-line(unsafe-typecast)
                sqrtPriceLimitX96: uint160(sqrtPriceX96)
            });
        }

        // The input the pool leg leaves mints through the terminal.
        if (poolAmountIn < amountIn) {
            amountOut += _routeThroughJuicebox({
                projectId: projectId,
                inputCurrency: inputCurrency,
                outputCurrency: zeroForOne ? key.currency1 : key.currency0,
                amountIn: amountIn - poolAmountIn,
                isBuying: true,
                terminal: terminal,
                amountOutMin: 0
            });
        }

        // Both legs together deliver at least minting the whole input, less the rounding margin, and the caller's
        // tagged minimum. This also catches V4's per-step rounding on thin liquidity, where fees can eat a pool fill.
        if (floorAmountOut > margin && amountOutMin < floorAmountOut - margin) amountOutMin = floorAmountOut - margin;
        if (amountOut < amountOutMin) {
            revert JBUniswapV4Hook_InsufficientOutput({amount: amountOut, minimum: amountOutMin});
        }

        // The pool leg skips this hook's callbacks and the mint leg runs under `_routing`, so neither can reenter.
        // forge-lint: disable-next-item(reentrancy-events)
        emit RouteSelected({
            poolId: key.toId(), useJuicebox: poolAmountIn < amountIn, expectedTokens: amountOut, caller: msg.sender
        });

        return _createSwapDelta({amountIn: amountIn, amountOut: amountOut});
    }

    /// @notice Sells whichever way delivers most, each quoted exactly: everything in the pool, everything cashed out,
    /// or a split.
    /// @dev The split sells in the pool down to `legSqrtPriceLimitX96`, cashes out what the leg leaves up to what the
    /// PoolManager holds of the token (callers settle their input after the swap), and leaves any rest to the outer
    /// swap, where `_afterSwap` checks a tagged minimum against all of it. Cashing everything out needs the PoolManager
    /// to hold the whole input. Cash-outs are quoted by the terminal's preview, which the terminal enforces as the
    /// leg's minimum, and run first, on the state the preview read. Pool parts are quoted by `quoteSwap` and then run
    /// the
    /// same swaps; the cash-out between cannot swap this pool. Ties go to the pool alone, then to cashing everything
    /// out.
    /// @param key The pool key.
    /// @param params The swap parameters.
    /// @param projectId The ID of the project whose tokens are sold.
    /// @param amountIn The exact input amount.
    /// @param amountOutMin The caller's tagged minimum output, or 0.
    /// @param terminal The project's primary terminal for the output token.
    /// @param legSqrtPriceLimitX96 The split's pool-leg price limit, or zero when the price is already past it.
    /// @param reclaimAmountOut The preview of cashing out the whole input.
    /// @return delta The swap delta to return to the PoolManager (zero for a plain V4 swap).
    function _routeSell(
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 projectId,
        uint256 amountIn,
        uint256 amountOutMin,
        IJBTerminal terminal,
        uint160 legSqrtPriceLimitX96,
        uint256 reclaimAmountOut
    )
        internal
        returns (BeforeSwapDelta delta)
    {
        bool zeroForOne = params.zeroForOne;
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 heldAmount = inputCurrency.balanceOf(address(poolManager));
        if (amountIn > heldAmount) reclaimAmountOut = 0;

        // Everything in the pool, as a plain V4 swap would sell it.
        (,,, uint256 poolAmountOut) = _quoteSwapOf({key: key, params: params, legSqrtPriceLimitX96: 0, heldAmount: 0});

        // The split.
        (bool quoted, uint256 legAmountIn, uint256 legAmountOut, uint256 restAmountOut) =
            _quoteSwapOf({key: key, params: params, legSqrtPriceLimitX96: legSqrtPriceLimitX96, heldAmount: heldAmount});
        uint256 cashOutCount = amountIn - legAmountIn;
        if (cashOutCount > heldAmount) cashOutCount = heldAmount;
        // A cash-out of the whole input reuses its preview.
        uint256 cashOutAmountOut = cashOutCount == 0
            ? 0
            : cashOutCount == amountIn
                ? reclaimAmountOut
                : calculateExpectedOutputFromSelling({
                    projectId: projectId,
                    tokenAmountIn: cashOutCount,
                    outputToken: Currency.unwrap(outputCurrency),
                    terminal: terminal
                });
        // A split whose cash-out quotes nothing, or whose output V4's deltas cannot carry, is not one.
        uint256 splitAmountOut = quoted && (cashOutCount == 0 || cashOutAmountOut != 0)
            ? legAmountOut + cashOutAmountOut + restAmountOut
            : 0;
        if (splitAmountOut > MAX_V4_DELTA) splitAmountOut = 0;

        if (reclaimAmountOut >= splitAmountOut) {
            (legAmountIn, cashOutCount, cashOutAmountOut, splitAmountOut) =
            (0, amountIn, reclaimAmountOut, reclaimAmountOut);
        }

        if (splitAmountOut <= poolAmountOut) {
            // The calls before this event revert or are views, so they cannot reenter.
            // forge-lint: disable-next-item(reentrancy-events)
            emit RouteSelected({
                poolId: key.toId(), useJuicebox: false, expectedTokens: poolAmountOut, caller: msg.sender
            });
            return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }

        // The cash-out runs first, on the state its preview read; it cannot swap this pool (`_routing`).
        uint256 amountOut;
        if (cashOutCount != 0) {
            amountOut = _routeThroughJuicebox({
                projectId: projectId,
                inputCurrency: inputCurrency,
                outputCurrency: outputCurrency,
                amountIn: cashOutCount,
                isBuying: false,
                terminal: terminal,
                amountOutMin: cashOutAmountOut
            });
        }
        if (legAmountIn != 0) {
            (legAmountIn, legAmountOut) = _swapPool({
                key: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn - cashOutCount,
                sqrtPriceLimitX96: legSqrtPriceLimitX96
            });
            amountOut += legAmountOut;
        }

        if (legAmountIn + cashOutCount < amountIn) {
            // The outer swap sells the rest in the pool, and `_afterSwap` checks a tagged minimum against all of it.
            _splitAmountOut = amountOut;
        } else if (amountOut < amountOutMin) {
            revert JBUniswapV4Hook_InsufficientOutput({amount: amountOut, minimum: amountOutMin});
        }

        // The pool leg skips this hook's callbacks and the cash-out leg runs under `_routing`, so neither can reenter.
        // forge-lint: disable-next-item(reentrancy-events)
        emit RouteSelected({poolId: key.toId(), useJuicebox: true, expectedTokens: amountOut, caller: msg.sender});

        return _createSwapDelta({amountIn: legAmountIn + cashOutCount, amountOut: amountOut});
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
            // The terminal is the project's primary terminal from JBDirectory, not caller input.
            // forge-lint: disable-next-item(arbitrary-send-eth)
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
            // The hook measures the reclaimed balance itself below.
            // forge-lint: disable-next-item(unused-return)
            IJBMultiTerminal(address(terminal))
                .cashOutTokensOf({
                    holder: address(this), // holder (hook owns the JB tokens)
                    projectId: projectId,
                    cashOutCount: amountIn, // Amount of JB tokens to cash out
                    tokenToReclaim: normalizedTokenOut, // Native ETH → JB_NATIVE_TOKEN
                    minTokensReclaimed: amountOutMin, // Minimum tokens required (enforced by JB terminal)
                    beneficiary: payable(address(this)), // beneficiary (hook)
                    metadata: _cashOutMetadataOf(projectId)
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

    /// @notice The V4 sqrt price, as a Q64.96, of a price of `amount1` token1 per `amount0` token0.
    /// @dev Prices of 2^128 or more lie past every V4 pool's range and return `type(uint256).max`. Prices of 2^63 or
    /// more use a Q128 ratio so the intermediate fits 256 bits.
    /// @param amount1 The token1 side of the price.
    /// @param amount0 The token0 side of the price.
    /// @param roundUp Whether to round the result up (otherwise down).
    /// @return sqrtPriceX96 The sqrt price.
    function _sqrtPriceX96Of(
        uint256 amount1,
        uint256 amount0,
        bool roundUp
    )
        internal
        pure
        returns (uint256 sqrtPriceX96)
    {
        if (amount0 == 0 || amount1 / amount0 >= 1 << 128) return type(uint256).max;

        // Q192 below 2^63 keeps room to round up; above it, a Q128 ratio's square root is shifted into Q96.
        uint256 shift = amount1 / amount0 < 1 << 63 ? 192 : 128;
        uint256 ratio = roundUp
            ? FullMath.mulDivRoundingUp({a: amount1, b: 2 ** shift, denominator: amount0})
            : FullMath.mulDiv({a: amount1, b: 2 ** shift, denominator: amount0});
        sqrtPriceX96 =
            Math.sqrt({a: ratio, rounding: roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor}) << (192 - shift) / 2;
    }

    /// @notice Runs an exact-input swap of this pool from this hook, which skips this hook's callbacks.
    /// @param key The pool key.
    /// @param zeroForOne The swap direction.
    /// @param amountIn The exact input amount.
    /// @param sqrtPriceLimitX96 The swap's price limit.
    /// @return amountInUsed The input the swap used.
    /// @return amountOut The swap's output.
    function _swapPool(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    )
        internal
        returns (uint256 amountInUsed, uint256 amountOut)
    {
        BalanceDelta delta = poolManager.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData: bytes("")
        });

        // Exact input: the input leg is a debt of this hook (negative), the output leg a credit (positive).
        // forge-lint: disable-next-line(unsafe-typecast)
        amountInUsed = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
    }

    /// @notice The combined fee, in pips, that a swap in `zeroForOne`'s direction pays on `key`'s pool: the LP fee
    /// composed with the directional protocol fee, as Uniswap V4 charges it on the input.
    /// @dev Static pools use `key.fee`; dynamic-fee pools use the LP fee stored in slot0.
    /// @param key The pool key.
    /// @param zeroForOne Whether the swap sells token0 for token1.
    /// @return swapFee The combined swap fee in pips.
    function _swapFeeOf(PoolKey memory key, bool zeroForOne) internal view returns (uint24 swapFee) {
        // Read protocol fee from slot0 (directional: lower 12 bits = zeroForOne, upper 12 bits = oneForZero)
        // slot0 holds the LP fee V4 swaps with: `key.fee` for static pools, the hook-set fee for dynamic ones.
        (,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(PoolIdLibrary.toId(key));

        // Compose the directional protocol fee with the LP fee (a zero protocol fee leaves the LP fee).
        swapFee = (zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee()).calculateSwapFee(lpFee);
    }
}
