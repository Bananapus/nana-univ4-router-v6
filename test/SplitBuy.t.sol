// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {IJBDirectory, IJBPrices, IJBTokens, JBUniswapV4Hook} from "../src/JBUniswapV4Hook.sol";
import {JBUniswapV4HookData} from "../src/libraries/JBUniswapV4HookData.sol";
import {MockERC20WithDecimals} from "./mock/MockERC20.sol";

/// @notice Exact-input swaps with a chosen price limit and raw hook data. Settles the whole input up front and takes
/// back whatever the swap leaves.
contract SplitBuySwapper is IUnlockCallback {
    IPoolManager internal immutable PM;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    receive() external payable {}

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96,
        bytes calldata hookData
    )
        external
        payable
        returns (uint256 used, uint256 out)
    {
        (used, out) = abi.decode(
            PM.unlock(abi.encode(key, zeroForOne, amountIn, sqrtPriceLimitX96, hookData, msg.sender)),
            (uint256, uint256)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (
            PoolKey memory key,
            bool zeroForOne,
            uint256 amountIn,
            uint160 sqrtPriceLimitX96,
            bytes memory hookData,
            address payer
        ) = abi.decode(data, (PoolKey, bool, uint256, uint160, bytes, address));
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        if (input.isAddressZero()) {
            PM.settle{value: amountIn}();
        } else {
            PM.sync(input);
            require(IERC20(Currency.unwrap(input)).transferFrom(payer, address(PM), amountIn));
            PM.settle();
        }
        BalanceDelta d = PM.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData: hookData
        });
        uint256 used = uint256(uint128(-(zeroForOne ? d.amount0() : d.amount1())));
        uint256 out = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
        if (amountIn > used) PM.take({currency: input, to: payer, amount: amountIn - used});
        if (out != 0) PM.take({currency: output, to: payer, amount: out});
        return abi.encode(used, out);
    }
}

/// @notice A data hook shaped like the buyback hook: it can send the whole pay to its own pay hook, which tries to
/// swap through the PoolManager and, when that fails, adds the pay back to the balance and mints at the weight.
contract BuybackShapedHook is IJBRulesetDataHook, IJBPayHook {
    IPoolManager internal immutable PM;
    IJBController internal immutable CONTROLLER;
    bool public divert;
    bool public deliver = true;

    constructor(IPoolManager pm, IJBController controller) {
        PM = pm;
        CONTROLLER = controller;
    }

    function setBehavior(bool divertPays, bool deliverTokens) external {
        divert = divertPays;
        deliver = deliverTokens;
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        if (!divert) return (context.weight, hookSpecifications);
        hookSpecifications = new JBPayHookSpecification[](1);
        hookSpecifications[0] = JBPayHookSpecification({
            hook: IJBPayHook(address(this)), noop: false, amount: context.amount.value, metadata: ""
        });
        return (0, hookSpecifications);
    }

    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable {
        // Inside a pool swap the PoolManager is already unlocked, so this reverts and the pay mints instead.
        try PM.unlock("") {} catch {}
        if (!deliver) return;
        IJBTerminal(msg.sender).addToBalanceOf{value: msg.value}({
            projectId: context.projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: msg.value,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
        });
        CONTROLLER.mintTokensOf({
            projectId: context.projectId,
            tokenCount: FullMath.mulDiv({a: msg.value, b: context.weight, denominator: 1e18}),
            beneficiary: context.beneficiary,
            memo: "",
            useReservedPercent: true
        });
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        returns (uint256, uint256, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        return (
            context.cashOutTaxRate, context.cashOutCount, context.totalSupply, context.surplus.value, hookSpecifications
        );
    }

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure returns (bool) {
        return true;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Exact-input swaps in a router's order: swap first, then settle what was used and take the output, so the
/// PoolManager holds none of the input during the swap.
contract SplitSellSwapper is IUnlockCallback {
    IPoolManager internal immutable PM;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    receive() external payable {}

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        bytes calldata hookData
    )
        external
        returns (uint256 used, uint256 out)
    {
        (used, out) =
            abi.decode(PM.unlock(abi.encode(key, zeroForOne, amountIn, hookData, msg.sender)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, bytes, address));
        BalanceDelta d = PM.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData: hookData
        });
        uint256 used = uint256(uint128(-(zeroForOne ? d.amount0() : d.amount1())));
        uint256 out = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        PM.sync(input);
        require(IERC20(Currency.unwrap(input)).transferFrom(payer, address(PM), used));
        PM.settle();
        PM.take({currency: zeroForOne ? key.currency1 : key.currency0, to: payer, amount: out});
        return abi.encode(used, out);
    }
}

/// @notice Exact-input swaps in a router's order with a chosen price limit: swap first, then settle what was used and
/// take the output, so the PoolManager holds none of the input during the swap.
contract RouterOrderSwapper is IUnlockCallback {
    IPoolManager internal immutable PM;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    receive() external payable {}

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    )
        external
        payable
        returns (uint256 used, uint256 out)
    {
        (used, out) = abi.decode(
            PM.unlock(abi.encode(key, zeroForOne, amountIn, sqrtPriceLimitX96, msg.sender)), (uint256, uint256)
        );
        if (address(this).balance != 0) payable(msg.sender).transfer(address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimitX96, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, uint160, address));
        BalanceDelta d = PM.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData: ""
        });
        uint256 used = uint256(uint128(-(zeroForOne ? d.amount0() : d.amount1())));
        uint256 out = uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        if (input.isAddressZero()) {
            PM.settle{value: used}();
        } else {
            PM.sync(input);
            require(IERC20(Currency.unwrap(input)).transferFrom(payer, address(PM), used));
            PM.settle();
        }
        if (out != 0) PM.take({currency: zeroForOne ? key.currency1 : key.currency0, to: payer, amount: out});
        return abi.encode(used, out);
    }
}

