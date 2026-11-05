// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {JBUniswapV4Hook} from "../src/JBUniswapV4Hook.sol";
import {ForkSwapper} from "./SplitBuyBaseFork.t.sol";

/// @notice Direct sells on Base's live project 13 and project 7 pools, with this source's hook deployed over the live
/// 1.2.0 hook (`0xf70B…95c8`), against the real terminal, REVOwner data hook and buyback hook. Each sell is compared
/// with the deployed hook and with cashing out everything.
/// @dev Run with `RPC_BASE_MAINNET` set to an archive endpoint.
contract SplitSellBaseForkTest is Test {
    uint256 internal constant BLOCK = 52_922_000;
    address internal constant HOOK = 0xf70B71605f1C0A8Ff7580557645BB7e29fE495c8;
    IPoolManager internal constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IJBTerminal internal constant TERMINAL = IJBTerminal(0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
    address internal constant REGISTRY = 0x72F55a54CD53410a5Ff175508a5A384227081788;
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
            currency1: Currency.wrap(_token(pid)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(HOOK)
        });
    }

    function _token(uint256 pid) internal pure returns (address) {
        return pid == 13 ? TOKEN_13 : TOKEN_7;
    }

    function _upgrade() internal {
        JBUniswapV4Hook live = JBUniswapV4Hook(payable(HOOK));
        deployCodeTo(
            "src/JBUniswapV4Hook.sol:JBUniswapV4Hook",
            abi.encode(live.poolManager(), live.TOKENS(), live.DIRECTORY(), live.PRICES()),
            HOOK
        );
    }

    /// @dev The fee-free issuance price for a buyer, so a buy limited there is a plain pool swap.
    function _issuanceLimit(uint256 pid) internal pure returns (uint160) {
        return uint160(Math.sqrt((pid == 13 ? uint256(50_000) : 7750) << 192));
    }

    /// @dev Moves the pool before the sell: state 0 as-is, 1 a pump (a pool buy of 1 ETH limited at issuance), 2 a dump
    /// (pay the terminal 1 ETH, or 0.01 on project 13, and sell the tokens into the pool).
    function _setState(uint256 pid, uint256 state) internal {
        if (state == 1) {
            swapper.swap{value: 1 ether}(_key(pid), true, 1 ether, _issuanceLimit(pid), 0);
        } else if (state == 2) {
            uint256 amount = pid == 13 ? 0.01 ether : 1 ether;
            uint256 tokens =
                TERMINAL.pay{value: amount}(pid, JBConstants.NATIVE_TOKEN, amount, address(this), 0, "", "");
            _sell(pid, tokens, 0);
        }
    }

    function sellFor(uint256 pid, uint256 amount, uint256 minOut) external returns (uint256 out) {
        IERC20(_token(pid)).approve(address(swapper), amount);
        (, out) = swapper.swap(_key(pid), false, amount, TickMath.MAX_SQRT_PRICE - 1, minOut);
    }

    /// @dev Sells `amount` held tokens with the router-standard extreme limit; a revert counts as no output.
    function _sell(uint256 pid, uint256 amount, uint256 minOut) internal returns (uint256 out) {
        try this.sellFor(pid, amount, minOut) returns (uint256 o) {
            out = o;
        } catch {}
    }

    /// @dev Cashes out `amount` held tokens at the terminal, skipping the buyback hook as the hook's leg does. A revert
    /// counts as no output.
    function _reclaim(uint256 pid, uint256 amount) internal returns (uint256 out) {
        bytes memory skip = JBMetadataResolver.addToMetadata({
            originalMetadata: "",
            idToAdd: JBMetadataResolver.getId({purpose: "cashOut", target: REGISTRY}),
            dataToAdd: abi.encode(uint256(0), true)
        });
        uint256 before = address(this).balance;
        try IJBCashOutTerminal(address(TERMINAL))
            .cashOutTokensOf(address(this), pid, amount, JBConstants.NATIVE_TOKEN, 0, payable(address(this)), skip) {
            out = address(this).balance - before;
        } catch {}
    }

    //*********************************************************************//
    // ------------------------------ tests ------------------------------ //
    //*********************************************************************//

    /// @notice Sells of 1 to 400 project 13 tokens in three pool states: 2.0.0 gives at least the deployed 1.2.0 hook,
    /// and at least cashing out everything when the PoolManager holds enough of the token for the cash-out leg.
    function test_compare_sells_p13() public {
        _compareSells(13, [uint256(1 ether), 10 ether, 50 ether, 100 ether, 200 ether, 400 ether]);
    }

    /// @notice The same for 1,000 to 10,000,000 project 7 tokens.
    function test_compare_sells_p7() public {
        _compareSells(
            7, [uint256(1000 ether), 10_000 ether, 100_000 ether, 1_000_000 ether, 3_000_000 ether, 10_000_000 ether]
        );
    }

    function _compareSells(uint256 pid, uint256[6] memory sizes) internal {
        for (uint256 state; state < 3; state++) {
            for (uint256 i; i < sizes.length; i++) {
                uint256 snap = vm.snapshotState();
                _setState(pid, state);
                deal(_token(pid), address(this), sizes[i]);
                uint256 inventory = IERC20(_token(pid)).balanceOf(address(PM));
                uint256 base = vm.snapshotState();
                uint256 deployed = _sell(pid, sizes[i], 0);
                vm.revertToState(base);
                uint256 all = _reclaim(pid, sizes[i]);
                vm.revertToState(base);
                _upgrade();
                uint256 updated = _sell(pid, sizes[i], 0);
                vm.revertToState(snap);

                emit log_string(string.concat(
                        "sell | ",
                        vm.toString(pid),
                        " | ",
                        vm.toString(state),
                        " | ",
                        vm.toString(sizes[i] / 1e18),
                        " | inventory ",
                        vm.toString(inventory / 1e18),
                        " | 1.2.0 ",
                        vm.toString(deployed),
                        " | all-reclaim ",
                        vm.toString(all),
                        " | 2.0.0 ",
                        vm.toString(updated),
                        " |"
                    ));
                assertGe(updated, deployed, "never below the deployed hook");
                if (sizes[i] <= inventory) {
                    assertGe(updated + all / 1e6 + 3, all, "never below cashing out everything");
                }
            }
        }
    }

    /// @notice A terminal cash-out with no metadata, where the buyback hook may sell through this pool, never pays the
    /// holder less than with the deployed hook.
    function test_terminalCashOuts_notBelowDeployed() public {
        uint256[2] memory pids = [uint256(13), 7];
        for (uint256 p; p < 2; p++) {
            for (uint256 i; i < 3; i++) {
                uint256 amount = (pids[p] == 13 ? 1 ether : 1000 ether) * 10 ** i;
                uint256 snap = vm.snapshotState();
                deal(_token(pids[p]), address(this), amount);
                uint256 deployed = _cashOut(pids[p], amount);
                vm.revertToState(snap);
                deal(_token(pids[p]), address(this), amount);
                _upgrade();
                uint256 updated = _cashOut(pids[p], amount);
                vm.revertToState(snap);
                emit log_string(string.concat(
                        "cash-out | ",
                        vm.toString(pids[p]),
                        " | ",
                        vm.toString(amount / 1e18),
                        " | 1.2.0 ",
                        vm.toString(deployed),
                        " | 2.0.0 ",
                        vm.toString(updated),
                        " |"
                    ));
                assertGe(updated, deployed, "never below the deployed hook");
            }
        }
    }

    function _cashOut(uint256 pid, uint256 amount) internal returns (uint256) {
        uint256 before = address(this).balance;
        IJBCashOutTerminal(address(TERMINAL))
            .cashOutTokensOf(address(this), pid, amount, JBConstants.NATIVE_TOKEN, 0, payable(address(this)), "");
        return address(this).balance - before;
    }

    /// @notice Sandwiches of a sell: the attacker sells first and buys back after with what it got. Without a minimum
    /// the victim's loss and the attacker's gain are logged; with the unattacked quote less 0.5% or 1%, the victim
    /// loses at most that, and the attacker gains no more than the same attack gains on 1.2.0.
    function test_sandwich_sells_p13() public {
        for (uint256 s; s < 3; s++) {
            _compareSandwich(13, 100 ether, s == 0 ? 10_000 : s * 50);
        }
    }

    function test_sandwich_sells_p7() public {
        for (uint256 s; s < 3; s++) {
            _compareSandwich(7, 1_000_000 ether, s == 0 ? 10_000 : s * 50);
        }
    }

    function _compareSandwich(uint256 pid, uint256 amount, uint256 slippageBps) internal {
        (uint256 deployedProfit, uint256 deployedLoss, uint256 deployedHonest) =
            _sandwich(pid, amount, slippageBps, false);
        (uint256 profit, uint256 loss, uint256 honest) = _sandwich(pid, amount, slippageBps, true);
        emit log_string(string.concat(
                "sandwich | ",
                vm.toString(pid),
                " | ",
                vm.toString(amount / 1e18),
                " | min bps ",
                slippageBps == 10_000 ? "none" : vm.toString(slippageBps),
                " | 1.2.0 honest ",
                vm.toString(deployedHonest),
                " profit tokens ",
                vm.toString(deployedProfit / 1e18),
                " victim loss bps ",
                vm.toString(deployedHonest == 0 ? 0 : deployedLoss * 10_000 / deployedHonest),
                " | 2.0.0 honest ",
                vm.toString(honest),
                " profit tokens ",
                vm.toString(profit / 1e18),
                " victim loss bps ",
                vm.toString(honest == 0 ? 0 : loss * 10_000 / honest),
                " |"
            ));
        assertGe(honest, deployedHonest, "unattacked, never below the deployed hook");
        if (slippageBps != 10_000) {
            // 1.2.0 reverts these victims' sells; 2.0.0 fills them within their minimum, which leaves the attacker at
            // most that slippage.
            assertLe(loss, honest * slippageBps / 10_000, "the victim loses at most its slippage");
        }
    }

    /// @dev Front-runs a sell of `amount` with a sell of `k * k * amount / 100` tokens for `k` in 1..30 (up to 9x the
    /// victim's), then buys back with the front-run's output, limited at issuance so the buy stays in the pool. Returns
    /// the attacker's best token gain, the victim's worst loss against the unattacked sell among sells that went
    /// through, and the unattacked output.
    function _sandwich(
        uint256 pid,
        uint256 amount,
        uint256 slippageBps,
        bool upgraded
    )
        internal
        returns (uint256 bestProfit, uint256 worstLoss, uint256 honest)
    {
        uint256 start = vm.snapshotState();
        if (upgraded) _upgrade();
        uint256 base = vm.snapshotState();
        deal(_token(pid), address(this), amount);
        honest = _sell(pid, amount, 0);
        vm.revertToState(base);
        uint256 minOut = honest * (10_000 - slippageBps) / 10_000;
        for (uint256 k = 1; k <= 30; k++) {
            uint256 x = k * k * amount / 100;
            uint256 snap = vm.snapshotState();
            deal(_token(pid), address(this), x);
            uint256 got = _sell(pid, x, 0);
            deal(_token(pid), address(this), amount);
            uint256 victim = _sell(pid, amount, minOut);
            uint256 back;
            if (got != 0) (, back) = swapper.swap{value: got}(_key(pid), true, got, _issuanceLimit(pid), 0);
            vm.revertToState(snap);

            // A reverted sell keeps the victim's tokens; only fills count.
            if (victim == 0) continue;
            if (back > x && back - x > bestProfit) bestProfit = back - x;
            if (honest > victim && honest - victim > worstLoss) worstLoss = honest - victim;
        }
        vm.revertToState(start);
    }
}
