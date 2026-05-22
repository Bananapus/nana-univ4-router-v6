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
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
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
    MockJBPrices_RegressionGaps,
    MockJBTerminalStore_RegressionGaps
} from "../TestRegressionGaps.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";

contract RevertingSellPreviewTerminal {
    uint256 public lastProjectId;
    address public lastToken;
    uint256 public lastAmount;
    address public lastBeneficiary;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTerminalStore_RegressionGaps public TERMINAL_STORE;

    function setTerminalStore(address terminalStore) external {
        TERMINAL_STORE = MockJBTerminalStore_RegressionGaps(terminalStore);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        pure
        returns (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256, JBPayHookSpecification[] memory)
    {
        return (ruleset, beneficiaryTokenCount, 0, new JBPayHookSpecification[](0));
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
        revert("preview disabled");
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

        uint256 outputAmount = TERMINAL_STORE.currentReclaimableSurplusOf(
                projectId,
                1 ether,
                // forge-lint: disable-next-line(unsafe-typecast)
                uint32(uint160(tokenToReclaim)),
                18
            ) * cashOutCount / 1 ether;
        require(outputAmount >= minTokensReclaimed, "Insufficient tokens reclaimed");

        if (outputAmount > 0) {
            MockERC20(tokenToReclaim).mint(beneficiary, outputAmount);
        }

        return outputAmount;
    }

    function resetLastCall() external {
        lastProjectId = 0;
        lastToken = address(0);
        lastAmount = 0;
        lastBeneficiary = address(0);
    }
}

contract RegressionSellPreviewFallbackTest is Test {
    using PoolIdLibrary for PoolKey;

    JBUniswapV4Hook internal hook;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTokens_RegressionGaps internal mockJBTokens;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBDirectory_RegressionGaps internal mockJBDirectory;
    RevertingSellPreviewTerminal internal mockTerminal;
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

    function setUp() public {
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);

        mockJBTokens = new MockJBTokens_RegressionGaps();
        mockJBDirectory = new MockJBDirectory_RegressionGaps();
        mockTerminal = new RevertingSellPreviewTerminal();
        mockJBController = new MockJBController_RegressionGaps();
        mockJBPrices = new MockJBPrices_RegressionGaps();
        mockJBTerminalStore = new MockJBTerminalStore_RegressionGaps();

        mockJBDirectory.setMockTerminal(address(mockTerminal));
        mockJBDirectory.setMockController(address(mockJBController));
        mockTerminal.setTerminalStore(address(mockJBTerminalStore));

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

        paymentToken = new MockERC20("Payment", "PAY");
        projectToken = new MockERC20("Project", "PRJ");
        if (address(paymentToken) > address(projectToken)) {
            (paymentToken, projectToken) = (projectToken, paymentToken);
        }

        mockJBTokens.setProjectId(address(projectToken), 123);
        mockJBController.setWeight(123, 1 ether);
        mockJBTerminalStore.setSurplus(123, address(paymentToken), 5 ether);

        key = PoolKey({
            currency0: Currency.wrap(address(paymentToken)),
            currency1: Currency.wrap(address(projectToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        paymentToken.mint(address(this), 100 ether);
        projectToken.mint(address(this), 100 ether);

        paymentToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        projectToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        paymentToken.approve(address(jbSwapRouter), type(uint256).max);
        projectToken.approve(address(jbSwapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120_000, tickUpper: 120_000, liquidityDelta: 10 ether, salt: 0}),
            bytes("")
        );
    }

    function test_sellSidePreviewRevertForcesWorseV4Route() public {
        uint256 amountIn = 1 ether;

        uint256 v4Estimate = hook.estimateUniswapOutput(key.toId(), key, amountIn, false);
        uint256 quotedSellOutput = hook.calculateExpectedOutputFromSelling(
            123, amountIn, address(paymentToken), IJBTerminal(address(mockTerminal))
        );
        uint256 liveCashOutOutput = mockTerminal.cashOutTokensOf(
            address(this), 123, amountIn, address(paymentToken), 0, payable(address(this)), bytes(""), 0
        );

        assertEq(quotedSellOutput, 0, "preview revert zeroes the JB sell quote");
        assertGt(liveCashOutOutput, v4Estimate, "live JB sell path should beat the V4 estimate");
        mockTerminal.resetLastCall();

        uint256 paymentBalanceBefore = paymentToken.balanceOf(address(this));

        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            0
        );

        uint256 received = paymentToken.balanceOf(address(this)) - paymentBalanceBefore;

        assertEq(mockTerminal.lastProjectId(), 0, "router should not have executed the JB sell path");
        assertLt(received, liveCashOutOutput, "router still picked the worse V4 path after preview reverted");
    }
}
