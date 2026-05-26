// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "../utils/JuiceboxSwapRouter.sol";
import {
    MockJBTokens_RegressionGaps,
    MockJBDirectory_RegressionGaps,
    MockJBMultiTerminal_RegressionGaps,
    MockJBController_RegressionGaps,
    MockJBPrices_RegressionGaps,
    MockJBTerminalStore_RegressionGaps
} from "../TestRegressionGaps.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";

contract RegressionLargeTradeMisrouteTest is Test {
    using PoolIdLibrary for PoolKey;

    JBUniswapV4Hook internal hook;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTokens_RegressionGaps internal mockJBTokens;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBDirectory_RegressionGaps internal mockJBDirectory;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBMultiTerminal_RegressionGaps internal mockJBMultiTerminal;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBController_RegressionGaps internal mockJBController;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBPrices_RegressionGaps internal mockJBPrices;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTerminalStore_RegressionGaps internal mockJBTerminalStore;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    JuiceboxSwapRouter internal jbSwapRouter;

    MockERC20 internal paymentToken;
    MockERC20 internal projectToken;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);

        mockJBTokens = new MockJBTokens_RegressionGaps();
        mockJBDirectory = new MockJBDirectory_RegressionGaps();
        mockJBMultiTerminal = new MockJBMultiTerminal_RegressionGaps();
        mockJBController = new MockJBController_RegressionGaps();
        mockJBPrices = new MockJBPrices_RegressionGaps();
        mockJBTerminalStore = new MockJBTerminalStore_RegressionGaps();

        mockJBDirectory.setMockTerminal(address(mockJBMultiTerminal));
        mockJBDirectory.setMockController(address(mockJBController));
        mockJBMultiTerminal.setTerminalStore(address(mockJBTerminalStore));

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

        paymentToken = new MockERC20("Payment", "PAY");
        projectToken = new MockERC20("Project", "PRJ");

        if (address(paymentToken) > address(projectToken)) {
            (paymentToken, projectToken) = (projectToken, paymentToken);
        }

        mockJBTokens.setProjectId(address(projectToken), 123);
        mockJBController.setWeight(123, 0.5 ether);
        mockJBMultiTerminal.setProjectToken(123, address(projectToken));
        mockJBMultiTerminal.setPayReturnAmount(5 ether);
        mockJBPrices.setPricePerUnitOf(123, 1, uint32(uint160(address(paymentToken))), 1e18);

        key = PoolKey({
            currency0: Currency.wrap(address(paymentToken)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        paymentToken.mint(address(this), 100 ether);
        projectToken.mint(address(this), 100 ether);

        paymentToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        projectToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        paymentToken.approve(address(jbSwapRouter), type(uint256).max);
        projectToken.approve(address(jbSwapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120_000, tickUpper: 120_000, liquidityDelta: 1 ether, salt: 0}),
            bytes("")
        );
    }

    function test_largeBuyCanMisrouteToV4BelowJBQuote() public {
        uint256 amountIn = 10 ether;
        uint256 jbQuote = hook.calculateExpectedTokensWithCurrency(123, address(paymentToken), amountIn);
        uint256 v4Estimate = hook.estimateUniswapOutput(id, key, amountIn, true);

        assertEq(jbQuote, 5 ether, "sanity: configured JB quote");
        assertGt(v4Estimate, jbQuote, "router must prefer the inflated V4 estimate");

        uint256 balanceBefore = projectToken.balanceOf(address(this));
        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                // Safe: `amountIn` is a test constant (`10 ether`) and fits comfortably in int256.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            0
        );
        uint256 received = projectToken.balanceOf(address(this)) - balanceBefore;

        assertEq(mockJBMultiTerminal.lastProjectId(), 0, "the hook routed through V4 instead of Juicebox");
        assertLt(received, jbQuote, "the user received less than the available JB mint path");
    }
}
