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

import {IJBFeeTerminal} from "@bananapus/core-v6/src/interfaces/IJBFeeTerminal.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "../utils/JuiceboxSwapRouter.sol";
import {
    MockJBController_RegressionGaps,
    MockJBDirectory_RegressionGaps,
    MockJBMultiTerminal_RegressionGaps,
    MockJBPrices_RegressionGaps,
    MockJBTerminalStore_RegressionGaps,
    MockJBTokens_RegressionGaps
} from "../TestRegressionGaps.sol";

/// @notice Regression test: when the project terminal reports `FEE() > JBConstants.MAX_FEE`,
/// `JBUniswapV4Hook.calculateExpectedOutputFromSelling` must return 0 so the JB sell path is treated as ineligible
/// and the swap degrades to V4. Previously the function would underflow (or revert), DoSing the sell route.
contract RegressionInvalidFeeSellDoSTest is Test {
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

    uint256 internal constant PROJECT_ID = 123;

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

        bytes memory constructorArgs = abi.encode(
            manager,
            IJBTokens(address(mockJBTokens)),
            IJBDirectory(address(mockJBDirectory)),
            IJBPrices(address(mockJBPrices))
        );
        (, bytes32 salt) = HookMiner.find({
            deployer: address(this),
            flags: flags,
            creationCode: type(JBUniswapV4Hook).creationCode,
            constructorArgs: constructorArgs
        });

        hook = new JBUniswapV4Hook{salt: salt}(
            manager,
            IJBTokens(address(mockJBTokens)),
            IJBDirectory(address(mockJBDirectory)),
            IJBPrices(address(mockJBPrices))
        );

        paymentToken = new MockERC20("Payment", "PAY");
        projectToken = new MockERC20("Project", "PRJ");
        if (address(projectToken) > address(paymentToken)) {
            (projectToken, paymentToken) = (paymentToken, projectToken);
        }

        mockJBTokens.setProjectId({token: address(projectToken), projectId: PROJECT_ID});
        mockJBMultiTerminal.setProjectToken({projectId: PROJECT_ID, projectToken: address(projectToken)});

        key = PoolKey({
            currency0: Currency.wrap(address(projectToken)),
            currency1: Currency.wrap(address(paymentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        manager.initialize({key: key, sqrtPriceX96: TickMath.getSqrtPriceAtTick(0)});

        paymentToken.mint(address(this), 100 ether);
        projectToken.mint(address(this), 100 ether);
        paymentToken.approve({spender: address(modifyLiquidityRouter), value: type(uint256).max});
        projectToken.approve({spender: address(modifyLiquidityRouter), value: type(uint256).max});
        projectToken.approve({spender: address(jbSwapRouter), value: type(uint256).max});

        modifyLiquidityRouter.modifyLiquidity({
            key: key,
            params: ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            hookData: bytes("")
        });

        // Configure the terminal-store preview path so calculateExpectedOutputFromSelling reaches the FEE() branch.
        mockJBMultiTerminal.setPayReturnAmount(1 ether);
    }

    /// @notice When the terminal reports a fee above MAX_FEE, the JB sell estimator returns 0 (treating the JB
    /// route as ineligible) instead of underflowing.
    function test_calculateExpectedOutputFromSelling_returnsZeroWhenFeeExceedsMax() public {
        // Override FEE() to return 1001 (> MAX_FEE = 1000).
        vm.mockCall({
            callee: address(mockJBMultiTerminal),
            data: abi.encodeWithSelector(IJBFeeTerminal.FEE.selector),
            returnData: abi.encode(uint256(1001))
        });

        uint256 result = hook.calculateExpectedOutputFromSelling({
            projectId: PROJECT_ID,
            tokenAmountIn: 1 ether,
            outputToken: address(paymentToken),
            terminal: IJBFeeTerminal(address(mockJBMultiTerminal))
        });

        assertEq(result, 0, "JB sell estimate must be 0 when fee > MAX_FEE (RISKS section 9 fall-through)");
    }
}
