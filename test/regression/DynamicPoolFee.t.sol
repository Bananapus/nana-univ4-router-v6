// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @notice Minimal mocks for JB dependencies (unused by estimateUniswapOutput, but required by constructor).
contract StubJBTokens {
    function projectIdOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract StubJBDirectory {
    function primaryTerminalOf(uint256, address) external pure returns (address) {
        return address(0);
    }

    function controllerOf(uint256) external pure returns (address) {
        return address(0);
    }
}

contract StubJBPrices {
    // forge-lint: disable-next-line(mixed-case-function)
    function DEFAULT_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function pricePerUnitOf(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        return 1e18;
    }
}

/// @notice Regression test for M-10: estimateUniswapOutput must not revert on dynamic fee pools.
/// @dev Before the fix, key.fee == DYNAMIC_FEE_FLAG (0x800000) was used as a literal fee in
///      FullMath.mulDiv(estimatedOut, 0x800000, 1_000_000), producing ~8.39x the input and causing
///      an arithmetic underflow on subtraction.
contract DynamicPoolFeeTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager manager;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    JBUniswapV4Hook hook;

    MockERC20 tokenA;
    MockERC20 tokenB;

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    function setUp() public {
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        StubJBTokens stubTokens = new StubJBTokens();
        StubJBDirectory stubDirectory = new StubJBDirectory();
        StubJBPrices stubPrices = new StubJBPrices();

        // Mine a valid hook address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            manager,
            IJBTokens(address(stubTokens)),
            IJBDirectory(address(stubDirectory)),
            IJBPrices(address(stubPrices))
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(
            manager,
            IJBTokens(address(stubTokens)),
            IJBDirectory(address(stubDirectory)),
            IJBPrices(address(stubPrices))
        );

        // Deploy tokens and sort them
        tokenA = new MockERC20("TokenA", "A");
        tokenB = new MockERC20("TokenB", "B");
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
    }

    /// @notice Helper: create and initialize a pool, add liquidity, return key and id.
    function _createPool(uint24 fee) internal returns (PoolKey memory key, PoolId id) {
        key = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        manager.initialize(key, SQRT_PRICE_1_1);

        // Mint and approve tokens for liquidity
        tokenA.mint(address(this), 100 ether);
        tokenB.mint(address(this), 100 ether);
        tokenA.approve(address(modifyLiquidityRouter), 100 ether);
        tokenB.approve(address(modifyLiquidityRouter), 100 ether);

        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}), ""
        );
    }

    /// @notice DYNAMIC_FEE_FLAG is the sentinel value 0x800000, not a valid fee.
    function test_dynamicFeeFlag_isNotValidFee() public pure {
        uint24 flag = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        assertEq(flag, 0x800000, "DYNAMIC_FEE_FLAG should be 0x800000");
        assertTrue(flag > 1_000_000, "DYNAMIC_FEE_FLAG exceeds MAX_LP_FEE");
        assertTrue(LPFeeLibrary.isDynamicFee(flag), "isDynamicFee should return true for flag");
    }

    /// @notice Before the fix, this would revert due to arithmetic underflow.
    /// The sentinel 0x800000 (8,388,608) used as a fee multiplier produces a value
    /// ~8.39x the input, so `estimatedOut - fee > estimatedOut` underflows.
    function test_estimateOutput_dynamicFeePool_doesNotRevert() public {
        (PoolKey memory dynKey, PoolId dynId) = _createPool(LPFeeLibrary.DYNAMIC_FEE_FLAG);

        // LP fee in slot0 defaults to 0 for a fresh dynamic pool.
        // estimateUniswapOutput should read lpFee=0 from slot0 and skip fee deduction.
        uint256 estimatedOut = hook.estimateUniswapOutput(dynId, dynKey, 1 ether, true);
        assertGt(estimatedOut, 0, "Should return positive estimate for dynamic fee pool");
    }

    /// @notice With a non-zero LP fee set in slot0, the estimate should deduct correctly.
    function test_estimateOutput_dynamicFeePool_deductsSlot0Fee() public {
        (PoolKey memory dynKey, PoolId dynId) = _createPool(LPFeeLibrary.DYNAMIC_FEE_FLAG);

        // Set the LP fee in slot0 to 3000 (0.3%) by pranking as the hook
        vm.prank(address(hook));
        manager.updateDynamicLPFee(dynKey, 3000);

        uint256 estimatedOut = hook.estimateUniswapOutput(dynId, dynKey, 1 ether, true);
        assertGt(estimatedOut, 0, "Should return positive estimate");

        // Compare against a static 3000-fee pool to verify fee deduction matches
        (PoolKey memory staticKey, PoolId staticId) = _createPool(3000);
        uint256 staticEstimate = hook.estimateUniswapOutput(staticId, staticKey, 1 ether, true);

        assertEq(estimatedOut, staticEstimate, "Dynamic pool with lpFee=3000 should match static pool with fee=3000");
    }

    /// @notice Static fee pools must still work correctly after the fix.
    function test_estimateOutput_staticFeePool_unchanged() public {
        (PoolKey memory staticKey, PoolId staticId) = _createPool(3000);

        uint256 estimatedOut = hook.estimateUniswapOutput(staticId, staticKey, 1 ether, true);
        assertGt(estimatedOut, 0, "Static fee pool should return positive estimate");

        // Fee deduction: estimatedOut should be less than a zero-fee pool's output.
        // At 1:1 price, output ≈ amountIn * (1 - fee/1_000_000) = 1e18 * 0.997 = 0.997e18
        assertLt(estimatedOut, 1 ether, "Output should be less than input due to fee");
    }

    /// @notice Demonstrates the underflow that the fix prevents.
    /// FullMath.mulDiv(estimatedOut, DYNAMIC_FEE_FLAG, 1_000_000) > estimatedOut.
    function test_arithmeticProof_sentinelCausesUnderflow() public pure {
        uint256 estimatedOut = 1 ether;
        uint256 feeDeduction = FullMath.mulDiv(estimatedOut, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1_000_000);

        // 0x800000 = 8,388,608 — the "fee" deduction is ~8.39x the input
        assertGt(feeDeduction, estimatedOut, "Sentinel value produces fee > 100% of output");
        // This subtraction would underflow: estimatedOut - feeDeduction
    }
}
