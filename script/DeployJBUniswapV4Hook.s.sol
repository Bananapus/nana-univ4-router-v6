// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {JBUniswapV4Hook} from "../src/JBUniswapV4Hook.sol";

/// @title DeployJBUniswapV4Hook
/// @notice Script to deploy the JBUniswapV4Hook with multi-currency support
contract DeployJBUniswapV4Hook is Script {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    function run() external {
        // Get the pool manager address from environment.
        address poolManager = vm.envOr("POOL_MANAGER", address(0));
        require(poolManager != address(0), "POOL_MANAGER environment variable not set");

        // Get the core deployment addresses.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deploying JBUniswapV4Hook with:");
        console2.log("  Deployer:", deployer);
        console2.log("  Pool Manager:", poolManager);
        console2.log("  JB Tokens:", address(core.tokens));
        console2.log("  JB Directory:", address(core.directory));
        console2.log("  JB Prices:", address(core.prices));

        vm.startBroadcast(deployerPrivateKey);

        // Calculate the required flags for the hook permissions.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        // Prepare constructor arguments.
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), core.tokens, core.directory, core.prices);

        // Find a valid hook address using HookMiner.
        (address hookAddress, bytes32 salt) = HookMiner.find({
            deployer: deployer,
            flags: flags,
            creationCode: type(JBUniswapV4Hook).creationCode,
            constructorArgs: constructorArgs
        });

        console2.log("Found hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));

        // Deploy the hook with the mined address.
        JBUniswapV4Hook hook = new JBUniswapV4Hook{salt: salt}({
            poolManager: IPoolManager(poolManager), tokens: core.tokens, directory: core.directory, prices: core.prices
        });

        console2.log("JBUniswapV4Hook deployed at:", address(hook));

        // Verify the hook permissions.
        Hooks.Permissions memory deployedPermissions = hook.getHookPermissions();
        console2.log("Hook permissions:");
        console2.log("  beforeSwap:", deployedPermissions.beforeSwap);
        console2.log("  afterSwap:", deployedPermissions.afterSwap);

        vm.stopBroadcast();

        // Save deployment info.
        string memory deploymentInfo = string(
            abi.encodePacked(
                "JBUniswapV4Hook deployed at: ",
                vm.toString(address(hook)),
                "\nDeployer: ",
                vm.toString(deployer),
                "\nJBPrices: ",
                vm.toString(address(core.prices))
            )
        );

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile("deployments/JBUniswapV4Hook.txt", deploymentInfo);
        console2.log("Deployment info saved to deployments/JBUniswapV4Hook.txt");
    }
}
