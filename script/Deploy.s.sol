// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {JBUniswapV4Hook} from "src/JBUniswapV4Hook.sol";

contract DeployScript is Script {
    /// @notice the salts that are used to deploy the contracts.
    bytes32 uniswapV4Hook = "JBUniswapV4HookV6";

    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    /// @notice tracks the addresses that are required for the chain we are deploying to.
    address poolManager;

    function run() public {
        // Get the core deployment addresses.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        // Pool manager must be provided (V4 is still rolling out).
        poolManager = vm.envOr("POOL_MANAGER", address(0));
        require(poolManager != address(0), "POOL_MANAGER environment variable not set");

        deploy();
    }

    function deploy() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Calculate the required hook permission flags.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        // Prepare constructor arguments.
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), core.tokens, core.directory, core.prices);

        // Mine a valid hook address.
        (address hookAddress, bytes32 salt) =
            HookMiner.find(deployer, flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        console2.log("Deploying JBUniswapV4Hook to:", hookAddress);

        vm.startBroadcast(deployerPrivateKey);

        JBUniswapV4Hook hook =
            new JBUniswapV4Hook{salt: salt}(IPoolManager(poolManager), core.tokens, core.directory, core.prices);

        console2.log("JBUniswapV4Hook deployed at:", address(hook));

        vm.stopBroadcast();
    }
}
