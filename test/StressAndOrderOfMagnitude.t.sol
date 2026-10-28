// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {JBUniswapV4Hook} from "../src/JBUniswapV4Hook.sol";
import {MockERC20, MockERC20WithDecimals} from "./mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "./utils/JuiceboxSwapRouter.sol";
// Import Juicebox interfaces and structs from the hook file
import {IJBTokens, IJBPrices, IJBDirectory} from "../src/JBUniswapV4Hook.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {OracleQuote} from "./utils/OracleQuote.sol";

// ──────────────────────────────────────────────────────────────────────────
// Mock Juicebox contracts (copied from JBUniswapV4Hook.t.sol)
// ──────────────────────────────────────────────────────────────────────────

contract MockJBTokens {
    mapping(address => uint256) public projectIdOf;
    mapping(uint256 => address) public tokenOf;

    function setProjectId(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
        if (projectId != 0) tokenOf[projectId] = token;
    }

    function creditBalanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MockJBDirectory {
    address public mockTerminal;
    address public mockController;

    function setMockTerminal(address terminal) external {
        mockTerminal = terminal;
    }

    function setMockController(address controller) external {
        mockController = controller;
    }

    function controllerOf(
        uint256 /* projectId */
    )
        external
        view
        returns (address)
    {
        return mockController;
    }

    function primaryTerminalOf(
        uint256,
        /* projectId */
        address /* token */
    )
        external
        view
        returns (address)
    {
        return mockTerminal;
    }
}

contract MockJBPrices {
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public prices;

    // forge-lint: disable-next-line(mixed-case-function)
    function DEFAULT_PROJECT_ID() external pure returns (uint256) {
        return 0;
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

    function pricePerUnitOf(
        uint256 projectId,
        uint256 pricingCurrency,
        uint256 unitCurrency,
        uint256 /* decimals */
    )
        external
        view
        returns (uint256)
    {
        uint256 price = prices[projectId][pricingCurrency][unitCurrency];
        return price > 0 ? price : 1e18;
    }
}

contract MockJBMultiTerminal {
    uint256 public lastProjectId;
    address public lastToken;
    uint256 public lastAmount;
    address public lastBeneficiary;

    mapping(uint256 => address) public projectTokens;

    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTerminalStore public TERMINAL_STORE;

    uint256 public overridePayReturnAmount;
    uint256 public overrideCashOutReturnAmount;
    bool public useOverridePayReturn;
    bool public useOverrideCashOutReturn;

    /// @notice JB protocol fee (2.5% = 25 out of MAX_FEE 1000).
    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    function setProjectToken(uint256 projectId, address projectToken) external {
        projectTokens[projectId] = projectToken;
    }

    function setTerminalStore(address terminalStore) external {
        TERMINAL_STORE = MockJBTerminalStore(terminalStore);
    }

    /// @dev The store prices a payment with this context: native ETH in the base currency (ID 1), other tokens in
    /// their address-derived currency at their own decimals.
    function accountingContextForTokenOf(uint256, address token) external view returns (JBAccountingContext memory) {
        if (token == JBConstants.NATIVE_TOKEN) return JBAccountingContext({token: token, decimals: 18, currency: 1});
        // forge-lint: disable-next-line(unsafe-typecast)
        return
            JBAccountingContext({token: token, decimals: MockERC20(token).decimals(), currency: uint32(uint160(token))});
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function STORE() external view returns (IJBTerminalStore) {
        return IJBTerminalStore(address(TERMINAL_STORE));
    }

    function setPayReturnAmount(uint256 amount) external {
        overridePayReturnAmount = amount;
        useOverridePayReturn = true;
    }

    function setCashOutReturnAmount(uint256 amount) external {
        overrideCashOutReturnAmount = amount;
        useOverrideCashOutReturn = true;
    }

    function resetOverrides() external {
        useOverridePayReturn = false;
        useOverrideCashOutReturn = false;
    }

    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 beneficiaryTokenCount)
    {
        lastProjectId = projectId;
        lastToken = token;
        lastAmount = amount;
        lastBeneficiary = beneficiary;

        if (useOverridePayReturn) {
            beneficiaryTokenCount = overridePayReturnAmount;
        } else {
            beneficiaryTokenCount = amount * 1000;
        }

        require(beneficiaryTokenCount >= minReturnedTokens, "Insufficient tokens returned");

        // Production terminals pull ERC-20 inputs during pay; consume the hook's temporary allowance in the mock too.
        if (msg.value == 0 && amount != 0) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0)) {
            MockERC20(projectToken).mint(beneficiary, beneficiaryTokenCount);
        }

        return beneficiaryTokenCount;
    }

    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256)
    {
        lastProjectId = projectId;
        lastToken = tokenToReclaim;
        lastAmount = cashOutCount;
        lastBeneficiary = beneficiary;

        uint256 outputAmount;

        if (useOverrideCashOutReturn) {
            outputAmount = overrideCashOutReturnAmount;
        } else {
            uint256 surplusAmount =
            // forge-lint: disable-next-line(unsafe-typecast)
            TERMINAL_STORE.currentReclaimableSurplusOf(projectId, 1 ether, uint32(uint160(tokenToReclaim)), 18);
            outputAmount = (surplusAmount * cashOutCount) / 1e18;
        }

        require(outputAmount >= minTokensReclaimed, "Insufficient tokens reclaimed");

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && cashOutCount != 0) {
            MockERC20(projectToken).burn(holder, cashOutCount);
        }

        if (outputAmount > 0) {
            MockERC20(tokenToReclaim).mint(beneficiary, outputAmount);
        }

        return outputAmount;
    }

    function previewCashOutFrom(
        address,
        uint256 projectId,
        uint256 cashOutCount,
        address tokenToReclaim,
        address payable,
        bytes calldata
    )
        external
        view
        returns (JBRuleset memory, uint256, uint256, JBCashOutHookSpecification[] memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currency = uint32(uint160(tokenToReclaim));
        uint256 surplusPerTokenValue = TERMINAL_STORE.surplusPerToken(projectId, currency);
        uint256 reclaimAmount = surplusPerTokenValue == 0 ? 0 : (surplusPerTokenValue * cashOutCount) / 1e18;
        JBRuleset memory ruleset;
        return (ruleset, reclaimAmount, 0, new JBCashOutHookSpecification[](0));
    }
}