/// @notice A cash-out data hook that names a buyback registry and accepts only cash-outs whose metadata tells that
/// registry to skip its pool sale.
contract SkipCheckingDataHook is IJBRulesetDataHook {
    address public constant BUYBACK_HOOK = address(0x7E61);

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        pure
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        return (context.weight, hookSpecifications);
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        returns (uint256, uint256, uint256, uint256, JBCashOutHookSpecification[] memory hookSpecifications)
    {
        (bool found, bytes memory data) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId({purpose: "cashOut", target: BUYBACK_HOOK}), metadata: context.metadata
        });
        require(found, "no skip entry");
        (uint256 minimum, bool skip) = abi.decode(data, (uint256, bool));
        require(minimum == 0 && skip, "not a skip");
        return
            (
                context.cashOutTaxRate,
                context.cashOutCount,
                context.totalSupply,
                context.surplus.value,
                hookSpecifications
            );
    }

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Buys of a project token fill from the pool while it beats the payer's issuance rate and mint the rest, and
/// sells fill from the pool while it beats the marginal reclaim rate and cash out the rest, against real Juicebox core
/// contracts and a real PoolManager.
contract SplitBuyTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant OWNER = address(0xBEEF);
    uint256 internal constant WEIGHT = 50_000e18; // project tokens per ETH, as Base project 13

    JBDirectory internal directory;
    JBTokens internal tokens;
    JBPrices internal prices;
    JBController internal controller;
    JBMultiTerminal internal terminal;

    IPoolManager internal manager;
    JBUniswapV4Hook internal hook;
    SplitBuySwapper internal swapper;
    PoolModifyLiquidityTest internal liquidityRouter;
    BuybackShapedHook internal dataHook;
    SplitSellSwapper internal sellSwapper;
    RouterOrderSwapper internal routerSwapper;

    /// @dev The cash-out tax rate and cash-out data hook `_launch` gives a project.
    uint16 internal cashOutTaxRate;
    address internal cashOutDataHook;

    /// @dev Whether `_sellSetup` launches the sold project as project 1, the fee project.
    bool internal sellFeeProject;

    receive() external payable {}

    function setUp() public {
        JBPermissions permissions = new JBPermissions(address(0));
        JBProjects projects = new JBProjects(OWNER, address(0), address(0));
        directory = new JBDirectory(permissions, projects, OWNER);
        tokens = new JBTokens(directory, new JBERC20({permissions: permissions, projects: projects}));
        JBRulesets rulesets = new JBRulesets(directory);
        prices = new JBPrices(directory, permissions, projects, OWNER, address(0));
        controller = new JBController(
            directory,
            new JBFundAccessLimits(directory),
            permissions,
            prices,
            projects,
            rulesets,
            new JBSplits(directory),
            tokens,
            address(0),
            address(0)
        );
        vm.prank(OWNER);
        directory.setIsAllowedToSetFirstController(address(controller), true);
        terminal = new JBMultiTerminal(
            new JBFeelessAddresses(OWNER),
            permissions,
            projects,
            new JBSplits(directory),
            new JBTerminalStore(directory, prices, rulesets),
            tokens,
            IPermit2(address(0)),
            address(0)
        );

        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        swapper = new SplitBuySwapper(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        dataHook = new BuybackShapedHook(manager, controller);
        sellSwapper = new SplitSellSwapper(manager);
        routerSwapper = new RouterOrderSwapper(manager);

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(manager, IJBTokens(address(tokens)), IJBDirectory(address(directory)), prices);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, args);
        hook = new JBUniswapV4Hook{salt: salt}(
            manager, IJBTokens(address(tokens)), IJBDirectory(address(directory)), IJBPrices(address(prices))
        );

        vm.deal(address(this), 1e30);
    }

    //*********************************************************************//
    // ------------------------------ setup ------------------------------ //
    //*********************************************************************//

    /// @dev Launches a project that accepts `acceptedToken` and mints `weight` per whole unit of it, with its ERC-20.
    function _launch(
        address acceptedToken,
        uint8 decimals,
        uint256 weight,
        uint16 reservedPercent,
        bool withDataHook
    )
        internal
        returns (uint256 projectId, address projectToken)
    {
        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        rulesetConfigs[0].weight = uint112(weight);
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = JBRulesetMetadata({
            reservedPercent: reservedPercent,
            cashOutTaxRate: cashOutTaxRate,
            // forge-lint: disable-next-line(unsafe-typecast)
            baseCurrency: uint32(uint160(acceptedToken)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: withDataHook,
            useDataHookForCashOut: cashOutDataHook != address(0),
            dataHook: withDataHook ? address(dataHook) : cashOutDataHook,
            metadata: 0
        });
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: acceptedToken, decimals: decimals, currency: uint32(uint160(acceptedToken))});
        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](1);
        terminals[0] = JBTerminalConfig({terminal: terminal, accountingContextsToAccept: contexts});

        projectId = controller.launchProjectFor({
            owner: OWNER,
            projectUri: "",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminals,
            memo: ""
        });
        vm.prank(OWNER);
        projectToken = address(controller.deployERC20For({projectId: projectId, name: "P", symbol: "P", salt: 0}));
    }

    /// @dev A pool for `input`/`projectToken` priced at `poolPercent`% of the issuance rate (output per input), with
    /// `liquidity` over `halfWidth` tick spacings on each side of the price. Fee 1%, tick spacing 200.
    function _pool(
        address input,
        address projectToken,
        uint256 issuancePerInput18,
        uint256 poolPercent,
        uint128 liquidity,
        int24 halfWidth,
        uint24 fee
    )
        internal
        returns (PoolKey memory key, bool zeroForOne)
    {
        zeroForOne = input < projectToken;
        key = PoolKey({
            currency0: Currency.wrap(zeroForOne ? input : projectToken),
            currency1: Currency.wrap(zeroForOne ? projectToken : input),
            fee: fee,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        // Price as token1 per token0, in Q192.
        uint256 rate18 = issuancePerInput18 * poolPercent / 100;
        uint256 ratioX192 = zeroForOne
            ? FullMath.mulDiv({a: rate18, b: 1 << 192, denominator: 1e18})
            : FullMath.mulDiv({a: 1e18, b: 1 << 192, denominator: rate18});
        uint160 sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
        manager.initialize(key, sqrtPriceX96);

        if (liquidity != 0) {
            int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96) / 200 * 200;
            _fund(key.currency0);
            _fund(key.currency1);
            liquidityRouter.modifyLiquidity{value: key.currency0.isAddressZero() ? 1e29 : 0}(
                key,
                ModifyLiquidityParams({
                    tickLower: tick - halfWidth * 200,
                    tickUpper: tick + halfWidth * 200,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: 0
                }),
                ""
            );
        }
    }

    function _fund(Currency currency) internal {
        if (currency.isAddressZero()) return;
        address token = Currency.unwrap(currency);
        if (tokens.projectIdOf(IJBToken(token)) != 0) {
            // Mint project tokens for the LP by paying the project directly.
            uint256 projectId = tokens.projectIdOf(IJBToken(token));
            vm.prank(address(controller));
            tokens.mintFor({holder: address(this), projectId: projectId, count: 1e33});
        } else {
            MockERC20WithDecimals(token).mint(address(this), 1e33);
        }
        IERC20(token).approve(address(liquidityRouter), type(uint256).max);
        IERC20(token).approve(address(swapper), type(uint256).max);
    }

    /// @dev Buys with `amountIn` of the pool's input, returning the project tokens received.
    function _buy(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 limit,
        bytes memory hookData
    )
        internal
        returns (uint256 out)
    {
        bool native = (zeroForOne ? key.currency0 : key.currency1).isAddressZero();
        (, out) = swapper.swap{value: native ? amountIn : 0}(key, zeroForOne, amountIn, limit, hookData);
    }

    function _extreme(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev What paying the terminal directly mints for the payer.
    function _mintAll(uint256 projectId, address token, uint256 amount) internal view returns (uint256 count) {
        (, count,,) = terminal.previewPayFor(projectId, token, amount, address(this), "");
    }

    function _supply(address projectToken) internal view returns (uint256) {
        return IERC20(projectToken).totalSupply();
    }

    /// @dev A native-ETH project at 50,000 tokens per ETH and its pool.
    function _nativeSetup(
        uint16 reservedPercent,
        uint256 poolPercent,
        uint128 liquidity
    )
        internal
        returns (uint256 projectId, address projectToken, PoolKey memory key)
    {
        (projectId, projectToken) = _launch(JBConstants.NATIVE_TOKEN, 18, WEIGHT, reservedPercent, false);
        uint256 rate = _mintAll(projectId, JBConstants.NATIVE_TOKEN, 1e18);
        (key,) = _pool(address(0), projectToken, rate, poolPercent, liquidity, 10, 10_000);
    }

    //*********************************************************************//
    // ------------------------------ tests ------------------------------ //
    //*********************************************************************//

    /// @notice A deep pool that beats issuance fills the whole buy; nothing mints.
    function test_poolOnly() public {
        (uint256 projectId, address projectToken, PoolKey memory key) = _nativeSetup(0, 200, 1e24);
        uint256 supply = _supply(projectToken);
        uint256 out = _buy(key, true, 0.01 ether, _extreme(true), "");
        assertEq(_supply(projectToken), supply, "nothing minted");
        assertGt(out, _mintAll(projectId, JBConstants.NATIVE_TOKEN, 0.01 ether) * 19 / 10, "about 2x issuance");
    }

    /// @notice A pool worse than issuance takes nothing; the whole buy mints at the previewed count.
    function test_mintOnly() public {
        (uint256 projectId, address projectToken, PoolKey memory key) = _nativeSetup(0, 50, 1e24);
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        uint256 supply = _supply(projectToken);
        uint256 out = _buy(key, true, 1 ether, _extreme(true), "");
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(out, _mintAll(projectId, JBConstants.NATIVE_TOKEN, 1 ether), "the mint");
        assertEq(_supply(projectToken) - supply, out, "all minted");
        assertEq(priceAfter, priceBefore, "pool untouched");
    }

    /// @notice A thin pool that beats issuance fills until its marginal rate meets issuance, and the rest mints. The
    /// buyer gets more than minting everything and more than the plain swap, which fills below issuance.
    function test_split() public {
        (uint256 projectId, address projectToken, PoolKey memory key) = _nativeSetup(0, 130, 1e20);
        uint256 amountIn = 1 ether;
        uint256 mintAll = _mintAll(projectId, JBConstants.NATIVE_TOKEN, amountIn);

        uint256 supply = _supply(projectToken);
        uint256 out = _buy(key, true, amountIn, _extreme(true), "");
        uint256 minted = _supply(projectToken) - supply;
        assertGt(minted, 0, "mint leg");
        assertGt(out, minted, "pool leg");
        assertGt(out, mintAll, "beats minting everything");

        // The pool stops where its marginal output after the 1% fee meets issuance: price * 0.99 = 50,000.
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 priceX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
        assertApproxEqRel(priceX192 * 99 / 100, uint256(50_000) << 192, 1e12, "stopped at the issuance limit");
        assertGe(priceX192 * 99, uint256(5_000_000) << 192, "never past it");
    }

    /// @notice This hook never sets an LP fee, so a dynamic-fee pool would charge none; initializing one reverts.
    function test_dynamicFeePool_rejected() public {
        (, address projectToken) = _launch(JBConstants.NATIVE_TOKEN, 18, WEIGHT, 0, false);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(projectToken),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(JBUniswapV4Hook.JBUniswapV4Hook_DynamicFeeNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, uint160(1) << 96);
    }

    /// @notice A caller limit at the fee-free issuance price keeps a plain V4 swap: partial fill, no mint.
    function test_callerLimitAtIssuance_isPlainSwap() public {
        (, address projectToken, PoolKey memory key) = _nativeSetup(0, 130, 1e20);
        uint256 supply = _supply(projectToken);
        uint160 limit = uint160(Math.sqrt(uint256(50_000) << 192));
        (uint256 used, uint256 out) = swapper.swap{value: 1 ether}(key, true, 1 ether, limit, "");
        assertEq(_supply(projectToken), supply, "no mint leg");
        assertLt(used, 1 ether, "partial fill");
        assertGt(out, 0, "pool fill");
    }

    /// @notice The buyback hook limits its swaps at the fee-free issuance price from the total mint count (or the
    /// beneficiary count when skipping splits), which can round a few units under the hook's count. Those swaps stay
    /// plain: this hook never pays the terminal from inside them, so a buyback pay never mints twice.
    function test_buybackLimitedSwaps_neverMint() public {
        (uint256 projectId, address projectToken, PoolKey memory key) = _nativeSetup(3800, 2000, 1e20);
        uint256 amountIn = 0.37 ether;
        (, uint256 beneficiaryCount, uint256 reservedCount,) =
            terminal.previewPayFor(projectId, JBConstants.NATIVE_TOKEN, amountIn, address(hook), "");
        uint256[4] memory counts =
            [beneficiaryCount + reservedCount, beneficiaryCount, beneficiaryCount - 1, beneficiaryCount - 3];
        for (uint256 i; i < counts.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 supply = _supply(projectToken);
            // `JBSwapLib.sqrtPriceLimitFromAmounts` for zeroForOne: floor(sqrt(floor(minimum * 2^192 / amountIn))).
            uint160 limit = uint160(Math.sqrt(FullMath.mulDiv({a: counts[i], b: 1 << 192, denominator: amountIn})));
            swapper.swap{value: amountIn}(key, true, amountIn, limit, abi.encode(uint256(0)));
            assertEq(_supply(projectToken), supply, "no mint from inside a buyback-limited swap");
            vm.revertToState(snap);
        }
    }

    /// @notice An ERC-20 input (6 decimals) splits the same way, and the temporary terminal allowance is consumed.
    function test_split_erc20Input() public {
        MockERC20WithDecimals usdc = new MockERC20WithDecimals("USD", "USD", 6);
        (uint256 projectId, address projectToken) = _launch(address(usdc), 6, 20e18, 0, false);
        uint256 rate = _mintAll(projectId, address(usdc), 1e18);
        (PoolKey memory key, bool zeroForOne) = _pool(address(usdc), projectToken, rate, 130, 1e17, 10, 10_000);
        usdc.mint(address(this), 1e12);
        usdc.approve(address(swapper), type(uint256).max);

        uint256 amountIn = 50_000e6;
        uint256 supply = _supply(projectToken);
        uint256 out = _buy(key, zeroForOne, amountIn, _extreme(zeroForOne), "");
        assertGt(_supply(projectToken), supply, "mint leg");
        assertGe(out, _mintAll(projectId, address(usdc), amountIn), "at least the mint");
        assertEq(usdc.allowance(address(hook), address(terminal)), 0, "allowance consumed");
        assertEq(usdc.balanceOf(address(hook)), 0, "nothing left in the hook");
    }

    /// @notice A tagged minimum applies to the pool and mint legs together.
    function test_taggedMinimumCoversBothLegs() public {
        (,, PoolKey memory key) = _nativeSetup(0, 130, 1e20);
        uint256 snap = vm.snapshotState();
        uint256 out = _buy(key, true, 1 ether, _extreme(true), "");
        vm.revertToState(snap);

        vm.expectRevert();
        _buy(key, true, 1 ether, _extreme(true), abi.encodePacked(JBUniswapV4HookData.TAG, abi.encode(out + 1)));

        assertEq(
            _buy(key, true, 1 ether, _extreme(true), abi.encodePacked(JBUniswapV4HookData.TAG, abi.encode(out))),
            out,
            "a minimum equal to the total passes"
        );
    }

    /// @notice A data hook that sends the pay to its own swap (the buyback pattern) falls back to minting at the
    /// ruleset's weight inside a pool swap. The hook prices the mint leg at that weight and the buyer still gets at
    /// least issuance.
    function test_divertingDataHook_mintsAtWeight() public {
        (uint256 projectId, address projectToken) = _launch(JBConstants.NATIVE_TOKEN, 18, WEIGHT, 3800, true);
        uint256 rate = _mintAll(projectId, JBConstants.NATIVE_TOKEN, 1e18);
        (PoolKey memory key,) = _pool(address(0), projectToken, rate, 130, 1e20, 10, 10_000);
        dataHook.setBehavior(true, true);

        uint256 out = _buy(key, true, 1 ether, _extreme(true), "");
        assertGe(out, rate - 1, "at least issuance");
    }

    /// @notice A diverting hook that delivers nothing fails the buy instead of underpaying it.
    function test_divertingDataHook_thatUnderdelivers_reverts() public {
        (uint256 projectId, address projectToken) = _launch(JBConstants.NATIVE_TOKEN, 18, WEIGHT, 0, true);
        uint256 rate = _mintAll(projectId, JBConstants.NATIVE_TOKEN, 1e18);
        (PoolKey memory key,) = _pool(address(0), projectToken, rate, 130, 1e20, 10, 10_000);
        dataHook.setBehavior(true, false);

        vm.expectRevert();
        _buy(key, true, 1 ether, _extreme(true), "");
    }

    /// @notice The oracle attributes the interval before a split buy to the pre-buy tick and the interval after to the
    /// moved price, the same as a plain swap.
    function test_observationsAroundTheNestedSwap() public {
        (,, PoolKey memory key) = _nativeSetup(0, 130, 1e20);
        (, int24 tickBefore,,) = manager.getSlot0(key.toId());
        // Absolute warps: via-IR can reuse a cached `block.timestamp` across `vm.warp` calls.
        vm.warp(101);
        _buy(key, true, 1 ether, _extreme(true), "");
        (, int24 tickAfter,,) = manager.getSlot0(key.toId());
        assertLt(tickAfter, tickBefore, "the pool leg moved the price");
        vm.warp(201);

        uint32[] memory ago = new uint32[](3);
        ago[0] = 200;
        ago[1] = 100;
        ago[2] = 0;
        (int56[] memory cumulatives,) = hook.observe(key, ago);
        assertEq((cumulatives[1] - cumulatives[0]) / 100, tickBefore, "before the buy");
        assertEq((cumulatives[2] - cumulatives[1]) / 100, tickAfter, "after the buy");
    }

    /// @notice Fuzz: across liquidity, pool-to-issuance ratios, sizes, fees and issuance rates, a buy never gets less
    /// than minting the whole input, less V4's rounding of the pool leg's input (two wei of input, valued at issuance)
    /// and three base units of mint rounding.
    function testFuzz_neverBelowMintAll(
        uint128 liquidity,
        uint256 poolPercent,
        uint256 amountIn,
        uint24 fee,
        uint256 weight,
        uint16 reservedPercent
    )
        public
    {
        liquidity = uint128(bound(liquidity, 1e15, 1e25));
        poolPercent = bound(poolPercent, 1, 1000);
        amountIn = bound(amountIn, 1e9, 1000 ether);
        fee = uint24(bound(fee, 0, 100_000));
        weight = bound(weight, 1e15, 1e27);
        reservedPercent = uint16(bound(reservedPercent, 0, 9000));

        (uint256 projectId, address projectToken) =
            _launch(JBConstants.NATIVE_TOKEN, 18, weight, reservedPercent, false);
        uint256 rate = _mintAll(projectId, JBConstants.NATIVE_TOKEN, 1e18);
        vm.assume(rate > 1e9);
        (PoolKey memory key,) = _pool(address(0), projectToken, rate, poolPercent, liquidity, 20, fee);

        uint256 mintAll = _mintAll(projectId, JBConstants.NATIVE_TOKEN, amountIn);
        uint256 out = _buy(key, true, amountIn, _extreme(true), "");
        // The hook's rounding margin: a millionth of the issuance plus 3 units.
        assertGe(out + mintAll / 1_000_000 + 3, mintAll, "never below minting everything");
    }

    function testFuzz_sixDecimalSmallBuys_neverRevert(
        uint128 liquidity,
        uint256 poolPercent,
        uint256 amountIn,
        uint24 fee
    )
        public
    {
        liquidity = uint128(bound(liquidity, 1e10, 1e22));
        poolPercent = bound(poolPercent, 101, 400);
        amountIn = bound(amountIn, 1e3, 1e7);
        fee = uint24(bound(fee, 0, 10_000));

        MockERC20WithDecimals usd = new MockERC20WithDecimals("USD", "USD", 6);
        (uint256 projectId, address projectToken) = _launch(address(usd), 6, 1e18, 0, false);
        uint256 rate = _mintAll(projectId, address(usd), 1e18);
        (PoolKey memory key, bool zeroForOne) = _pool(address(usd), projectToken, rate, poolPercent, liquidity, 20, fee);
        uint256 mintAll = _mintAll(projectId, address(usd), amountIn);
        (, uint256 out) = swapper.swap(key, zeroForOne, amountIn, _extreme(zeroForOne), "");
        assertGe(out + mintAll / 1_000_000 + 3, mintAll, "never below minting everything");
    }

    function testFuzz_dustTicksSmallBuys_neverRevert(
        uint256 poolPercent,
        uint256 amountIn,
        uint24 fee,
        uint256 dust,
        uint8 positions
    )
        public
    {
        poolPercent = bound(poolPercent, 101, 150);
        amountIn = bound(amountIn, 1e3, 1e7);
        fee = uint24(bound(fee, 0, 10_000));
        dust = bound(dust, 1, 1e9);
        positions = uint8(bound(positions, 1, 40));

        MockERC20WithDecimals usd = new MockERC20WithDecimals("USD", "USD", 6);
        (uint256 projectId, address projectToken) = _launch(address(usd), 6, 1e18, 0, false);
        uint256 rate = _mintAll(projectId, address(usd), 1e18);
        (PoolKey memory key, bool zeroForOne) = _pool(address(usd), projectToken, rate, poolPercent, 0, 20, fee);
        _fund(key.currency0);
        _fund(key.currency1);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        tick = tick / 200 * 200;
        for (int24 k = -int24(uint24(positions)); k < int24(uint24(positions)); k++) {
            liquidityRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tick + k * 200, tickUpper: tick + (k + 1) * 200, liquidityDelta: int256(dust), salt: 0
                }),
                ""
            );
        }
        uint256 mintAll = _mintAll(projectId, address(usd), amountIn);
        (, uint256 out) = swapper.swap(key, zeroForOne, amountIn, _extreme(zeroForOne), "");
        assertGe(out + mintAll / 1_000_000 + 3, mintAll, "never below minting everything");
    }

    /// @notice When V4's rounding would eat a pool fill (here the 1% fee takes the whole one-unit input of a 0-decimal
    /// token), the buy mints instead.
    function test_poolFillEatenByRounding_mints() public {
        MockERC20WithDecimals unit = new MockERC20WithDecimals("U", "U", 0);
        (uint256 projectId, address projectToken) = _launch(address(unit), 0, 1e18, 0, false);
        uint256 rate = _mintAll(projectId, address(unit), 1e18);
        (PoolKey memory key, bool zeroForOne) = _pool(address(unit), projectToken, rate, 130, 1e20, 10, 10_000);
        uint256 mintAll = _mintAll(projectId, address(unit), 1);

        (, uint256 out) = swapper.swap(key, zeroForOne, 1, _extreme(zeroForOne), "");
        assertEq(out, mintAll, "mints the whole input");
    }

    //*********************************************************************//
    // ------------------------------ sells ------------------------------ //
    //*********************************************************************//

    /// @dev A native-ETH project with `taxRate`, 1,000 ETH of surplus and 100M tokens (half held here by the seller,
    /// half by the LP), so cashing out pays up to 1e-5 ETH per token. Its pool pays `poolPercent`% of that per token at
    /// the start, with `liquidity` over `halfWidth` tick spacings on each side. Fee 1%, tick spacing 200.
    function _sellSetup(
        uint16 taxRate,
        uint256 poolPercent,
        uint128 liquidity,
        int24 halfWidth
    )
        internal
        returns (uint256 projectId, address projectToken, PoolKey memory key)
    {
        // Project 1 collects the terminal's fees; the sold project is another one unless `sellFeeProject`.
        if (!sellFeeProject) _launch(JBConstants.NATIVE_TOKEN, 18, WEIGHT, 0, false);
        cashOutTaxRate = taxRate;
        (projectId, projectToken) = _launch(JBConstants.NATIVE_TOKEN, 18, WEIGHT, 0, false);
        terminal.pay{value: 1000 ether}(projectId, JBConstants.NATIVE_TOKEN, 1000 ether, address(this), 0, "", "");
        vm.prank(address(controller));
        tokens.mintFor({holder: address(this), projectId: projectId, count: 5e25});
        IERC20(projectToken).approve(address(liquidityRouter), type(uint256).max);
        IERC20(projectToken).approve(address(sellSwapper), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(projectToken),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        // 1e5 tokens per ETH at 100%.
        uint160 sqrtPriceX96 = uint160(Math.sqrt((uint256(1e7) / poolPercent) << 192));
        manager.initialize(key, sqrtPriceX96);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96) / 200 * 200;
        liquidityRouter.modifyLiquidity{value: 1e29}(
            key,
            ModifyLiquidityParams({
                tickLower: tick - halfWidth * 200,
                tickUpper: tick + halfWidth * 200,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );
    }

    function _sell(PoolKey memory key, uint256 amount, bytes memory hookData) internal returns (uint256 out) {
        (, out) = sellSwapper.swap(key, false, amount, hookData);
    }

    /// @dev What the same sell gets from the pool alone: the terminal's preview fails, so the hook leaves it to V4.
    function _poolOnly(PoolKey memory key, uint256 amount) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        vm.mockCallRevert(address(terminal), abi.encodeWithSelector(terminal.previewCashOutFrom.selector), "");
        out = _sell(key, amount, "");
        vm.clearMockedCalls();
        vm.revertToState(snap);
    }

    /// @dev What cashing out the same tokens at the terminal pays.
    function _reclaimAll(uint256 projectId, uint256 amount) internal returns (uint256 out) {
        uint256 snap = vm.snapshotState();
        out = terminal.cashOutTokensOf({
            holder: address(this),
            projectId: projectId,
            cashOutCount: amount,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: ""
        });
        vm.revertToState(snap);
    }

    /// @notice A pool that pays more than the marginal reclaim rate fills until it meets it, and the rest cashes out:
    /// the seller gets more than the pool alone and more than cashing out everything.
    function test_sell_split() public {
        (uint256 projectId, address projectToken, PoolKey memory key) = _sellSetup(5000, 60, 1e22, 30);
        uint256 amount = 1e24;
        uint256 poolOnly = _poolOnly(key, amount);
        uint256 reclaimAll = _reclaimAll(projectId, amount);
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());

        uint256 supply = _supply(projectToken);
        uint256 out = _sell(key, amount, "");
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertGt(supply - _supply(projectToken), 0, "cash-out leg");
        assertGt(priceAfter, priceBefore, "pool leg");
        assertGt(out, poolOnly, "beats the pool alone");
        assertGt(out, reclaimAll, "beats cashing out everything");
        assertGt(
            IERC20(address(tokens.tokenOf(1))).balanceOf(address(hook)),
            0,
            "the fee's project 1 tokens stay in the hook"
        );
    }

    /// @notice When the cash-out leg would pay less than selling the same tokens in the pool (a steep 90% tax, whose
    /// average rate is well under its marginal rate, against a deep pool), the whole sell stays in the pool.
    function test_sell_cashOutWorseThanPool_staysInPool() public {
        (uint256 projectId, address projectToken, PoolKey memory key) = _sellSetup(9000, 11, 1e23, 30);
        uint256 amount = 1e24;
        uint256 poolOnly = _poolOnly(key, amount);
        uint256 supply = _supply(projectToken);
        uint256 out = _sell(key, amount, "");
        assertEq(_supply(projectToken), supply, "nothing cashed out");
        assertEq(out, poolOnly, "the pool alone");
        assertGt(out, _reclaimAll(projectId, amount), "which beats cashing out everything");
    }

    /// @notice The cash-out leg takes at most what the PoolManager holds of the token (the router settles the input
    /// after the swap), and the outer swap sells the rest in the pool instead of reverting. A tagged minimum covers
    /// both parts.
    function test_sell_inventoryCap_restSellsInPool() public {
        (, address projectToken, PoolKey memory key) = _sellSetup(0, 50, 1e20, 10);
        uint256 amount = 1e23;
        uint256 inventory = IERC20(projectToken).balanceOf(address(manager));
        assertLt(inventory, amount, "the PoolManager holds less than the sell");
        uint256 poolOnly = _poolOnly(key, amount);

        uint256 snap = vm.snapshotState();
        uint256 supply = _supply(projectToken);
        uint256 out = _sell(key, amount, "");
        assertEq(supply - _supply(projectToken), inventory, "cashes out what the PoolManager holds");
        assertGt(out, poolOnly, "beats the pool alone");
        vm.revertToState(snap);

        vm.expectRevert();
        _sell(key, amount, abi.encodePacked(JBUniswapV4HookData.TAG, abi.encode(out + 1)));
        assertEq(
            _sell(key, amount, abi.encodePacked(JBUniswapV4HookData.TAG, abi.encode(out))),
            out,
            "a minimum equal to the total passes"
        );
    }

    /// @notice The cash-out leg tells the buyback registry a data hook names to skip its pool sale, which could not
    /// unlock the PoolManager inside this swap.
    function test_sell_cashOutSkipsBuybackSale() public {
        cashOutDataHook = address(new SkipCheckingDataHook());
        (uint256 projectId, address projectToken, PoolKey memory key) = _sellSetup(0, 50, 1e22, 10);

        vm.expectRevert("no skip entry");
        _reclaimAll(projectId, 1e22);

        uint256 supply = _supply(projectToken);
        _sell(key, 1e22, "");
        assertEq(supply - _supply(projectToken), 1e22, "all cashed out");
    }

    /// @notice Sells of the fee project's token stay in the pool: its cash-out fee would mint its token back to the
    /// hook mid-sell.
    function test_sell_feeProject_staysInPool() public {
        sellFeeProject = true;
        (uint256 projectId, address projectToken, PoolKey memory key) = _sellSetup(5000, 60, 1e22, 30);
        assertEq(projectId, 1, "the fee project");
        uint256 poolOnly = _poolOnly(key, 1e24);
        uint256 supply = _supply(projectToken);
        assertEq(_sell(key, 1e24, ""), poolOnly, "the pool alone");
        assertEq(_supply(projectToken), supply, "nothing cashed out");
    }

    /// @notice Cases where the reclaim curve's rounding makes the marginal-rate split worse than cashing out everything
    /// (by about 108 ppm), or than a floor derived from it (which used to revert): the exact comparison picks the best,
    /// and cashing out everything counts when the PoolManager holds the whole input.
    function test_sell_reclaimRounding_picksBest() public {
        _assertSellBest(5000, 50, 214_749_614_204_962_798_835_619, 760_000e18);
        _assertSellBest(5000, 51, 1e21, 1e24);
    }

    function _assertSellBest(uint16 taxRate, uint256 poolPercent, uint128 liquidity, uint256 amount) internal {
        uint256 snap = vm.snapshotState();
        (uint256 projectId, address projectToken, PoolKey memory key) = _sellSetup(taxRate, poolPercent, liquidity, 30);
        uint256 inventory = IERC20(projectToken).balanceOf(address(manager));
        uint256 poolOnly = _poolOnly(key, amount);
        uint256 reclaimAll = _reclaimAll(projectId, amount);
        uint256 out = _sell(key, amount, "");
        assertGe(out, poolOnly, "never below the pool alone");
        if (amount <= inventory) assertGe(out, reclaimAll, "never below cashing out everything");
        vm.revertToState(snap);
    }

    /// @notice Fuzz: across tax rates, pool prices, liquidity and sizes, a sell never gets less than the pool alone,
    /// and never less than cashing out everything when the PoolManager holds the whole input.
    function testFuzz_sell_neverBelowPoolOrReclaim(
        uint16 taxRate,
        uint256 poolPercent,
        uint128 liquidity,
        uint256 amount
    )
        public
    {
        taxRate = uint16(bound(taxRate, 0, 10_000));
        poolPercent = bound(poolPercent, 1, 1000);
        liquidity = uint128(bound(liquidity, 1e15, 1e23));
        amount = bound(amount, 1e9, 1e25);

        (uint256 projectId, address projectToken, PoolKey memory key) = _sellSetup(taxRate, poolPercent, liquidity, 30);
        uint256 inventory = IERC20(projectToken).balanceOf(address(manager));
        uint256 poolOnly = _poolOnly(key, amount);
        uint256 reclaimAll = _reclaimAll(projectId, amount);

        uint256 out = _sell(key, amount, "");
        assertGe(out, poolOnly, "never below the pool alone");
        if (amount <= inventory) assertGe(out, reclaimAll, "never below cashing out everything");
    }

    //*********************************************************************//
    // ------------------- routed vs plain pool swaps -------------------- //
    //*********************************************************************//

    /// @notice Fuzz: a buy across input decimals, pool shapes, dust positions, fees, sizes, price limits and both
    /// settle orders succeeds wherever the plain pool swap does, never gets less, and stays within the price limit.
    function testFuzz_buy_neverWorseThanPlainSwap(
        uint8 inputKind,
        uint256 weight,
        uint16 reservedPercent,
        uint256 poolPercent,
        uint128 liquidity,
        int24 halfWidth,
        uint24 fee,
        uint8 dustPositions,
        uint256 amountIn,
        uint24 limitTicks,
        bool routerOrder
    )
        public
    {
        inputKind = uint8(bound(inputKind, 0, 2));
        weight = bound(weight, 1e15, 1e24);
        reservedPercent = uint16(bound(reservedPercent, 0, 9000));
        poolPercent = bound(poolPercent, 1, 1000);
        liquidity = uint128(bound(liquidity, 0, 1e24));
        halfWidth = int24(bound(halfWidth, 1, 30));
        fee = uint24(bound(fee, 0, 100_000));
        dustPositions = uint8(bound(dustPositions, 0, 10));

        // Native ETH, a 6-decimal stablecoin or an 18-decimal token.
        uint8 decimals = inputKind == 1 ? 6 : 18;
        address input =
            inputKind == 0 ? JBConstants.NATIVE_TOKEN : address(new MockERC20WithDecimals("IN", "IN", decimals));
        amountIn = bound(amountIn, 1, 1e6 * 10 ** decimals);

        (uint256 projectId, address projectToken) = _launch(input, decimals, weight, reservedPercent, false);
        uint256 rate = _mintAll(projectId, input, 10 ** decimals) * 1e18 / 10 ** decimals;
        vm.assume(rate != 0);
        address poolInput = inputKind == 0 ? address(0) : input;
        (PoolKey memory key, bool zeroForOne) =
            _pool(poolInput, projectToken, rate, poolPercent, liquidity, halfWidth, fee);
        _fund(key.currency0);
        _fund(key.currency1);
        if (poolInput != address(0)) IERC20(poolInput).approve(address(routerSwapper), type(uint256).max);
        _dust(key, dustPositions);

        _assertNeverWorseThanPlain(key, zeroForOne, amountIn, _limit(key, zeroForOne, limitTicks), routerOrder);
    }

    /// @notice Fuzz: a sell across tax rates, pool shapes, sizes, price limits and both settle orders succeeds wherever
    /// the plain pool swap does, never gets less, and stays within the price limit.
    function testFuzz_sell_neverWorseThanPlainSwap(
        uint16 taxRate,
        uint256 poolPercent,
        uint128 liquidity,
        int24 halfWidth,
        uint256 amount,
        uint24 limitTicks,
        bool routerOrder
    )
        public
    {
        taxRate = uint16(bound(taxRate, 0, 10_000));
        poolPercent = bound(poolPercent, 1, 1000);
        liquidity = uint128(bound(liquidity, 1e10, 1e23));
        halfWidth = int24(bound(halfWidth, 1, 30));

        (, address projectToken, PoolKey memory key) = _sellSetup(taxRate, poolPercent, liquidity, halfWidth);
        amount = bound(amount, 1, IERC20(projectToken).balanceOf(address(this)));
        IERC20(projectToken).approve(address(swapper), type(uint256).max);
        IERC20(projectToken).approve(address(routerSwapper), type(uint256).max);

        _assertNeverWorseThanPlain(key, false, amount, _limit(key, false, limitTicks), routerOrder);
    }

    /// @dev Swaps once with the terminal's previews failing, so the hook leaves the whole swap to the pool, then once
    /// for real from the same state, and checks the real swap against the plain one.
    function _assertNeverWorseThanPlain(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 limit,
        bool routerOrder
    )
        internal
    {
        uint256 snap = vm.snapshotState();
        vm.mockCallRevert(address(terminal), abi.encodeWithSelector(terminal.previewPayFor.selector), "");
        vm.mockCallRevert(address(terminal), abi.encodeWithSelector(terminal.previewCashOutFrom.selector), "");
        (bool plainOk, uint256 plainUsed, uint256 plainOut) = _trySwap(key, zeroForOne, amountIn, limit, routerOrder);
        vm.clearMockedCalls();
        vm.revertToState(snap);

        (bool ok, uint256 used, uint256 out) = _trySwap(key, zeroForOne, amountIn, limit, routerOrder);
        if (!plainOk) return;
        assertTrue(ok, "succeeds wherever the plain swap does");
        // The hook's rounding margin: a millionth plus 3 units.
        assertGe(out + plainOut / 1_000_000 + 3, plainOut, "never below the plain swap");

        // At an average price no worse than the plain swap's, the routed swap adds no slippage of its own. Otherwise
        // it may trail the limit by the LP fee, as a plain swap can, and no further.
        if ((out + out / 1_000_000 + 3) * plainUsed >= plainOut * used) return;
        uint256 netUsed = used * (1e6 - key.fee) / 1e6;
        uint256 floor = zeroForOne
            ? FullMath.mulDiv({
                a: FullMath.mulDiv({a: netUsed, b: limit, denominator: 1 << 96}), b: limit, denominator: 1 << 96
            })
            : FullMath.mulDiv({
                a: FullMath.mulDiv({a: netUsed, b: 1 << 96, denominator: limit}), b: 1 << 96, denominator: limit
            });
        assertGe(out + floor / 1_000_000 + 3, floor, "within the price limit");
    }

    function _trySwap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 limit,
        bool routerOrder
    )
        internal
        returns (bool ok, uint256 used, uint256 out)
    {
        uint256 value = (zeroForOne ? key.currency0 : key.currency1).isAddressZero() ? amountIn : 0;
        if (routerOrder) {
            try routerSwapper.swap{value: value}(key, zeroForOne, amountIn, limit) returns (uint256 u, uint256 o) {
                return (true, u, o);
            } catch {}
        } else {
            try swapper.swap{value: value}(key, zeroForOne, amountIn, limit, "") returns (uint256 u, uint256 o) {
                return (true, u, o);
            } catch {}
        }
    }

    /// @dev The price limit `ticks` past the current tick in the swap's direction, or no limit when `ticks` is 0.
    function _limit(PoolKey memory key, bool zeroForOne, uint24 ticks) internal view returns (uint160) {
        ticks = uint24(bound(ticks, 0, 50_000));
        if (ticks == 0) return _extreme(zeroForOne);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int256 target = zeroForOne ? int256(tick) - int256(uint256(ticks)) : int256(tick) + int256(uint256(ticks));
        if (target <= TickMath.MIN_TICK || target >= TickMath.MAX_TICK) return _extreme(zeroForOne);
        // forge-lint: disable-next-line(unsafe-typecast)
        return TickMath.getSqrtPriceAtTick(int24(target));
    }

    /// @dev Adds dust liquidity over `positions` single-spacing ranges on each side of the current tick.
    function _dust(PoolKey memory key, uint8 positions) internal {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        tick = tick / 200 * 200;
        for (int24 k = -int24(uint24(positions)); k < int24(uint24(positions)); k++) {
            liquidityRouter.modifyLiquidity{value: key.currency0.isAddressZero() ? 1e18 : 0}(
                key,
                ModifyLiquidityParams({
                    tickLower: tick + k * 200, tickUpper: tick + (k + 1) * 200, liquidityDelta: 1e6, salt: 0
                }),
                ""
            );
        }
    }
}
