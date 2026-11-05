// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";

/// @notice A linear quote at the hook oracle's TWAP (best-effort window up to `TWAP_PERIOD`, spot without history),
/// after the pool's swap fee. Tests use it as a reference V4 price read through the hook's public oracle surface.
library OracleQuote {
    using ProtocolFeeLibrary for uint16;
    using ProtocolFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    function quote(
        JBUniswapV4Hook hook,
        IPoolManager manager,
        PoolKey memory key,
        uint256 amountIn,
        bool zeroForOne
    )
        internal
        view
        returns (uint256 amountOut)
    {
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(PoolIdLibrary.toId(key));

        uint32 window = hook.observationCoverageOf(key);
        if (window > uint32(1800)) window = uint32(1800);
        if (window != 0) {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = window;
            (int56[] memory tickCumulatives,) = hook.observe(key, secondsAgos);
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 tick = int24(delta / int56(uint56(window)));
            if (delta < 0 && delta % int56(uint56(window)) != 0) tick--;
            sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        }

        uint24 swapFee =
            (zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee()).calculateSwapFee(lpFee);
        uint256 amountInAfterFee = FullMath.mulDiv(
            amountIn, ProtocolFeeLibrary.PIPS_DENOMINATOR - swapFee, ProtocolFeeLibrary.PIPS_DENOMINATOR
        );

        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            amountOut = zeroForOne
                ? FullMath.mulDiv(amountInAfterFee, ratioX192, 1 << 192)
                : FullMath.mulDiv(amountInAfterFee, 1 << 192, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            amountOut = zeroForOne
                ? FullMath.mulDiv(amountInAfterFee, ratioX128, 1 << 128)
                : FullMath.mulDiv(amountInAfterFee, 1 << 128, ratioX128);
        }
    }
}
