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

/// @notice Exact-input swaps on a native/project-token pool, in a router's order: swap, settle what was used, take the
/// output, then check the caller's minimum output.
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
        uint160 limit,
        uint256 minOut
    )
        external
        payable
        returns (uint256 used, uint256 out)
    {
        (used, out) =
            abi.decode(PM.unlock(abi.encode(key, zeroForOne, amountIn, limit, msg.sender)), (uint256, uint256));
        // A router's minimum output on the whole swap.
        require(out >= minOut, "below minimum");
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

    function swapFor(
        uint256 pid,
        uint256 amountIn,
        uint160 limit,
        uint256 minOut
    )
        external
        returns (uint256 used, uint256 out)
    {
        return swapper.swap{value: amountIn}(_key(pid), true, amountIn, limit, minOut);
    }

    /// @dev A direct buy with the router-standard extreme limit and no minimum; `ok` is false if the swap reverts.
    function _buy(uint256 pid, uint256 amountIn) internal returns (bool ok, uint256 used, uint256 out) {
        return _buy(pid, amountIn, 0);
    }

    /// @dev A direct buy with the router-standard extreme limit and a minimum output.
    function _buy(uint256 pid, uint256 amountIn, uint256 minOut) internal returns (bool ok, uint256 used, uint256 out) {
        return _buy(pid, amountIn, TickMath.MIN_SQRT_PRICE + 1, minOut);
    }

    /// @dev A direct buy with a price limit and a minimum output.
    function _buy(
        uint256 pid,
        uint256 amountIn,
        uint160 limit,
        uint256 minOut
    )
        internal
        returns (bool ok, uint256 used, uint256 out)
    {
        try this.swapFor(pid, amountIn, limit, minOut) returns (uint256 u, uint256 o) {
            return (true, u, o);
        } catch {
            return (false, 0, 0);
        }
    }

    function _sell(uint256 pid, uint256 amount) internal returns (uint256 out) {
        IERC20(Currency.unwrap(_key(pid).currency1)).approve(address(swapper), amount);
        (, out) = swapper.swap(_key(pid), false, amount, TickMath.MAX_SQRT_PRICE - 1, 0);
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
            swapper.swap{value: 1 ether}(_key(pid), true, 1 ether, _issuanceLimit(pid), 0);
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

    /// @dev Front-runs a buy of `amount` with a pool buy limited at issuance (the attacker's best), then sells the
    /// attacker's tokens back. Front-runs are `k * k * amount / 300` for `k` in 1..30 without a minimum (up to 3x the
    /// buy), and `k * k * amount / 60_000` for `k` in 1..60 with one (up to 6%, where attacks still pass the minimum).
    /// The victim's buy carries the unattacked quote less `slippageBps` (10_000 sends no minimum). Runs on 1.3.0 when
    /// `upgraded`, else on the deployed 1.2.0 hook. Returns the attacker's best profit, the victim's worst loss against
    /// the unattacked buy among buys that went through, how many attacks made the victim's buy revert, the unattacked
    /// output, and whether the unattacked buy used its whole input.
    function _sandwich(
        uint256 pid,
        uint256 amount,
        uint256 slippageBps,
        bool upgraded
    )
        internal
        returns (uint256 bestProfit, uint256 worstLoss, uint256 reverts, uint256 honest, bool filled)
    {
        uint256 start = vm.snapshotState();
        if (upgraded) _upgrade();
        uint256 base = vm.snapshotState();
        uint256 honestUsed;
        (, honestUsed, honest) = _buy(pid, amount);
        filled = honestUsed == amount;
        vm.revertToState(base);
        uint256 minOut = honest * (10_000 - slippageBps) / 10_000;
        for (uint256 k = 1; k <= (slippageBps == 10_000 ? 30 : 60); k++) {
            uint256 x = k * k * amount / (slippageBps == 10_000 ? 300 : 60_000);
            uint256 snap = vm.snapshotState();
            (uint256 used, uint256 bought) = swapper.swap{value: x}(_key(pid), true, x, _issuanceLimit(pid), 0);
            (bool ok,, uint256 victim) = _buy(pid, amount, minOut);
            uint256 back = _sell(pid, bought);
            vm.revertToState(snap);

            if (!ok) {
                reverts++;
                continue;
            }
            if (upgraded) assertGe(victim + 1e6, _mintAll(pid, amount), "the victim never gets less than issuance");
            if (back > used && back - used > bestProfit) bestProfit = back - used;
            if (honest > victim && honest - victim > worstLoss) worstLoss = honest - victim;
        }
        vm.revertToState(start);
    }

    /// @notice Sandwiches of a buy sent with no minimum, on 1.3.0 and on the deployed 1.2.0 under the same attacks. On
    /// 1.3.0 the victim still gets at least minting everything; the pool's surplus above issuance is exposed.
    function test_sandwich_victimSetsNoMinimum_p13() public {
        _sandwiches(13, 10_000);
    }

    function test_sandwich_victimSetsNoMinimum_p7() public {
        _sandwiches(7, 10_000);
    }

    /// @notice The same attacks on a buy carrying a client's minimum: the unattacked quote less 0.5%. The victim loses
    /// at most that, and the attacker nets no more than the same attack nets on 1.2.0 wherever 1.2.0 fills the buy.
    function test_sandwich_victimSetsHalfPercentMinimum_p13() public {
        _sandwiches(13, 50);
    }

    function test_sandwich_victimSetsHalfPercentMinimum_p7() public {
        _sandwiches(7, 50);
    }

    /// @notice The same, with a 1% minimum.
    function test_sandwich_victimSetsOnePercentMinimum_p13() public {
        _sandwiches(13, 100);
    }

    function test_sandwich_victimSetsOnePercentMinimum_p7() public {
        _sandwiches(7, 100);
    }

    function _sandwiches(uint256 pid, uint256 slippageBps) internal {
        uint256 base = pid == 13 ? 0.001 ether : 0.1 ether;
        _compareSandwich(pid, base, slippageBps);
        _compareSandwich(pid, base * 10, slippageBps);
        _compareSandwich(pid, base * 100, slippageBps);
    }

    function _compareSandwich(uint256 pid, uint256 amount, uint256 slippageBps) internal {
        (uint256 deployedProfit, bool deployedFilled) = _runSandwich(pid, amount, slippageBps, false);
        (uint256 profit,) = _runSandwich(pid, amount, slippageBps, true);
        if (slippageBps != 10_000 && deployedFilled) {
            assertLe(profit, deployedProfit, "with a minimum, no more extractable than on 1.2.0");
        }
    }

    function _runSandwich(
        uint256 pid,
        uint256 amount,
        uint256 slippageBps,
        bool upgraded
    )
        internal
        returns (uint256 profit, bool filled)
    {
        uint256 loss;
        uint256 reverts;
        uint256 honest;
        (profit, loss, reverts, honest, filled) = _sandwich(pid, amount, slippageBps, upgraded);
        if (slippageBps != 10_000) {
            assertLe(loss, honest * slippageBps / 10_000, "the victim loses at most its slippage");
        }
        _logSandwich(upgraded, pid, amount, slippageBps, profit, loss, reverts, honest);
    }

    function _logSandwich(
        bool upgraded,
        uint256 pid,
        uint256 amount,
        uint256 slippageBps,
        uint256 profit,
        uint256 loss,
        uint256 reverts,
        uint256 honest
    )
        internal
    {
        emit log_string(string.concat(
                "sandwich | ",
                upgraded ? "1.3.0" : "1.2.0",
                " | ",
                vm.toString(pid),
                " | ",
                vm.toString(amount),
                " | min bps ",
                slippageBps == 10_000 ? "none" : vm.toString(slippageBps),
                " | profit wei ",
                vm.toString(profit),
                " | victim loss bps ",
                vm.toString(honest == 0 ? 0 : loss * 10_000 / honest),
                " | reverts ",
                vm.toString(reverts),
                " | honest ",
                vm.toString(honest),
                " | mintAll ",
                vm.toString(_mintAll(pid, amount)),
                " |"
            ));
    }

    //*********************************************************************//
    // ------------------- 1.3.0 against 1.2.0, case by case ------------- //
    //*********************************************************************//

    /// @dev What a buy leaves the buyer: the tokens, plus unspent input valued at minting (the buyer can still pay the
    /// terminal with it). A reverted buy leaves the whole input.
    function _buyerValue(
        uint256 pid,
        uint256 amount,
        bool ok,
        uint256 used,
        uint256 out
    )
        internal
        pure
        returns (uint256)
    {
        return ok ? out + _mintAll(pid, amount - used) : _mintAll(pid, amount);
    }

    /// @notice Every honest buy in every pool state, with the router-standard extreme limit (the split path) and with a
    /// limit at the fee-free issuance price (the plain-swap path): 1.3.0 leaves the buyer at least what 1.2.0 does,
    /// with unspent input valued at minting.
    function test_compare_honestBuys() public {
        uint256[6] memory sizes = [uint256(0.0001 ether), 0.001 ether, 0.01 ether, 0.1 ether, 1 ether, 10 ether];
        for (uint256 p; p < 2; p++) {
            uint256 pid = p == 0 ? 13 : 7;
            for (uint256 state; state < 3; state++) {
                for (uint256 plain; plain < 2; plain++) {
                    for (uint256 i; i < sizes.length; i++) {
                        _compareBuy(
                            pid, state, sizes[i], plain == 1 ? _issuanceLimit(pid) : TickMath.MIN_SQRT_PRICE + 1
                        );
                    }
                }
            }
        }
    }

    function _compareBuy(uint256 pid, uint256 state, uint256 amount, uint160 limit) internal {
        uint256 snap = vm.snapshotState();
        _setState(pid, state);
        (bool ok, uint256 used, uint256 out) = _buy(pid, amount, limit, 0);
        uint256 deployed = _buyerValue(pid, amount, ok, used, out);
        vm.revertToState(snap);
        _setState(pid, state);
        _upgrade();
        (bool ok2, uint256 used2, uint256 out2) = _buy(pid, amount, limit, 0);
        uint256 updated = _buyerValue(pid, amount, ok2, used2, out2);
        vm.revertToState(snap);
        _logCompare(
            "buy", pid, state, amount, limit == TickMath.MIN_SQRT_PRICE + 1 ? "split" : "plain", deployed, updated
        );
        assertGe(updated, deployed, "1.3.0 leaves the buyer at least what 1.2.0 does");
    }

    /// @dev A sell that counts a revert (a pool already at its price bound) as no output.
    function _trySell(uint256 pid, uint256 amount) internal returns (uint256 out) {
        IERC20(Currency.unwrap(_key(pid).currency1)).approve(address(swapper), amount);
        try swapper.swap(_key(pid), false, amount, TickMath.MAX_SQRT_PRICE - 1, 0) returns (uint256, uint256 o) {
            out = o;
        } catch {}
    }

    /// @notice Every sell in every pool state: sells route the same way on both versions.
    function test_compare_sells() public {
        uint256[4] memory ethWorth = [uint256(0.001 ether), 0.01 ether, 0.1 ether, 1 ether];
        for (uint256 p; p < 2; p++) {
            uint256 pid = p == 0 ? 13 : 7;
            for (uint256 state; state < 3; state++) {
                for (uint256 i; i < ethWorth.length; i++) {
                    uint256 tokens = _mintAll(pid, ethWorth[i]);
                    uint256 snap = vm.snapshotState();
                    _setState(pid, state);
                    deal(Currency.unwrap(_key(pid).currency1), address(this), tokens, true);
                    uint256 deployed = _trySell(pid, tokens);
                    vm.revertToState(snap);
                    _setState(pid, state);
                    deal(Currency.unwrap(_key(pid).currency1), address(this), tokens, true);
                    _upgrade();
                    uint256 updated = _trySell(pid, tokens);
                    vm.revertToState(snap);
                    _logCompare("sell", pid, state, tokens, "sell", deployed, updated);
                    assertGe(updated, deployed, "sells leave the seller at least what 1.2.0 does");
                }
            }
        }
    }

    /// @notice Each attack from the sandwich search, run on both versions against a victim whose client quotes on the
    /// version it uses and sends no minimum: 1.3.0 leaves the victim at least what 1.2.0 does under the same attack.
    function test_compare_attackedBuys_noMinimum_p13() public {
        _compareAttacks(13, 10_000);
    }

    function test_compare_attackedBuys_noMinimum_p7() public {
        _compareAttacks(7, 10_000);
    }

    /// @notice The same with a 0.5% minimum.
    function test_compare_attackedBuys_halfPercentMinimum_p13() public {
        _compareAttacks(13, 50);
    }

    function test_compare_attackedBuys_halfPercentMinimum_p7() public {
        _compareAttacks(7, 50);
    }

    /// @notice The same with a 1% minimum.
    function test_compare_attackedBuys_onePercentMinimum_p13() public {
        _compareAttacks(13, 100);
    }

    function test_compare_attackedBuys_onePercentMinimum_p7() public {
        _compareAttacks(7, 100);
    }

    function _compareAttacks(uint256 pid, uint256 slippageBps) internal {
        uint256 base = pid == 13 ? 0.001 ether : 0.1 ether;
        _compareAttacksOn(pid, base, slippageBps);
        _compareAttacksOn(pid, base * 10, slippageBps);
        _compareAttacksOn(pid, base * 100, slippageBps);
    }

    function _compareAttacksOn(uint256 pid, uint256 amount, uint256 slippageBps) internal {
        uint256 snap = vm.snapshotState();
        (,, uint256 honest) = _buy(pid, amount);
        vm.revertToState(snap);
        _upgrade();
        (,, uint256 honest2) = _buy(pid, amount);
        vm.revertToState(snap);

        uint256 worstGap;
        uint256 worstX;
        for (uint256 k = 1; k <= (slippageBps == 10_000 ? 30 : 60); k++) {
            uint256 x = k * k * amount / (slippageBps == 10_000 ? 300 : 60_000);
            uint256 deployed = _attackedVictimValue(pid, amount, x, honest * (10_000 - slippageBps) / 10_000, false);
            uint256 updated = _attackedVictimValue(pid, amount, x, honest2 * (10_000 - slippageBps) / 10_000, true);
            if (deployed > updated && deployed - updated > worstGap) {
                worstGap = deployed - updated;
                worstX = x;
            }
        }
        emit log_string(string.concat(
                "attacked | ",
                vm.toString(pid),
                " | ",
                vm.toString(amount),
                " | min bps ",
                slippageBps == 10_000 ? "none" : vm.toString(slippageBps),
                " | worst 1.2.0 minus 1.3.0 ",
                vm.toString(worstGap),
                " | at front-run ",
                vm.toString(worstX),
                " |"
            ));
        assertEq(worstGap, 0, "1.3.0 leaves the victim at least what 1.2.0 does under the same attack");
    }

    function _attackedVictimValue(
        uint256 pid,
        uint256 amount,
        uint256 x,
        uint256 minOut,
        bool upgraded
    )
        internal
        returns (uint256 value)
    {
        uint256 snap = vm.snapshotState();
        if (upgraded) _upgrade();
        swapper.swap{value: x}(_key(pid), true, x, _issuanceLimit(pid), 0);
        (bool ok, uint256 used, uint256 out) = _buy(pid, amount, minOut);
        value = _buyerValue(pid, amount, ok, used, out);
        vm.revertToState(snap);
    }

    function _logCompare(
        string memory kind,
        uint256 pid,
        uint256 state,
        uint256 amount,
        string memory path,
        uint256 deployed,
        uint256 updated
    )
        internal
    {
        emit log_string(string.concat(
                "cmp | ",
                kind,
                " | ",
                vm.toString(pid),
                " | ",
                vm.toString(state),
                " | ",
                vm.toString(amount),
                " | ",
                path,
                " | ",
                vm.toString(deployed),
                " | ",
                vm.toString(updated),
                " |"
            ));
    }
}
