// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "../utils/JuiceboxSwapRouter.sol";
import {
    MockJBTokens_RegressionGaps,
    MockJBDirectory_RegressionGaps,
    MockJBController_RegressionGaps,
    MockJBPrices_RegressionGaps
} from "../TestRegressionGaps.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";

contract ExtremeDecimalsERC20 is MockERC20 {
    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}

    function decimals() public pure override returns (uint8) {
        return type(uint8).max;
    }
}

contract RegressionBadDecimalsTest is Test {
    using PoolIdLibrary for PoolKey;

    JBUniswapV4Hook internal hook;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTokens_RegressionGaps internal mockJBTokens;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBDirectory_RegressionGaps internal mockJBDirectory;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBController_RegressionGaps internal mockJBController;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBPrices_RegressionGaps internal mockJBPrices;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    JuiceboxSwapRouter internal jbSwapRouter;

    MockERC20 internal projectToken;
    ExtremeDecimalsERC20 internal paymentToken;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);

        mockJBTokens = new MockJBTokens_RegressionGaps();
        mockJBDirectory = new MockJBDirectory_RegressionGaps();
        mockJBController = new MockJBController_RegressionGaps();
        mockJBPrices = new MockJBPrices_RegressionGaps();

        mockJBDirectory.setMockController(address(mockJBController));

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
        paymentToken = new ExtremeDecimalsERC20("Extreme", "XDEC");

        mockJBTokens.setProjectId(address(projectToken), 123);
        mockJBController.setWeight(123, 1000e18);
        mockJBPrices.setPricePerUnitOf(123, 1, uint32(uint160(address(paymentToken))), 1e18);

        if (address(paymentToken) < address(projectToken)) {
            key = PoolKey({
                currency0: Currency.wrap(address(paymentToken)),
                currency1: Currency.wrap(address(projectToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            manager.initialize(key, TickMath.getSqrtPriceAtTick(76_000));
        } else {
            key = PoolKey({
                currency0: Currency.wrap(address(projectToken)),
                currency1: Currency.wrap(address(paymentToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            manager.initialize(key, TickMath.getSqrtPriceAtTick(-76_000));
        }

        id = key.toId();

        projectToken.mint(address(this), 1_000_000 ether);
        paymentToken.mint(address(this), 1_000_000 ether);
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

    function test_buySideFallbackWithExtremeDecimalsDegradesToV4() public {
        uint256 v4Quote = hook.estimateUniswapOutput(id, key, 1 ether, address(paymentToken) < address(projectToken));
        assertGt(v4Quote, 0, "the V4 path should be otherwise live");

        assertEq(
            hook.calculateExpectedTokensWithCurrency(123, address(paymentToken), 1 ether),
            0,
            "extreme decimals should disable the static fallback quote"
        );

        uint256 balanceBefore = projectToken.balanceOf(address(this));
        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: address(paymentToken) < address(projectToken),
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: address(paymentToken) < address(projectToken)
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            0
        );

        assertGt(projectToken.balanceOf(address(this)) - balanceBefore, 0, "swap should still complete via V4");
    }
}
