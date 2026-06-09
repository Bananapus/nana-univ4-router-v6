// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {TestStructuralArbitrage} from "../TestStructuralArbitrage.t.sol";

/// @notice Feature tests for the zero-`amountOutMin` TWAP protection floor (Option A + allow-cold).
/// @dev A swap that omits an explicit `amountOutMin` and settles through V4 is protected by a TWAP-derived floor when
/// the pool's oracle is warm, and is ALLOWED (no floor) when the pool is cold — so fresh pools are never bricked.
/// JB-routed swaps are never re-floored against the TWAP (they carry their own routing floor). Reuses the
/// `TestStructuralArbitrage` harness (a 1:1 JB pool with a concave bonding-curve terminal).
contract GenericZeroMinTwapFloorTest is TestStructuralArbitrage {
    /// @notice Sell `amount` of the JB token (token0) with NO explicit minimum (`amountOutMin == 0`).
    function _sellZeroMin(uint256 amount) internal {
        token0.mint(address(this), amount);
        token0.approve(address(jbSwapRouter), amount);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        jbSwapRouter.swap(key, params, 0);
    }

    /// @notice Warm the pool's TWAP at ~1:1 by recording a second, old-enough observation.
    function _warmTwap() internal {
        vm.warp(block.timestamp + 1801);
        token1.mint(address(this), 0.001 ether);
        token1.approve(address(jbSwapRouter), 0.001 ether);
        jbSwapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(0.001 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            1 // explicit min: this warm-up swap is not the unit under test
        );
        vm.warp(block.timestamp + 1801);
    }

    /// @notice Drain the bonding curve so the JB cash-out reclaim falls below V4 — forcing the swap to settle through
    /// V4 (where the pure-V4 `_afterSwap` floor applies).
    function _drainSoV4Wins() internal {
        terminalStore.configure(1 ether, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);
    }

    /// @notice COLD pool, JB-routed: a zero-min sell on a fresh pool must NOT revert. Guards against bricking
    /// fresh-pool swaps — the regression the broad (fail-closed) design would have caused.
    function test_coldPool_zeroMin_jbRouted_notBricked() public {
        _sellZeroMin(SWAP_SIZE); // JB wins by default in this harness; no TWAP, no floor, succeeds.
    }

    /// @notice COLD pool, V4-settled: even when V4 wins routing, a zero-min swap on a cold pool is ALLOWED (the hook
    /// cannot derive a trustworthy floor without a TWAP, so it imposes none rather than reverting).
    function test_coldPool_zeroMin_v4Route_allowed() public {
        _drainSoV4Wins();
        _sellZeroMin(SWAP_SIZE); // cold -> _twapProtectionFloor returns 0 -> no floor -> succeeds.
    }

    /// @notice WARM pool, V4-settled: as zero-min sells push spot below the warm ~1:1 TWAP, the protection floor
    /// eventually rejects a fill — protecting generic integrations that omit an explicit minimum. The sells run in
    /// the
    /// same block so the time-weighted TWAP stays anchored near 1:1 while spot drops.
    function test_warmPool_zeroMin_floorProtects() public {
        _warmTwap();
        _drainSoV4Wins();

        bool sawFloorRevert;
        for (uint256 i = 0; i < 50; i++) {
            token0.mint(address(this), SWAP_SIZE);
            token0.approve(address(jbSwapRouter), SWAP_SIZE);
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(SWAP_SIZE),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try jbSwapRouter.swap(key, params, 0) {
            // Fill was within the TWAP floor — keep pushing spot down.
            }
            catch {
                sawFloorRevert = true;
                break;
            }
        }
        assertTrue(sawFloorRevert, "warm-pool zero-min swap must be floored once spot falls below the TWAP tolerance");
    }

    /// @notice WARM pool: a SMALL zero-min swap (negligible price impact) stays within the TWAP floor and succeeds —
    /// the floor protects against bad fills without blocking fair ones.
    function test_warmPool_zeroMin_fairSwapSucceeds() public {
        _warmTwap();
        _drainSoV4Wins();
        _sellZeroMin(0.01 ether); // tiny impact -> output within tolerance of the ~1:1 TWAP -> succeeds.
    }
}
