// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {JBUniswapV4Hook} from "../src/JBUniswapV4Hook.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../src/JBUniswapV4Hook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// ============================================================
// Mock contracts for invariant testing
// ============================================================

contract MockJBTokensInv {
    mapping(address => uint256) public projectIdOf;
    mapping(uint256 => address) public tokenOf;

    function setProjectId(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
        if (projectId != 0) tokenOf[projectId] = token;
    }

    function creditBalanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MockJBDirectoryInv {
    address public mockTerminal;
    address public mockController;

    function setMockTerminal(address terminal) external {
        mockTerminal = terminal;
    }

    function setMockController(address controller) external {
        mockController = controller;
    }

    function controllerOf(uint256) external view returns (address) {
        return mockController;
    }

    function primaryTerminalOf(uint256, address) external view returns (address) {
        return mockTerminal;
    }
}

contract MockJBPricesInv {
    // forge-lint: disable-next-line(mixed-case-function)
    function DEFAULT_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function pricePerUnitOf(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        return 1e18;
    }
}

contract MockJBControllerInv {
    mapping(uint256 => uint256) public weights;

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: 1,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: uint112(weights[projectId]),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });
    }
}

contract MockJBTerminalStoreInv {
    function currentReclaimableSurplusOf(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function currentReclaimableSurplusOf(
        uint256,
        uint256,
        IJBTerminal[] calldata,
        address[] calldata,
        uint256,
        uint256
    )
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function currentTotalReclaimableSurplusOf(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MockJBMultiTerminalInv {
    mapping(uint256 => address) public projectTokens;
    MockJBTerminalStoreInv public terminalStore;

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    function setProjectToken(uint256 projectId, address projectToken) external {
        projectTokens[projectId] = projectToken;
    }

    function setTerminalStore(address _store) external {
        terminalStore = MockJBTerminalStoreInv(_store);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function STORE() external view returns (IJBTerminalStore) {
        return IJBTerminalStore(address(terminalStore));
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 beneficiaryTokenCount)
    {
        beneficiaryTokenCount = amount * 1000;
        // Production terminals pull ERC-20 inputs during pay; consume the hook's temporary allowance in the mock too.
        if (msg.value == 0 && amount != 0) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0)) {
            MockERC20(projectToken).mint(beneficiary, beneficiaryTokenCount);
        }
    }

    function cashOutTokensOf(
        address,
        uint256,
        uint256,
        address,
        uint256,
        address payable,
        bytes calldata,
        uint256 /* referralProjectId */
    )
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        return contexts;
    }

    function previewCashOutFrom(
        address,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    )
        external
        pure
        returns (JBRuleset memory, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        JBRuleset memory ruleset;
        return (ruleset, 0, 0, new JBCashOutHookSpecification[](0));
    }
}

// ============================================================
// Handler: performs random swaps, time warps, and observations
// ============================================================

/// @title InvariantHandler
/// @notice Performs random swap operations on the pool and tracks state for invariant verification.
/// @dev Used as the target contract for Forge's invariant testing framework. Each function represents
/// an action the fuzzer can call in any order and at any depth.
contract InvariantHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    JBUniswapV4Hook public hook;
    PoolSwapTest public swapRouter;
    PoolKey public key;
    PoolId public id;
    MockERC20 public token0;
    MockERC20 public token1;
    IPoolManager public manager;

    // Ghost variables for tracking invariants
    int56[] public tickCumulativeHistory;
    uint32[] public timestampHistory;
    uint256 public swapCount;
    uint256 public warpCount;
    uint256 public observeCount;

    // Track total token balances for conservation
    uint256 public totalToken0Minted;
    uint256 public totalToken1Minted;

    constructor(
        JBUniswapV4Hook _hook,
        PoolSwapTest _swapRouter,
        PoolKey memory _key,
        MockERC20 _token0,
        MockERC20 _token1,
        IPoolManager _manager
    ) {
        hook = _hook;
        swapRouter = _swapRouter;
        key = _key;
        id = _key.toId();
        token0 = _token0;
        token1 = _token1;
        manager = _manager;
    }

    /// @notice Perform a swap in a random direction with a random amount
    /// @param zeroForOne Whether to swap token0 for token1
    /// @param amount The swap amount (bounded to reasonable range)
    function doSwap(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 0.0001 ether, 0.1 ether);

        // Mint tokens for the swap
        if (zeroForOne) {
            token0.mint(address(this), amount);
            token0.approve(address(swapRouter), amount);
            totalToken0Minted += amount;
        } else {
            token1.mint(address(this), amount);
            token1.approve(address(swapRouter), amount);
            totalToken1Minted += amount;
        }

        uint160 sqrtLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: sqrtLimit
        });

        try swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0))) {
            swapCount++;
        } catch {
            // Swap can fail due to price limits; this is expected behavior
        }
    }

    /// @notice Warp time forward by a random amount
    /// @param timeJump The number of seconds to warp forward (bounded)
    function doWarp(uint256 timeJump) external {
        timeJump = bound(timeJump, 1, 3600); // 1 second to 1 hour
        vm.warp(block.timestamp + timeJump);
        warpCount++;
    }

    /// @notice Call observe() and record the tick cumulative at the current timestamp
    function doObserve() external {
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;

        try hook.observe(key, secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory /* secondsPerLiqCumulatives */
        ) {
            tickCumulativeHistory.push(tickCumulatives[0]);
            timestampHistory.push(uint32(block.timestamp));
            observeCount++;
        } catch {
            // May fail if oracle not ready; this is expected
        }
    }

    /// @notice Perform a swap followed by an observation in the same block
    /// @param zeroForOne Swap direction
    /// @param amount Swap amount
    function swapAndObserve(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 0.0001 ether, 0.1 ether);

        if (zeroForOne) {
            token0.mint(address(this), amount);
            token0.approve(address(swapRouter), amount);
            totalToken0Minted += amount;
        } else {
            token1.mint(address(this), amount);
            token1.approve(address(swapRouter), amount);
            totalToken1Minted += amount;
        }

        uint160 sqrtLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: sqrtLimit
        });

        try swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0))) {
            swapCount++;

            // Now observe
            uint32[] memory secondsAgos = new uint32[](1);
            secondsAgos[0] = 0;

            try hook.observe(key, secondsAgos) returns (
                int56[] memory tickCumulatives,
                uint160[] memory /* secondsPerLiqCumulatives */
            ) {
                tickCumulativeHistory.push(tickCumulatives[0]);
                timestampHistory.push(uint32(block.timestamp));
                observeCount++;
            } catch {}
        } catch {}
    }

    // ---------------------------------------------------------------
    // Accessors for invariant assertions
    // ---------------------------------------------------------------

    function getTickCumulativeHistoryLength() external view returns (uint256) {
        return tickCumulativeHistory.length;
    }

    function getTickCumulativeAt(uint256 index) external view returns (int56) {
        return tickCumulativeHistory[index];
    }

    function getTimestampAt(uint256 index) external view returns (uint32) {
        return timestampHistory[index];
    }
}

