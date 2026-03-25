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

// ═══════════════════════════════════════════════════════════════════════
// Mock contracts — scoped to this test file
// ═══════════════════════════════════════════════════════════════════════

/// @notice Minimal mock that maps token addresses to project IDs.
contract MockJBTokens_Preview {
    // token address => project ID (0 = not a JB token)
    mapping(address => uint256) public projectIdOf;

    /// @notice Register a token as belonging to a project.
    function setProjectId(address token, uint256 projectId) external {
        projectIdOf[token] = projectId;
    }
}

/// @notice Mock directory that can return different terminals per (project, token).
contract MockJBDirectory_Preview {
    // Per-(projectId, token) terminal override.
    mapping(uint256 => mapping(address => address)) public _terminals;

    // Default fallback terminal (used when no per-pair override is set).
    address public defaultTerminal;

    // Controller address (returned for all projects).
    address public mockController;

    /// @notice Set the default terminal returned for any project/token pair.
    function setDefaultTerminal(address terminal) external {
        defaultTerminal = terminal;
    }

    /// @notice Set a specific terminal for a (project, token) pair.
    function setTerminal(uint256 projectId, address token, address terminal) external {
        _terminals[projectId][token] = terminal;
    }

    /// @notice Set the controller returned by `controllerOf`.
    function setMockController(address controller) external {
        mockController = controller;
    }

    /// @notice Resolve terminal: per-pair first, then default.
    function primaryTerminalOf(uint256 projectId, address token) external view returns (address) {
        // Check per-pair override first.
        address specific = _terminals[projectId][token];
        if (specific != address(0)) return specific;
        // Fall back to the default terminal.
        return defaultTerminal;
    }

    /// @notice Controller lookup.
    function controllerOf(uint256) external view returns (address) {
        return mockController;
    }
}

