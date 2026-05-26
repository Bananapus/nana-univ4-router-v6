// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";

contract MockTokensRegression {
    function projectIdOf(IJBToken) external pure returns (uint256) {
        return 0;
    }
}

contract DummyRegression {}

contract RegressionHookDataLengthTest is Test {
    address internal constant POOL_MANAGER = address(0xBEEF);

    JBUniswapV4Hook internal hook;
    PoolKey internal key;
    SwapParams internal params;
    MockTokensRegression internal tokens;
    DummyRegression internal directory;
    DummyRegression internal prices;

    function setUp() public {
        tokens = new MockTokensRegression();
        directory = new DummyRegression();
        prices = new DummyRegression();

        bytes memory constructorArgs = abi.encode(address(this));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(address(this));
        hook.setChainSpecificConstants({
            newPoolManager: IPoolManager(POOL_MANAGER),
            newTokens: IJBTokens(address(tokens)),
            newDirectory: IJBDirectory(address(directory)),
            newPrices: IJBPrices(address(prices))
        });

        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
    }

    function test_beforeSwap_acceptsPlainAmountOutMinForPureV4Swap() public {
        vm.prank(POOL_MANAGER);
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(this), key, params, abi.encode(1));

        assertEq(selector, hook.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(fee, 0);
    }

    function test_beforeSwap_acceptsExtraMetadataWhenNoJBTokenIsInvolved() public {
        bytes memory hookData = abi.encode(uint256(1), uint256(2));

        vm.prank(POOL_MANAGER);
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(address(this), key, params, hookData);

        assertEq(selector, hook.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(fee, 0);
    }
}
