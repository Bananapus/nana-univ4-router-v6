// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
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
import {Oracle} from "../src/libraries/Oracle.sol";
import {MockERC20} from "./mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "./utils/JuiceboxSwapRouter.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../src/JBUniswapV4Hook.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// ============================================================
// Mock contracts (copied from OracleDeepTest.t.sol since
// Forge compiles test files independently)
// ============================================================

contract MockJBTokens_Observe {
    mapping(address => uint256) public projectIdOf;
    mapping(uint256 => address) public tokenOf;

    function setProjectId(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
        if (projectId != 0) tokenOf[projectId] = token;
    }
}

contract MockJBDirectory_Observe {
    address public mockTerminal;
    address public mockController;

    function setMockTerminal(address terminal) external {
        mockTerminal = terminal;
    }

    function setMockController(address controller) external {
        mockController = controller;
    }

    function controllerOf(
        uint256 /* projectId */
    )
        external
        view
        returns (address)
    {
        return mockController;
    }

    function primaryTerminalOf(
        uint256,
        /* projectId */
        address /* token */
    )
        external
        view
        returns (address)
    {
        return mockTerminal;
    }
}

contract MockJBPrices_Observe {
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public prices;

    // forge-lint: disable-next-line(mixed-case-function)
    function DEFAULT_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function setPricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 price
    )
        external
    {
        prices[projectId][pricingCurrency][unitCurrency] = price;
    }

    function pricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 /* decimals */
    )
        external
        view
        returns (uint256)
    {
        uint256 price = prices[projectId][pricingCurrency][unitCurrency];
        return price > 0 ? price : 1e18;
    }
}

contract MockJBTerminalStore_Observe {
    mapping(uint256 => mapping(uint256 => uint256)) public surplusPerToken;

    function setSurplus(uint256 projectId, address token, uint256 surplusAmount) external {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currency = uint32(uint160(token));
        surplusPerToken[projectId][currency] = surplusAmount;
    }

    function currentReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        uint256 currency,
        uint256 /* decimals */
    )
        external
        view
        returns (uint256)
    {
        uint256 surplusPerTokenValue = surplusPerToken[projectId][currency];
        if (surplusPerTokenValue == 0) return 0;
        return (surplusPerTokenValue * cashOutCount) / 1e18;
    }

    function currentTotalReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        uint256, /* decimals */
        uint256 currency
    )
        external
        view
        returns (uint256)
    {
        uint256 surplusPerTokenValue = surplusPerToken[projectId][currency];
        if (surplusPerTokenValue == 0) return 0;
        return (surplusPerTokenValue * cashOutCount) / 1e18;
    }
}

