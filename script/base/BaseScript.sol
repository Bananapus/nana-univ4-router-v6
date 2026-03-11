// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

/// @notice Shared configuration between scripts
contract BaseScript is Script {
    IPermit2 immutable PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager immutable POOL_MANAGER;
    IPositionManager immutable POSITION_MANAGER;
    IUniswapV4Router04 immutable SWAP_ROUTER;
    address immutable DEPLOYER_ADDRESS;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////
    IERC20 internal constant TOKEN0 = IERC20(0x0165878A594ca255338adfa4d48449f69242Eb8F);
    IERC20 internal constant TOKEN1 = IERC20(0xa513E6E4b8f2a923D98304ec87F64353C4D5C853);
    IHooks constant HOOK_CONTRACT = IHooks(address(0));
    /////////////////////////////////////

    Currency immutable CURRENCY0;
    Currency immutable CURRENCY1;

    constructor() {
        POOL_MANAGER = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        POSITION_MANAGER = IPositionManager(payable(AddressConstants.getPositionManagerAddress(block.chainid)));
        SWAP_ROUTER = IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));

        DEPLOYER_ADDRESS = getDeployer();

        (CURRENCY0, CURRENCY1) = getCurrencies();

        vm.label(address(TOKEN0), "Token0");
        vm.label(address(TOKEN1), "Token1");

        vm.label(address(DEPLOYER_ADDRESS), "Deployer");
        vm.label(address(POOL_MANAGER), "PoolManager");
        vm.label(address(POSITION_MANAGER), "PositionManager");
        vm.label(address(SWAP_ROUTER), "SwapRouter");
        vm.label(address(HOOK_CONTRACT), "HookContract");
    }

    function getCurrencies() public pure returns (Currency, Currency) {
        require(address(TOKEN0) != address(TOKEN1));

        if (TOKEN0 < TOKEN1) {
            return (Currency.wrap(address(TOKEN0)), Currency.wrap(address(TOKEN1)));
        } else {
            return (Currency.wrap(address(TOKEN1)), Currency.wrap(address(TOKEN0)));
        }
    }

    function getDeployer() public returns (address) {
        address[] memory wallets = vm.getWallets();

        require(wallets.length > 0, "No wallets found");

        return wallets[0];
    }
}
