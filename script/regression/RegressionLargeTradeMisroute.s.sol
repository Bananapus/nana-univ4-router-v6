// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {MockERC20} from "../../test/mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "../../test/utils/JuiceboxSwapRouter.sol";
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";

contract MockJBTokensRegression {
    mapping(address => uint256) public projectIdOf;

    function setProjectId(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
    }
}

contract MockJBDirectoryRegression {
    address public mockTerminal;
    address public mockController;

    function setMockTerminal(address terminal) external {
        mockTerminal = terminal;
    }

    function setMockController(address controller) external {
        mockController = controller;
    }

    function controllerOf(uint256) external view returns (address) {
        return mockController;
    }

    function primaryTerminalOf(uint256, address) external view returns (address) {
        return mockTerminal;
    }
}

contract MockJBPricesRegression {
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public prices;

    function pricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256
    )
        external
        view
        returns (uint256)
    {
        uint256 price = prices[projectId][pricingCurrency][unitCurrency];
        return price == 0 ? 1e18 : price;
    }

    function setPricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 price
    )
        external
    {
        prices[projectId][pricingCurrency][unitCurrency] = price;
    }
}

contract MockJBControllerRegression {
    mapping(uint256 => uint256) public weights;
    mapping(uint256 => uint16) public reservedPercents;

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        metadata = JBRulesetMetadata({
            reservedPercent: reservedPercents[projectId],
            cashOutTaxRate: 0,
            baseCurrency: 1,
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 0,
            weight: uint112(weights[projectId]),
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: JBRulesetMetadataResolver.packRulesetMetadata(metadata)
        });
    }
}

contract MockJBTerminalStoreRegression {
    function previewCashOutFrom(
        address,
        address,
        uint256,
        uint256,
        address,
        bool,
        bytes calldata
    )
        external
        pure
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory specs
        )
    {
        specs = new JBCashOutHookSpecification[](0);
        return (ruleset, reclaimAmount, cashOutTaxRate, specs);
    }
}

contract MockJBMultiTerminalRegression {
    uint256 public overridePayReturnAmount;
    bool public useOverridePayReturn;
    uint256 public lastProjectId;

    mapping(uint256 => address) public projectTokens;
    MockJBTerminalStoreRegression public terminalStore;
    mapping(uint256 => JBAccountingContext[]) internal _accountingContextsOf;

    function setTerminalStore(address terminalStore_) external {
        terminalStore = MockJBTerminalStoreRegression(terminalStore_);
    }

    function setProjectToken(uint256 projectId, address projectToken) external {
        projectTokens[projectId] = projectToken;
    }

    function setPayReturnAmount(uint256 amount) external {
        overridePayReturnAmount = amount;
        useOverridePayReturn = true;
    }

    function previewPayFor(
        uint256,
        address,
        uint256 amount,
        address,
        bytes calldata
    )
        external
        view
        returns (JBRuleset memory ruleset, uint256 beneficiaryTokenCount, uint256, JBPayHookSpecification[] memory)
    {
        beneficiaryTokenCount = useOverridePayReturn ? overridePayReturnAmount : amount;
        return (ruleset, beneficiaryTokenCount, 0, new JBPayHookSpecification[](0));
    }

    function pay(
        uint256 projectId,
        address,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata,
        bytes calldata
    )
        external
        returns (uint256 beneficiaryTokenCount)
    {
        lastProjectId = projectId;
        beneficiaryTokenCount = useOverridePayReturn ? overridePayReturnAmount : amount;
        require(beneficiaryTokenCount >= minReturnedTokens, "min returned");
        MockERC20(projectTokens[projectId]).mint({to: beneficiary, amount: beneficiaryTokenCount});
        return beneficiaryTokenCount;
    }

    function previewCashOutFrom(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address payable beneficiary,
        bytes calldata metadata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        return terminalStore.previewCashOutFrom(
            address(this), holder, projectId, cashOutCount, tokenToReclaim, beneficiary != address(0), metadata
        );
    }

    function cashOutTokensOf(
        address,
        uint256,
        uint256,
        address,
        uint256,
        address payable,
        bytes calldata
    )
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function accountingContextsOf(uint256 projectId) external view returns (JBAccountingContext[] memory contexts) {
        return _accountingContextsOf[projectId];
    }

    function STORE() external view returns (IJBTerminalStore) {
        return IJBTerminalStore(address(terminalStore));
    }

    function FEE() external pure returns (uint256) {
        return 25;
    }
}