/// @notice Minimal mock controller that returns static weight and metadata.
contract MockJBController_Preview {
    // project ID => weight
    mapping(uint256 => uint256) public weights;

    /// @notice Set the weight for a project.
    function setWeight(uint256 projectId, uint256 weight) external {
        weights[projectId] = weight;
    }

    /// @notice Return a ruleset with the configured weight (baseCurrency = ETH).
    function currentRulesetOf(uint256 projectId)
        external
        view
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        // Default metadata (no reserved rate, baseCurrency = ETH = 1).
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
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        // Pack metadata into the ruleset for JBRulesetMetadataResolver.
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
contract MockJBPrices_Preview {
    // forge-lint: disable-next-line(mixed-case-function)
    function DEFAULT_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function pricePerUnitOf(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        // 1:1 price conversion.
        return 1e18;
    }
}

/// @notice Mock terminal that implements `previewPayFor` with configurable output.
///         Also implements `pay` so JB-routed swaps can complete.
contract MockTerminalWithPreview {
    // Project token for minting on pay.
    mapping(uint256 => address) public projectTokens;

    // Configurable preview return value.
    uint256 public previewBeneficiaryCount;

    // Flag: if true, previewPayFor reverts.
    bool public previewReverts;

    // Track last pay call for assertions.
    uint256 public lastPayProjectId;

    /// @notice Set the project token used for minting in `pay`.
    function setProjectToken(uint256 projectId, address token) external {
        projectTokens[projectId] = token;
    }

    /// @notice Set the value returned by `previewPayFor`.
    function setPreviewReturn(uint256 amount) external {
        previewBeneficiaryCount = amount;
    }

    /// @notice Toggle whether `previewPayFor` reverts.
    function setPreviewReverts(bool flag) external {
        previewReverts = flag;
    }

    /// @notice Simulates paying a project. Returns a configurable token count.
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
        // Revert if configured to test the fallback path.
        require(!previewReverts, "PREVIEW_REVERTED");

        // Return the configured preview amount.
        return (ruleset, previewBeneficiaryCount, 0, new JBPayHookSpecification[](0));
    }

    /// @notice Accept payments and mint project tokens to the beneficiary.
    function pay(
        uint256 projectId,
        address,
        uint256,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256 beneficiaryTokenCount)
    {
        // Record the call.
        lastPayProjectId = projectId;

        // Return the same count as the preview (consistent behaviour).
        beneficiaryTokenCount = previewBeneficiaryCount;

        // Actually mint tokens so the swap settles correctly.
        address projectToken = projectTokens[projectId];
        if (projectToken != address(0) && beneficiaryTokenCount > 0) {
            MockERC20(projectToken).mint(beneficiary, beneficiaryTokenCount);
        }
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external pure returns (uint256) {
        return 25;
    }

    /// @notice Accept ETH for native-token payments.
    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
// Test 1: previewPayFor routing (success path)
// ═══════════════════════════════════════════════════════════════════════

/// @title PreviewPayForRoutingTest
/// @notice When `previewPayFor` succeeds and returns more tokens than V4,
///         the hook should route through Juicebox using that estimate.
contract PreviewPayForRoutingTest is Test {
    // Accept ETH for V4 settlement.
    receive() external payable {}

    using PoolIdLibrary for PoolKey;

    // ─── Shared constants
    // ────────────────────────────────────
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    // ─── Contracts
    // ───────────────────────────────────────────
    JBUniswapV4Hook internal hook;
    MockJBTokens_Preview internal mockTokens;
    MockJBDirectory_Preview internal mockDirectory;
    MockTerminalWithPreview internal mockTerminal;
    MockJBController_Preview internal mockController;
    MockJBPrices_Preview internal mockPrices;

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
        mockTokens = new MockJBTokens_Preview();
        mockDirectory = new MockJBDirectory_Preview();
        mockTerminal = new MockTerminalWithPreview();
        mockController = new MockJBController_Preview();
        mockPrices = new MockJBPrices_Preview();

        // Wire JB directory.
        mockDirectory.setDefaultTerminal(address(mockTerminal));
        mockDirectory.setMockController(address(mockController));

        // Mine the correct hook address (permission bits must match).
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
        mockTokens.setProjectId(address(projectToken), 123);

        // Configure the controller with a static weight.
        mockController.setWeight(123, 1000e18);

        // Configure the mock terminal to return project tokens on pay.
        mockTerminal.setProjectToken(123, address(projectToken));

        // Set the preview to return a high value so JB route wins.
        mockTerminal.setPreviewReturn(5000e18);

        // Build the V4 pool key (tokens must be sorted).
        if (address(paymentToken) < address(projectToken)) {
            key = PoolKey({
                currency0: Currency.wrap(address(paymentToken)),
                currency1: Currency.wrap(address(projectToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            // Buying project token = swapping paymentToken -> projectToken = zeroForOne.
            zeroForOne = true;
        } else {
            key = PoolKey({
                currency0: Currency.wrap(address(projectToken)),
                currency1: Currency.wrap(address(paymentToken)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
            // Buying project token = swapping paymentToken (token1) -> projectToken (token0) = !zeroForOne.
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

    /// @notice When previewPayFor returns more tokens than V4 would give,
    ///         the hook routes through Juicebox and the terminal's pay() is called.
    function test_PreviewPayFor_RoutesToJuicebox() public {
        // Set preview return to a very high value so JB wins.
        mockTerminal.setPreviewReturn(5000e18);

        // Execute a swap buying project tokens.
        uint256 amountIn = 1 ether;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Perform the swap (amountOutMin = 0 so it always passes).
        jbSwapRouter.swap(key, params, 0);

        // The terminal's pay() should have been called (JB route was selected).
        assertEq(mockTerminal.lastPayProjectId(), 123, "swap should route through JB terminal");
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Test 2: previewPayFor fallback (revert path)
// ═══════════════════════════════════════════════════════════════════════

/// @title PreviewPayForFallbackTest
/// @notice When `previewPayFor` reverts, the hook falls back to
///         `calculateExpectedTokensWithCurrency` for its JB estimate.
contract PreviewPayForFallbackTest is Test {
    // Accept ETH for V4 settlement.
    receive() external payable {}

    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    JBUniswapV4Hook internal hook;
    MockJBTokens_Preview internal mockTokens;
    MockJBDirectory_Preview internal mockDirectory;
    MockTerminalWithPreview internal mockTerminal;
    MockJBController_Preview internal mockController;
    MockJBPrices_Preview internal mockPrices;

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
        mockTokens = new MockJBTokens_Preview();
        mockDirectory = new MockJBDirectory_Preview();
        mockTerminal = new MockTerminalWithPreview();
        mockController = new MockJBController_Preview();
        mockPrices = new MockJBPrices_Preview();

        // Wire JB directory.
        mockDirectory.setDefaultTerminal(address(mockTerminal));
        mockDirectory.setMockController(address(mockController));

        // Mine the hook address.
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
        projectToken = new MockERC20("Project", "PRJ");
        paymentToken = new MockERC20("Payment", "PAY");

        // Register as JB token.
        mockTokens.setProjectId(address(projectToken), 123);

        // Configure the controller: weight = 1000e18 (produces 1000 tokens per 1 ETH).
        mockController.setWeight(123, 1000e18);

        // Configure the terminal to revert on previewPayFor.
        mockTerminal.setPreviewReverts(true);
        // Set pay return to match static estimate (1000 * amountIn).
        mockTerminal.setPreviewReturn(1000e18);
        mockTerminal.setProjectToken(123, address(projectToken));

        // Build pool key.
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

        // Mint and approve tokens.
        projectToken.mint(address(this), 1_000_000 ether);
        paymentToken.mint(address(this), 1_000_000 ether);
        projectToken.approve(address(modifyLiqRouter), type(uint256).max);
        paymentToken.approve(address(modifyLiqRouter), type(uint256).max);
        projectToken.approve(address(jbSwapRouter), type(uint256).max);
        paymentToken.approve(address(jbSwapRouter), type(uint256).max);

        // Initialize pool at 1:1 price.
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add very shallow liquidity (V4 gives ~1 token per 1 ETH after fee).
        // Static JB estimate = 1000e18 >> V4 estimate, so JB route wins.
        modifyLiqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1000 ether, salt: 0}),
            bytes("")
        );
    }

    /// @notice When previewPayFor reverts, the hook falls back to static weight estimation.
    ///         If the static estimate beats V4, the swap still routes through JB.
    function test_PreviewPayFor_FallbackToStaticEstimate() public {
        // The static estimate is weight * amount / 1e18 = 1000e18 * 1e18 / 1e18 = 1000e18.
        // V4 gives approximately 1e18 at 1:1 price with 0.3% fee = ~0.997e18.
        // JB route should win.
        uint256 staticEstimate = hook.calculateExpectedTokensWithCurrency({
            projectId: 123, paymentToken: address(paymentToken), paymentAmount: 1 ether
        });

        // The static estimate should be ~1000e18.
        assertGt(staticEstimate, 0, "static estimate should be positive");

        // Execute the swap. Despite previewPayFor reverting, the fallback should work.
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // The swap should complete without reverting (fallback to static estimate).
        jbSwapRouter.swap(key, params, 0);

        // Since the static estimate >> V4 estimate, JB route should be selected.
        assertEq(mockTerminal.lastPayProjectId(), 123, "swap should route through JB after preview fallback");
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Test 3: No terminal fallback (primaryTerminalOf returns address(0))
// ═══════════════════════════════════════════════════════════════════════

/// @title NoTerminalFallbackTest
/// @notice When `primaryTerminalOf` returns `address(0)` for the payment token,
///         the hook uses static `calculateExpectedTokensWithCurrency` without
///         calling `previewPayFor`, and the swap completes via V4 if the
///         static estimate is lower.
contract NoTerminalFallbackTest is Test {
    // Accept ETH for V4 settlement.
    receive() external payable {}

    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    JBUniswapV4Hook internal hook;
    MockJBTokens_Preview internal mockTokens;
    MockJBDirectory_Preview internal mockDirectory;
    MockJBController_Preview internal mockController;
    MockJBPrices_Preview internal mockPrices;

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
        mockTokens = new MockJBTokens_Preview();
        mockDirectory = new MockJBDirectory_Preview();
        mockController = new MockJBController_Preview();
        mockPrices = new MockJBPrices_Preview();

        // Wire directory: NO terminal set (defaultTerminal stays address(0)).
        mockDirectory.setMockController(address(mockController));

        // Mine the hook address.
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
        projectToken = new MockERC20("Project", "PRJ");
        paymentToken = new MockERC20("Payment", "PAY");

        // Register as JB token.
        mockTokens.setProjectId(address(projectToken), 123);

        // Set a low weight so static estimate is small and V4 wins.
        mockController.setWeight(123, 1e18);

        // Build pool key.
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

        // Mint and approve tokens.
        projectToken.mint(address(this), 1_000_000 ether);
        paymentToken.mint(address(this), 1_000_000 ether);
        projectToken.approve(address(modifyLiqRouter), type(uint256).max);
        paymentToken.approve(address(modifyLiqRouter), type(uint256).max);
        projectToken.approve(address(jbSwapRouter), type(uint256).max);
        paymentToken.approve(address(jbSwapRouter), type(uint256).max);

        // Initialize pool at 1:1 price.
        manager.initialize(key, SQRT_PRICE_1_1);

        // Add deep liquidity so V4 gives ~1 token per 1 ETH (minus 0.3% fee).
        modifyLiqRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 10_000 ether, salt: 0}),
            bytes("")
        );
    }

    /// @notice When no terminal exists (address(0)), the hook uses static estimation.
    ///         With a low weight (1e18), the static estimate is 1 token per 1 ETH,
    ///         which is comparable to V4 at 1:1 price. The swap should complete
    ///         without reverting regardless of which route is chosen.
    function test_NoTerminal_UsesStaticEstimation_NoRevert() public {
        // The static estimate: weight * amount / 1e18 = 1e18 * 1e18 / 1e18 = 1e18.
        uint256 staticEstimate = hook.calculateExpectedTokensWithCurrency({
            projectId: 123, paymentToken: address(paymentToken), paymentAmount: 1 ether
        });

        // Should be approximately 1e18 (no reserved rate).
        assertGt(staticEstimate, 0, "static estimate should be positive without terminal");

        // Execute the swap. The key point: no revert from trying to call previewPayFor
        // on address(0). The hook gracefully uses static estimation.
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // This must NOT revert — the hook should handle the no-terminal case gracefully.
        jbSwapRouter.swap(key, params, 0);
    }
}