contract MockJBController {
    mapping(uint256 => uint256) public weights;
    mapping(uint256 => uint16) public reservedPercents;

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function setReservedPercent(uint256 projectId, uint16 reservedPercent) external {
        reservedPercents[projectId] = reservedPercent;
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
            scopeCashOutsToLocalBalances: true,
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

contract MockJBTerminalStore {
    mapping(uint256 => mapping(uint256 => uint256)) public surplusPerToken;

    function setSurplus(uint256 projectId, address token, uint256 surplusAmount) external {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 currency = uint32(uint160(token));
        surplusPerToken[projectId][currency] = surplusAmount;
    }

    function currentReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        uint256 currency,
        uint256
    )
        external
        view
        returns (uint256)
    {
        uint256 surplusPerTokenValue = surplusPerToken[projectId][currency];
        if (surplusPerTokenValue == 0) return 0;
        return (surplusPerTokenValue * cashOutCount) / 1e18;
    }

    function currentTotalReclaimableSurplusOf(
        uint256 projectId,
        uint256 cashOutCount,
        uint256, /* decimals */
        uint256 currency
    )
        external
        view
        returns (uint256)
    {
        uint256 surplusPerTokenValue = surplusPerToken[projectId][currency];
        if (surplusPerTokenValue == 0) return 0;
        return (surplusPerTokenValue * cashOutCount) / 1e18;
    }
}

// ──────────────────────────────────────────────────────────────────────────
// Stress & Order-of-Magnitude Tests
// ──────────────────────────────────────────────────────────────────────────

contract StressAndOrderOfMagnitudeTest is Test {
    receive() external payable {}

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    JBUniswapV4Hook hook;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTokens mockJBTokens;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBDirectory mockJBDirectory;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBMultiTerminal mockJBMultiTerminal;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBController mockJBController;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBPrices mockJBPrices;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockJBTerminalStore mockJBTerminalStore;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    JuiceboxSwapRouter jbSwapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    bytes constant ZERO_BYTES = "";

    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        // Warp to a reasonable timestamp so TWAP oracle has enough history
        vm.warp(10_000);

        // Deploy core contracts
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        swapRouter = new PoolSwapTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy mock Juicebox contracts
        mockJBTokens = new MockJBTokens();
        mockJBDirectory = new MockJBDirectory();
        mockJBMultiTerminal = new MockJBMultiTerminal();
        mockJBController = new MockJBController();
        mockJBPrices = new MockJBPrices();
        mockJBTerminalStore = new MockJBTerminalStore();

        mockJBDirectory.setMockTerminal(address(mockJBMultiTerminal));
        mockJBDirectory.setMockController(address(mockJBController));
        mockJBMultiTerminal.setTerminalStore(address(mockJBTerminalStore));

        // Deploy the hook with proper address mining
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            manager,
            IJBTokens(address(mockJBTokens)),
            IJBDirectory(address(mockJBDirectory)),
            IJBPrices(address(mockJBPrices))
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(
            manager,
            IJBTokens(address(mockJBTokens)),
            IJBDirectory(address(mockJBDirectory)),
            IJBPrices(address(mockJBPrices))
        );

        // Deploy test tokens
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Set up a Juicebox project for token0
        mockJBTokens.setProjectId(address(token0), 123);
        mockJBController.setWeight(123, 1000e18);
        mockJBMultiTerminal.setProjectToken(123, address(token0));

        // Set a 1:1 ETH price for token1
        uint32 token1CurrencyId = uint32(uint160(address(token1)));
        uint256 baseCurrency = 1;
        mockJBPrices.setPricePerUnitOf(123, token1CurrencyId, baseCurrency, 1e18);

        // Set up the V4 pool
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        id = key.toId();

        // Give tokens to the test user
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);

        // Approve tokens for liquidity addition
        token0.approve(address(modifyLiquidityRouter), 1000 ether);
        token1.approve(address(modifyLiquidityRouter), 1000 ether);

        // Approve tokens for the hook
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        // Initialize the pool
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // 4. Test calculateExpectedTokensWithCurrency with max weight
    //    Weight is uint112, so max is 2^112-1 = 5192296858534827628530496329220096.
    //    For 1 wei of payment, the formula is:
    //      tokens = weight * 1 / 1e18 (after normalization)
    //    This should not overflow thanks to FullMath.mulDiv.
    // ──────────────────────────────────────────────────────────────────────
    function test_CalculateExpectedTokens_MaxWeight() public {
        uint256 projectId = 200;
        uint256 maxWeight = type(uint112).max; // 5192296858534827628530496329220096

        mockJBController.setWeight(projectId, maxWeight);
        mockJBTokens.setProjectId(address(token0), projectId);
        mockJBDirectory.setMockController(address(mockJBController));
        mockJBDirectory.setMockTerminal(address(mockJBMultiTerminal));

        // Calculate expected tokens for 1 wei payment (native ETH, address(0))
        uint256 expectedTokens = hook.calculateExpectedTokensWithCurrency(projectId, address(0), 1);

        // With weight = uint112.max and paymentAmount = 1 wei:
        //   paymentAmount18 = 1 (already in wei, 18 decimals)
        //   tokens = mulDiv(uint112.max, 1, 1e18) = uint112.max / 1e18
        //   = 5192296858534827628530496329220096 / 1e18
        //   = 5192296858534827 (approximately)
        assertGt(expectedTokens, 0, "Max weight with 1 wei should produce non-zero tokens");
        console.log("Max weight, 1 wei payment => tokens:", expectedTokens);

        // Also test with 1 ether payment (should be exactly uint112.max)
        uint256 expectedTokensOneEth = hook.calculateExpectedTokensWithCurrency(projectId, address(0), 1 ether);
        assertEq(expectedTokensOneEth, maxWeight, "Max weight with 1 ETH should return weight tokens");
    }

    // ──────────────────────────────────────────────────────────────────────
    // 5. Test calculateExpectedTokensWithCurrency with 1 wei payment
    //    Normal weight (1000e18), 1 wei payment. Expected:
    //      tokens = mulDiv(1000e18, 1, 1e18) = 1000
    //    This verifies correct rounding for tiny payments.
    // ──────────────────────────────────────────────────────────────────────
    function test_CalculateExpectedTokens_OneWei() public view {
        // Project 123 has weight = 1000e18 (set in setUp)
        uint256 expectedTokens = hook.calculateExpectedTokensWithCurrency(123, address(0), 1);

        // weight = 1000e18, paymentAmount18 = 1
        // tokens = mulDiv(1000e18, 1, 1e18) = 1000
        assertEq(expectedTokens, 1000, "1 wei with weight 1000e18 should return 1000 tokens");

        // Test with weight = 1 (very small weight)
        // Project 123's weight is already 1000e18 from setUp, so use a different approach:
        // We can't change the weight for project 123 here in a view function,
        // so we just verify the existing project's behavior.

        // Test with 0 wei
        uint256 zeroPayment = hook.calculateExpectedTokensWithCurrency(123, address(0), 0);
        assertEq(zeroPayment, 0, "0 wei should return 0 tokens");
    }

    // ──────────────────────────────────────────────────────────────────────
    // 7. Fuzz calculateExpectedTokensWithCurrency across different decimal
    //    tokens (0 to 18 decimals). The internal function normalizes to 18
    //    decimals before calculating. Verify correct behavior for each.
    // ──────────────────────────────────────────────────────────────────────
    function testFuzz_CalculateTokens_TinyDecimals(uint8 decimals) public {
        decimals = uint8(bound(uint256(decimals), 0, 18));

        // Create a new project with a custom-decimal payment token
        uint256 projectId = 300 + uint256(decimals);
        mockJBController.setWeight(projectId, 1000e18);

        // Deploy a MockERC20WithDecimals as the payment token
        MockERC20WithDecimals customToken =
            new MockERC20WithDecimals(string.concat("Dec", vm.toString(decimals)), "DEC", decimals);

        // Set up project token lookup (use token0 as the project token)
        mockJBTokens.setProjectId(address(token0), projectId);

        // Calculate one full unit of the custom token
        // For 6 decimals: 1e6. For 0 decimals: 1. For 18 decimals: 1e18.
        uint256 oneUnit = 10 ** uint256(decimals);

        // Set price for this token's currency
        uint32 customCurrencyId = uint32(uint160(address(customToken)));
        // 1:1 with base currency: one base unit priced in this token at its decimals, as the terminal store reads it
        mockJBPrices.setPricePerUnitOf(projectId, customCurrencyId, 1, oneUnit);

        uint256 expectedTokens = hook.calculateExpectedTokensWithCurrency(projectId, address(customToken), oneUnit);

        // With weight = 1000e18 and 1 full unit of payment:
        //   tokens = mulDiv(oneUnit, 1000e18, oneUnit) = 1000e18
        // This should be the same regardless of the payment token's native decimals.
        assertEq(
            expectedTokens,
            1000e18,
            string.concat("1 full unit with ", vm.toString(decimals), " decimals should return 1000e18 tokens")
        );

        // Test with minimum amount (1 smallest unit)
        uint256 minTokens = hook.calculateExpectedTokensWithCurrency(projectId, address(customToken), 1);

        if (decimals == 18) {
            // 1 wei normalized is 1 wei. mulDiv(1000e18, 1, 1e18) = 1000
            assertEq(minTokens, 1000, "1 wei at 18 decimals should return 1000 tokens");
        } else if (decimals == 0) {
            // 1 unit at 0 decimals normalizes to 1e18. mulDiv(1000e18, 1e18, 1e18) = 1000e18
            assertEq(minTokens, 1000e18, "1 unit at 0 decimals should return 1000e18 tokens");
        } else {
            // 1 smallest unit normalizes to (1 * 1e18) / 10^decimals
            // tokens = mulDiv(1000e18, normalized, 1e18) = 1000 * normalized / 1e18 * 1e18 = 1000 * (1e18 /
            // 10^decimals) = 1000e18 / 10^decimals
            uint256 expectedMin = (1000e18) / (10 ** uint256(decimals));
            assertEq(
                minTokens,
                expectedMin,
                string.concat(
                    "1 smallest unit at ", vm.toString(decimals), " decimals should produce correctly scaled tokens"
                )
            );
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // 8. Test extreme combination: max weight + large payment amount
    //    weight = uint112.max, paymentAmount = 1000 ETH
    //    Verifies FullMath.mulDiv handles the 2-step multiplication:
    //      intermediate = mulDiv(uint112.max, 1000e18, 1e18) = uint112.max * 1000
    //    This intermediate can exceed uint256 without mulDiv's 512-bit handling.
    // ──────────────────────────────────────────────────────────────────────
    function test_ExtremeConversion_LargeWeight_LargeAmount() public {
        uint256 projectId = 400;
        uint256 maxWeight = type(uint112).max;

        mockJBController.setWeight(projectId, maxWeight);
        mockJBTokens.setProjectId(address(token0), projectId);

        // Calculate expected tokens for a large payment (1000 ETH)
        uint256 expectedTokens = hook.calculateExpectedTokensWithCurrency(projectId, address(0), 1000 ether);

        // With weight = uint112.max and paymentAmount = 1000e18:
        //   paymentAmount18 = 1000e18 (native ETH, 18 decimals)
        //   tokens = mulDiv(uint112.max, 1000e18, 1e18) = uint112.max * 1000
        //   = 5192296858534827628530496329220096 * 1000
        //   = 5192296858534827628530496329220096000
        uint256 expectedExact = uint256(maxWeight) * 1000;
        assertEq(expectedTokens, expectedExact, "Max weight * 1000 ETH should produce weight * 1000 tokens");

        // Test with an even larger amount: 1 million ETH
        uint256 expectedTokensMillionEth =
            hook.calculateExpectedTokensWithCurrency(projectId, address(0), 1_000_000 ether);
        uint256 expectedMillionExact = uint256(maxWeight) * 1_000_000;
        assertEq(
            expectedTokensMillionEth, expectedMillionExact, "Max weight * 1M ETH should produce weight * 1M tokens"
        );

        console.log("Max weight * 1000 ETH:", expectedTokens);
        console.log("Max weight * 1M ETH:", expectedTokensMillionEth);

        // Verify the result fits in uint256: uint112.max * 1e6 < uint256.max
        // uint112.max = ~5.19e33, * 1e6 = ~5.19e39, uint256.max = ~1.16e77
        // Plenty of headroom
        assertLt(expectedTokensMillionEth, type(uint256).max, "Result should fit in uint256");

        // Test with price conversion factor (non-1:1 price)
        // Set up a 2:1 price (2 base currency per payment token, so one base unit is 0.5 payment tokens)
        uint32 token1CurrencyId = uint32(uint160(address(token1)));
        mockJBPrices.setPricePerUnitOf(projectId, token1CurrencyId, 1, 0.5e18);

        uint256 expectedWithPrice = hook.calculateExpectedTokensWithCurrency(projectId, address(token1), 100 ether);

        // tokens = mulDiv(100e18, uint112.max, 0.5e18) = uint112.max * 200
        uint256 expectedWithPriceExact = uint256(maxWeight) * 200;
        assertEq(
            expectedWithPrice,
            expectedWithPriceExact,
            "Max weight with 2x price conversion should produce weight * 200 tokens"
        );
    }
}