contract RegressionLargeTradeMisrouteExecutor {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    function execute() external {
        IPoolManager manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        PoolModifyLiquidityTest modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        JuiceboxSwapRouter jbSwapRouter = new JuiceboxSwapRouter(manager);

        MockJBTokensRegression tokens = new MockJBTokensRegression();
        MockJBDirectoryRegression directory = new MockJBDirectoryRegression();
        MockJBPricesRegression prices = new MockJBPricesRegression();
        MockJBControllerRegression controller = new MockJBControllerRegression();
        MockJBTerminalStoreRegression terminalStore = new MockJBTerminalStoreRegression();
        MockJBMultiTerminalRegression terminal = new MockJBMultiTerminalRegression();

        directory.setMockController(address(controller));
        directory.setMockTerminal(address(terminal));
        terminal.setTerminalStore(address(terminalStore));

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            manager, IJBTokens(address(tokens)), IJBDirectory(address(directory)), IJBPrices(address(prices))
        );

        (, bytes32 salt) = HookMiner.find({
            deployer: address(this),
            flags: flags,
            creationCode: type(JBUniswapV4Hook).creationCode,
            constructorArgs: constructorArgs
        });

        JBUniswapV4Hook hook = new JBUniswapV4Hook{salt: salt}(
            manager, IJBTokens(address(tokens)), IJBDirectory(address(directory)), IJBPrices(address(prices))
        );

        MockERC20 projectToken = new MockERC20("Project", "PRJ");
        MockERC20 paymentToken = new MockERC20("Payment", "PAY");
        if (address(projectToken) > address(paymentToken)) {
            (projectToken, paymentToken) = (paymentToken, projectToken);
        }

        tokens.setProjectId({token: address(projectToken), projectId: 123});
        controller.setWeight({projectId: 123, weight: 1e18});
        terminal.setProjectToken({projectId: 123, projectToken: address(projectToken)});

        uint32 paymentCurrencyId = uint32(uint160(address(paymentToken)));
        prices.setPricePerUnitOf({projectId: 123, pricingCurrency: paymentCurrencyId, unitCurrency: 1, price: 1e18});

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(projectToken)),
            currency1: Currency.wrap(address(paymentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize({key: key, sqrtPriceX96: SQRT_PRICE_1_1});

        projectToken.mint({to: address(this), amount: 20 ether});
        paymentToken.mint({to: address(this), amount: 40 ether});
        projectToken.approve({spender: address(modifyLiquidityRouter), value: type(uint256).max});
        paymentToken.approve({spender: address(modifyLiquidityRouter), value: type(uint256).max});
        paymentToken.approve({spender: address(jbSwapRouter), value: type(uint256).max});

        modifyLiquidityRouter.modifyLiquidity({
            key: key,
            params: ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            hookData: bytes("")
        });

        uint256 amountIn = 8 ether;
        uint256 jbQuote = 6 ether;
        terminal.setPayReturnAmount(jbQuote);

        uint256 v4Quote =
            hook.estimateUniswapOutput({poolId: key.toId(), key: key, amountIn: amountIn, zeroForOne: false});

        uint256 balanceBefore = projectToken.balanceOf(address(this));
        // The regression script amount is deliberately small and cannot exceed `int256.max`.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 exactInputAmount = -int256(amountIn);
        jbSwapRouter.swap({
            key: key,
            params: SwapParams({
                zeroForOne: false, amountSpecified: exactInputAmount, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            amountOutMin: 0
        });
        uint256 actualOut = projectToken.balanceOf(address(this)) - balanceBefore;

        console2.log({p0: "JB quote", p1: jbQuote});
        console2.log({p0: "V4 quoted out", p1: v4Quote});
        console2.log({p0: "Actual V4 out", p1: actualOut});
        console2.log({p0: "Terminal used projectId", p1: terminal.lastProjectId()});

        require(v4Quote > jbQuote, "setup failed: V4 quote must beat JB quote");
        require(actualOut < jbQuote, "setup failed: actual V4 output must underperform JB route");
        require(terminal.lastProjectId() == 0, "expected the hook to choose V4, not JB");
    }
}

contract RegressionLargeTradeMisrouteScript is Script {
    function run() external {
        RegressionLargeTradeMisrouteExecutor executor = new RegressionLargeTradeMisrouteExecutor();
        executor.execute();
    }
}
