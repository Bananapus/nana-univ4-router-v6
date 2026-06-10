// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {TestStructuralArbitrage} from "../TestStructuralArbitrage.t.sol";

/// @notice Tests the `hookData` discriminator: a swap's minimum output is enforced ONLY when `hookData` carries the
/// `JB_HOOK_DATA_TAG` prefix. Any other payload — empty, or a generic integration's own metadata (a large word, an
/// ABI
/// offset, an address) — carries no minimum, so a foreign first word is never mis-read as one and the swap proceeds
/// under the caller's own protection. The hook imposes no floor of its own. Reuses the `TestStructuralArbitrage`
/// harness (a 1:1 JB pool with a concave bonding-curve terminal).
contract GenericHookDataDiscriminatorTest is TestStructuralArbitrage {
    PoolSwapTest.TestSettings internal _swapSettings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    /// @notice Tagged hookData carrying an explicit minimum, as a JB-aware caller would build it.
    function _taggedMin(uint256 amountOutMin) internal view returns (bytes memory) {
        return abi.encodePacked(hook.JB_HOOK_DATA_TAG(), abi.encode(amountOutMin));
    }

    /// @notice Sell `amount` of token0 directly through V4's `PoolSwapTest` with caller-supplied `hookData` — the
    /// shape
    /// a generic integration uses (it does not route through `JuiceboxSwapRouter`).
    function _rawSell(uint256 amount, bytes memory hookData) internal {
        token0.mint(address(this), amount);
        token0.approve(address(swapRouter), amount);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap(key, params, _swapSettings, hookData);
    }

    /// @notice Drain the bonding curve so the JB cash-out reclaim falls below V4 — forcing settlement through V4.
    function _drainSoV4Wins() internal {
        terminalStore.configure(1 ether, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);
    }

    /// @notice Empty hookData (the common generic-integration shape) is allowed — no minimum, no floor, no revert.
    function test_emptyHookData_allowed() public {
        _drainSoV4Wins();
        _rawSell(SWAP_SIZE, "");
    }

    /// @notice Foreign hookData with a LARGE first word (a hash/address/selector a router forwards) is NOT mis-read as
    /// an astronomical minimum — without the tag it would DoS every such swap. Untagged -> no minimum -> allowed.
    function test_foreignHookData_largeWord_notMisreadAsMin() public {
        _drainSoV4Wins();
        _rawSell(SWAP_SIZE, abi.encode(type(uint256).max, type(uint256).max));
    }

    /// @notice Foreign hookData with a SMALL first word (e.g. an ABI head offset `0x20`) carries no minimum -> allowed,
    /// and is not silently treated as a 32-wei minimum either.
    function test_foreignHookData_smallWord_carriesNoMin() public {
        _drainSoV4Wins();
        _rawSell(SWAP_SIZE, abi.encode(uint256(0x20), uint256(0)));
    }

    /// @notice A TAGGED explicit minimum is enforced against the actual settled output: an unsatisfiable minimum
    /// reverts, and the revert carries the hook's own `JBUniswapV4Hook_InsufficientOutput` selector (PoolManager wraps
    /// it).
    function test_taggedMin_enforced_revertsPrecisely() public {
        _drainSoV4Wins();
        token0.mint(address(this), SWAP_SIZE);
        token0.approve(address(swapRouter), SWAP_SIZE);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(SWAP_SIZE),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        bool reverted;
        try swapRouter.swap(key, params, _swapSettings, _taggedMin(type(uint256).max)) {
        // no revert
        }
        catch (bytes memory reason) {
            reverted = true;
            assertTrue(
                _containsSelector(reason, JBUniswapV4Hook.JBUniswapV4Hook_InsufficientOutput.selector),
                "must revert with InsufficientOutput"
            );
        }
        assertTrue(reverted, "tagged unsatisfiable minimum must revert");
    }

    /// @notice A satisfiable tagged minimum succeeds.
    function test_taggedMin_satisfiable_succeeds() public {
        _drainSoV4Wins();
        _rawSell(SWAP_SIZE, _taggedMin(1));
    }

    /// @notice A tagged zero minimum is an explicit opt-out and never reverts (equivalent to no minimum).
    function test_taggedZeroMin_optsOut() public {
        _drainSoV4Wins();
        _rawSell(SWAP_SIZE * 5, _taggedMin(0));
    }

    /// @notice JB-routed swaps keep their own routing floor and are not bricked on a fresh pool. Routed via JB's own
    /// router, which settles the hook's custom JB-routed delta (a generic V4 router cannot, by design).
    function test_jbRouted_coldPool_notBricked() public {
        token0.mint(address(this), SWAP_SIZE);
        token0.approve(address(jbSwapRouter), SWAP_SIZE);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(SWAP_SIZE),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        jbSwapRouter.swap(key, params, 0);
    }

    /// @notice Returns true if `data` contains the 4-byte `selector` (PoolManager wraps inner hook reverts).
    function _containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) {
                return true;
            }
        }
        return false;
    }
}
