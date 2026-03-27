// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "../utils/JuiceboxSwapRouter.sol";
import {
    MockJBTokens_AuditGaps,
    MockJBDirectory_AuditGaps,
    MockJBMultiTerminal_AuditGaps,
    MockJBController_AuditGaps,
    MockJBPrices_AuditGaps,
    MockJBTerminalStore_AuditGaps
} from "../TestAuditGaps.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";

contract RevertingDecimalsERC20 is MockERC20 {
    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}

    function decimals() public pure override returns (uint8) {
        revert("NO_DECIMALS_METADATA");
    }
}

contract JBUniswapV4HookDecimalsTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    JBUniswapV4Hook internal hook;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTokens_AuditGaps internal mockJBTokens;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBDirectory_AuditGaps internal mockJBDirectory;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBMultiTerminal_AuditGaps internal mockJBMultiTerminal;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBController_AuditGaps internal mockJBController;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBPrices_AuditGaps internal mockJBPrices;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTerminalStore_AuditGaps internal mockJBTerminalStore;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    JuiceboxSwapRouter internal jbSwapRouter;

    MockERC20 internal projectToken;
    RevertingDecimalsERC20 internal paymentToken;
    PoolKey internal key;
    PoolId internal id;
    bool internal zeroForOne;

    function setUp() public {
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);

        mockJBTokens = new MockJBTokens_AuditGaps();
        mockJBDirectory = new MockJBDirectory_AuditGaps();
        mockJBMultiTerminal = new MockJBMultiTerminal_AuditGaps();
        mockJBController = new MockJBController_AuditGaps();
        mockJBPrices = new MockJBPrices_AuditGaps();
        mockJBTerminalStore = new MockJBTerminalStore_AuditGaps();

        mockJBDirectory.setMockTerminal(address(mockJBMultiTerminal));
        mockJBDirectory.setMockController(address(mockJBController));
        mockJBMultiTerminal.setTerminalStore(address(mockJBTerminalStore));

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

        projectToken = new MockERC20("Project", "PRJ");
        paymentToken = new RevertingDecimalsERC20("Broken USD", "bUSD");

        mockJBTokens.setProjectId(address(projectToken), 123);
        mockJBController.setWeight(123, 1000e18);
        mockJBMultiTerminal.setProjectToken(123, address(projectToken));
        mockJBMultiTerminal.setPayReturnAmount(1000e18);
        mockJBPrices.setPricePerUnitOf(123, 1, uint32(uint160(address(paymentToken))), 1e18);

        // A pool priced just above the hook's under-quoted buy-side estimate (~1e9 raw project units).
        if (address(paymentToken) < address(projectToken)) {
            key = PoolKey({
                currency0: Currency.wrap(address(paymentToken)),
                currency1: Currency.wrap(address(projectToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            zeroForOne = true;
            manager.initialize(key, TickMath.getSqrtPriceAtTick(76_000));
        } else {
            key = PoolKey({
                currency0: Currency.wrap(address(projectToken)),
                currency1: Currency.wrap(address(paymentToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            zeroForOne = false;
            manager.initialize(key, TickMath.getSqrtPriceAtTick(-76_000));
        }

        id = key.toId();

        projectToken.mint(address(this), 1_000_000_000_000_000 ether);
        paymentToken.mint(address(this), 1_000_000_000_000_000 * 1e6);

        projectToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        paymentToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        projectToken.approve(address(jbSwapRouter), type(uint256).max);
        paymentToken.approve(address(jbSwapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120_000, tickUpper: 120_000, liquidityDelta: 1000 ether, salt: 0}),
            bytes("")
        );
    }

    function test_BuyQuote_IgnoresNonStandardPaymentTokenDecimals_AndRoutesToWorseV4Path() public {
        uint256 amountIn = 1e6; // 1 payment token when terminal accounting context is 6 decimals.

        uint256 hookQuote = hook.calculateExpectedTokensWithCurrency(123, address(paymentToken), amountIn);
        uint256 actualTerminalMint = mockJBMultiTerminal.overridePayReturnAmount();
        uint256 v4Quote = hook.estimateUniswapOutput(id, key, amountIn, zeroForOne);

        assertEq(hookQuote, 1_000_000_000, "Hook should fall back to 18 decimals and under-quote the buy path");
        assertGt(v4Quote, hookQuote, "Pool quote must beat the hook's stale under-quote");
        assertGt(actualTerminalMint, v4Quote, "Actual terminal pay path should mint materially more than V4");

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        jbSwapRouter.swap(key, params, 0);

        assertEq(mockJBMultiTerminal.lastProjectId(), 0, "Misquote should route through V4 instead of terminal.pay");
    }
}

contract JBUniswapV4HookProtocolFeeTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    JBUniswapV4Hook internal hook;
    MockJBTokens_AuditGaps internal mockJBTokens;
    MockJBDirectory_AuditGaps internal mockJBDirectory;
    MockJBMultiTerminal_AuditGaps internal mockJBMultiTerminal;
    MockJBController_AuditGaps internal mockJBController;
    MockJBPrices_AuditGaps internal mockJBPrices;
    MockJBTerminalStore_AuditGaps internal mockJBTerminalStore;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    JuiceboxSwapRouter internal jbSwapRouter;

    MockERC20 internal projectToken;
    MockERC20 internal paymentToken;
    PoolKey internal key;
    PoolId internal id;
    bool internal zeroForOne;

    function setUp() public {
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);

        mockJBTokens = new MockJBTokens_AuditGaps();
        mockJBDirectory = new MockJBDirectory_AuditGaps();
        mockJBMultiTerminal = new MockJBMultiTerminal_AuditGaps();
        mockJBController = new MockJBController_AuditGaps();
        mockJBPrices = new MockJBPrices_AuditGaps();
        mockJBTerminalStore = new MockJBTerminalStore_AuditGaps();

        mockJBDirectory.setMockTerminal(address(mockJBMultiTerminal));
        mockJBDirectory.setMockController(address(mockJBController));
        mockJBMultiTerminal.setTerminalStore(address(mockJBTerminalStore));

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

        projectToken = new MockERC20("Project", "PRJ");
        paymentToken = new MockERC20("Payment", "PAY");

        mockJBTokens.setProjectId(address(projectToken), 456);
        mockJBController.setWeight(456, 996_500_000_000_000_000);
        mockJBMultiTerminal.setProjectToken(456, address(projectToken));
        mockJBMultiTerminal.setPayReturnAmount(996_500_000_000_000_000);
        mockJBPrices.setPricePerUnitOf(456, 1, uint32(uint160(address(paymentToken))), 1e18);

        if (address(paymentToken) < address(projectToken)) {
            key = PoolKey({
                currency0: Currency.wrap(address(paymentToken)),
                currency1: Currency.wrap(address(projectToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            zeroForOne = true;
        } else {
            key = PoolKey({
                currency0: Currency.wrap(address(projectToken)),
                currency1: Currency.wrap(address(paymentToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            zeroForOne = false;
        }

        manager.initialize(key, SQRT_PRICE_1_1);
        id = key.toId();

        manager.setProtocolFeeController(address(this));
        uint24 packedProtocolFee = zeroForOne ? 1000 : uint24(1000 << 12);
        manager.setProtocolFee(key, packedProtocolFee);

        projectToken.mint(address(this), 1_000_000 ether);
        paymentToken.mint(address(this), 1_000_000 ether);

        projectToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        paymentToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        projectToken.approve(address(jbSwapRouter), type(uint256).max);
        paymentToken.approve(address(jbSwapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 10_000 ether, salt: 0}),
            bytes("")
        );
    }

    /// @notice Verify that estimateUniswapOutput correctly includes the protocol fee.
    /// With the fix, the V4 quote should be lower than the JB quote, so routing
    /// correctly prefers the JB terminal pay path.
    function test_V4Quote_IncludesProtocolFee_AndRoutesToBetterJBPath() public {
        uint256 amountIn = 1 ether;

        uint256 hookQuote = hook.calculateExpectedTokensWithCurrency(456, address(paymentToken), amountIn);
        uint256 actualTerminalMint = mockJBMultiTerminal.overridePayReturnAmount();
        uint256 v4Quote = hook.estimateUniswapOutput(id, key, amountIn, zeroForOne);

        // With the fix: V4 quote now correctly includes protocol fee + LP fee,
        // so the V4 quote should be LOWER than the JB quote.
        assertEq(hookQuote, actualTerminalMint, "Static JB fallback quote should match the configured terminal mint");
        assertLt(v4Quote, hookQuote, "V4 quote with protocol fee should be lower than JB quote");

        // Now verify routing actually goes through Juicebox (the better path)
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        jbSwapRouter.swap(key, params, 0);

        // With the fix, routing should now correctly go to the JB terminal
        assertEq(mockJBMultiTerminal.lastProjectId(), 456, "Should route through Juicebox terminal (better path)");
    }

    /// @notice Verify that the protocol fee reduces the estimate compared to LP-fee-only.
    /// This test compares estimates with and without protocol fees on the same pool configuration.
    function test_ProtocolFee_ReducesEstimate() public {
        uint256 amountIn = 1 ether;

        // Get the current estimate (with protocol fee set to 1000 pips = 0.1%)
        uint256 estimateWithProtocolFee = hook.estimateUniswapOutput(id, key, amountIn, zeroForOne);

        // Remove the protocol fee
        manager.setProtocolFee(key, 0);

        // Get the estimate without protocol fee
        uint256 estimateWithoutProtocolFee = hook.estimateUniswapOutput(id, key, amountIn, zeroForOne);

        // The estimate with protocol fee should be strictly less than without
        assertLt(estimateWithProtocolFee, estimateWithoutProtocolFee, "Protocol fee should reduce the output estimate");

        // Verify the difference is approximately correct.
        // LP fee = 3000 pips (0.3%), protocol fee = 1000 pips (0.1%)
        // Combined swap fee = protocolFee + lpFee - (protocolFee * lpFee / 1e6)
        //                   = 1000 + 3000 - (1000 * 3000 / 1e6) = 3997 pips
        // Without protocol fee: output = amountIn * (1 - 3000/1e6) = 0.997 * amountIn
        // With protocol fee:    output = amountIn * (1 - 3997/1e6) = 0.996003 * amountIn
        // Difference should be about 0.000997 * amountIn
        uint256 difference = estimateWithoutProtocolFee - estimateWithProtocolFee;
        uint256 expectedDifference = amountIn * 997 / 1_000_000; // 0.0997% of input
        assertApproxEqAbs(
            difference,
            expectedDifference,
            1, // Allow 1 wei rounding
            "Difference should match expected protocol fee impact"
        );
    }
}
