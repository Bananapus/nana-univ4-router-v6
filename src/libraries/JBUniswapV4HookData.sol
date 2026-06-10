// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Shared encoding constants for `JBUniswapV4Hook` swap `hookData`.
/// @dev Exposed as a library constant so downstream contracts (e.g. a JB-aware router) and off-chain callers can
/// reference the tag at compile time without an instance call. `JBUniswapV4Hook.JB_HOOK_DATA_TAG` mirrors `TAG`.
library JBUniswapV4HookData {
    /// @notice The 4-byte prefix that marks `hookData` as carrying a Juicebox `amountOutMin`.
    /// @dev `JBUniswapV4Hook` reads a minimum only from `hookData` that begins with this tag and is at least 36 bytes
    /// (`TAG ++ abi.encode(amountOutMin)`). Any other payload carries no minimum, so a foreign first word is never
    /// mis-decoded as one. A JB-aware caller builds it as `abi.encodePacked(JBUniswapV4HookData.TAG, abi.encode(min))`.
    bytes4 internal constant TAG = bytes4(keccak256("JBUniswapV4Hook.amountOutMin.v1"));
}