contract MockJBMultiTerminal_Observe {
    uint256 public lastProjectId;
    address public lastToken;
    uint256 public lastAmount;
    address public lastBeneficiary;
    mapping(uint256 => address) public projectTokens;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTerminalStore_Observe public TERMINAL_STORE;
    uint256 public overridePayReturnAmount;
    bool public useOverridePayReturn;

    /// @notice JB protocol fee (2.5% = 25 out of MAX_FEE 1000).
    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    function setProjectToken(uint256 projectId, address projectToken) external {
        projectTokens[projectId] = projectToken;
    }

    function setTerminalStore(address terminalStore) external {
        TERMINAL_STORE = MockJBTerminalStore_Observe(terminalStore);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function STORE() external view returns (IJBTerminalStore) {
        return IJBTerminalStore(address(TERMINAL_STORE));
    }

    function setPayReturnAmount(uint256 amount) external {
        overridePayReturnAmount = amount;
        useOverridePayReturn = true;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 beneficiaryTokenCount)
    {
        lastProjectId = projectId;
        lastToken = token;
        lastAmount = amount;
        lastBeneficiary = beneficiary;

        if (useOverridePayReturn) {
            beneficiaryTokenCount = overridePayReturnAmount;
        } else {
            beneficiaryTokenCount = amount * 1000;
        }

        require(beneficiaryTokenCount >= minReturnedTokens, "Insufficient tokens returned");

        // Production terminals pull ERC-20 inputs during pay; consume the hook's temporary allowance in the mock too.
        if (msg.value == 0 && amount != 0) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0)) {
            MockERC20(projectToken).mint(beneficiary, beneficiaryTokenCount);
        }

        return beneficiaryTokenCount;
    }

    function cashOutTokensOf(
        address,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata,
        uint256 /* referralProjectId */
    )
        external
        returns (uint256)
    {
        lastProjectId = projectId;
        lastToken = tokenToReclaim;
        lastAmount = cashOutCount;
        lastBeneficiary = beneficiary;

        uint256 outputAmount;
        uint256 surplusAmount =
        // forge-lint: disable-next-line(unsafe-typecast)
        TERMINAL_STORE.currentReclaimableSurplusOf(projectId, 1 ether, uint32(uint160(tokenToReclaim)), 18);
        outputAmount = (surplusAmount * cashOutCount) / 1e18;

        require(outputAmount >= minTokensReclaimed, "Insufficient tokens reclaimed");

        if (outputAmount > 0) {
            MockERC20(tokenToReclaim).mint(beneficiary, outputAmount);
        }

        return outputAmount;
    }

    function previewCashOutFrom(
        address,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address payable,
        bytes calldata
    )
        external
        view
        returns (JBRuleset memory, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currency = uint32(uint160(tokenToReclaim));
        uint256 surplusPerTokenValue = TERMINAL_STORE.surplusPerToken(projectId, currency);
        uint256 reclaimAmount = surplusPerTokenValue == 0 ? 0 : (surplusPerTokenValue * cashOutCount) / 1e18;
        JBRuleset memory ruleset;
        return (ruleset, reclaimAmount, 0, new JBCashOutHookSpecification[](0));
    }
}

