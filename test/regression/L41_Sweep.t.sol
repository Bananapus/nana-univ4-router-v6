// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPrices} from "@bananapus/core-v6/src/interfaces/IJBPrices.sol";
import {IUniswapV3Factory} from "../../src/interfaces/IUniswapV3Factory.sol";
import {MockERC20} from "../../test/mock/MockERC20.sol";

/// @title L-41 Regression: sweep function can recover stuck tokens
/// @notice The contract has receive() but previously had no way to recover stuck tokens/ETH.
contract L41_SweepTest is Test {
    JBUniswapV4Hook hook;
    address deployer;
    address recipient;
    MockERC20 token;

    function setUp() public {
        deployer = address(this);
        recipient = makeAddr("recipient");

        // Deploy with mocked dependencies (we only test sweep, not swap logic)
        address poolManager = makeAddr("poolManager");
        vm.etch(poolManager, hex"00");

        // Deploy the hook (for testing sweep, we don't need a flag-valid address)
        JBUniswapV4Hook tempHook = new JBUniswapV4Hook(
            IPoolManager(poolManager),
            IJBTokens(makeAddr("tokens")),
            IJBDirectory(makeAddr("directory")),
            IJBPrices(makeAddr("prices")),
            IUniswapV3Factory(makeAddr("v3factory")),
            makeAddr("weth")
        );

        // For testing, we just verify the deployer check works on the temp instance
        hook = tempHook;

        // Deploy mock token
        token = new MockERC20("Test", "TST");
    }

    function test_sweepERC20() public {
        // Send tokens to the hook (simulating stuck tokens)
        uint256 amount = 1000e18;
        token.mint(address(hook), amount);
        assertEq(token.balanceOf(address(hook)), amount);

        // Sweep should work from deployer
        hook.sweep(address(token), recipient);

        assertEq(token.balanceOf(address(hook)), 0, "Hook should have no tokens after sweep");
        assertEq(token.balanceOf(recipient), amount, "Recipient should have received tokens");
    }

    function test_sweepETH() public {
        // Send ETH to the hook
        uint256 amount = 1 ether;
        vm.deal(address(hook), amount);
        assertEq(address(hook).balance, amount);

        // Sweep should work from deployer
        hook.sweep(address(0), recipient);

        assertEq(address(hook).balance, 0, "Hook should have no ETH after sweep");
        assertEq(recipient.balance, amount, "Recipient should have received ETH");
    }

    function test_sweepRevertsForNonDeployer() public {
        token.mint(address(hook), 1000e18);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(JBUniswapV4Hook.JBUniswapV4Hook_Unauthorized.selector);
        hook.sweep(address(token), attacker);
    }
}