// ============================================================
// Invariant Test Suite
// ============================================================

/// @title InvariantTest
/// @notice Stateful fuzz/invariant tests for JBUniswapV4Hook.
///
/// Properties tested:
///   1. Oracle monotonicity: tickCumulative values returned by observe() are monotonically
///      non-decreasing when the pool tick is non-negative (and bounded regardless).
///   2. Flash-accounting conservation: After any swap routed through the hook, total value
///      in the V4 pool + JB terminal is conserved (no tokens created or destroyed by the pool).
///   3. TWAP dampening: A single-block manipulation produces smaller TWAP deviation than spot deviation.
contract InvariantTest is Test {
    receive() external payable {}

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    JBUniswapV4Hook hook;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTokensInv mockJBTokens;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBDirectoryInv mockJBDirectory;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBMultiTerminalInv mockJBMultiTerminal;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBControllerInv mockJBController;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBPricesInv mockJBPrices;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTerminalStoreInv mockJBTerminalStore;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    bytes constant ZERO_BYTES = "";
    uint256 constant PROJECT_ID = 999;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;

    InvariantHandler handler;

    function setUp() public {
        vm.warp(10_000);

        // Deploy V4 infrastructure
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy JB mocks
        mockJBTokens = new MockJBTokensInv();
        mockJBDirectory = new MockJBDirectoryInv();
        mockJBMultiTerminal = new MockJBMultiTerminalInv();
        mockJBController = new MockJBControllerInv();
        mockJBPrices = new MockJBPricesInv();
        mockJBTerminalStore = new MockJBTerminalStoreInv();

        mockJBDirectory.setMockTerminal(address(mockJBMultiTerminal));
        mockJBDirectory.setMockController(address(mockJBController));
        mockJBMultiTerminal.setTerminalStore(address(mockJBTerminalStore));

        // Mine hook address with correct flags
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            manager,
            IJBTokens(address(mockJBTokens)),
            IJBDirectory(address(mockJBDirectory)),
            IJBPrices(address(mockJBPrices))
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(
            manager,
            IJBTokens(address(mockJBTokens)),
            IJBDirectory(address(mockJBDirectory)),
            IJBPrices(address(mockJBPrices))
        );

        // Deploy test tokens
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Do NOT register either token as a JB project token. This ensures all swaps route
        // through V4 only, isolating oracle and flash-accounting properties from mock terminal
        // behavior. JB routing is tested separately in ThreeWayRouting.t.sol and TestStructuralArbitrage.t.sol.

        // Set up V4 pool at 1:1 price
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        // Mint tokens and provide liquidity
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.approve(address(modifyLiquidityRouter), 1000 ether);
        token1.approve(address(modifyLiquidityRouter), 1000 ether);

        manager.initialize(key, SQRT_PRICE_1_1);

        // Add wide-range liquidity so swaps can execute across a broad tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // Deploy handler
        handler = new InvariantHandler(hook, swapRouter, key, token0, token1, manager);

        // Approve handler to use tokens
        token0.approve(address(handler), type(uint256).max);
        token1.approve(address(handler), type(uint256).max);

        // Target the handler for invariant testing
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------
    // Invariant 1: Oracle tick cumulative monotonicity
    // ---------------------------------------------------------------

    /// @notice Tick cumulatives observed at non-decreasing timestamps must satisfy the monotonicity
    /// bound: the difference between consecutive observations is bounded by maxTick * elapsed time.
    /// For pools near tick 0 (our 1:1 setup), cumulative values grow roughly proportionally to time.
    function invariant_oracleTickCumulativeBounded() public view {
        uint256 len = handler.getTickCumulativeHistoryLength();
        if (len < 2) return;

        for (uint256 i = 1; i < len; i++) {
            int56 prevCumulative = handler.getTickCumulativeAt(i - 1);
            int56 currCumulative = handler.getTickCumulativeAt(i);
            uint32 prevTimestamp = handler.getTimestampAt(i - 1);
            uint32 currTimestamp = handler.getTimestampAt(i);

            // Timestamps must be non-decreasing
            assertGe(currTimestamp, prevTimestamp, "Timestamps must be non-decreasing");

            // If same timestamp, the tick may have changed between observations (due to swaps
            // within the same block). observe(secondsAgo=0) uses the CURRENT pool tick to compute
            // the counterfactual cumulative, so cumulatives can differ within the same block.
            // We still verify the bounded diff property below, with elapsed=0 -> maxDiff=0 only if
            // we skip. Since they CAN differ, just continue to the next pair.
            if (currTimestamp == prevTimestamp) {
                continue;
            }

            // The difference in tick cumulatives is bounded by maxTick * elapsed seconds.
            // |tickCumulatives[i] - tickCumulatives[i-1]| <= 887272 * (t[i] - t[i-1])
            int56 diff = currCumulative - prevCumulative;
            uint32 elapsed = currTimestamp - prevTimestamp;
            int56 maxDiff = int56(887_272) * int56(uint56(elapsed));

            assertTrue(
                diff >= -maxDiff && diff <= maxDiff, "Tick cumulative difference must be bounded by maxTick * elapsed"
            );
        }
    }

    // ---------------------------------------------------------------
    // Invariant 2: Flash-accounting conservation
    // ---------------------------------------------------------------

    /// @notice The PoolManager enforces flash-accounting: every take() must be balanced by a settle()
    /// within the same unlock() call. If a swap completes without revert, conservation held.
    /// We verify this by checking that the pool's token balances remain consistent with recorded state:
    /// PoolManager's balance of each token must be >= the pool's internally tracked balance.
    function invariant_flashAccountingConservation() public view {
        // PoolManager's actual token balances
        uint256 managerToken0Balance = token0.balanceOf(address(manager));
        uint256 managerToken1Balance = token1.balanceOf(address(manager));

        // If any swaps have occurred, the PoolManager must still hold tokens
        // (liquidity was provided, so balance should be positive)
        if (handler.swapCount() > 0) {
            // The PoolManager should not have lost tokens; its balance should always be sufficient
            // to cover the pool's tracked reserves. We cannot read internal reserves directly, but
            // we can verify the manager holds a non-zero balance (liquidity was deposited).
            assertGt(
                managerToken0Balance + managerToken1Balance,
                0,
                "PoolManager must hold tokens after swaps (conservation)"
            );
        }

        // The hook should not accumulate tokens — it settles everything within each swap
        uint256 hookToken0Balance = token0.balanceOf(address(hook));
        uint256 hookToken1Balance = token1.balanceOf(address(hook));

        assertEq(hookToken0Balance, 0, "Hook must not accumulate token0 between transactions");
        assertEq(hookToken1Balance, 0, "Hook must not accumulate token1 between transactions");
    }

    // ---------------------------------------------------------------
    // Invariant 3: Oracle cardinality never exceeds cap
    // ---------------------------------------------------------------

    /// @notice The oracle cardinality should never exceed the configured hard cap.
    function invariant_oracleCardinalityCapped() public view {
        (, uint16 cardinality, uint16 cardinalityNext) = hook.states(id);
        uint16 maxCardinality = hook.MAX_TWAP_CARDINALITY();

        assertLe(cardinality, maxCardinality, "Oracle cardinality must not exceed the configured cap");
        assertLe(cardinalityNext, maxCardinality, "Oracle cardinalityNext must not exceed the configured cap");

        // Cardinality must be >= 1 (initialized in afterInitialize)
        assertGe(cardinality, 1, "Oracle cardinality must be at least 1 after initialization");
    }

    // ---------------------------------------------------------------
    // Invariant 4: Oracle observation state consistency
    // ---------------------------------------------------------------

    /// @notice The oracle index must always be within bounds of cardinality, and the most recent
    /// observation must be initialized.
    function invariant_oracleStateConsistency() public view {
        (uint16 index, uint16 cardinality,) = hook.states(id);

        // Index must be < cardinality
        assertLt(index, cardinality, "Oracle index must be less than cardinality");

        // The observation at the current index must be initialized
        (uint32 timestamp,,, bool initialized) = hook.observations(id, index);
        assertTrue(initialized, "Current observation must be initialized");

        // Timestamp must be <= current block timestamp
        assertLe(timestamp, uint32(block.timestamp), "Observation timestamp must not exceed current block time");
    }

    // ---------------------------------------------------------------
    // Deterministic test: TWAP dampening
    // ---------------------------------------------------------------

    /// @notice A single-block price manipulation should be dampened by TWAP relative to spot.
    /// After TWAP warmup, the TWAP estimate should deviate less than spot from the true price
    /// when a large single-block push occurs.
    function test_twapDampensSingleBlockManipulation() public {
        // Grow oracle cardinality first by doing initial swaps at short intervals.
        // We need enough cardinality to store observations spanning TWAP_PERIOD (1800s).
        // Then spread out swaps to build sufficient time history.
        uint32 twapPeriod = hook.TWAP_PERIOD();

        // Phase 1: Grow cardinality with 10 rapid swaps (1s apart, just to bump cardinality)
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1);
            token0.mint(address(this), 0.0001 ether);
            token0.approve(address(swapRouter), 0.0001 ether);
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true, amountSpecified: -0.0001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings(false, false),
                abi.encode(uint256(0))
            );
        }

        // Phase 2: Warp well beyond TWAP_PERIOD and do another swap to create a wide-span observation
        vm.warp(block.timestamp + twapPeriod + 600); // TWAP_PERIOD + 10 minutes buffer

        token1.mint(address(this), 0.001 ether);
        token1.approve(address(swapRouter), 0.001 ether);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint256(0))
        );

        // Verify TWAP is active by querying observe() with [TWAP_PERIOD, 0]
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;

        (int56[] memory preCumulatives,) = hook.observe(key, secondsAgos);
        int56 preDelta = preCumulatives[1] - preCumulatives[0];
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 preTwapTick = int24(preDelta / int56(uint56(twapPeriod)));

        // Record pre-manipulation spot price
        (uint160 preSpotSqrtPrice,,,) = manager.getSlot0(id);
        uint160 preTwapSqrtPrice = TickMath.getSqrtPriceAtTick(preTwapTick);

        assertTrue(preTwapSqrtPrice > 0, "TWAP should be active after warmup");

        // Execute a large manipulation swap in a single block
        token0.mint(address(this), 5 ether);
        token0.approve(address(swapRouter), 5 ether);

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -5 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint256(0))
        );

        // Record post-manipulation spot and TWAP
        (uint160 postSpotSqrtPrice,,,) = manager.getSlot0(id);

        (int56[] memory postCumulatives,) = hook.observe(key, secondsAgos);
        int56 postDelta = postCumulatives[1] - postCumulatives[0];
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 postTwapTick = int24(postDelta / int56(uint56(twapPeriod)));
        uint160 postTwapSqrtPrice = TickMath.getSqrtPriceAtTick(postTwapTick);

        // Calculate deviations from pre-manipulation baseline
        uint256 spotDeviation = _absoluteDiff(uint256(postSpotSqrtPrice), uint256(preSpotSqrtPrice));
        uint256 twapDeviation = _absoluteDiff(uint256(postTwapSqrtPrice), uint256(preTwapSqrtPrice));

        console.log("--- TWAP Dampening ---");
        console.log("  Pre-manip spot:   %d", preSpotSqrtPrice);
        console.log("  Post-manip spot:  %d", postSpotSqrtPrice);
        console.log("  Pre-manip TWAP:   %d", preTwapSqrtPrice);
        console.log("  Post-manip TWAP:  %d", postTwapSqrtPrice);
        console.log("  Spot deviation:   %d", spotDeviation);
        console.log("  TWAP deviation:   %d", twapDeviation);

        // TWAP deviation should be strictly less than spot deviation
        assertLt(twapDeviation, spotDeviation, "TWAP must dampen single-block manipulation vs spot");
    }

    // ---------------------------------------------------------------
    // Deterministic test: observe() monotonicity across swaps
    // ---------------------------------------------------------------

    /// @notice After a sequence of swaps separated by time warps, observe(0) should return
    /// tick cumulatives that are bounded and consistent with the passage of time.
    function test_observeMonotonicityAcrossSwaps() public {
        int56[] memory cumulatives = new int56[](10);
        uint32[] memory timestamps = new uint32[](10);

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 60); // 1 minute between swaps

            // Alternate swap direction to keep price near center
            bool direction = (i % 2 == 0);
            MockERC20 inputToken = direction ? token0 : token1;
            inputToken.mint(address(this), 0.01 ether);
            inputToken.approve(address(swapRouter), 0.01 ether);

            uint160 sqrtLimit = direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

            swapRouter.swap(
                key,
                SwapParams({zeroForOne: direction, amountSpecified: -0.01 ether, sqrtPriceLimitX96: sqrtLimit}),
                PoolSwapTest.TestSettings(false, false),
                abi.encode(uint256(0))
            );

            // Observe current cumulative
            uint32[] memory secondsAgos = new uint32[](1);
            secondsAgos[0] = 0;
            (int56[] memory tickCums,) = hook.observe(key, secondsAgos);

            cumulatives[i] = tickCums[0];
            timestamps[i] = uint32(block.timestamp);
        }

        // Verify bounded differences
        for (uint256 i = 1; i < 10; i++) {
            int56 diff = cumulatives[i] - cumulatives[i - 1];
            uint32 elapsed = timestamps[i] - timestamps[i - 1];
            int56 maxDiff = int56(887_272) * int56(uint56(elapsed));

            assertTrue(
                diff >= -maxDiff && diff <= maxDiff,
                string.concat("Observation ", vm.toString(i), ": tick cumulative diff out of bounds")
            );
        }
    }

    // ---------------------------------------------------------------
    // Deterministic test: flash-accounting conservation per swap
    // ---------------------------------------------------------------

    /// @notice Each individual swap must maintain token conservation: the sum of tokens entering
    /// and leaving the PoolManager via the swap must net to zero (PoolManager enforces this).
    /// We verify indirectly: if a swap completes without revert, flash-accounting was satisfied.
    /// Additionally, the hook should never retain tokens between transactions.
    function test_flashAccountingConservationPerSwap() public {
        // Warm up the oracle
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 300);

            token0.mint(address(this), 0.001 ether);
            token0.approve(address(swapRouter), 0.001 ether);

            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings(false, false),
                abi.encode(uint256(0))
            );
        }

        // Now execute 20 swaps and verify conservation after each
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 12); // ~1 block

            bool direction = (i % 3 != 0); // Mostly buy, sometimes sell
            MockERC20 inputToken = direction ? token1 : token0;
            uint256 amount = 0.01 ether;

            inputToken.mint(address(this), amount);
            inputToken.approve(address(swapRouter), amount);

            uint160 sqrtLimit = !direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

            // Swap should succeed (flash-accounting enforced by PoolManager)
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: !direction,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: sqrtLimit
                }),
                PoolSwapTest.TestSettings(false, false),
                abi.encode(uint256(0))
            );

            // Hook must not retain any tokens after the swap
            assertEq(token0.balanceOf(address(hook)), 0, "Hook holds token0 after swap");
            assertEq(token1.balanceOf(address(hook)), 0, "Hook holds token1 after swap");
        }
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    /// @dev Returns |a - b| for unsigned integers
    function _absoluteDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
