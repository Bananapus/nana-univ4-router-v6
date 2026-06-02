// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ─── Forge test framework
// ────────────────────────────────────────────
import {Test} from "forge-std/Test.sol";

// ─── Uniswap V4 core
// ────────────────────────────────────────────────
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

// ─── Hook under test and periphery
// ──────────────────────────────────
import {JBUniswapV4Hook} from "../../src/JBUniswapV4Hook.sol";
import {MockERC20} from "../mock/MockERC20.sol";
import {JuiceboxSwapRouter} from "../utils/JuiceboxSwapRouter.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// ─── Juicebox types
// ─────────────────────────────────────────────────
import {IJBTokens, IJBPrices, IJBDirectory} from "../../src/JBUniswapV4Hook.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";

// ═══════════════════════════════════════════════════════════════════════
// Mock contracts — scoped to this test file
// ═══════════════════════════════════════════════════════════════════════

/// @notice Minimal mock that maps token addresses to project IDs.
contract MockJBTokens_BalanceDelta {
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

/// @notice Mock directory that returns a single terminal and controller.
contract MockJBDirectory_BalanceDelta {
    address public defaultTerminal;
    address public mockController;

    function setDefaultTerminal(address terminal) external {
        defaultTerminal = terminal;
    }

    function setMockController(address controller) external {
        mockController = controller;
    }

    function primaryTerminalOf(uint256, address) external view returns (address) {
        return defaultTerminal;
    }

    function controllerOf(uint256) external view returns (address) {
        return mockController;
    }
}

/// @notice Minimal mock controller that returns static weight and metadata.
contract MockJBController_BalanceDelta {
    mapping(uint256 => uint256) public weights;

    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        metadata = JBRulesetMetadata({
            reservedPercent: 0,
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

/// @notice Mock prices that returns 1:1 for all pairs.
contract MockJBPrices_BalanceDelta {
    // forge-lint: disable-next-line(mixed-case-function)
    function DEFAULT_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function pricePerUnitOf(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        return 1e18;
    }
}

/// @notice Fee-on-transfer terminal mock.
/// @dev `pay()` returns `reportedAmount` but only mints `actualAmount` tokens to the beneficiary.
///      This simulates a fee-on-transfer token scenario where the terminal's return value exceeds
///      the real balance change observed by the hook.
///      `previewPayFor()` returns `reportedAmount` so the routing decision still picks JB over V4.
contract FeeOnTransferTerminal {
    /// @notice The amount reported by pay() / previewPayFor() as the return value.
    uint256 public reportedAmount;

    /// @notice The amount actually minted to the beneficiary (less than reportedAmount).
    uint256 public actualAmount;

    /// @notice Project token address used for minting.
    mapping(uint256 => address) public projectTokens;

    /// @notice Track last pay call for assertions.
    uint256 public lastPayProjectId;
    uint256 public lastPayAmount;
    address public lastPayBeneficiary;

    /// @notice Configure the mismatch between reported and actual amounts.
    /// @param reported The value returned by pay() (what the terminal claims).
    /// @param actual The tokens actually minted (what the beneficiary receives).
    function setAmounts(uint256 reported, uint256 actual) external {
        require(actual <= reported, "actual must be <= reported");
        reportedAmount = reported;
        actualAmount = actual;
    }

    /// @notice Set the project token used for minting in pay().
    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    /// @notice Preview returns the inflated (reported) amount so the hook routes through JB.
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
            JBPayHookSpecification[] memory hooks
        )
    {
        return (ruleset, reportedAmount, 0, new JBPayHookSpecification[](0));
    }

    /// @notice Accepts payment, returns reportedAmount but only mints actualAmount.
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
        lastPayBeneficiary = beneficiary;

        // Return the inflated amount (what the old code would trust).
        beneficiaryTokenCount = reportedAmount;

        // Production terminals pull ERC-20 inputs during pay; consume the hook's temporary allowance in the mock too.
        if (msg.value == 0 && amount != 0) {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        }

        // But only actually mint the reduced amount (simulating a fee-on-transfer).
        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && actualAmount > 0) {
            MockERC20(projectToken).mint(beneficiary, actualAmount);
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    /// @notice Accept ETH for native-token payments.
    receive() external payable {}
}

/// @notice Fee-on-transfer terminal mock for the sell (cashOut) side.
/// @dev `cashOutTokensOf()` returns `reportedAmount` but only mints `actualAmount` of the
///      output token to the beneficiary.
contract FeeOnTransferTerminalSell {
    /// @notice The amount reported by cashOutTokensOf() as the return value.
    uint256 public reportedAmount;

    /// @notice The amount actually minted to the beneficiary (less than reportedAmount).
    uint256 public actualAmount;

    /// @notice Project token address for each project (used by the hook to look up tokens).
    mapping(uint256 => address) public projectTokens;

    /// @notice Output token used for minting during cashOut.
    address public outputToken;

    /// @notice Track last cashOut call for assertions.
    uint256 public lastCashOutProjectId;

    /// @notice Configure the mismatch between reported and actual amounts.
    function setAmounts(uint256 reported, uint256 actual) external {
        require(actual <= reported, "actual must be <= reported");
        reportedAmount = reported;
        actualAmount = actual;
    }

    /// @notice Set the project token.
    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    /// @notice Set the output token minted during cashOut.
    function setOutputToken(address token) external {
        outputToken = token;
    }

    /// @notice Preview returns the inflated (reported) amount so the hook routes through JB.
    function previewCashOutFrom(
        address,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    )
        external
        view
        returns (
            JBRuleset memory ruleset,
            uint256 reclaimAmount,
            uint256 cashOutTaxRate,
            JBCashOutHookSpecification[] memory hooks
        )
    {
        return (ruleset, reportedAmount, 0, new JBCashOutHookSpecification[](0));
    }

    /// @notice Accepts cashOut, returns reportedAmount but only mints actualAmount of output token.
    function cashOutTokensOf(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        address,
        uint256,
        address payable beneficiary,
        bytes calldata
    )
        external
        returns (uint256)
    {
        lastCashOutProjectId = projectId;

        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && cashOutCount != 0) {
            MockERC20(projectToken).burn(holder, cashOutCount);
        }

        // Actually mint only the reduced amount.
        if (outputToken != address(0) && actualAmount > 0) {
            MockERC20(outputToken).mint(beneficiary, actualAmount);
        }

        // Return the inflated amount (what the old code would trust).
        return reportedAmount;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
// Test: Balance-delta settlement for fee-on-transfer tokens (buy side)
// ═══════════════════════════════════════════════════════════════════════

/// @title BalanceDeltaSettlement_BuyTest
/// @notice Verifies that when a terminal reports returning X tokens from pay() but only
///         delivers Y < X tokens (fee-on-transfer), the hook settles Y (the actual received
///         amount) instead of X (the reported amount).
contract BalanceDeltaSettlement_BuyTest is Test {
    receive() external payable {}

    using PoolIdLibrary for PoolKey;

    // ─── Constants
    // ─────────────────────────────────────────
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 internal constant PROJECT_ID = 123;
    uint256 internal constant WEIGHT = 1000e18;

    /// @notice Reported amount from terminal (inflated).
    uint256 internal constant REPORTED_AMOUNT = 5000e18;

    /// @notice Actual amount minted (fee-on-transfer reduces it by 10%).
    uint256 internal constant ACTUAL_AMOUNT = 4500e18;

    // ─── Contracts
    // ─────────────────────────────────────────
    JBUniswapV4Hook internal hook;
    MockJBTokens_BalanceDelta internal mockTokens;
    MockJBDirectory_BalanceDelta internal mockDirectory;
    FeeOnTransferTerminal internal fotTerminal;
    MockJBController_BalanceDelta internal mockController;
    MockJBPrices_BalanceDelta internal mockPrices;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiqRouter;
    JuiceboxSwapRouter internal jbSwapRouter;

    MockERC20 internal projectToken;
    MockERC20 internal paymentToken;
    PoolKey internal key;
    PoolId internal id;
    bool internal zeroForOne;

    function setUp() public {
        // Deploy V4 core.
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        modifyLiqRouter = new PoolModifyLiquidityTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);

        // Deploy mock JB contracts.
        mockTokens = new MockJBTokens_BalanceDelta();
        mockDirectory = new MockJBDirectory_BalanceDelta();
        fotTerminal = new FeeOnTransferTerminal();
        mockController = new MockJBController_BalanceDelta();
        mockPrices = new MockJBPrices_BalanceDelta();

        // Wire JB directory.
        mockDirectory.setDefaultTerminal(address(fotTerminal));
        mockDirectory.setMockController(address(mockController));

        // Mine the correct hook address.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory ctorArgs = abi.encode(
            manager,
            IJBTokens(address(mockTokens)),
            IJBDirectory(address(mockDirectory)),
            IJBPrices(address(mockPrices))
        );
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, ctorArgs);

        // Deploy hook at the mined address.
        hook = new JBUniswapV4Hook{salt: salt}(
            manager,
            IJBTokens(address(mockTokens)),
            IJBDirectory(address(mockDirectory)),
            IJBPrices(address(mockPrices))
        );

        // Deploy ERC-20 test tokens.
        projectToken = new MockERC20("Project", "PRJ");
        paymentToken = new MockERC20("Payment", "PAY");

        // Register the project token as a JB project token.
        mockTokens.setProjectId(address(projectToken), PROJECT_ID);

        // Configure the controller with a static weight.
        mockController.setWeight(PROJECT_ID, WEIGHT);

        // Configure the fee-on-transfer terminal.
        fotTerminal.setProjectToken(PROJECT_ID, address(projectToken));
        fotTerminal.setAmounts(REPORTED_AMOUNT, ACTUAL_AMOUNT);

        // Build the V4 pool key (tokens must be sorted).
        if (address(paymentToken) < address(projectToken)) {
            key = PoolKey({
                currency0: Currency.wrap(address(paymentToken)),
                currency1: Currency.wrap(address(projectToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            zeroForOne = true;
        } else {
            key = PoolKey({
                currency0: Currency.wrap(address(projectToken)),
                currency1: Currency.wrap(address(paymentToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            zeroForOne = false;
        }
        id = key.toId();

        // Mint tokens for liquidity and swaps.
        projectToken.mint(address(this), 1_000_000 ether);
        paymentToken.mint(address(this), 1_000_000 ether);

        // Approve routers.
        projectToken.approve(address(modifyLiqRouter), type(uint256).max);
        paymentToken.approve(address(modifyLiqRouter), type(uint256).max);
        projectToken.approve(address(jbSwapRouter), type(uint256).max);
        paymentToken.approve(address(jbSwapRouter), type(uint256).max);

        // Initialize pool at 1:1 price.
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add liquidity so V4 swaps are possible.
        modifyLiqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1000 ether, salt: 0}),
            bytes("")
        );
    }

    /// @notice When a terminal reports returning 5000e18 tokens but only mints 4500e18
    ///         (simulating fee-on-transfer), the hook should settle the actual 4500e18,
    ///         not the reported 5000e18. The swap succeeds and the user receives the
    ///         correct (lower) amount.
    function test_BuySide_FeeOnTransfer_SettlesActualBalance() public {
        uint256 amountIn = 1 ether;

        // Record balances before the swap.
        uint256 projectTokenBefore = projectToken.balanceOf(address(this));
        uint256 paymentTokenBefore = paymentToken.balanceOf(address(this));

        // Execute a swap buying project tokens.
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // The swap should succeed (with the fix, the hook measures actual balance delta).
        jbSwapRouter.swap(key, params, 0);

        // Check balances after the swap.
        uint256 projectTokenAfter = projectToken.balanceOf(address(this));
        uint256 paymentTokenAfter = paymentToken.balanceOf(address(this));

        // Verify the terminal was called.
        assertEq(fotTerminal.lastPayProjectId(), PROJECT_ID, "Terminal should have been called for project 123");
        assertEq(fotTerminal.lastPayBeneficiary(), address(hook), "Hook should be the pay beneficiary");

        // User should have spent 1 ether of payment tokens.
        assertEq(paymentTokenBefore - paymentTokenAfter, amountIn, "User should have spent exactly 1 ether");

        // User should have received ACTUAL_AMOUNT (4500e18), NOT REPORTED_AMOUNT (5000e18).
        uint256 tokensReceived = projectTokenAfter - projectTokenBefore;
        assertEq(tokensReceived, ACTUAL_AMOUNT, "User should receive the actual minted amount, not the reported amount");

        // Explicitly verify the key invariant: received != reported.
        assertTrue(tokensReceived < REPORTED_AMOUNT, "Received amount must be less than the inflated reported amount");
    }

    /// @notice When the fee-on-transfer gap is zero (actual == reported), the hook
    ///         should behave identically to a normal terminal.
    function test_BuySide_NoFee_SettlesFullAmount() public {
        // Configure terminal with no fee gap: reported == actual.
        fotTerminal.setAmounts(5000e18, 5000e18);

        uint256 amountIn = 1 ether;
        uint256 projectTokenBefore = projectToken.balanceOf(address(this));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        jbSwapRouter.swap(key, params, 0);

        uint256 tokensReceived = projectToken.balanceOf(address(this)) - projectTokenBefore;
        assertEq(tokensReceived, 5000e18, "With no fee gap, user should receive the full reported amount");
    }

    /// @notice When the fee-on-transfer takes a large fee (50%), the hook should
    ///         still settle the correct reduced amount without reverting.
    function test_BuySide_LargeFeeOnTransfer_SettlesReducedAmount() public {
        uint256 reported = 5000e18;
        uint256 actual = 2500e18; // 50% fee

        fotTerminal.setAmounts(reported, actual);

        uint256 amountIn = 1 ether;
        uint256 projectTokenBefore = projectToken.balanceOf(address(this));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        jbSwapRouter.swap(key, params, 0);

        uint256 tokensReceived = projectToken.balanceOf(address(this)) - projectTokenBefore;
        assertEq(tokensReceived, actual, "With 50% fee, user should receive only the actual amount");
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Test: Balance-delta settlement for fee-on-transfer tokens (sell side)
// ═══════════════════════════════════════════════════════════════════════

/// @title BalanceDeltaSettlement_SellTest
/// @notice Verifies that when a terminal previews returning X tokens from cashOutTokensOf() but only delivers
///         Y < X output tokens, the hook reverts instead of settling a lower-output sell route.
contract BalanceDeltaSettlement_SellTest is Test {
    receive() external payable {}

    using PoolIdLibrary for PoolKey;

    // ─── Constants
    // ─────────────────────────────────────────
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 internal constant PROJECT_ID = 456;

    /// @notice Reported amount from terminal cashOut (inflated).
    uint256 internal constant REPORTED_AMOUNT = 2e18;

    /// @notice Actual amount minted to beneficiary (fee-on-transfer reduces it).
    uint256 internal constant ACTUAL_AMOUNT = 1.8e18;

    // ─── Contracts
    // ─────────────────────────────────────────
    JBUniswapV4Hook internal hook;
    MockJBTokens_BalanceDelta internal mockTokens;
    MockJBDirectory_BalanceDelta internal mockDirectory;
    FeeOnTransferTerminalSell internal fotTerminal;
    MockJBController_BalanceDelta internal mockController;
    MockJBPrices_BalanceDelta internal mockPrices;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiqRouter;
    JuiceboxSwapRouter internal jbSwapRouter;

    MockERC20 internal projectToken;
    MockERC20 internal paymentToken;
    PoolKey internal key;
    PoolId internal id;
    bool internal zeroForOne;

    function setUp() public {
        // Deploy V4 core.
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        modifyLiqRouter = new PoolModifyLiquidityTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);

        // Deploy mock JB contracts.
        mockTokens = new MockJBTokens_BalanceDelta();
        mockDirectory = new MockJBDirectory_BalanceDelta();
        fotTerminal = new FeeOnTransferTerminalSell();
        mockController = new MockJBController_BalanceDelta();
        mockPrices = new MockJBPrices_BalanceDelta();

        // Wire JB directory.
        mockDirectory.setDefaultTerminal(address(fotTerminal));
        mockDirectory.setMockController(address(mockController));

        // Mine the correct hook address.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory ctorArgs = abi.encode(
            manager,
            IJBTokens(address(mockTokens)),
            IJBDirectory(address(mockDirectory)),
            IJBPrices(address(mockPrices))
        );
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, ctorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(
            manager,
            IJBTokens(address(mockTokens)),
            IJBDirectory(address(mockDirectory)),
            IJBPrices(address(mockPrices))
        );

        // Deploy ERC-20 test tokens.
        // For selling: user sells projectToken to get paymentToken.
        projectToken = new MockERC20("SellProject", "SPRJ");
        paymentToken = new MockERC20("SellPayment", "SPAY");

        // Register the project token as a JB project token.
        mockTokens.setProjectId(address(projectToken), PROJECT_ID);

        // Controller: set weight to zero so buy-side is NOT competitive.
        // This forces the hook to consider the sell side for routing.
        mockController.setWeight(PROJECT_ID, 0);

        // Configure the fee-on-transfer terminal for sell side.
        fotTerminal.setProjectToken(PROJECT_ID, address(projectToken));
        fotTerminal.setOutputToken(address(paymentToken));
        fotTerminal.setAmounts(REPORTED_AMOUNT, ACTUAL_AMOUNT);

        // Build the V4 pool key (tokens must be sorted).
        // Selling projectToken for paymentToken: zeroForOne depends on sort order.
        if (address(projectToken) < address(paymentToken)) {
            key = PoolKey({
                currency0: Currency.wrap(address(projectToken)),
                currency1: Currency.wrap(address(paymentToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            // Selling projectToken (currency0) for paymentToken (currency1) = zeroForOne.
            zeroForOne = true;
        } else {
            key = PoolKey({
                currency0: Currency.wrap(address(paymentToken)),
                currency1: Currency.wrap(address(projectToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            // Selling projectToken (currency1) for paymentToken (currency0) = !zeroForOne.
            zeroForOne = false;
        }
        id = key.toId();

        // Mint tokens for liquidity and swaps.
        projectToken.mint(address(this), 1_000_000 ether);
        paymentToken.mint(address(this), 1_000_000 ether);

        // Approve routers.
        projectToken.approve(address(modifyLiqRouter), type(uint256).max);
        paymentToken.approve(address(modifyLiqRouter), type(uint256).max);
        projectToken.approve(address(jbSwapRouter), type(uint256).max);
        paymentToken.approve(address(jbSwapRouter), type(uint256).max);

        // Initialize pool at 1:1 price.
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add liquidity — use a narrow range but enough for V4 to function.
        modifyLiqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1000 ether, salt: 0}),
            bytes("")
        );
    }

    /// @notice When a terminal previews returning 2e18 tokens from cashOut but only mints 1.8e18
    ///         (simulating fee-on-transfer), the hook should revert instead of settling an under-filled sell route.
    function test_SellSide_FeeOnTransfer_RevertsWhenActualOutputBelowPreview() public {
        uint256 amountIn = 1 ether; // selling 1 ether of project tokens

        uint256 projectTokenBefore = projectToken.balanceOf(address(this));
        uint256 paymentTokenBefore = paymentToken.balanceOf(address(this));

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        vm.expectRevert();
        jbSwapRouter.swap(key, params, 0);

        assertEq(fotTerminal.lastCashOutProjectId(), 0, "terminal effects should revert");
        assertEq(projectToken.balanceOf(address(this)), projectTokenBefore, "user should keep project tokens");
        assertEq(
            paymentToken.balanceOf(address(this)), paymentTokenBefore, "user should receive no under-filled output"
        );
    }
}
