// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BaseScript} from "./base/BaseScript.sol";

contract SwapScript is BaseScript {
    function run() external {
        PoolKey memory poolKey = PoolKey({
            currency0: CURRENCY0,
            currency1: CURRENCY1,
            fee: 3000,
            tickSpacing: 60,
            hooks: HOOK_CONTRACT // This must match the pool
        });
        bytes memory hookData = new bytes(0);

        vm.startBroadcast();

        // We'll approve both, just for testing.
        TOKEN1.approve(address(SWAP_ROUTER), type(uint256).max);
        TOKEN0.approve(address(SWAP_ROUTER), type(uint256).max);

        // Execute swap
        SWAP_ROUTER.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0, // Very bad, but we want to allow for unlimited price impact
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 30
        });

        vm.stopBroadcast();
    }
}
