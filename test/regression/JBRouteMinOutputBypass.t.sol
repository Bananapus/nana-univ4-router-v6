// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {MockERC20} from "../mock/MockERC20.sol";
import {PreviewPayForRoutingTest} from "./PreviewPayForRouting.t.sol";

contract UncheckedJuiceboxSwapRouter {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    IPoolManager public immutable poolManager;

    bytes4 private immutable _hookDataTag;

    address private _msgSender;

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    constructor(IPoolManager newPoolManager, bytes4 hookDataTag) {
        poolManager = newPoolManager;
        _hookDataTag = hookDataTag;
    }

    function msgSender() external view returns (address) {
        return _msgSender;
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        uint256 amountOutMin
    )
        external
        payable
        returns (BalanceDelta delta)
    {
        _msgSender = msg.sender;

        // JB-aware caller: tag the minimum so the hook reads and enforces it.
        bytes memory hookData = abi.encodePacked(_hookDataTag, abi.encode(amountOutMin));
        delta = abi.decode(
            poolManager.unlock(
                abi.encode(CallbackData({sender: msg.sender, key: key, params: params, hookData: hookData}))
            ),
            (BalanceDelta)
        );

        _msgSender = address(0);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager can call");

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        Currency inputCurrency = data.params.zeroForOne ? data.key.currency0 : data.key.currency1;
        uint256 inputAmount = data.params.amountSpecified < 0
            ? uint256(-data.params.amountSpecified)
            : uint256(data.params.amountSpecified);

        if (!inputCurrency.isAddressZero()) {
            IERC20 inputToken = IERC20(Currency.unwrap(inputCurrency));
            inputToken.safeTransferFrom(data.sender, address(this), inputAmount);
            inputCurrency.settle(poolManager, address(this), inputAmount, false);
        } else {
            poolManager.settle{value: inputAmount}();
        }

        BalanceDelta delta = poolManager.swap(data.key, data.params, data.hookData);

        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        if (data.params.zeroForOne) {
            // The mock router is only fed small test amounts, so this cannot exceed `int256.max`.
            // forge-lint: disable-next-line(unsafe-typecast)
            delta0 += int256(inputAmount);
        } else {
            // The mock router is only fed small test amounts, so this cannot exceed `int256.max`.
            // forge-lint: disable-next-line(unsafe-typecast)
            delta1 += int256(inputAmount);
        }

        if (delta0 < 0) {
            // The branch proves `-delta0` is non-negative and fits the pool manager settlement amount.
            // forge-lint: disable-next-line(unsafe-typecast)
            data.key.currency0.settle(poolManager, data.sender, uint256(-delta0), false);
        }
        if (delta1 < 0) {
            // The branch proves `-delta1` is non-negative and fits the pool manager settlement amount.
            // forge-lint: disable-next-line(unsafe-typecast)
            data.key.currency1.settle(poolManager, data.sender, uint256(-delta1), false);
        }

        if (delta0 > 0) {
            // The branch proves `delta0` is non-negative and fits the pool manager withdrawal amount.
            // forge-lint: disable-next-line(unsafe-typecast)
            data.key.currency0.take(poolManager, data.sender, uint256(delta0), false);
        }
        if (delta1 > 0) {
            // The branch proves `delta1` is non-negative and fits the pool manager withdrawal amount.
            // forge-lint: disable-next-line(unsafe-typecast)
            data.key.currency1.take(poolManager, data.sender, uint256(delta1), false);
        }

        return abi.encode(delta);
    }

    receive() external payable {}
}

contract MockTerminalIgnoringMin {
    mapping(uint256 => address) public projectTokens;

    uint256 public previewBeneficiaryCount;
    uint256 public actualPayAmount;
    uint256 public lastPayProjectId;

    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    function setPreviewReturn(uint256 amount) external {
        previewBeneficiaryCount = amount;
    }

    function setActualPayAmount(uint256 amount) external {
        actualPayAmount = amount;
    }

    function previewPayFor(
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 beneficiaryTokenCount,
            uint256 reservedCount,
            JBPayHookSpecification[] memory hookSpecifications
        )
    {
        return (ruleset, previewBeneficiaryCount, 0, hookSpecifications);
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 beneficiaryTokenCount)
    {
        lastPayProjectId = projectId;
        beneficiaryTokenCount = actualPayAmount;

        if (token != address(0) && amount != 0) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && actualPayAmount > 0) {
            MockERC20(projectToken).mint(beneficiary, actualPayAmount);
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    receive() external payable {}
}

contract JBRouteMinOutputBypassTest is PreviewPayForRoutingTest {
    MockTerminalIgnoringMin internal maliciousTerminal;
    UncheckedJuiceboxSwapRouter internal uncheckedRouter;

    function _installMaliciousTerminal() internal {
        maliciousTerminal = new MockTerminalIgnoringMin();
        maliciousTerminal.setProjectToken(123, address(projectToken));
        maliciousTerminal.setPreviewReturn(5000e18);
        maliciousTerminal.setActualPayAmount(1e18);

        mockDirectory.setDefaultTerminal(address(maliciousTerminal));

        uncheckedRouter = new UncheckedJuiceboxSwapRouter(manager, hook.JB_HOOK_DATA_TAG());
        projectToken.approve(address(uncheckedRouter), type(uint256).max);
        paymentToken.approve(address(uncheckedRouter), type(uint256).max);
    }

    function test_hookRevertsWhenRealizedJBRouteOutputIsBelowMin() public {
        _installMaliciousTerminal();

        uint256 balanceBefore = projectToken.balanceOf(address(this));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.expectRevert();
        uncheckedRouter.swap(key, params, 5000e18);

        assertEq(projectToken.balanceOf(address(this)), balanceBefore, "revert unwinds below-min output");
    }

    function test_hookRevertsWhenBuySideJBRouteUnderperformsV4Quote() public {
        _installMaliciousTerminal();

        uint256 amountIn = 1 ether;
        uint256 v4Quote = hook.estimateUniswapOutput({poolId: id, key: key, amountIn: amountIn, zeroForOne: zeroForOne});
        maliciousTerminal.setPreviewReturn(v4Quote + 1 ether);
        maliciousTerminal.setActualPayAmount(v4Quote / 2);

        uint256 balanceBefore = projectToken.balanceOf(address(this));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // PoolManager wraps hook errors, so asserting any revert here is enough to prove the route floor is enforced.
        vm.expectRevert();
        uncheckedRouter.swap(key, params, 0);

        assertEq(projectToken.balanceOf(address(this)), balanceBefore, "revert unwinds below-v4 buy route");
    }
}
