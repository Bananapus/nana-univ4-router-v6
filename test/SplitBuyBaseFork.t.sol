// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {JBUniswapV4Hook} from "../src/JBUniswapV4Hook.sol";

/// @notice Exact-input swaps on a native/project-token pool, in a router's order: swap, then settle what was used and
/// take the output.
contract ForkSwapper is IUnlockCallback {
    IPoolManager internal immutable PM;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    receive() external payable {}

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 limit
    )
        external
        payable
        returns (uint256 used, uint256 out)
    {
        (used, out) =
            abi.decode(PM.unlock(abi.encode(key, zeroForOne, amountIn, limit, msg.sender)), (uint256, uint256));
        if (address(this).balance != 0) payable(msg.sender).transfer(address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, uint160, address));
        BalanceDelta d = PM.swap({
            key: key,
            // forge-lint: disable-next-line(unsafe-typecast)
            params: SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
            hookData: ""
        });
        uint256 used = uint256(uint128(zeroForOne ? -d.amount0() : -d.amount1()));
        uint256 out = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
        if (zeroForOne) {
            PM.settle{value: used}();
            PM.take({currency: key.currency1, to: payer, amount: out});
        } else {
            PM.sync(key.currency1);
            require(IERC20(Currency.unwrap(key.currency1)).transferFrom(payer, address(PM), used));
            PM.settle();
            PM.take({currency: key.currency0, to: payer, amount: out});
        }
        return abi.encode(used, out);
    }
}

