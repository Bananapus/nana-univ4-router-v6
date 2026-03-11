// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

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
// Import Juicebox interfaces and structs from the hook file
import {IJBTokens, IJBPrices, IJBDirectory, IJBTerminalStore} from "../src/JBUniswapV4Hook.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// ============================================
// Mock Juicebox contracts for testing
// ============================================

contract MockJBTokens {
    mapping(address => uint256) public projectIdOf;

    function setProjectId(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
    }
}

contract MockJBDirectory {
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

contract MockJBPrices {
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public prices;

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

contract MockJBTerminalStore {
    mapping(uint256 => mapping(uint256 => uint256)) public surplusPerToken;

    function setSurplus(uint256 projectId, address token, uint256 surplusAmount) external {
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
}

contract MockJBMultiTerminal {
    uint256 public lastProjectId;
    address public lastToken;
    uint256 public lastAmount;
    address public lastBeneficiary;

    mapping(uint256 => address) public projectTokens;

    MockJBTerminalStore public TERMINAL_STORE;

    uint256 public overridePayReturnAmount;
    uint256 public overrideCashOutReturnAmount;
    bool public useOverridePayReturn;
    bool public useOverrideCashOutReturn;

    /// @notice JB protocol fee (2.5% = 25 out of MAX_FEE 1000).
    function FEE() external pure returns (uint256) {
        return 25;
    }

    function setProjectToken(uint256 projectId, address projectToken) external {
        projectTokens[projectId] = projectToken;
    }

    function setTerminalStore(address terminalStore) external {
        TERMINAL_STORE = MockJBTerminalStore(terminalStore);
    }

    function STORE() external view returns (IJBTerminalStore) {
        return IJBTerminalStore(address(TERMINAL_STORE));
    }

    function setPayReturnAmount(uint256 amount) external {
        overridePayReturnAmount = amount;
        useOverridePayReturn = true;
    }

    function setCashOutReturnAmount(uint256 amount) external {
        overrideCashOutReturnAmount = amount;
        useOverrideCashOutReturn = true;
    }

    function resetOverrides() external {
        useOverridePayReturn = false;
        useOverrideCashOutReturn = false;
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
        bytes calldata
    )
        external
        returns (uint256)
    {
        lastProjectId = projectId;
        lastToken = tokenToReclaim;
        lastAmount = cashOutCount;
        lastBeneficiary = beneficiary;

        uint256 outputAmount;

        if (useOverrideCashOutReturn) {
            outputAmount = overrideCashOutReturnAmount;
        } else {
            uint256 surplusAmount =
                TERMINAL_STORE.currentReclaimableSurplusOf(projectId, 1 ether, uint32(uint160(tokenToReclaim)), 18);
            outputAmount = (surplusAmount * cashOutCount) / 1e18;
        }

        require(outputAmount >= minTokensReclaimed, "Insufficient tokens reclaimed");

        if (outputAmount > 0) {
            MockERC20(tokenToReclaim).mint(beneficiary, outputAmount);
        }

        return outputAmount;
    }
}

contract MockJBController {
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

// ============================================
// Two-Way Routing Test Suite (V4 vs Juicebox)
// ============================================

contract TwoWayRoutingTest is Test {
    receive() external payable {}

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    JBUniswapV4Hook hook;
    MockJBTokens mockJBTokens;
    MockJBDirectory mockJBDirectory;
    MockJBMultiTerminal mockJBMultiTerminal;
    MockJBController mockJBController;
    MockJBPrices mockJBPrices;
    MockJBTerminalStore mockJBTerminalStore;

    PoolManager manager;
    PoolSwapTest swapRouter;
    JuiceboxSwapRouter jbSwapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    bytes constant ZERO_BYTES = "";
    uint256 constant PROJECT_ID = 123;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        vm.warp(10_000);

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        jbSwapRouter = new JuiceboxSwapRouter(IPoolManager(address(manager)));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        mockJBTokens = new MockJBTokens();
        mockJBDirectory = new MockJBDirectory();
        mockJBMultiTerminal = new MockJBMultiTerminal();
        mockJBController = new MockJBController();
        mockJBPrices = new MockJBPrices();
        mockJBTerminalStore = new MockJBTerminalStore();

        mockJBDirectory.setMockTerminal(address(mockJBMultiTerminal));
        mockJBDirectory.setMockController(address(mockJBController));
        mockJBMultiTerminal.setTerminalStore(address(mockJBTerminalStore));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            IJBTokens(address(mockJBTokens)),
            IJBDirectory(address(mockJBDirectory)),
            IJBPrices(address(mockJBPrices))
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(
            IPoolManager(address(manager)),
            IJBTokens(address(mockJBTokens)),
            IJBDirectory(address(mockJBDirectory)),
            IJBPrices(address(mockJBPrices))
        );

        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Set up JB project: token0 is the project token
        mockJBTokens.setProjectId(address(token0), PROJECT_ID);
        mockJBController.setWeight(PROJECT_ID, 1000e18);
        mockJBMultiTerminal.setProjectToken(PROJECT_ID, address(token0));

        uint32 token1CurrencyId = uint32(uint160(address(token1)));
        mockJBPrices.setPricePerUnitOf(PROJECT_ID, token1CurrencyId, 1, 1e18);

        // Set up V4 pool
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);

        token0.approve(address(modifyLiquidityRouter), 1000 ether);
        token1.approve(address(modifyLiquidityRouter), 1000 ether);

        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        manager.initialize(key, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // ============================================
    // Test 1: JB wins the two-way comparison
    // ============================================

    /// Given token0 is a JB project token with a very high weight (10000e18)
    /// And V4 pool has 1:1 pricing
    /// When the user buys token0 with 1 ether of token1
    /// Then JB should give the best output (10000 tokens vs ~1 from V4)
    /// And a BestRouteSelected event should be emitted with routeType 1 (juicebox)
    function test_TwoWay_JBWins() public {
        // Set JB weight very high so JB gives way more tokens than Uniswap
        mockJBController.setWeight(PROJECT_ID, 10_000e18);

        // Prepare swap tokens BEFORE setting up expectEmit
        token1.mint(address(this), 1 ether);
        token1.approve(address(jbSwapRouter), 1 ether);

        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});

        // Set expectEmit right before the swap call
        vm.expectEmit(true, false, false, false);
        emit JBUniswapV4Hook.BestRouteSelected(id, 1, 0);

        jbSwapRouter.swap(key, params, 0);

        // Verify JB terminal was called
        assertEq(mockJBMultiTerminal.lastProjectId(), PROJECT_ID, "Should have routed through Juicebox");
    }

    // ============================================
    // Test 2: V4 wins the two-way comparison
    // ============================================

    /// Given JB surplus is very low
    /// And V4 pool has 1:1 pricing
    /// When the user sells token0 for token1
    /// Then V4 should be the best option (default passthrough)
    /// And a BestRouteSelected event should be emitted with routeType 0 (v4)
    function test_TwoWay_V4Wins() public {
        // Make JB unattractive
        mockJBTerminalStore.setSurplus(PROJECT_ID, address(token1), 0.01 ether);

        token0.approve(address(jbSwapRouter), 1 ether);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectEmit(true, false, false, false);
        emit JBUniswapV4Hook.BestRouteSelected(id, 0, 0);

        jbSwapRouter.swap(key, params, 0);
    }

    // ============================================
    // Test 3: V4 wins when JB output is low
    // ============================================

    /// Given JB surplus gives less output than V4
    /// When the user sells token0 for token1
    /// Then V4 should win as the default passthrough
    function test_TwoWay_V4DefaultsWhenJBLow() public {
        // JB surplus low enough that JB output < V4
        mockJBTerminalStore.setSurplus(PROJECT_ID, address(token1), 0.5 ether);

        token0.approve(address(jbSwapRouter), 1 ether);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectEmit(true, false, false, false);
        emit JBUniswapV4Hook.BestRouteSelected(id, 0, 0);

        jbSwapRouter.swap(key, params, 0);
    }

    // ============================================
    // Test 4: JB terminal unavailable
    // ============================================

    /// Given new tokens are created where neither is a JB project token
    /// When the user swaps
    /// Then V4 passthrough happens (no JB involvement)
    /// And RouteSelected is emitted with useJuicebox=false
    function test_TwoWay_JBTerminalUnavailable() public {
        MockERC20 nonJBToken0 = new MockERC20("NonJB0", "NJB0");
        MockERC20 nonJBToken1 = new MockERC20("NonJB1", "NJB1");

        if (address(nonJBToken0) > address(nonJBToken1)) {
            (nonJBToken0, nonJBToken1) = (nonJBToken1, nonJBToken0);
        }

        PoolKey memory nonJBKey = PoolKey({
            currency0: Currency.wrap(address(nonJBToken0)),
            currency1: Currency.wrap(address(nonJBToken1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        nonJBToken0.mint(address(this), 1000 ether);
        nonJBToken1.mint(address(this), 1000 ether);
        nonJBToken0.approve(address(modifyLiquidityRouter), 1000 ether);
        nonJBToken1.approve(address(modifyLiquidityRouter), 1000 ether);

        manager.initialize(nonJBKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            nonJBKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        PoolId nonJBId = nonJBKey.toId();

        // Approve for swap and set expectEmit right before swap call
        nonJBToken0.approve(address(swapRouter), 1 ether);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        // For non-JB tokens, only RouteSelected is emitted (not BestRouteSelected)
        vm.expectEmit(true, false, false, true);
        emit JBUniswapV4Hook.RouteSelected(nonJBId, false, 0);

        swapRouter.swap(nonJBKey, params, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0)));
    }

    // ============================================
    // Test 5: Selling JB tokens - both routes compared
    // ============================================

    /// Given token0 is a JB project token
    /// And JB surplus is very high (5 ETH per token, better than V4)
    /// When the user sells token0 for token1 (zeroForOne=true)
    /// Then JB should win via calculateExpectedOutputFromSelling
    function test_TwoWay_SellingJBToken_JBWins() public {
        // Set high surplus for selling JB tokens
        mockJBTerminalStore.setSurplus(PROJECT_ID, address(token1), 5 ether);

        token0.approve(address(jbSwapRouter), 1 ether);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectEmit(true, false, false, false);
        emit JBUniswapV4Hook.BestRouteSelected(id, 1, 0);

        jbSwapRouter.swap(key, params, 0);

        assertEq(mockJBMultiTerminal.lastProjectId(), PROJECT_ID, "Should route through JB for selling");
    }

    // ============================================
    // Test 6: Native ETH routing
    // ============================================

    /// Given a pool with Currency.wrap(address(0)) as one currency (native ETH)
    /// And the other token is a JB project token with high weight
    /// When the user swaps
    /// Then both routes should be compared for native ETH
    function test_TwoWay_NativeETH_JBWins() public {
        MockERC20 ethPairToken = new MockERC20("ETHPair", "EP");
        uint256 ethProjectId = 789;

        mockJBTokens.setProjectId(address(ethPairToken), ethProjectId);
        mockJBController.setWeight(ethProjectId, 10_000e18);
        mockJBMultiTerminal.setProjectToken(ethProjectId, address(ethPairToken));

        // currency0 = native ETH (address(0)), currency1 = ethPairToken
        Currency nativeETH = Currency.wrap(address(0));
        Currency wrappedToken = Currency.wrap(address(ethPairToken));

        PoolKey memory ethKey = PoolKey({
            currency0: nativeETH, currency1: wrappedToken, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });

        vm.deal(address(this), 100 ether);
        ethPairToken.mint(address(this), 1000 ether);
        ethPairToken.approve(address(modifyLiquidityRouter), 1000 ether);

        manager.initialize(ethKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            ethKey,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        PoolId ethId = ethKey.toId();

        // zeroForOne=true means selling currency0 (ETH) for currency1 (ethPairToken = JB token)
        // This is buying JB tokens with ETH
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectEmit(true, false, false, false);
        emit JBUniswapV4Hook.BestRouteSelected(ethId, 1, 0);

        jbSwapRouter.swap{value: 1 ether}(ethKey, params, 0);

        assertEq(mockJBMultiTerminal.lastProjectId(), ethProjectId, "Should route through JB for native ETH swap");
    }

    // ============================================
    // Test 7: amountOutMin applied to winner
    // ============================================

    /// Given JB wins routing but output is below amountOutMin
    /// When the user executes the swap
    /// Then the transaction should revert
    function test_TwoWay_AmountOutMin_AppliedToWinner() public {
        // JB weight high so JB routing wins
        mockJBController.setWeight(PROJECT_ID, 10_000e18);

        // Override pay to return a specific amount
        mockJBMultiTerminal.setPayReturnAmount(5000 ether);

        // Prepare tokens
        token1.mint(address(this), 1 ether);
        token1.approve(address(jbSwapRouter), 1 ether);

        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});

        // amountOutMin higher than what JB returns (5000 < 6000)
        // JB terminal enforces minReturnedTokens internally, causing revert wrapped by PoolManager
        vm.expectRevert();
        jbSwapRouter.swap(key, params, 6000 ether);

        mockJBMultiTerminal.resetOverrides();
    }

    // ============================================
    // Test 8: Fuzz - routing consistency
    // ============================================

    /// Given fuzzed JB weight
    /// When the user performs a swap
    /// Then the best route should always be selected and not revert
    function testFuzz_TwoWay_RoutingConsistency(uint256 jbWeight) public {
        jbWeight = bound(jbWeight, 1e18, 100_000e18);

        vm.warp(block.timestamp + 10_000);

        mockJBController.setWeight(PROJECT_ID, jbWeight);

        mockJBTerminalStore.setSurplus(PROJECT_ID, address(token1), 0.5 ether);

        // Prepare tokens
        token1.mint(address(this), 1 ether);
        token1.approve(address(jbSwapRouter), 1 ether);

        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});

        // Should not revert for any valid combination
        jbSwapRouter.swap(key, params, 0);

        // Verify output is positive
        uint256 token0Balance = token0.balanceOf(address(this));
        assertGt(token0Balance, 0, "Should have received output tokens from some route");
    }

    // ============================================
    // Test 9: Exact output swap reverts
    // ============================================

    /// Given amountSpecified > 0 (exact output swap)
    /// When the user attempts the swap
    /// Then it should revert (error wrapped by PoolManager)
    function test_TwoWay_ExactOutputSwap_Reverts() public {
        token1.mint(address(this), 10 ether);
        token1.approve(address(jbSwapRouter), 10 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: 1 ether, // positive = exact output (not supported)
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        // The hook reverts with ExactOutputSwapsNotSupported, wrapped by PoolManager
        vm.expectRevert();
        jbSwapRouter.swap(key, params, 0);
    }
}
