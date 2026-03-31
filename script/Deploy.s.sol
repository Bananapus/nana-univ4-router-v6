// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {JBUniswapV4Hook} from "../src/JBUniswapV4Hook.sol";

contract DeployScript is Script {
    /// @notice Tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;

    function run() external {
        // Get the Uniswap V4 PoolManager address for this chain.
        address poolManager = _getPoolManager();

        // Get the core deployment addresses.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Calculate the required flags for the hook permissions.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        // Prepare constructor arguments.
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), core.tokens, core.directory, core.prices);

        // Mine a valid hook address.
        (address hookAddress, bytes32 salt) = HookMiner.find({
            deployer: deployer,
            flags: flags,
            creationCode: type(JBUniswapV4Hook).creationCode,
            constructorArgs: constructorArgs
        });

        console2.log("Deploying JBUniswapV4Hook to:", hookAddress);

        vm.startBroadcast(deployerPrivateKey);

        JBUniswapV4Hook hook = new JBUniswapV4Hook{salt: salt}({
            poolManager: IPoolManager(poolManager), tokens: core.tokens, directory: core.directory, prices: core.prices
        });

        console2.log("JBUniswapV4Hook deployed at:", address(hook));

        vm.stopBroadcast();
    }

    /// @notice Returns the Uniswap V4 PoolManager address for the current chain.
    function _getPoolManager() internal view returns (address) {
        // Ethereum
        if (block.chainid == 1) return 0x000000000004444c5dc75cB358380D2e3dE08A90;
        // Optimism
        if (block.chainid == 10) return 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
        // Base
        if (block.chainid == 8453) return 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        // Arbitrum
        if (block.chainid == 42_161) return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        // Sepolia
        if (block.chainid == 11_155_111) return 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        // Base Sepolia
        if (block.chainid == 84_532) return 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        // Arbitrum Sepolia
        if (block.chainid == 421_614) return 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;

        revert("Unsupported chain for Uniswap V4 PoolManager");
    }
}