/// @notice Direct buys on Base's live project 13 and project 7 pools, with this source's hook deployed over the live
/// 1.2.0 hook (`0xf70B…95c8`), against the real terminal, REVOwner data hook and buyback hook.
/// @dev Run with `RPC_BASE_MAINNET` set to an archive endpoint.
contract SplitBuyBaseForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BLOCK = 52_922_000;
    address internal constant HOOK = 0xf70B71605f1C0A8Ff7580557645BB7e29fE495c8;
    IPoolManager internal constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IJBTerminal internal constant TERMINAL = IJBTerminal(0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
    address internal constant TOKEN_13 = 0x761A27084Efd69b94889F699D7A7493EC42f9622;
    address internal constant TOKEN_7 = 0xF6627cF19317C33B457f77452876e6e297c4942F;

    ForkSwapper internal swapper;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_BASE_MAINNET", string("https://base-rpc.publicnode.com")), BLOCK);
        swapper = new ForkSwapper(PM);
        vm.deal(address(this), 10_000 ether);
    }

    //*********************************************************************//
    // ----------------------------- helpers ----------------------------- //
    //*********************************************************************//

    function _key(uint256 pid) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(pid == 13 ? TOKEN_13 : TOKEN_7),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(HOOK)
        });
    }

    /// @dev The payer's tokens per ETH from issuance (project 7 after its 38% reserved split).
    function _mintAll(uint256 pid, uint256 amount) internal pure returns (uint256) {
        return amount * (pid == 13 ? 50_000 : 7750);
    }

    function _upgrade() internal {
        JBUniswapV4Hook live = JBUniswapV4Hook(payable(HOOK));
        deployCodeTo(
            "src/JBUniswapV4Hook.sol:JBUniswapV4Hook",
            abi.encode(live.poolManager(), live.TOKENS(), live.DIRECTORY(), live.PRICES()),
            HOOK
        );
    }

    function swapFor(uint256 pid, uint256 amountIn, uint160 limit) external returns (uint256 used, uint256 out) {
        return swapper.swap{value: amountIn}(_key(pid), true, amountIn, limit);
    }

    /// @dev A direct buy with the router-standard extreme limit; `ok` is false if the swap reverts.
    function _buy(uint256 pid, uint256 amountIn) internal returns (bool ok, uint256 used, uint256 out) {
        try this.swapFor(pid, amountIn, TickMath.MIN_SQRT_PRICE + 1) returns (uint256 u, uint256 o) {
            return (true, u, o);
        } catch {
            return (false, 0, 0);
        }
    }

    function _sell(uint256 pid, uint256 amount) internal returns (uint256 out) {
        IERC20(Currency.unwrap(_key(pid).currency1)).approve(address(swapper), amount);
        (, out) = swapper.swap(_key(pid), false, amount, TickMath.MAX_SQRT_PRICE - 1);
    }

    /// @dev The fee-free issuance price for a buyer, so a swap limited there is a plain pool swap.
    function _issuanceLimit(uint256 pid) internal pure returns (uint160) {
        return uint160(Math.sqrt((pid == 13 ? uint256(50_000) : 7750) << 192));
    }

    function _tick(uint256 pid) internal view returns (int24 tick) {
        (, tick,,) = PM.getSlot0(_key(pid).toId());
    }

    /// @dev Moves the pool before the buy, as a third party would: state 0 as-is, 1 a pump (a pool buy limited at
    /// issuance), 2 a dump (pay the terminal, sell the tokens into the pool).
    function _setState(uint256 pid, uint256 state) internal {
        if (state == 1) {
            swapper.swap{value: 1 ether}(_key(pid), true, 1 ether, _issuanceLimit(pid));
        } else if (state == 2) {
            uint256 amount = pid == 13 ? 0.01 ether : 1 ether;
            uint256 tokens =
                TERMINAL.pay{value: amount}(pid, JBConstants.NATIVE_TOKEN, amount, address(this), 0, "", "");
            _sell(pid, tokens);
        }
    }

    //*********************************************************************//
    // ------------------------------ tests ------------------------------ //
    //*********************************************************************//

    /// @notice The upgrade keeps the oracle's storage: observation state and TWAP reads match before and after.
    function test_upgradeKeepsOracleStorage() public {
        PoolKey memory key = _key(13);
        (uint16 index, uint16 cardinality, uint16 next) = JBUniswapV4Hook(payable(HOOK)).states(key.toId());
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800;
        (int56[] memory before,) = JBUniswapV4Hook(payable(HOOK)).observe(key, ago);
        _upgrade();
        (uint16 index2, uint16 cardinality2, uint16 next2) = JBUniswapV4Hook(payable(HOOK)).states(key.toId());
        (int56[] memory afterUpgrade,) = JBUniswapV4Hook(payable(HOOK)).observe(key, ago);
        assertEq(index2, index);
        assertEq(cardinality2, cardinality);
        assertEq(next2, next);
        assertEq(afterUpgrade[0], before[0]);
        assertEq(afterUpgrade[1], before[1]);
    }

    /// @notice Across sizes, both pools and three pool states, the upgraded hook never gives a buyer less than
    /// minting the whole input, and never less than the deployed hook when the deployed hook fills the whole input.
    /// Logs the table for the PR.
    function test_table_neverBelowDeployedOrMintAll() public {
        uint256[9] memory sizes = [
            uint256(0.0001 ether),
            0.001 ether,
            0.002 ether,
            0.003 ether,
            0.01 ether,
            0.1 ether,
            1 ether,
            3 ether,
            10 ether
        ];
        uint256[2] memory pids = [uint256(13), 7];
        for (uint256 p; p < 2; p++) {
            for (uint256 state; state < 3; state++) {
                uint256 base = vm.snapshotState();
                _setState(pids[p], state);
                emit log_named_int(
                    string.concat("project ", vm.toString(pids[p]), " state ", vm.toString(state), " tick"),
                    _tick(pids[p])
                );
                for (uint256 i; i < sizes.length; i++) {
                    uint256 snap = vm.snapshotState();
                    (bool ok, uint256 used, uint256 deployed) = _buy(pids[p], sizes[i]);
                    vm.revertToState(snap);
                    _upgrade();
                    (bool ok2,, uint256 updated) = _buy(pids[p], sizes[i]);
                    vm.revertToState(snap);

                    uint256 mintAll = _mintAll(pids[p], sizes[i]);
                    emit log_string(string.concat(
                            "| ",
                            vm.toString(pids[p]),
                            " | ",
                            vm.toString(state),
                            " | ",
                            vm.toString(sizes[i]),
                            " | ",
                            ok ? vm.toString(deployed) : "revert",
                            " | ",
                            ok ? vm.toString(used) : "-",
                            " | ",
                            vm.toString(updated),
                            " | ",
                            vm.toString(mintAll),
                            " |"
                        ));
                    assertTrue(ok2, "the upgraded hook fills");
                    assertGe(updated + 1e6, mintAll, "never below minting everything");
                    if (ok && used == sizes[i]) assertGe(updated + 1e6, deployed, "never below the deployed hook");
                }
                vm.revertToState(base);
            }
        }
    }

    /// @notice A pay through the terminal, where the buyback hook swaps through this pool, settles exactly as it does
    /// with the deployed hook, and this hook never pays the terminal from inside it (one `Pay` event, the payer's).
    function test_buybackPays_unchangedAndNeverMintTwice() public {
        uint256[5] memory sizes = [uint256(0.0001 ether), 0.001 ether, 0.01 ether, 0.1 ether, 1 ether];
        uint256[2] memory pids = [uint256(13), 7];
        for (uint256 p; p < 2; p++) {
            IERC20 token = IERC20(Currency.unwrap(_key(pids[p]).currency1));
            for (uint256 i; i < sizes.length; i++) {
                uint256 snap = vm.snapshotState();
                uint256 balance = token.balanceOf(address(0xBEEF));
                TERMINAL.pay{value: sizes[i]}(pids[p], JBConstants.NATIVE_TOKEN, sizes[i], address(0xBEEF), 0, "", "");
                uint256 deployed = token.balanceOf(address(0xBEEF)) - balance;
                vm.revertToState(snap);

                _upgrade();
                vm.recordLogs();
                TERMINAL.pay{value: sizes[i]}(pids[p], JBConstants.NATIVE_TOKEN, sizes[i], address(0xBEEF), 0, "", "");
                Vm.Log[] memory logs = vm.getRecordedLogs();
                uint256 updated = token.balanceOf(address(0xBEEF)) - balance;
                vm.revertToState(snap);

                uint256 pays;
                for (uint256 l; l < logs.length; l++) {
                    if (logs[l].topics[0] == IJBTerminal.Pay.selector) pays++;
                }
                assertEq(pays, 1, "only the payer's pay");
                assertEq(updated, deployed, "same settlement as the deployed hook");
            }
        }
    }

    /// @dev Front-runs a buy of `amount` with pool buys (limited at issuance, the attacker's best) `step` apart, then
    /// sells the attacker's tokens back. Returns the best attacker profit and the victim's worst loss against the
    /// unattacked buy.
    function _sandwich(
        uint256 pid,
        uint256 amount,
        uint256 step,
        uint256 steps
    )
        internal
        returns (uint256 bestProfit, uint256 worstLoss, uint256 honest)
    {
        _upgrade();
        uint256 start = vm.snapshotState();
        (,, honest) = _buy(pid, amount);
        vm.revertToState(start);
        for (uint256 k = 1; k <= steps; k++) {
            uint256 x = k * step;
            uint256 snap = vm.snapshotState();
            (uint256 used, uint256 bought) = swapper.swap{value: x}(_key(pid), true, x, _issuanceLimit(pid));
            (,, uint256 victim) = _buy(pid, amount);
            uint256 back = _sell(pid, bought);
            vm.revertToState(snap);

            assertGe(victim + 1e6, _mintAll(pid, amount), "the victim never gets less than issuance");
            if (back > used && back - used > bestProfit) bestProfit = back - used;
            if (honest > victim && honest - victim > worstLoss) worstLoss = honest - victim;
        }
    }

    function test_sandwich() public {
        uint256[4] memory amounts13 = [uint256(0.001 ether), 0.003 ether, 0.01 ether, 0.1 ether];
        for (uint256 i; i < amounts13.length; i++) {
            (uint256 profit, uint256 loss, uint256 honest) = _sandwich(13, amounts13[i], 0.0002 ether, 30);
            _logSandwich(13, amounts13[i], profit, loss, honest);
        }
        uint256[3] memory amounts7 = [uint256(0.1 ether), 1 ether, 10 ether];
        for (uint256 i; i < amounts7.length; i++) {
            (uint256 profit, uint256 loss, uint256 honest) = _sandwich(7, amounts7[i], 0.1 ether, 30);
            _logSandwich(7, amounts7[i], profit, loss, honest);
        }
    }

    function _logSandwich(uint256 pid, uint256 amount, uint256 profit, uint256 loss, uint256 honest) internal {
        emit log_string(string.concat(
                "sandwich | ",
                vm.toString(pid),
                " | ",
                vm.toString(amount),
                " | profit wei ",
                vm.toString(profit),
                " | profit bps of pay ",
                vm.toString(profit * 10_000 / amount),
                " | victim loss bps ",
                vm.toString(honest == 0 ? 0 : loss * 10_000 / honest),
                " | honest ",
                vm.toString(honest),
                " | mintAll ",
                vm.toString(_mintAll(pid, amount)),
                " |"
            ));
    }
}
