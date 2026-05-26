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

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "../utils/JuiceboxSwapRouter.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// ============================================
// Mock contracts for sell-path reentrancy test
// ============================================

/// @notice Mock JBTokens that maps token addresses to project IDs.
contract MockJBTokensReentrancy {
    mapping(address => uint256) public projectIdOf;

    function setProjectId(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
    }
}

/// @notice Mock JBDirectory that returns configurable terminal and controller addresses.
contract MockJBDirectoryReentrancy {
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

/// @notice Mock JBPrices that returns configurable prices.
contract MockJBPricesReentrancy {
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

/// @notice Mock JBController that returns configurable rulesets.
contract MockJBControllerReentrancy {
    mapping(uint256 => uint256) public weights;
    mapping(uint256 => uint16) public cashOutTaxRates;
    mapping(uint256 => bool) public useDataHookForCashOuts;

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function setCashOutTaxRate(uint256 projectId, uint16 rate) external {
        cashOutTaxRates[projectId] = rate;
    }

    function setUseDataHookForCashOut(uint256 projectId, bool flag) external {
        useDataHookForCashOuts[projectId] = flag;
    }

    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        metadata = JBRulesetMetadata({
            reservedPercent: 0,
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
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: false,
            useDataHookForCashOut: useDataHookForCashOuts[projectId],
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

/// @notice Mock terminal store that returns a large surplus so JB route is chosen over V4.
contract MockStoreReentrancy {
    uint256 public fixedSurplus;
    uint256 public previewReclaimAmount;
    bool public usePreviewOverride;

    function setFixedSurplus(uint256 surplus) external {
        fixedSurplus = surplus;
    }

    function setPreviewReclaimAmount(uint256 reclaimAmount) external {
        previewReclaimAmount = reclaimAmount;
        usePreviewOverride = true;
    }

    function currentReclaimableSurplusOf(uint256, uint256, uint256, uint256) external view returns (uint256) {
        return fixedSurplus;
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
        view
        returns (uint256)
    {
        return fixedSurplus;
    }

    function currentTotalReclaimableSurplusOf(uint256, uint256, uint256, uint256) external view returns (uint256) {
        return fixedSurplus;
    }

    function previewCashOutFrom(
        address,
        address,
        uint256,
        uint256,
        address,
        bool,
        bytes calldata
    )
        external
        view
        returns (JBRuleset memory, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        return (
            JBRuleset({
                cycleNumber: 0,
                id: 0,
                basedOnId: 0,
                start: 0,
                duration: 0,
                weight: 0,
                weightCutPercent: 0,
                approvalHook: IJBRulesetApprovalHook(address(0)),
                metadata: 0
            }),
            usePreviewOverride ? previewReclaimAmount : fixedSurplus,
            0,
            new JBCashOutHookSpecification[](0)
        );
    }
}

/// @notice Malicious terminal that attempts reentrancy during cashOutTokensOf.
///
/// When the hook routes a sell-side swap through Juicebox, it calls this terminal's
/// cashOutTokensOf. This terminal then attempts a second swap through the PoolManager,
/// which triggers the hook's _beforeSwap again. Since _routing is true at that point,
/// the re-entrant swap should revert with JBUniswapV4Hook_ReentrantRouting.
contract ReentrantSellTerminal {
    IPoolManager public immutable PM;
    MockStoreReentrancy public immutable MOCK_STORE;
    PoolKey public reentrantPoolKey;
    bool public reentrancyAttempted;
    bool public reentrancySucceeded;

    constructor(IPoolManager _pm, MockStoreReentrancy _store) {
        PM = _pm;
        MOCK_STORE = _store;
    }

    function setPoolKey(PoolKey memory _key) external {
        reentrantPoolKey = _key;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25; // 2.5%
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function STORE() external view returns (IJBTerminalStore) {
        return IJBTerminalStore(address(MOCK_STORE));
    }

    /// @notice pay() is not expected on the sell path, but included for interface completeness.
    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 0;
    }

    /// @notice cashOutTokensOf attempts a re-entrant swap through the same pool.
    ///
    /// The hook sets _routing = true before calling this function. When we attempt another
    /// swap, the hook's _beforeSwap checks _routing and should revert with
    /// JBUniswapV4Hook_ReentrantRouting.
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
        returns (uint256)
    {
        reentrancyAttempted = true;

        // Attempt re-entrant swap. We are inside PoolManager.unlock context (from the outer swap),
        // so we can call PM.swap directly. The hook's _beforeSwap will see _routing == true and revert.
        PoolKey memory k = reentrantPoolKey;
        PM.swap(
            k,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            abi.encode(uint256(0))
        );

        // If we reach here, reentrancy was not blocked
        reentrancySucceeded = true;
        return 0;
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        return contexts;
    }

    function previewCashOutFrom(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address payable,
        bytes calldata metadata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        return MOCK_STORE.previewCashOutFrom(
            address(this), holder, projectId, cashOutCount, tokenToReclaim, false, metadata
        );
    }

    receive() external payable {}
}

// ============================================
// Sell-path reentrancy test
// ============================================

/// @title SellPathReentrancyTest
/// @notice Verifies that the _routing reentrancy guard in JBUniswapV4Hook blocks re-entrant
/// swaps triggered from inside cashOutTokensOf on the sell path.
///
/// The buy-path reentrancy (via pay()) is tested in JBUniswapV4Hook.t.sol. This test covers
/// the sell-path where a malicious terminal attempts to re-enter the hook during cashOutTokensOf.
///
/// Flow:
///   1. User sells JB tokens (token0) for counter-asset (token1) via the hook
///   2. Hook determines JB cashout is better than V4 pool
///   3. Hook sets _routing = true and calls terminal.cashOutTokensOf()
///   4. Malicious terminal attempts another swap through the same PoolManager
///   5. Hook's _beforeSwap sees _routing == true and reverts with ReentrantRouting
///   6. The entire transaction reverts (the try-catch is NOT in the hook's sell path;
///      _routeThroughJuicebox does NOT wrap cashOutTokensOf in try-catch)
contract SellPathReentrancyTest is Test {
    receive() external payable {}

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    JBUniswapV4Hook hook;
    MockJBTokensReentrancy mockJbTokens;
    MockJBDirectoryReentrancy mockJbDirectory;
    MockJBControllerReentrancy mockJbController;
    MockJBPricesReentrancy mockJbPrices;
    MockStoreReentrancy mockStore;
    ReentrantSellTerminal reentrantTerminal;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    JuiceboxSwapRouter jbSwapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    bytes constant ZERO_BYTES = "";
    uint256 constant PROJECT_ID = 42;

    MockERC20 token0; // JB project token (will be sold)
    MockERC20 token1; // Counter-asset (output)
    PoolKey key;
    PoolId id;

    function setUp() public {
        vm.warp(10_000);

        // Deploy V4 infrastructure
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        swapRouter = new PoolSwapTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy JB mocks
        mockJbTokens = new MockJBTokensReentrancy();
        mockJbDirectory = new MockJBDirectoryReentrancy();
        mockJbController = new MockJBControllerReentrancy();
        mockJbPrices = new MockJBPricesReentrancy();
        mockStore = new MockStoreReentrancy();

        // Deploy reentrant terminal
        reentrantTerminal = new ReentrantSellTerminal(manager, mockStore);

        // Wire up directory
        mockJbDirectory.setMockTerminal(address(reentrantTerminal));
        mockJbDirectory.setMockController(address(mockJbController));

        // Deploy hook with address-mined salt
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            manager,
            IJBTokens(address(mockJbTokens)),
            IJBDirectory(address(mockJbDirectory)),
            IJBPrices(address(mockJbPrices))
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(
            manager,
            IJBTokens(address(mockJbTokens)),
            IJBDirectory(address(mockJbDirectory)),
            IJBPrices(address(mockJbPrices))
        );

        // Create tokens, ensuring correct ordering
        token0 = new MockERC20("JBToken", "JBT");
        token1 = new MockERC20("CounterAsset", "CA");

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Configure JB project: token0 is the project token being sold
        mockJbTokens.setProjectId(address(token0), PROJECT_ID);
        mockJbController.setWeight(PROJECT_ID, 1000e18);
        // Set a cashOutTaxRate for realistic bonding curve behavior.
        mockJbController.setCashOutTaxRate(PROJECT_ID, 5000); // 50%

        // Set price feed: 1:1 between token1 and base currency
        uint32 token1CurrencyId = uint32(uint160(address(token1)));
        mockJbPrices.setPricePerUnitOf(PROJECT_ID, token1CurrencyId, 1, 1e18);

        // Configure store to return large surplus so JB route beats V4
        // With 1 ether sell and ~0.997 V4 output, a surplus of 100 ether ensures JB wins
        mockStore.setFixedSurplus(100 ether);

        // Give terminal the pool key for the re-entrant swap attempt
        // (We set this after pool creation, see below)

        // Set up V4 pool at 1:1 price
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        // Set the pool key on the reentrant terminal
        reentrantTerminal.setPoolKey(key);

        // Mint and approve tokens for liquidity
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);
        token0.approve(address(modifyLiquidityRouter), 1000 ether);
        token1.approve(address(modifyLiquidityRouter), 1000 ether);

        // Approve hook for settlement
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        // Initialize pool
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add liquidity to V4 pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    /// @notice Sell-path reentrancy: a malicious terminal's cashOutTokensOf attempts a
    /// re-entrant swap. The _routing guard should block it.
    ///
    /// Given a reentrant terminal that attempts another swap during cashOutTokensOf
    /// And the sell-side swap routes through Juicebox (JB output > V4)
    /// When the terminal triggers a second swap from inside cashOutTokensOf
    /// Then the _routing guard blocks the reentrant swap
    /// And the entire transaction reverts
    function test_sellPathReentrancy_revertsWithRoutingGuard() public {
        // Prepare: mint JB tokens (token0) to sell
        token0.mint(address(this), 1 ether);
        token0.approve(address(jbSwapRouter), 1 ether);

        // Sell JB tokens: zeroForOne = true (selling token0 for token1)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether, // exact input: sell 1 ether of token0
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // The swap should revert because:
        // 1. Hook routes sell-side through JB (surplus=100 ether >> V4 ~0.997 ether)
        // 2. Hook sets _routing = true
        // 3. Hook calls reentrantTerminal.cashOutTokensOf()
        // 4. Terminal attempts PM.swap() which triggers hook._beforeSwap
        // 5. _beforeSwap sees _routing == true, reverts JBUniswapV4Hook_ReentrantRouting
        // 6. PoolManager wraps the error in WrappedError and the entire transaction unwinds
        //
        // Note: We use vm.expectRevert() without args because PoolManager wraps the hook's
        // JBUniswapV4Hook_ReentrantRouting error inside a WrappedError(address,bytes4,bytes,bytes4)
        // whose encoding includes the hook address (deterministic but fragile to match exactly).
        vm.expectRevert();
        jbSwapRouter.swap(key, params, 0);

        // Verify the terminal did attempt reentrancy (it was called)
        // Note: since the entire tx reverted, storage changes in the terminal are also rolled back.
        // We can't check reentrancyAttempted here because the revert unwound everything.
        // The vm.expectRevert() above is the primary assertion.
    }

    /// @notice Verifies that a non-reentrant sell-side swap succeeds when the terminal does NOT
    /// attempt reentrancy. This confirms the _routing guard only blocks actual reentrant calls
    /// and does not interfere with normal operation.
    ///
    /// Uses the same setup but with a well-behaved terminal that simply returns tokens.
    function test_sellPathNonReentrant_succeedsNormally() public {
        // Deploy a well-behaved terminal that does not attempt reentrancy
        WellBehavedSellTerminal goodTerminal = new WellBehavedSellTerminal(mockStore);
        goodTerminal.setProjectToken(PROJECT_ID, address(token0));
        mockJbDirectory.setMockTerminal(address(goodTerminal));

        // Prepare: mint JB tokens (token0) to sell
        token0.mint(address(this), 1 ether);
        token0.approve(address(jbSwapRouter), 1 ether);

        // Sell JB tokens
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        // This should succeed: JB route is chosen (surplus=100 ether >> V4) and the terminal
        // does not attempt reentrancy, so _routing guard does not fire.
        jbSwapRouter.swap(key, params, 0);

        // Verify the terminal was called
        assertEq(goodTerminal.lastProjectId(), PROJECT_ID, "Terminal should have been called with correct project ID");
        assertGt(goodTerminal.lastCashOutCount(), 0, "Terminal should have processed a cash out");
    }

    /// @notice Projects that opt into cash-out data-hook overrides are not sell-side best-execution candidates.
    /// The hook should decline JB routing and let the V4 pool handle the swap instead of relying on a stale static
    /// terminal-store estimate.
    function test_sellPathWithCashOutDataHook_prefersV4OverPreviewedJBEstimate() public {
        mockJbController.setUseDataHookForCashOut(PROJECT_ID, true);
        mockStore.setPreviewReclaimAmount(0);

        token0.mint(address(this), 1 ether);
        token0.approve(address(jbSwapRouter), 1 ether);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        uint256 balanceBefore = token1.balanceOf(address(this));
        jbSwapRouter.swap(key, params, 0);
        uint256 balanceAfter = token1.balanceOf(address(this));

        assertGt(balanceAfter, balanceBefore, "swap should execute through V4");
        assertFalse(reentrantTerminal.reentrancyAttempted(), "sell path should not route through JB");
    }
}

/// @notice Well-behaved terminal that performs cashOutTokensOf without reentrancy.
/// Used as a control test to verify normal sell-side routing works when no reentrancy occurs.
contract WellBehavedSellTerminal {
    MockStoreReentrancy public immutable MOCK_STORE;

    uint256 public lastProjectId;
    uint256 public lastCashOutCount;
    mapping(uint256 => address) public projectTokens;

    constructor(MockStoreReentrancy _store) {
        MOCK_STORE = _store;
    }

    function setProjectToken(uint256 projectId, address projectToken) external {
        projectTokens[projectId] = projectToken;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function STORE() external view returns (IJBTerminalStore) {
        return IJBTerminalStore(address(MOCK_STORE));
    }

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 0;
    }

    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256,
        address payable beneficiary,
        bytes calldata,
        uint256 /* referralProjectId */
    )
        external
        returns (uint256)
    {
        lastProjectId = projectId;
        lastCashOutCount = cashOutCount;

        // Well-behaved: just mint the output tokens and return (no reentrancy)
        uint256 outputAmount = MOCK_STORE.fixedSurplus();
        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && cashOutCount != 0) {
            MockERC20(projectToken).burn(holder, cashOutCount);
        }
        if (outputAmount > 0) {
            MockERC20(tokenToReclaim).mint(beneficiary, outputAmount);
        }
        return outputAmount;
    }

    function accountingContextsOf(uint256) external pure returns (JBAccountingContext[] memory contexts) {
        return contexts;
    }

    function previewCashOutFrom(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address payable,
        bytes calldata metadata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        return MOCK_STORE.previewCashOutFrom(
            address(this), holder, projectId, cashOutCount, tokenToReclaim, false, metadata
        );
    }

    receive() external payable {}
}
