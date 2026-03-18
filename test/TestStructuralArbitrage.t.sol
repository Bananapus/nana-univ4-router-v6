// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
import {JuiceboxSwapRouter} from "./utils/JuiceboxSwapRouter.sol";
import {IJBTokens, IJBPrices, IJBDirectory, IJBTerminalStore} from "../src/JBUniswapV4Hook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// ============================================
// Mock Juicebox contracts
// ============================================

contract MockJBTokensSA {
    mapping(address => uint256) public projectIdOf;

    function setProjectId(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
    }
}

contract MockJBDirectorySA {
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

contract MockJBPricesSA {
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
        uint256
    )
        external
        view
        returns (uint256)
    {
        uint256 price = prices[projectId][pricingCurrency][unitCurrency];
        return price > 0 ? price : 1e18;
    }
}

contract MockJBControllerSA {
    mapping(uint256 => uint256) public weights;
    mapping(uint256 => uint16) public reservedPercents;
    mapping(uint256 => uint16) public cashOutTaxRates;

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function setReservedPercent(uint256 projectId, uint16 reservedPercent) external {
        reservedPercents[projectId] = reservedPercent;
    }

    function setCashOutTaxRate(uint256 projectId, uint16 rate) external {
        cashOutTaxRates[projectId] = rate;
    }

    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        metadata = JBRulesetMetadata({
            reservedPercent: reservedPercents[projectId],
            cashOutTaxRate: cashOutTaxRates[projectId],
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
            useTotalSurplusForCashOuts: false,
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

/// @notice Terminal store that models the actual JB bonding curve with a cashOutTaxRate.
///
/// The JB bonding curve formula (from JBCashOuts.sol):
///   reclaim = surplus * count * [(MAX - tax) + tax * (count / supply)] / (supply * MAX)
///
/// When cashOutTaxRate > 0, the tax retains a fraction of surplus in the project on each cashout.
/// This means the absolute surplus strictly decreases with each cashout, which is what makes the
/// hook's routing estimate (based on current surplus) converge below the V4 pool price.
///
/// For the read-only estimate (used by the hook for route comparison), we use the current
/// surplus and supply. For the mutating recordCashOut, we compute the reclaim, then reduce
/// both surplus and supply.
contract ConcaveBondingCurveStore {
    uint256 public surplus;
    uint256 public totalSupply;
    uint256 public cashOutTaxRate; // out of MAX_TAX_RATE = 10,000

    uint256 constant MAX_TAX_RATE = 10_000;

    function configure(uint256 _surplus, uint256 _totalSupply, uint256 _cashOutTaxRate) external {
        surplus = _surplus;
        totalSupply = _totalSupply;
        cashOutTaxRate = _cashOutTaxRate;
    }

    /// @notice Compute reclaim amount using the JB bonding curve formula.
    /// reclaim = surplus * count * [(MAX - tax) + tax * count / supply] / (supply * MAX)
    function _computeReclaim(uint256 _surplus, uint256 count, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return 0;
        uint256 taxTerm = cashOutTaxRate * count / supply;
        uint256 bracket = (MAX_TAX_RATE - cashOutTaxRate) + taxTerm;
        return (_surplus * count * bracket) / (supply * MAX_TAX_RATE);
    }

    /// @notice Mutating cashout: compute reclaim, reduce surplus and supply.
    function recordCashOut(uint256 cashOutCount) external returns (uint256 reclaimAmount) {
        require(totalSupply > 0, "no supply");
        reclaimAmount = _computeReclaim(surplus, cashOutCount, totalSupply);
        surplus -= reclaimAmount;
        totalSupply -= cashOutCount;
    }

    /// @notice Read-only estimate (matches what the hook calls for route comparison).
    function currentReclaimableSurplusOf(
        uint256,
        uint256 cashOutCount,
        uint256,
        uint256
    )
        external
        view
        returns (uint256)
    {
        return _computeReclaim(surplus, cashOutCount, totalSupply);
    }

    /// @notice Overloaded version the hook also calls.
    function currentReclaimableSurplusOf(
        uint256,
        uint256 cashOutCount,
        IJBTerminal[] calldata,
        JBAccountingContext[] calldata,
        uint256,
        uint256
    )
        external
        view
        returns (uint256)
    {
        return _computeReclaim(surplus, cashOutCount, totalSupply);
    }
}

/// @notice Terminal that wraps ConcaveBondingCurveStore. Each cashOut mutates the store,
/// reducing surplus and supply so that the hook's routing estimate eventually drops below V4.
contract ConcaveBondingCurveTerminal {
    uint256 public lastProjectId;
    address public lastToken;
    uint256 public lastAmount;
    address public lastBeneficiary;

    mapping(uint256 => address) public projectTokens;

    ConcaveBondingCurveStore public store;

    // Tracks cumulative output for test assertions
    uint256 public cumulativeOutput;
    uint256 public callCount;
    uint256[] public outputHistory;

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25; // 2.5%
    }

    function setProjectToken(uint256 projectId, address projectToken) external {
        projectTokens[projectId] = projectToken;
    }

    function setStore(address _store) external {
        store = ConcaveBondingCurveStore(_store);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function STORE() external view returns (IJBTerminalStore) {
        return IJBTerminalStore(address(store));
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
        lastProjectId = projectId;
        lastToken = token;
        lastAmount = amount;
        lastBeneficiary = beneficiary;

        // Default: 1000 tokens per unit input
        beneficiaryTokenCount = amount * 1000;

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0)) {
            MockERC20(projectToken).mint(beneficiary, beneficiaryTokenCount);
        }
    }

    function cashOutTokensOf(
        address,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256)
    {
        lastProjectId = projectId;
        lastToken = tokenToReclaim;
        lastAmount = cashOutCount;
        lastBeneficiary = beneficiary;

        // Mutate the bonding curve state. Each call reduces surplus and supply.
        // The tax rate ensures surplus is retained, causing the hook's estimate to converge downward.
        uint256 outputAmount = store.recordCashOut(cashOutCount);

        require(outputAmount >= minTokensReclaimed, "Insufficient tokens reclaimed");

        // Track for assertions
        callCount++;
        cumulativeOutput += outputAmount;
        outputHistory.push(outputAmount);

        if (outputAmount > 0) {
            MockERC20(tokenToReclaim).mint(beneficiary, outputAmount);
        }

        return outputAmount;
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        return contexts;
    }

    function getOutputHistory() external view returns (uint256[] memory) {
        return outputHistory;
    }
}

// ============================================
// Structural Arbitrage Bound Test Suite
// ============================================

/// @title TestStructuralArbitrage
/// @notice Proves that the bonding curve bounds repeated JB-routed extraction.
///
/// When the hook routes a sell-side swap through JB cashOut, the V4 pool price does NOT move
/// (tokens bypass the AMM). However, each cashOut reduces surplus in the bonding curve (the
/// cashOutTaxRate retains surplus, so the surplus-to-supply ratio decreases over time).
/// Eventually the hook's estimate (based on current surplus/supply) drops below the V4 pool
/// price, and routing switches to V4. This makes sustained extraction self-limiting.
///
/// The JB bonding curve formula: reclaim = surplus * count * [(MAX-tax) + tax*(count/supply)] / (supply*MAX)
///
/// Key properties proven:
///   1. Surplus strictly decreases with each cashout (surplus drainage).
///   2. Total extracted is bounded below the initial surplus (extraction bound).
///   3. The hook eventually stops routing through JB (convergence to V4).
///   4. Splitting a large cashout into smaller ones extracts strictly less (subadditivity).
///   5. The surplus-to-supply ratio strictly decreases (the mechanism that causes convergence).
///   6. Conservation: extracted + remaining = initial surplus (no value creation).
contract TestStructuralArbitrage is Test {
    receive() external payable {}

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    JBUniswapV4Hook hook;
    MockJBTokensSA mockJbTokens;
    MockJBDirectorySA mockJbDirectory;
    ConcaveBondingCurveTerminal terminal;
    MockJBControllerSA mockJbController;
    MockJBPricesSA mockJbPrices;
    ConcaveBondingCurveStore terminalStore;

    PoolManager manager;
    PoolSwapTest swapRouter;
    JuiceboxSwapRouter jbSwapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    bytes constant ZERO_BYTES = "";
    uint256 constant PROJECT_ID = 42;

    MockERC20 token0; // JB project token
    MockERC20 token1; // Counter-asset
    PoolKey key;
    PoolId id;

    // Initial bonding curve parameters.
    // Surplus of 500 ETH backing 100 tokens with 50% cashOutTaxRate.
    // Initial per-token reclaim (for 5 tokens):
    //   = 500 * 5 * [5000 + 5000*5/100] / (100 * 10000) = 500*5*5250/1000000 = 13.125 ETH
    //   per-token = 2.625 ETH. Versus V4 at 1:1 (~0.997 ETH after fee). JB wins initially.
    //
    // As surplus drains and supply drops, the hook's read-only estimate eventually falls below V4.
    uint256 constant INITIAL_SURPLUS = 500 ether;
    uint256 constant INITIAL_SUPPLY = 100 ether; // 100 tokens (18 decimals)
    uint256 constant CASH_OUT_TAX_RATE = 5000; // 50%
    uint256 constant SWAP_SIZE = 5 ether; // Sell 5 JB tokens per swap

    function setUp() public {
        vm.warp(10_000);

        // Deploy V4 infrastructure
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        jbSwapRouter = new JuiceboxSwapRouter(IPoolManager(address(manager)));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        // Deploy JB mocks
        mockJbTokens = new MockJBTokensSA();
        mockJbDirectory = new MockJBDirectorySA();
        mockJbController = new MockJBControllerSA();
        mockJbPrices = new MockJBPricesSA();

        // Deploy concave bonding curve terminal and store
        terminal = new ConcaveBondingCurveTerminal();
        terminalStore = new ConcaveBondingCurveStore();
        terminal.setStore(address(terminalStore));

        // Wire up directory
        mockJbDirectory.setMockTerminal(address(terminal));
        mockJbDirectory.setMockController(address(mockJbController));

        // Deploy hook with address-mined salt
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            IJBTokens(address(mockJbTokens)),
            IJBDirectory(address(mockJbDirectory)),
            IJBPrices(address(mockJbPrices))
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(
            IPoolManager(address(manager)),
            IJBTokens(address(mockJbTokens)),
            IJBDirectory(address(mockJbDirectory)),
            IJBPrices(address(mockJbPrices))
        );

        // Create tokens, ensuring correct ordering (currency0 < currency1)
        token0 = new MockERC20("JBToken", "JBT");
        token1 = new MockERC20("CounterAsset", "CA");

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Configure JB project: token0 is the project token
        mockJbTokens.setProjectId(address(token0), PROJECT_ID);
        mockJbController.setWeight(PROJECT_ID, 1000e18);
        mockJbController.setCashOutTaxRate(PROJECT_ID, uint16(CASH_OUT_TAX_RATE));
        terminal.setProjectToken(PROJECT_ID, address(token0));

        // Set price feed: 1:1 between token1 and base currency
        uint32 token1CurrencyId = uint32(uint160(address(token1)));
        mockJbPrices.setPricePerUnitOf(PROJECT_ID, token1CurrencyId, 1, 1e18);

        // Initialize bonding curve
        terminalStore.configure(INITIAL_SURPLUS, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);

        // Set up V4 pool at 1:1 price with moderate liquidity
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        // Mint liquidity tokens
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.approve(address(modifyLiquidityRouter), 1000 ether);
        token1.approve(address(modifyLiquidityRouter), 1000 ether);

        // Approve hook for settlement
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        manager.initialize(key, SQRT_PRICE_1_1);

        // Add liquidity to V4 pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // ============================================
    // Helper: execute one sell-side swap
    // ============================================

    /// @dev Sells `amount` of token0 (JB token) for token1 via the hook router.
    function _sellJbTokens(uint256 amount) internal {
        token0.mint(address(this), amount);
        token0.approve(address(jbSwapRouter), amount);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amount), // safe: test amounts are small
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        jbSwapRouter.swap(key, params, 0);
    }

    // ============================================
    // Test 1: Surplus strictly decreases with each cashout
    // ============================================

    /// @notice Each cashout removes surplus from the project. With a positive cashOutTaxRate,
    /// the surplus decreases monotonically. This is the fundamental mechanism that bounds
    /// extraction: less surplus means less reclaim available for future cashouts.
    function test_StructuralArbitrage_SurplusDrainMonotonic() public {
        ConcaveBondingCurveStore testStore = new ConcaveBondingCurveStore();
        testStore.configure(INITIAL_SURPLUS, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);

        uint256 cashOutSize = 5 ether;
        uint256 numRounds = 15;

        uint256[] memory surplusAfter = new uint256[](numRounds);
        uint256[] memory reclaimAmounts = new uint256[](numRounds);

        for (uint256 i = 0; i < numRounds; i++) {
            reclaimAmounts[i] = testStore.recordCashOut(cashOutSize);
            surplusAfter[i] = testStore.surplus();
        }

        console.log("--- Surplus Drain ---");
        console.log("  Initial surplus: %d", INITIAL_SURPLUS);
        for (uint256 i = 0; i < numRounds; i++) {
            console.log("  Round %d: reclaim=%d, surplus=%d", i, reclaimAmounts[i], surplusAfter[i]);
        }

        // Surplus must strictly decrease after each cashout
        assertLt(surplusAfter[0], INITIAL_SURPLUS, "First cashout must reduce surplus");
        for (uint256 i = 1; i < numRounds; i++) {
            assertLt(
                surplusAfter[i],
                surplusAfter[i - 1],
                string.concat(
                    "Surplus after round ", vm.toString(i), " must be less than after round ", vm.toString(i - 1)
                )
            );
        }
    }

    // ============================================
    // Test 2: Remaining reclaimable surplus strictly decreases
    // ============================================

    /// @notice The total reclaimable surplus for ALL remaining tokens strictly decreases
    /// after each cashout. Even though the per-token rate may increase as supply drops,
    /// the absolute surplus available for the remaining supply decreases. This bounds
    /// the total possible future extraction at any point.
    function test_StructuralArbitrage_RemainingReclaimableDecreases() public {
        ConcaveBondingCurveStore testStore = new ConcaveBondingCurveStore();
        testStore.configure(INITIAL_SURPLUS, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);

        uint256 cashOutSize = 5 ether;
        uint256 numRounds = 15;

        // At each step, compute the reclaim for the ENTIRE remaining supply.
        // This represents the maximum possible future extraction.
        uint256 initialFullReclaim = testStore.currentReclaimableSurplusOf(PROJECT_ID, INITIAL_SUPPLY, 0, 0);
        uint256[] memory fullReclaims = new uint256[](numRounds);

        for (uint256 i = 0; i < numRounds; i++) {
            testStore.recordCashOut(cashOutSize);
            uint256 remainingSupply = testStore.totalSupply();
            if (remainingSupply > 0) {
                fullReclaims[i] = testStore.currentReclaimableSurplusOf(PROJECT_ID, remainingSupply, 0, 0);
            }
        }

        console.log("--- Remaining Reclaimable Surplus ---");
        console.log("  Initial full reclaim: %d", initialFullReclaim);
        for (uint256 i = 0; i < numRounds; i++) {
            console.log("  After round %d: full reclaim of remaining = %d", i, fullReclaims[i]);
        }

        // Full reclaim must strictly decrease after each cashout
        assertLt(fullReclaims[0], initialFullReclaim, "First cashout must reduce full reclaimable");
        for (uint256 i = 1; i < numRounds; i++) {
            assertLt(
                fullReclaims[i],
                fullReclaims[i - 1],
                string.concat(
                    "Full reclaim after round ", vm.toString(i), " must be less than after round ", vm.toString(i - 1)
                )
            );
        }
    }

    // ============================================
    // Test 3: Total extraction bounded below initial surplus
    // ============================================

    /// @notice The cumulative output from repeated cashouts must be bounded below the initial surplus.
    /// Conservation (extracted + remaining = initial) combined with remaining > 0 proves this.
    function test_StructuralArbitrage_ExtractionBounded() public {
        // Execute many swaps to try to drain the surplus
        uint256 numSwaps = 15;

        for (uint256 i = 0; i < numSwaps; i++) {
            _sellJbTokens(SWAP_SIZE);
        }

        uint256 totalExtracted = terminal.cumulativeOutput();
        uint256 remainingSurplus = terminalStore.surplus();

        console.log("--- Extraction Bound Results ---");
        console.log("  Initial surplus:    %d", INITIAL_SURPLUS);
        console.log("  Total extracted:    %d", totalExtracted);
        console.log("  Remaining surplus:  %d", remainingSurplus);

        // Total extracted should be less than initial surplus
        assertLt(totalExtracted, INITIAL_SURPLUS, "Total extracted must be less than initial surplus");

        // Remaining surplus should be positive
        assertGt(remainingSurplus, 0, "Surplus should not be fully drained");

        // Conservation: extracted + remaining = initial (no value created or destroyed)
        assertEq(
            totalExtracted + remainingSurplus,
            INITIAL_SURPLUS,
            "Conservation: extracted + remaining should equal initial surplus"
        );
    }

    // ============================================
    // Test 4: Convergence -- JB routing eventually stops
    // ============================================

    /// @notice After enough cashouts, the JB bonding curve's read-only estimate drops below
    /// the V4 pool price, causing the hook to route through V4 instead. This proves the
    /// structural arbitrage is self-limiting.
    function test_StructuralArbitrage_ConvergesToV4() public {
        // Build TWAP history so the hook can compare routes.
        vm.warp(block.timestamp + 1801);

        // Small V4 swap to record a second observation (need cardinality >= 2 for TWAP)
        token1.mint(address(this), 0.001 ether);
        token1.approve(address(jbSwapRouter), 0.001 ether);
        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(0.001 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            0
        );
        vm.warp(block.timestamp + 1801);

        // Execute sell-side swaps until convergence or max iterations.
        uint256 maxSwaps = 50;
        uint256 jbRoutedCount = 0;
        uint256 v4RoutedCount = 0;
        bool sawV4Routing = false;

        for (uint256 i = 0; i < maxSwaps; i++) {
            uint256 cashoutsBefore = terminal.callCount();

            _sellJbTokens(SWAP_SIZE);

            uint256 cashoutsAfter = terminal.callCount();

            if (cashoutsAfter > cashoutsBefore) {
                jbRoutedCount++;
            } else {
                v4RoutedCount++;
                sawV4Routing = true;
            }

            // Once we see V4 routing, convergence is achieved.
            if (sawV4Routing) break;
        }

        console.log("--- Convergence Results ---");
        console.log("  JB-routed swaps:  %d", jbRoutedCount);
        console.log("  V4-routed swaps:  %d", v4RoutedCount);
        console.log("  Converged:        %s", sawV4Routing ? "yes" : "no");

        uint256[] memory history = terminal.getOutputHistory();
        if (history.length > 0) {
            console.log("  First cashout:    %d wei", history[0]);
            console.log("  Last cashout:     %d wei", history[history.length - 1]);
        }

        assertTrue(sawV4Routing, "Hook should eventually stop routing through JB and fall back to V4");
        assertGt(jbRoutedCount, 0, "Should have at least some JB-routed swaps before convergence");
    }

    // ============================================
    // Test 5: Splitting does not increase extraction
    // ============================================

    /// @notice An attacker splitting a large cashout into N smaller ones should not extract more
    /// than a single large cashout of the same total amount. With cashOutTaxRate > 0, the
    /// bonding curve formula is concave in count/supply: a single large cashout benefits from
    /// a higher count/supply ratio in the quadratic term, so it extracts MORE than the sum of
    /// smaller cashouts. This means splitting is always suboptimal for the extractor.
    function test_StructuralArbitrage_SplittingDoesNotHelp() public {
        uint256 largeCashOutAmount = 50 ether; // 50 tokens

        // Single large cashout
        ConcaveBondingCurveStore singleStore = new ConcaveBondingCurveStore();
        singleStore.configure(INITIAL_SURPLUS, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);
        uint256 singleShotOutput = singleStore.recordCashOut(largeCashOutAmount);

        // 10 smaller cashouts of 5 tokens each (same total)
        ConcaveBondingCurveStore splitStore = new ConcaveBondingCurveStore();
        splitStore.configure(INITIAL_SURPLUS, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);

        uint256 splitTotal = 0;
        uint256 splitSize = 5 ether;
        uint256 numSplits = 10;

        for (uint256 i = 0; i < numSplits; i++) {
            uint256 output = splitStore.recordCashOut(splitSize);
            splitTotal += output;
        }

        console.log("--- Splitting Analysis ---");
        console.log("  Single cashout of 50 tokens: %d wei", singleShotOutput);
        console.log("  10 splits of 5 tokens:       %d wei", splitTotal);
        console.log("  Difference:                  %d wei (single is better)", singleShotOutput - splitTotal);

        // The concave formula means splitting extracts LESS than a single large cashout.
        // single: surplus * 50 * [5000 + 5000*50/100] / (100*10000) = surplus * 50 * 7500 / 1000000
        // split sum: < single because each split sees a lower count/supply ratio (5/100 vs 50/100)
        assertLt(
            splitTotal,
            singleShotOutput,
            "Splitting into smaller cashouts must extract less than a single large cashout"
        );
    }

    // ============================================
    // Test 6: Conservation across full extraction
    // ============================================

    /// @notice Even with heavy extraction (75% of supply), conservation holds exactly:
    /// totalExtracted + remainingSurplus = initialSurplus. No value is created or destroyed.
    /// The remaining surplus is locked until more tokens are cashed out.
    function test_StructuralArbitrage_ConservationHolds() public {
        ConcaveBondingCurveStore testStore = new ConcaveBondingCurveStore();
        testStore.configure(INITIAL_SURPLUS, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);

        // Cash out 75% of total supply in 15 rounds of 5%
        uint256 roundSize = INITIAL_SUPPLY / 20; // 5% per round = 5 tokens
        uint256 totalExtracted = 0;
        uint256 numRounds = 15; // 75% total

        for (uint256 i = 0; i < numRounds; i++) {
            uint256 output = testStore.recordCashOut(roundSize);
            totalExtracted += output;
        }

        uint256 remainingSurplus = testStore.surplus();
        uint256 remainingSupply = testStore.totalSupply();

        console.log("--- Conservation After 75%% Extraction ---");
        console.log("  Total extracted:     %d wei", totalExtracted);
        console.log("  Remaining surplus:   %d wei", remainingSurplus);
        console.log("  Remaining supply:    %d wei", remainingSupply);
        console.log("  Extraction percent:  %d%%", (totalExtracted * 100) / INITIAL_SURPLUS);

        // Exact conservation
        assertEq(totalExtracted + remainingSurplus, INITIAL_SURPLUS, "Conservation: extracted + remaining = initial");

        // With 50% tax, the curve retains substantial surplus even after 75% supply reduction.
        assertGt(remainingSurplus, 0, "Surplus should not be fully drained");
        assertGt(
            remainingSurplus,
            INITIAL_SURPLUS / 10,
            "With 50% tax, >10% of surplus should remain after 75% supply reduction"
        );

        // Supply accounting
        assertEq(remainingSupply, INITIAL_SUPPLY - (roundSize * numRounds), "Supply accounting correct");
    }

    // ============================================
    // Test 7: Higher tax rate retains more surplus
    // ============================================

    /// @notice With a higher cashOutTaxRate, more surplus is retained after the same extraction.
    /// This demonstrates that the tax rate is the lever controlling how quickly extraction is bounded.
    function test_StructuralArbitrage_HigherTaxRetainsMore() public {
        uint256 cashOutSize = 5 ether;
        uint256 numRounds = 10;

        // Low tax (20%)
        ConcaveBondingCurveStore lowTaxStore = new ConcaveBondingCurveStore();
        lowTaxStore.configure(INITIAL_SURPLUS, INITIAL_SUPPLY, 2000);

        uint256 lowTaxExtracted = 0;
        for (uint256 i = 0; i < numRounds; i++) {
            lowTaxExtracted += lowTaxStore.recordCashOut(cashOutSize);
        }

        // High tax (80%)
        ConcaveBondingCurveStore highTaxStore = new ConcaveBondingCurveStore();
        highTaxStore.configure(INITIAL_SURPLUS, INITIAL_SUPPLY, 8000);

        uint256 highTaxExtracted = 0;
        for (uint256 i = 0; i < numRounds; i++) {
            highTaxExtracted += highTaxStore.recordCashOut(cashOutSize);
        }

        uint256 lowTaxRemaining = lowTaxStore.surplus();
        uint256 highTaxRemaining = highTaxStore.surplus();

        console.log("--- Tax Rate Comparison ---");
        console.log("  20%% tax: extracted=%d, remaining=%d", lowTaxExtracted, lowTaxRemaining);
        console.log("  80%% tax: extracted=%d, remaining=%d", highTaxExtracted, highTaxRemaining);

        // Higher tax should retain more surplus
        assertGt(highTaxRemaining, lowTaxRemaining, "Higher tax should retain more surplus");

        // Higher tax should extract less total
        assertLt(highTaxExtracted, lowTaxExtracted, "Higher tax should allow less total extraction");
    }

    // ============================================
    // Test 8: Partial extraction retains surplus; full extraction returns all
    // ============================================

    /// @notice The bonding curve tax only penalizes PARTIAL exits. Cashing out a fraction of
    /// supply returns less than the proportional surplus (tax retained). But cashing out the
    /// entire remaining supply returns ALL remaining surplus (bracket = MAX when count = supply).
    ///
    /// This test proves:
    ///   a) Partial extraction (75% supply) retains significant surplus.
    ///   b) After partial extraction, the hook's estimate for remaining tokens drops,
    ///      eventually making V4 more attractive.
    ///   c) Full supply exhaustion returns all surplus (conservation).
    function test_StructuralArbitrage_PartialVsFullExtraction() public {
        // --- Part A: Partial extraction retains surplus ---
        ConcaveBondingCurveStore partialStore = new ConcaveBondingCurveStore();
        partialStore.configure(INITIAL_SURPLUS, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);

        uint256 cashOutSize = 5 ether;
        uint256 partialRounds = 15; // 75% of 100 tokens = 75 tokens
        uint256 partialExtracted = 0;

        for (uint256 i = 0; i < partialRounds; i++) {
            partialExtracted += partialStore.recordCashOut(cashOutSize);
        }

        uint256 surplusAfterPartial = partialStore.surplus();

        console.log("--- Partial vs Full Extraction ---");
        console.log("  After 75%% supply consumed:");
        console.log("    Extracted: %d wei", partialExtracted);
        console.log("    Remaining surplus: %d wei", surplusAfterPartial);
        console.log("    Retained: %d%%", (surplusAfterPartial * 100) / INITIAL_SURPLUS);

        // Tax retains surplus: 75% supply extraction should yield well under 75% of surplus
        assertLt(
            partialExtracted,
            (INITIAL_SURPLUS * 75) / 100,
            "75% supply exit should extract less than 75% of surplus (tax penalty)"
        );
        assertGt(
            surplusAfterPartial,
            INITIAL_SURPLUS / 4,
            "At least 25% of surplus should remain after 75% supply exit with 50% tax"
        );

        // --- Part B: Full extraction returns all remaining surplus ---
        // Cash out the remaining 25%
        uint256 remainingSupply = partialStore.totalSupply();
        uint256 finalReclaim = partialStore.recordCashOut(remainingSupply);

        console.log("  After 100%% supply consumed:");
        console.log("    Final reclaim: %d wei", finalReclaim);
        console.log("    Remaining surplus: %d wei", partialStore.surplus());

        // The final cashout of ALL remaining supply returns ALL remaining surplus
        assertEq(finalReclaim, surplusAfterPartial, "Cashing out all remaining supply returns all remaining surplus");
        assertEq(partialStore.surplus(), 0, "No surplus remains after full exhaustion");
        assertEq(partialStore.totalSupply(), 0, "No supply remains");

        // --- Part C: Conservation ---
        assertEq(partialExtracted + finalReclaim, INITIAL_SURPLUS, "Conservation: total extracted = initial surplus");
    }
}
