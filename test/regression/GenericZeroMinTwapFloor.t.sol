// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {TestStructuralArbitrage} from "../TestStructuralArbitrage.t.sol";

/// @notice Feature tests for the TWAP protection floor applied to swaps that omit JB's `amountOutMin` hookData.
/// @dev The floor protects a generic integration (DEX aggregator, Universal Router, wallet) that swaps a JB pool
/// WITHOUT JB's hookData and settles through V4. It applies only when the caller gives no explicit minimum (empty
/// hookData); an explicit minimum — including an explicit zero, a deliberate opt-out — is honored as given. A cold
/// pool yields no floor (the swap proceeds), and the floor is measured against the input actually consumed so a fair
/// partial fill at a price limit is not rejected. JB-routed swaps keep their own routing floor and are not re-floored.
/// Reuses the `TestStructuralArbitrage` harness (a 1:1 JB pool with a concave bonding-curve terminal).
contract GenericZeroMinTwapFloorTest is TestStructuralArbitrage {
    PoolSwapTest.TestSettings internal _swapSettings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    /// @notice Sell `amount` of token0 directly through V4's `PoolSwapTest` with caller-supplied `hookData` — the
    /// shape
    /// a generic integration uses (it does not route through `JuiceboxSwapRouter`).
    function _rawSell(uint256 amount, uint160 sqrtPriceLimit, bytes memory hookData) internal {
        token0.mint(address(this), amount);
        token0.approve(address(swapRouter), amount);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: sqrtPriceLimit
        });
        swapRouter.swap(key, params, _swapSettings, hookData);
    }

    /// @notice Warm the pool's TWAP by recording a second, old-enough observation.
    function _warmTwap() internal {
        vm.warp(block.timestamp + 1801);
        _rawSell(0.001 ether, TickMath.MIN_SQRT_PRICE + 1, abi.encode(uint256(0)));
        vm.warp(block.timestamp + 1801);
    }

    /// @notice Drain the bonding curve so the JB cash-out reclaim falls below V4 — forcing settlement through V4.
    function _drainSoV4Wins() internal {
        terminalStore.configure(1 ether, INITIAL_SUPPLY, CASH_OUT_TAX_RATE);
    }

    /// @notice COLD pool, empty hookData: a generic swap on a fresh pool is ALLOWED (no TWAP to floor against).
    function test_emptyHookData_coldPool_allowed() public {
        _drainSoV4Wins();
        _rawSell(SWAP_SIZE, TickMath.MIN_SQRT_PRICE + 1, "");
    }

    /// @notice JB-routed swaps keep their own routing floor and are not bricked on a fresh pool. Routed via JB's own
    /// router, which settles the hook's custom JB-routed delta (a generic V4 router cannot do so, by design — generic
    /// integrations get the pure-V4 path).
    function test_jbRouted_zeroMin_coldPool_notBricked() public {
        token0.mint(address(this), SWAP_SIZE);
        token0.approve(address(jbSwapRouter), SWAP_SIZE);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(SWAP_SIZE),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        // Explicit-0 via JB's router is a deliberate opt-out; the JB-routed sell succeeds (JB wins by default).
        jbSwapRouter.swap(key, params, 0);
    }

    /// @notice WARM pool, empty hookData: as sells push spot below the warm ~1:1 TWAP, the floor rejects a fill —
    /// protecting generic integrations that omit a minimum. Sells run in the same block so the TWAP stays anchored.
    function test_emptyHookData_warmPool_floorProtects() public {
        _warmTwap();
        _drainSoV4Wins();

        bool sawFloorRevert;
        for (uint256 i = 0; i < 50; i++) {
            token0.mint(address(this), SWAP_SIZE);
            token0.approve(address(swapRouter), SWAP_SIZE);
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(SWAP_SIZE),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(key, params, _swapSettings, "") {
            // Fill was within the TWAP floor — keep pushing spot down.
            }
            catch {
                sawFloorRevert = true;
                break;
            }
        }
        assertTrue(sawFloorRevert, "warm-pool empty-hookData swap must be floored once spot falls below the tolerance");
    }

    /// @notice WARM pool, empty hookData, PARTIAL FILL at a fair price: a swap that reaches a tight `sqrtPriceLimitX96`
    /// consumes only a fraction of its requested input at a price within the TWAP tolerance. The floor is measured
    /// against the CONSUMED input, so this fair partial fill must NOT revert (flooring against the full requested
    /// input would reject it whenever the consumed fraction is below the tolerance).
    function test_emptyHookData_warmPool_fairPartialFill_notReverted() public {
        _warmTwap();
        _drainSoV4Wins();

        // A price limit ~0.05% below spot lets the swap fill only a sliver before stopping — a small consumed
        // fraction at a near-spot (fair) price. Requested input is large to make the fraction well under tolerance.
        uint160 spot = uint160(SQRT_PRICE_1_1);
        uint160 tightLimit = uint160((uint256(spot) * 9995) / 10_000);
        _rawSell(1000 ether, tightLimit, "");
    }

    /// @notice WARM pool: an explicit `amountOutMin == 0` is a deliberate take-any-price opt-out and is NOT floored,
    /// even on a large price-moving swap that an empty-hookData caller would have had floored.
    function test_warmPool_explicitZeroMin_optsOutOfFloor() public {
        _warmTwap();
        _drainSoV4Wins();
        // Large sell with an EXPLICIT zero minimum: honored as opt-out -> no floor -> must not revert.
        _rawSell(SWAP_SIZE * 10, TickMath.MIN_SQRT_PRICE + 1, abi.encode(uint256(0)));
    }

    /// @notice An explicit non-zero `amountOutMin` is enforced as given (the explicit path is unchanged): a minimum
    /// above the realizable output reverts, a satisfiable one succeeds.
    function test_explicitMin_enforced() public {
        _drainSoV4Wins();
        // Preamble first; `vm.expectRevert` binds to the very next call, which must be the swap itself.
        token0.mint(address(this), SWAP_SIZE);
        token0.approve(address(swapRouter), SWAP_SIZE);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(SWAP_SIZE),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        // Unsatisfiably high explicit minimum -> reverts.
        vm.expectRevert();
        swapRouter.swap(key, params, _swapSettings, abi.encode(type(uint256).max));
    }

    /// @notice Control for the explicit-min path: a trivially satisfiable minimum succeeds.
    function test_explicitMin_satisfiable_succeeds() public {
        _drainSoV4Wins();
        _rawSell(SWAP_SIZE, TickMath.MIN_SQRT_PRICE + 1, abi.encode(uint256(1)));
    }
}