contract MockJBController_Observe {
    mapping(uint256 => uint256) public weights;
    mapping(uint256 => uint16) public reservedPercents;

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function setReservedPercent(uint256 projectId, uint16 reservedPercent) external {
        reservedPercents[projectId] = reservedPercent;
    }

    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        metadata = JBRulesetMetadata({
            reservedPercent: reservedPercents[projectId],
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

// ============================================================
// TestObserve — Tests for JBUniswapV4Hook.observe()
// ============================================================

contract TestObserve is Test {
    receive() external payable {}

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    JBUniswapV4Hook hook;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTokens_Observe mockJBTokens;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBDirectory_Observe mockJBDirectory;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBMultiTerminal_Observe mockJBMultiTerminal;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBController_Observe mockJBController;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBPrices_Observe mockJBPrices;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTerminalStore_Observe mockJBTerminalStore;
    IPoolManager manager;
    PoolSwapTest swapRouter;
    JuiceboxSwapRouter jbSwapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    bytes constant ZERO_BYTES = "";

    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        // Start at a reasonable timestamp so TWAP calculations work
        vm.warp(10_000);

        // Deploy core contracts
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        swapRouter = new PoolSwapTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy mock Juicebox contracts
        mockJBTokens = new MockJBTokens_Observe();
        mockJBDirectory = new MockJBDirectory_Observe();
        mockJBMultiTerminal = new MockJBMultiTerminal_Observe();
        mockJBController = new MockJBController_Observe();
        mockJBPrices = new MockJBPrices_Observe();
        mockJBTerminalStore = new MockJBTerminalStore_Observe();

        mockJBDirectory.setMockTerminal(address(mockJBMultiTerminal));
        mockJBDirectory.setMockController(address(mockJBController));
        mockJBMultiTerminal.setTerminalStore(address(mockJBTerminalStore));

        // Calculate the required hook flags
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(this));

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(address(this));
        hook.setChainSpecificConstants({
            newPoolManager: manager,
            newTokens: IJBTokens(address(mockJBTokens)),
            newDirectory: IJBDirectory(address(mockJBDirectory)),
            newPrices: IJBPrices(address(mockJBPrices))
        });

        // Deploy test tokens
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Set up a Juicebox project for token0
        mockJBTokens.setProjectId(address(token0), 123);
        mockJBController.setWeight(123, 1000e18);
        mockJBMultiTerminal.setProjectToken(123, address(token0));

        // Set up pool key
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        id = key.toId();

        // Mint tokens for this test contract
        token0.mint(address(this), 100_000 ether);
        token1.mint(address(this), 100_000 ether);

        // Approve tokens for liquidity router
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Approve tokens for swap router
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Approve tokens for jbSwapRouter
        token0.approve(address(jbSwapRouter), type(uint256).max);
        token1.approve(address(jbSwapRouter), type(uint256).max);

        // Approve tokens for the hook (needed for Juicebox routing)
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        // Initialize the pool (triggers afterInitialize -> oracle init)
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add liquidity with wider range so swaps succeed at non-zero ticks
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // ---------------------------------------------------------------
    // Helper: perform a swap using the standard PoolSwapTest router
    // ---------------------------------------------------------------

    function _doSwap(bool zeroForOne, int256 amountSpecified) internal {
        uint160 sqrtLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtLimit});

        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0)));
    }

    // ---------------------------------------------------------------
    // 1. observe_returnsValidCumulatives
    // ---------------------------------------------------------------

    /// @notice After some swaps at different timestamps, observe() should return
    ///         valid cumulative values with correct array lengths.
    function test_observe_returnsValidCumulatives() public {
        // Advance time and do a swap to create a second observation
        vm.warp(10_100);
        _doSwap(true, -0.001 ether);

        // Advance time again and do another swap for a third observation
        vm.warp(10_130);
        _doSwap(false, -0.001 ether);

        // Call observe with [30, 0] — 30 seconds ago and now
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 30;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiqCumulatives) = hook.observe(key, secondsAgos);

        // Return arrays must have length == secondsAgos.length
        assertEq(tickCumulatives.length, 2, "tickCumulatives length should be 2");
        assertEq(secondsPerLiqCumulatives.length, 2, "secondsPerLiqCumulatives length should be 2");

        // tickCumulatives[1] (now) should be >= tickCumulatives[0] (30s ago)
        // because cumulative values grow monotonically with time for non-negative ticks,
        // or at least differ by tick * elapsed time
        // For a near-zero tick, the difference could be zero or slightly negative,
        // so we just verify the values are valid (non-reverting) and the difference is bounded
        int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
        // The tick difference over 30 seconds should be bounded: |tickDiff| <= maxTick * 30
        assertTrue(
            tickDiff >= -887_272 * 30 && tickDiff <= 887_272 * 30,
            "Tick cumulative difference should be bounded by maxTick * elapsed"
        );

        // secondsPerLiquidityCumulativeX128 should be monotonically non-decreasing
        assertGe(secondsPerLiqCumulatives[1], secondsPerLiqCumulatives[0], "secondsPerLiqCumulatives[1] should >= [0]");
    }

    // ---------------------------------------------------------------
    // 2. observe_emptyPool_reverts (target predates oldest observation)
    // ---------------------------------------------------------------

    /// @notice If we ask for data older than the oldest observation, it should revert
    ///         with Oracle_TargetPredatesOldestObservation.
    function test_observe_targetPredatesOldestObservation_reverts() public {
        // After setUp: pool initialized at t=10000 with 1 observation.
        // Advance time slightly and do a swap so cardinality=2 and index=1.
        vm.warp(10_100);
        _doSwap(true, -0.001 ether);

        // Now ask for an observation at 200 seconds ago from t=10100.
        // That targets t=9900, which is before the oldest observation at t=10000.
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 200;

        vm.expectRevert(
            abi.encodeWithSelector(Oracle.Oracle_TargetPredatesOldestObservation.selector, uint32(10_000), uint32(9900))
        );
        hook.observe(key, secondsAgos);
    }

    // ---------------------------------------------------------------
    // 3. observe_multipleSecondsAgos
    // ---------------------------------------------------------------

    /// @notice With multiple observations spread over time, observe() with multiple
    ///         secondsAgo values should return monotonically ordered cumulatives.
    function test_observe_multipleSecondsAgos() public {
        // Create observations at multiple timestamps
        vm.warp(10_100);
        _doSwap(true, -0.001 ether);

        vm.warp(10_400);
        _doSwap(false, -0.001 ether);

        vm.warp(10_700);
        _doSwap(true, -0.001 ether);

        vm.warp(11_000);
        _doSwap(false, -0.001 ether);

        // Current time is 11000. Query at [600, 300, 60, 0]
        // Targets: t=10400, t=10700, t=10940, t=11000
        uint32[] memory secondsAgos = new uint32[](4);
        secondsAgos[0] = 600;
        secondsAgos[1] = 300;
        secondsAgos[2] = 60;
        secondsAgos[3] = 0;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiqCumulatives) = hook.observe(key, secondsAgos);

        // Return arrays must have length 4
        assertEq(tickCumulatives.length, 4, "tickCumulatives length should be 4");
        assertEq(secondsPerLiqCumulatives.length, 4, "secondsPerLiqCumulatives length should be 4");

        // secondsPerLiquidityCumulativeX128 should be monotonically non-decreasing
        // (earlier secondsAgo = further back in time = smaller cumulative)
        for (uint256 i = 1; i < 4; i++) {
            assertGe(
                secondsPerLiqCumulatives[i],
                secondsPerLiqCumulatives[i - 1],
                "secondsPerLiqCumulatives should be monotonically non-decreasing"
            );
        }

        // Verify that values interpolate correctly:
        // The difference between adjacent cumulative values should be proportional to elapsed time.
        // For secondsPerLiquidityCumulativeX128, the increment per second depends on liquidity,
        // so we just verify the ordering holds and values are non-zero for the current time point.
        assertGt(secondsPerLiqCumulatives[3], 0, "Current secondsPerLiqCumulative should be > 0");
    }

    // ---------------------------------------------------------------
    // 4. observe_singleSecondAgo_zero
    // ---------------------------------------------------------------

    /// @notice Calling observe with secondsAgo=[0] should return the current cumulative values.
    ///         We cross-verify by calculating the expected value manually.
    function test_observe_singleSecondAgo_zero() public {
        // Create a second observation at a known time
        vm.warp(10_100);
        _doSwap(true, -0.001 ether);

        // Warp to a new time without doing a swap — observe(0) should still work
        // by transforming the last observation to the current timestamp.
        vm.warp(10_200);

        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 0;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiqCumulatives) = hook.observe(key, secondsAgos);

        assertEq(tickCumulatives.length, 1, "Should return single element");
        assertEq(secondsPerLiqCumulatives.length, 1, "Should return single element");

        // Manual verification:
        // The last observation was written at t=10100 during the swap.
        // observe(0) at t=10200 should transform it:
        //   tickCumulative = lastTickCumulative + tick * (10200 - 10100)
        //   where tick is the current pool tick
        IPoolManager pm = manager;
        (, int24 currentTick,,) = pm.getSlot0(id);
        uint128 currentLiquidity = pm.getLiquidity(id);

        // Read the last written observation to get its cumulative
        (uint32 lastTimestamp, int56 lastTickCumulative, uint160 lastSecPerLiq, bool initialized) =
            hook.observations(id, 1); // index 1 after the swap
        assertTrue(initialized, "Observation at index 1 should be initialized");
        assertEq(lastTimestamp, 10_100, "Last observation should be at t=10100");

        // Expected tickCumulative at t=10200
        int56 expectedTickCumulative = lastTickCumulative + int56(currentTick) * int56(uint56(10_200 - 10_100));
        assertEq(tickCumulatives[0], expectedTickCumulative, "tickCumulative should match manual calculation");

        // Expected secondsPerLiquidityCumulativeX128 at t=10200
        uint160 expectedSecPerLiq =
            lastSecPerLiq + ((uint160(10_200 - 10_100) << 128) / (currentLiquidity > 0 ? currentLiquidity : 1));
        assertEq(
            secondsPerLiqCumulatives[0], expectedSecPerLiq, "secondsPerLiqCumulative should match manual calculation"
        );
    }

    // ---------------------------------------------------------------
    // 5. observe_emptySecondsAgos_returnsEmptyArrays
    // ---------------------------------------------------------------

    /// @notice Calling observe with an empty secondsAgos array should return empty arrays.
    function test_observe_emptySecondsAgos_returnsEmptyArrays() public view {
        uint32[] memory secondsAgos = new uint32[](0);

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiqCumulatives) = hook.observe(key, secondsAgos);

        assertEq(tickCumulatives.length, 0, "Should return empty tickCumulatives array");
        assertEq(secondsPerLiqCumulatives.length, 0, "Should return empty secondsPerLiqCumulatives array");
    }

    // ---------------------------------------------------------------
    // 6. observe_atExactObservationTimestamp
    // ---------------------------------------------------------------

    /// @notice When the target timestamp exactly matches a recorded observation,
    ///         observe() should return the exact stored cumulative values (no interpolation).
    function test_observe_atExactObservationTimestamp() public {
        // Create observation at t=10100
        vm.warp(10_100);
        _doSwap(true, -0.001 ether);

        // Create observation at t=10200
        vm.warp(10_200);
        _doSwap(false, -0.001 ether);

        // Query at t=10200 for exactly 100 seconds ago (targets t=10100)
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 100;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiqCumulatives) = hook.observe(key, secondsAgos);

        // Read the observation at index 1 (written at t=10100)
        (uint32 obsTimestamp, int56 obsTickCumulative, uint160 obsSecPerLiq, bool initialized) =
            hook.observations(id, 1);
        assertTrue(initialized, "Observation should be initialized");
        assertEq(obsTimestamp, 10_100, "Observation timestamp should be 10100");

        // Values should match exactly — no interpolation needed
        assertEq(tickCumulatives[0], obsTickCumulative, "Should return exact observation tickCumulative");
        assertEq(secondsPerLiqCumulatives[0], obsSecPerLiq, "Should return exact observation secondsPerLiqCumulative");
    }

    // ---------------------------------------------------------------
    // 7. observe_interpolatesBetweenObservations
    // ---------------------------------------------------------------

    /// @notice When the target timestamp falls between two observations,
    ///         observe() should return interpolated values.
    function test_observe_interpolatesBetweenObservations() public {
        // Create observation at t=10100
        vm.warp(10_100);
        _doSwap(true, -0.001 ether);

        // Create observation at t=10200
        vm.warp(10_200);
        _doSwap(false, -0.001 ether);

        // Query at t=10200 for 50 seconds ago (targets t=10150, between obs at 10100 and 10200)
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 50;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiqCumulatives) = hook.observe(key, secondsAgos);

        // Find the observations that bracket t=10150 by scanning the observation array.
        // After auto-grow the observations may not be at indices 0 and 1.
        (, uint16 card,) = hook.states(id);

        // Scan for the observations at t=10100 and t=10200
        int56 beforeTickCum;
        uint160 beforeSecPerLiq;
        int56 afterTickCum;
        uint160 afterSecPerLiq;
        bool foundBefore;
        bool foundAfter;

        for (uint16 i = 0; i < card; i++) {
            (uint32 ts, int56 tc, uint160 spl, bool init) = hook.observations(id, i);
            if (init && ts == 10_100) {
                beforeTickCum = tc;
                beforeSecPerLiq = spl;
                foundBefore = true;
            }
            if (init && ts == 10_200) {
                afterTickCum = tc;
                afterSecPerLiq = spl;
                foundAfter = true;
            }
        }

        assertTrue(foundBefore, "Should find observation at t=10100");
        assertTrue(foundAfter, "Should find observation at t=10200");

        // The interpolated tickCumulative at t=10150 should be:
        // beforeTickCum + (afterTickCum - beforeTickCum) * 50 / 100
        // This matches Oracle.observeSingle's interpolation formula.
        int56 expectedTickCum = beforeTickCum + ((afterTickCum - beforeTickCum) * 50) / 100;
        assertEq(tickCumulatives[0], expectedTickCum, "Interpolated tickCumulative should match formula");

        // The interpolated secondsPerLiqCumulative at t=10150 should follow the same pattern
        uint160 expectedSecPerLiq = beforeSecPerLiq + uint160((uint256(afterSecPerLiq - beforeSecPerLiq) * 50) / 100);
        assertEq(
            secondsPerLiqCumulatives[0], expectedSecPerLiq, "Interpolated secondsPerLiqCumulative should match formula"
        );
    }
}
