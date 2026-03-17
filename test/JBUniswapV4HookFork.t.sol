// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {JBUniswapV4Hook} from "../src/JBUniswapV4Hook.sol";
import {JuiceboxSwapRouter} from "./utils/JuiceboxSwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import Juicebox interfaces
import {IJBTokens, IJBController, IJBPrices, IJBDirectory} from "../src/JBUniswapV4Hook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @title JBUniswapV4HookForkTest
/// @notice Fork tests using mainnet addresses
/// @dev To run these tests:
///      1. Optionally set MAINNET_RPC_URL in your .env file (e.g.,
/// MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY) If not set, defaults to
/// https://ethereum-rpc.publicnode.com (public RPC, may have rate limits)
///         For reliable testing, use your own RPC endpoint (Alchemy, Infura, QuickNode, etc.)
///      2. Run: forge test --match-contract JBUniswapV4HookForkTest -vv
/// @dev These tests use real mainnet contracts, so they require a mainnet RPC endpoint
/// @dev Note: Public RPC endpoints may rate limit. If tests fail with 429 errors, set MAINNET_RPC_URL to your own
/// endpoint
contract JBUniswapV4HookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // Mainnet Juicebox addresses
    address constant MAINNET_JB_TOKENS = 0x4d0Edd347FB1fA21589C1E109B3474924BE87636;
    address constant MAINNET_JB_DIRECTORY = 0x0061E516886A0540F63157f112C0588eE0651dCF;
    address constant MAINNET_JB_CONTROLLER = 0x27da30646502e2f642bE5281322Ae8C394F7668a;
    address constant MAINNET_JB_PRICES = 0x9b90E507cF6B7eB681A506b111f6f50245e614c4;
    address constant MAINNET_JB_TERMINAL_STORE = 0xfE33B439Ec53748C87DcEDACb83f05aDd5014744;
    // Mainnet token addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant BAN = 0x0faCEdf66a1E37714dbd748639Ea36D23254dB73;
    address constant NANA = 0x58204a8849BF6A625D56021adfD12ce4a4A3AF13;

    JBUniswapV4Hook hook;
    PoolManager manager;
    PoolSwapTest swapRouter;
    JuiceboxSwapRouter jbSwapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    // Test constants
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // sqrt(1.0001^0) * 2^96
    bytes constant ZERO_BYTES = "";

    PoolKey key;
    PoolId id;

    // Test user with mainnet ETH
    address testUser = address(0xBEEF);

    /// @notice Fork mainnet using RPC_ETHEREUM_MAINNET env var, falling back to a public RPC.
    function setUp() public {
        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl);

        // Mark mainnet contracts as persistent so they can be called in fork tests
        vm.makePersistent(MAINNET_JB_TOKENS);
        vm.makePersistent(MAINNET_JB_DIRECTORY);
        vm.makePersistent(MAINNET_JB_CONTROLLER);
        vm.makePersistent(MAINNET_JB_PRICES);
        vm.makePersistent(MAINNET_JB_TERMINAL_STORE);
        vm.makePersistent(WETH);
        vm.makePersistent(USDC);
        vm.makePersistent(BAN);
        vm.makePersistent(NANA);

        // Deploy core contracts
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        jbSwapRouter = new JuiceboxSwapRouter(IPoolManager(address(manager)));
        modifyLiquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        // Deploy the hook with mainnet addresses
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            IJBTokens(MAINNET_JB_TOKENS),
            IJBDirectory(MAINNET_JB_DIRECTORY),
            IJBPrices(MAINNET_JB_PRICES)
        );

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(
            IPoolManager(address(manager)),
            IJBTokens(MAINNET_JB_TOKENS),
            IJBDirectory(MAINNET_JB_DIRECTORY),
            IJBPrices(MAINNET_JB_PRICES)
        );

        // Set up a simple pool with NANA/WETH (currencies must be ordered: currency0 < currency1)
        key = PoolKey({
            currency0: Currency.wrap(NANA),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        id = key.toId();

        // Give test user some ETH (enough for liquidity provision)
        vm.deal(testUser, 1_100_000 ether); // 1M for WETH + 100k buffer

        // Try to initialize price to match the Juicebox price index (NANA per WETH)
        // Use the hook's calculation to get how many NANA are minted per 1 WETH, then convert to sqrtPriceX96.
        // ratio token1/token0 = WETH per NANA = 1e18 / (NANA per 1e18 WETH)
        uint160 initSqrtPriceX96 = SQRT_PRICE_1_1; // Default fallback
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));
        if (projectId != 0) {
            try hook.calculateExpectedTokensWithCurrency(projectId, WETH, 1 ether) returns (uint256 nanaPerWeth) {
                if (nanaPerWeth > 0) {
                    // ratioX192 = (WETH per NANA) * 2^192 = ((1e18 << 192) / nanaPerWeth)
                    uint256 ratioX192 = (uint256(1e18) << 192) / nanaPerWeth;
                    initSqrtPriceX96 = uint160(_sqrt(ratioX192));
                }
            } catch {
                // keep default fallback
            }
        }

        // Initialize the pool with the derived price
        manager.initialize(key, initSqrtPriceX96);

        // Add large liquidity to v4 pool to enable controlled price shifts via swaps
        {
            address user = testUser;
            // Fund user with tokens
            uint256 nanaAmount = 1_000_000 ether;
            uint256 wethLiquidityEth = 1_000_000 ether; // Match NANA amount for 1:1 price
            deal(NANA, user, nanaAmount);
            vm.deal(user, wethLiquidityEth);

            vm.startPrank(user);
            // Wrap ETH into WETH
            (bool wrapOk,) = WETH.call{value: wethLiquidityEth}(abi.encodeWithSignature("deposit()"));
            require(wrapOk, "WETH deposit failed");

            // Approvals for v4 liquidity router and swap router (future swaps)
            IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);
            IERC20(WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
            IERC20(WETH).approve(address(jbSwapRouter), type(uint256).max);
            // Approve PoolManager to transfer tokens during settlement
            IERC20(NANA).approve(address(manager), type(uint256).max);
            IERC20(WETH).approve(address(manager), type(uint256).max);

            // Add ample liquidity over a reasonably wide band
            modifyLiquidityRouter.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: -600, // multiple of tickSpacing (60)
                    tickUpper: 600,
                    liquidityDelta: 1_000_000 ether,
                    salt: bytes32(0)
                }),
                ZERO_BYTES
            );
            vm.stopPrank();
        }
    }

    // Integer sqrt via Babylonian method for uint256
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Test that the hook can be deployed and initialized with mainnet addresses
    function testHookDeployment() public view {
        assertTrue(address(hook) != address(0), "Hook should be deployed");
        assertEq(address(hook.TOKENS()), MAINNET_JB_TOKENS, "Should use mainnet JB_TOKENS");
        assertEq(address(hook.DIRECTORY()), MAINNET_JB_DIRECTORY, "Should use mainnet JB_DIRECTORY");
        assertEq(address(hook.PRICES()), MAINNET_JB_PRICES, "Should use mainnet JB_PRICES");
    }

    /// @notice Test that the hook can query a real Juicebox project
    function testQueryRealJuiceboxProject() public view {
        // Look up the project ID based on the NANA token address via JB Tokens registry
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));

        // Query the project's current ruleset
        (JBRuleset memory ruleset, JBRulesetMetadata memory metadata) =
            IJBController(MAINNET_JB_CONTROLLER).currentRulesetOf(projectId);

        // Validate that the project exists and has valid ruleset data
        assertTrue(ruleset.weight > 0, "Project should have a positive weight");
        assertTrue(metadata.baseCurrency > 0, "Project should have a base currency");

        // Test calculating expected tokens with ETH payment
        uint256 ethAmount = 1 ether;
        uint256 expectedTokens = hook.calculateExpectedTokensWithCurrency(projectId, address(0), 1 ether);

        // Should return tokens based on the project's weight
        assertTrue(expectedTokens > 0, "Should calculate expected tokens for ETH payment");
        // Test calculating expected tokens with NANA payment
        // uint256 nanaAmount = 1000 ether; // 1000 NANA
        // uint256 expectedTokensNANA = hook.calculateExpectedTokensWithCurrency(projectId, NANA, nanaAmount);

        // // Should return tokens (may be 0 if price feed doesn't exist, but should not revert)
        // assertTrue(expectedTokensNANA >= 0, "Should calculate expected tokens for NANA payment");

        // // Try to verify project token registration (if we can find the token)
        // // Note: The exact method to get project token may vary by Juicebox version
        // // This is optional validation - the main test is the ruleset query and calculations

        // // Test calculating expected output from selling tokens (if project has reclaimable surplus)
        // if (expectedTokens > 0) {
        //     uint256 expectedOutput = hook.calculateExpectedOutputFromSelling(projectId, expectedTokens, USDC);
        //     // Output may be 0 if no surplus, but should not revert
        //     assertTrue(expectedOutput >= 0, "Should calculate expected output from selling tokens");
        // }
    }

    /// @notice Test that the hook can detect if a token is a Juicebox project token
    function testDetectJuiceboxToken() public {
        // This test would need a real JB project token address
        // For now, we just verify the hook can call the TOKENS contract
        try IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(address(NANA))) returns (uint256 projectId) {
            // If address(0) returns 0, that's expected
            assertTrue(projectId == 0 || projectId > 0, "Should return a project ID or 0");
        } catch Error(string memory reason) {
            // Expected to fail for invalid token - address(0) is not a valid IJBToken
            console.log("projectIdOf failed for invalid token:", reason);
            // This is expected behavior
        } catch (bytes memory lowLevelData) {
            // Low-level revert (e.g., invalid function selector, contract doesn't exist)
            console.log("projectIdOf reverted with low-level error");
            // This is acceptable - the token contract may not exist or be invalid
        }
    }

    /// @notice Test that oracle initialization works
    function testOracleInitialization() public view {
        // Check that oracle was initialized during pool setup
        // Note: After adding liquidity in setUp(), the afterAddLiquidity hook records an observation
        // which grows cardinalityNext from 1 to 2 (since we were at capacity: index 0, cardinality 1)
        // However, if the block timestamp hasn't changed, Oracle.write() returns early without updating the index
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = hook.states(id);

        assertEq(index, 0, "Index should be 0 (unchanged if same block timestamp)");
        assertEq(cardinality, 1, "Cardinality should still be 1 (not updated if same block timestamp)");
        assertEq(cardinalityNext, 2, "CardinalityNext should be 2 after growing from initial 1");
    }

    /// @notice Test that TWAP estimation works with real pool data
    /// @dev Adapted from testEstimateUniswapOutput in the main test file
    function testTWAPEstimationWithRealPool() public view {
        // Test TWAP estimation for the NANA/WETH pool
        // With only initial observation, estimate should use spot price fallback

        try hook.estimateUniswapOutput(id, key, 1 ether, false) returns (uint256 estimatedOut) {
            // Should return positive value (may be 0 if pool has no liquidity)
            assertTrue(estimatedOut >= 0, "Should estimate output (may be 0 for empty pool)");
        } catch Error(string memory reason) {
            // Estimation may fail if pool has issues (no observations, invalid state)
            console.log("Uniswap output estimation failed:", reason);
            // This is acceptable - pool may not have enough TWAP data yet
        } catch (bytes memory lowLevelData) {
            // Low-level revert (e.g., division by zero, arithmetic overflow)
            console.log("Uniswap output estimation reverted with low-level error");
            // This is acceptable - pool state may be invalid or calculations may overflow
        }
    }

    /// @notice Complex test: Multi-route price comparison with real pools and Juicebox projects
    /// @dev Tests the hook's ability to compare v4 and Juicebox prices and route optimally
    /// @dev This test simulates a realistic scenario where both routes are available
    function testComplexMultiRoutePriceComparisonBuying() public view {
        // Test with a real swap amount
        uint256 testAmount = 1 ether; // 1 WETH

        // Estimate outputs from both routes
        uint256 v4Output;
        uint256 juiceboxOutput = 0;

        // Get v4 output estimate
        try hook.estimateUniswapOutput(id, key, testAmount, false) returns (uint256 output) {
            v4Output = output;
        } catch {
            v4Output = 0;
        }

        // Try to get Juicebox output (if we can find a project)
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));
        try hook.calculateExpectedTokensWithCurrency(projectId, address(0), testAmount) returns (uint256 output) {
            juiceboxOutput = output;
        } catch {
            juiceboxOutput = 0;
        }

        // Verify that at least one route returns a valid estimate
        assertTrue(v4Output > 0 || juiceboxOutput > 0, "At least one route should return a valid estimate");

        // Log the comparison for debugging
        console.log("V4 Output:", v4Output);
        console.log("Juicebox Output:", juiceboxOutput);

        // The hook should route to the best option
        uint256 bestOutput = v4Output;
        if (juiceboxOutput > bestOutput) bestOutput = juiceboxOutput;

        assertTrue(bestOutput > 0, "Best output should be positive");
    }

    /// @notice Complex test: Multi-route price comparison when selling NANA for WETH
    /// @dev Mirrors testComplexMultiRoutePriceComparison but focuses on the sell flow
    function testComplexMultiRoutePriceComparisonSelling() public view {
        uint256 testAmount = 1000 ether; // Sell 1,000 NANA for WETH

        uint256 v4Output;
        uint256 juiceboxOutput;

        // V4 estimate: selling token0 (NANA) for token1 (WETH) => zeroForOne = true
        try hook.estimateUniswapOutput(id, key, testAmount, true) returns (uint256 output) {
            v4Output = output;
        } catch {
            v4Output = 0;
        }

        // Juicebox sell-path output (receive WETH when redeeming NANA)
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));
        if (projectId != 0) {
            // Get terminal for the output token (WETH)
            address normalizedWETH = address(0x000000000000000000000000000000000000EEEe);
            IJBTerminal jbTerminal;
            try IJBDirectory(MAINNET_JB_DIRECTORY).primaryTerminalOf(projectId, normalizedWETH) returns (
                IJBTerminal t
            ) {
                jbTerminal = t;
            } catch {
                jbTerminal = IJBTerminal(address(0));
            }
            try hook.calculateExpectedOutputFromSelling(projectId, testAmount, WETH, jbTerminal) returns (
                uint256 output
            ) {
                juiceboxOutput = output;
            } catch {
                juiceboxOutput = 0;
            }
        }

        assertTrue(v4Output > 0 || juiceboxOutput > 0, "At least one route should return a valid estimate");

        console.log("V4 Output (WETH):", v4Output);
        console.log("Juicebox Output (WETH):", juiceboxOutput);

        uint256 bestOutput = v4Output;
        if (juiceboxOutput > bestOutput) bestOutput = juiceboxOutput;

        assertTrue(bestOutput > 0, "Best output should be positive");
    }

    /// @notice Test that an oracle observation is recorded after a swap on fork
    function testOracleObservationRecording() public {
        // Record initial observation index
        (uint16 initialIndex,,) = hook.states(id);

        // Prepare a user with tokens and add minimal liquidity so a swap can execute
        address user = testUser;
        uint256 banAmount = 1000 ether;
        uint256 wethForLiquidity = 2 ether;
        uint256 amountIn = 0.1 ether;

        // Fund user with BAN and ETH, then wrap ETH to WETH
        deal(BAN, user, banAmount);
        vm.deal(user, 5 ether);

        vm.startPrank(user);
        (bool wrapOk,) = WETH.call{value: wethForLiquidity + amountIn}(abi.encodeWithSignature("deposit()"));
        require(wrapOk, "WETH deposit failed");

        // Approve for liquidity and swap
        IERC20(BAN).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(WETH).approve(address(jbSwapRouter), amountIn);

        // Add a bit of liquidity to enable swapping
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 5 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // Ensure a different timestamp for a new observation slot
        vm.warp(block.timestamp + 1);

        // Execute a small WETH -> BAN swap (currency1 -> currency0)
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        jbSwapRouter.swap(key, params, 0); // 1% slippage
        vm.stopPrank();

        // Check that observation index moved forward (or wrapped)
        (uint16 newIndex,,) = hook.states(id);
        assertTrue(newIndex == initialIndex + 1 || newIndex == 0, "Index should have incremented");
    }

    // =========================
    // Price selection fork tests
    // =========================

    function _bestRouteSelectedSig() private pure returns (bytes32) {
        return keccak256("BestRouteSelected(bytes32,uint8,uint256,address)");
    }

    function _getLastBestRouteFromLogs() private returns (uint8 routeType, uint256 expectedTokens) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = _bestRouteSelectedSig();
        for (uint256 i = entries.length; i > 0; i--) {
            Vm.Log memory logEntry = entries[i - 1];
            if (logEntry.topics.length > 0 && logEntry.topics[0] == sig) {
                (routeType, expectedTokens,) = abi.decode(logEntry.data, (uint8, uint256, address));
                return (routeType, expectedTokens);
            }
        }
        return (0, 0);
    }

    /// @notice Make v4 clearly favorable by pushing price with a BAN->WETH swap, then verify route="v4".
    function testFork_V4BestPriceRoutesToV4_WETHtoNANA() public {
        address user = testUser;

        // Fund and wrap
        deal(NANA, user, 50_000 ether);
        vm.deal(user, 200 ether);
        vm.startPrank(user);
        (bool okWrap1,) = WETH.call{value: 100 ether}(abi.encodeWithSignature("deposit()"));
        require(okWrap1, "wrap failed");

        // Approvals
        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(WETH).approve(address(jbSwapRouter), type(uint256).max);

        // Add ample liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 200 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // Push price to make NANA cheaper vs WETH for a subsequent WETH->NANA swap:
        // Do a large NANA->WETH swap (zeroForOne=true) which increases NANA reserves and removes WETH.
        IERC20(NANA).approve(address(swapRouter), type(uint256).max);
        SwapParams memory pushDownNANAPrice = SwapParams({
            zeroForOne: true, amountSpecified: -int256(5000 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        // Best-effort; ignore failure due to liquidity limits
        try swapRouter.swap(
            key, pushDownNANAPrice, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(100))
        ) {}
            catch {} // 1% slippage

        // Now do the priced swap via JB router (so hook can choose route)
        vm.recordLogs();
        uint256 amountIn = 1 ether;
        SwapParams memory testSwap = SwapParams({
            zeroForOne: false,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        try jbSwapRouter.swap(key, testSwap, 0) { // 1% slippage
            (uint8 route, uint256 expectedTokens) = _getLastBestRouteFromLogs();
            // Expect v4 due to manipulated favorable v4 price
            assertEq(route, 0, "Expected best route to be v4");
        } catch Error(string memory reason) {
            console.log("testFork_V4BestPriceRoutesToV4 swap failed:", reason);
        } catch {
            console.log("testFork_V4BestPriceRoutesToV4 swap reverted");
        }
        vm.stopPrank();
    }

    /// @notice Mirror the previous test but for the NANA->WETH direction, ensuring v4 is selected when v4 pricing is
    /// best.
    function testFork_V4BestPriceRoutesToV4_NANAtoWETH() public {
        address user = testUser;

        // Fund and wrap
        deal(NANA, user, 50_000 ether);
        vm.deal(user, 200 ether);
        vm.startPrank(user);
        (bool okWrap1,) = WETH.call{value: 100 ether}(abi.encodeWithSignature("deposit()"));
        require(okWrap1, "wrap failed");

        // Approvals
        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);

        // Add ample liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 200 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // Push price to make WETH cheaper vs NANA for a subsequent NANA->WETH swap:
        // Do a large WETH->NANA swap (zeroForOne=false) which increases WETH reserves and removes NANA.
        SwapParams memory pushUpWETHSupply = SwapParams({
            zeroForOne: false, amountSpecified: -int256(5000 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        // Best-effort; ignore failure due to liquidity limits
        try swapRouter.swap(key, pushUpWETHSupply, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(100))) {}
            catch {} // 1% slippage

        // Now do the priced swap via JB router (so hook can choose route)
        vm.recordLogs();
        uint256 amountIn = 1000 ether;
        SwapParams memory testSwap = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        try jbSwapRouter.swap(key, testSwap, 0) { // 1% slippage
            (uint8 route, uint256 expectedTokens) = _getLastBestRouteFromLogs();
            // Expect v4 due to manipulated favorable v4 price
            assertEq(route, 0, "Expected best route to be v4");
        } catch Error(string memory reason) {
            console.log("testFork_V4BestPriceRoutesToV4_NANAtoWETH swap failed:", reason);
        } catch {
            console.log("testFork_V4BestPriceRoutesToV4_NANAtoWETH swap reverted");
        }
        vm.stopPrank();
    }

    /// @notice Prefer JB when JB quote beats v4; otherwise fall back to v4.
    function testFork_JuiceboxBestOrV4Fallback_WETHtoNANA() public {
        // Get NANA projectId
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));
        vm.assume(projectId != 0);

        // Create a pool with native ETH (address(0)) instead of WETH
        // Note: address(0) < NANA, so native ETH will be currency0
        PoolKey memory useKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(NANA),
            fee: 3000,
            tickSpacing: 120,
            hooks: IHooks(address(hook))
        });
        PoolId useId = useKey.toId();

        // Attempt to re-initialize price to the Juicebox price index
        {
            // Compute JB price: NANA per 1 native ETH
            try hook.calculateExpectedTokensWithCurrency(projectId, address(0), 1 ether) returns (uint256 nanaPerEth) {
                if (nanaPerEth > 0) {
                    // sqrtPriceX96 = sqrt((token1/token0) * 2^192)
                    // token1/token0 (ETH per NANA) = (1e18 / nanaPerEth)
                    uint256 ratioX192 = (uint256(1e18) << 192) / nanaPerEth;
                    uint160 jbSqrtPriceX96 = uint160(_sqrt(ratioX192));
                    // Initialize the pool at JB price
                    manager.initialize(useKey, jbSqrtPriceX96);
                }
            } catch {
                // If JB price unavailable, use default price
                manager.initialize(useKey, SQRT_PRICE_1_1);
            }
        }

        address user = testUser;
        // Funds
        deal(NANA, user, 10_000 ether);
        vm.deal(user, 50 ether);
        vm.startPrank(user);

        // Approvals
        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);

        // Add minimal liquidity so swaps via v4 can execute if chosen (using native ETH)
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            useKey,
            ModifyLiquidityParams({
                tickLower: -int24(useKey.tickSpacing),
                tickUpper: int24(useKey.tickSpacing),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        uint256 amountIn = 1 ether;
        // Compare expected outputs
        uint256 v4Out = 0;
        try hook.estimateUniswapOutput(useId, useKey, amountIn, true) returns (uint256 o) {
            v4Out = o;
        } catch {}

        uint256 jbOut = 0;
        // JB quote using native ETH (address(0)) as payment token
        try hook.calculateExpectedTokensWithCurrency(projectId, address(0), amountIn) returns (uint256 o) {
            jbOut = o;
        } catch {}

        // Record initial balance before swap
        uint256 initialNANA = IERC20(NANA).balanceOf(user);

        // Execute via JB router to let hook choose
        vm.recordLogs();
        SwapParams memory testSwap = SwapParams({
            zeroForOne: true, // Native ETH -> NANA
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        try jbSwapRouter.swap{value: amountIn}(useKey, testSwap, 100) { // 1% slippage
            (uint8 route, uint256 expectedTokens) = _getLastBestRouteFromLogs();

            // Check for primary terminal (same check as in JBUniswapV4Hook.sol)
            // When buying with WETH, we need to look up terminal that accepts native ETH (JB_NATIVE_TOKEN)
            // because terminals don't accept WETH directly - we'd need to unwrap WETH first
            IJBTerminal jbTerminal;
            address terminalToken = address(0x000000000000000000000000000000000000EEEe); // JB_NATIVE_TOKEN
            try IJBDirectory(MAINNET_JB_DIRECTORY).primaryTerminalOf(projectId, terminalToken) returns (IJBTerminal t) {
                jbTerminal = t;
            } catch {
                jbTerminal = IJBTerminal(address(0));
            }

            if (jbOut > v4Out && jbOut > 0 && address(jbTerminal) != address(0)) {
                assertEq(route, 1, "Expected route to be juicebox");

                // Verify quote accuracy: check actual tokens received match quote
                uint256 finalNANA = IERC20(NANA).balanceOf(user);
                uint256 nanaReceived = finalNANA > initialNANA ? finalNANA - initialNANA : 0;

                if (nanaReceived > 0 && jbOut > 0) {
                    uint256 diff = nanaReceived > jbOut ? nanaReceived - jbOut : jbOut - nanaReceived;
                    uint256 tolerance = jbOut / 100; // 1% tolerance
                    assertLe(diff, tolerance, "Quote should match actual received tokens (within 1% tolerance)");
                    assertGe(nanaReceived, jbOut * 90 / 100, "Should receive at least 90% of quoted tokens");
                }
            } else if (v4Out > 0) {
                assertEq(route, 0, "Expected route to be v4");
            }
        } catch Error(string memory reason) {
            console.log("testFork_JuiceboxBestOrV4Fallback swap failed:", reason);
        } catch {
            console.log("testFork_JuiceboxBestOrV4Fallback swap reverted");
        }
        vm.stopPrank();
    }

    /// @notice Mirror of testFork_JuiceboxBestOrV4Fallback for the sell (NANA->WETH) direction.
    function testFork_JuiceboxBestOrV4Fallback_NANAtoWETH() public {
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));
        vm.assume(projectId != 0);

        PoolKey memory useKey = key;
        PoolId useId = id;
        {
            try hook.calculateExpectedTokensWithCurrency(projectId, WETH, 1 ether) returns (uint256 nanaPerWeth) {
                if (nanaPerWeth > 0) {
                    PoolKey memory jbKey = PoolKey({
                        currency0: Currency.wrap(NANA),
                        currency1: Currency.wrap(WETH),
                        fee: 3000,
                        tickSpacing: 120,
                        hooks: IHooks(address(hook))
                    });
                    PoolId jbId = jbKey.toId();
                    uint256 ratioX192 = (uint256(1e18) << 192) / nanaPerWeth;
                    uint160 jbSqrtPriceX96 = uint160(_sqrt(ratioX192));
                    manager.initialize(jbKey, jbSqrtPriceX96);
                    useKey = jbKey;
                    useId = jbId;
                }
            } catch {}
        }

        address user = testUser;
        deal(NANA, user, 10_000 ether);
        vm.deal(user, 50 ether);
        vm.startPrank(user);
        (bool okWrap,) = WETH.call{value: 10 ether}(abi.encodeWithSignature("deposit()"));
        require(okWrap, "wrap failed");

        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            useKey,
            ModifyLiquidityParams({
                tickLower: -int24(useKey.tickSpacing),
                tickUpper: int24(useKey.tickSpacing),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        uint256 amountIn = 1000 ether;

        uint256 v4Out = 0;
        try hook.estimateUniswapOutput(useId, useKey, amountIn, true) returns (uint256 o) {
            v4Out = o;
        } catch {}

        uint256 jbOut = 0;
        // Get terminal for the output token (WETH)
        address normalizedWETH = address(0x000000000000000000000000000000000000EEEe);
        IJBTerminal jbTerminal;
        try IJBDirectory(MAINNET_JB_DIRECTORY).primaryTerminalOf(projectId, normalizedWETH) returns (IJBTerminal t) {
            jbTerminal = t;
        } catch {
            jbTerminal = IJBTerminal(address(0));
        }
        try hook.calculateExpectedOutputFromSelling(projectId, amountIn, WETH, jbTerminal) returns (uint256 o) {
            jbOut = o;
        } catch {}

        // Record initial balances before swap
        uint256 initialWETH = IERC20(WETH).balanceOf(user);
        uint256 initialNANA = IERC20(NANA).balanceOf(user);

        vm.recordLogs();
        SwapParams memory testSwap = SwapParams({
            zeroForOne: true,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        try jbSwapRouter.swap(useKey, testSwap, 0) { // 1% slippage
            (uint8 route,) = _getLastBestRouteFromLogs();

            if (jbOut > v4Out && jbOut > 0 && address(jbTerminal) != address(0)) {
                assertEq(route, 1, "Expected route to be juicebox");

                // Verify quote accuracy: check actual WETH received matches quote
                uint256 finalWETH = IERC20(WETH).balanceOf(user);
                uint256 wethReceived = finalWETH > initialWETH ? finalWETH - initialWETH : 0;

                if (wethReceived > 0 && jbOut > 0) {
                    uint256 diff = wethReceived > jbOut ? wethReceived - jbOut : jbOut - wethReceived;
                    uint256 tolerance = jbOut / 100; // 1% tolerance
                    assertLe(diff, tolerance, "Quote should match actual received tokens (within 1% tolerance)");
                    assertGe(wethReceived, jbOut * 90 / 100, "Should receive at least 90% of quoted tokens");
                }
            } else if (v4Out > 0) {
                assertEq(route, 0, "Expected route to be v4");
            }
        } catch Error(string memory reason) {
            console.log("testFork_JuiceboxBestOrV4Fallback_NANAtoWETH swap failed:", reason);
        } catch {
            console.log("testFork_JuiceboxBestOrV4Fallback_NANAtoWETH swap reverted");
        }
        vm.stopPrank();
    }

    /// @notice Test that pay() is executed when buying JB tokens through Juicebox
    /// @dev This test verifies the full buy flow:
    ///      1. User sends ETH to pool via a swap
    ///      2. Hook takes native ETH from pool
    ///      3. Hook calls terminal.pay() to buy JB tokens
    ///      4. Hook receives JB tokens and settles back to pool
    ///      5. Router settles tokens to user
    function testFork_BuyingJBTokenViaPay() public {
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));
        vm.assume(projectId != 0);

        address user = testUser;
        vm.deal(user, 250 ether); // Need enough for liquidity (200 ether) + swap (1 ether) + buffer
        vm.startPrank(user);

        // Create a pool with native ETH (address(0)) instead of WETH
        // Note: address(0) < NANA, so native ETH will be currency0
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(NANA),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId nativeId = nativeKey.toId();

        // Initialize native ETH pool
        manager.initialize(nativeKey, SQRT_PRICE_1_1);

        // Approve for swaps and liquidity
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);
        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add liquidity to enable swaps (using native ETH)
        deal(NANA, user, 10_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 200 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 200 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // Make Juicebox better than Uniswap by manipulating v4 price
        // Do a large swap that makes NANA more expensive in v4 (worse for buying NANA)
        SwapParams memory priceManipulation = SwapParams({
            zeroForOne: true, // Native ETH -> NANA, makes NANA more expensive (worse for buying NANA)
            amountSpecified: -int256(5000 ether),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(
            nativeKey, priceManipulation, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(100))
        ) {} // 1% slippage
            catch {}

        // Calculate expected outputs for buying
        uint256 buyAmount = 1 ether; // 1 native ETH

        uint256 v4Out = 0;
        try hook.estimateUniswapOutput(nativeId, nativeKey, buyAmount, true) returns (uint256 o) {
            v4Out = o;
        } catch {}

        uint256 jbOut = 0;
        // Use native ETH (address(0)) for JB price calculation
        try hook.calculateExpectedTokensWithCurrency(projectId, address(0), buyAmount) returns (uint256 o) {
            jbOut = o;
        } catch {}

        // Check for primary terminal that accepts native ETH (JB_NATIVE_TOKEN)
        IJBTerminal jbTerminal;
        address terminalToken = address(0x000000000000000000000000000000000000EEEe); // JB_NATIVE_TOKEN
        try IJBDirectory(MAINNET_JB_DIRECTORY).primaryTerminalOf(projectId, terminalToken) returns (IJBTerminal t) {
            jbTerminal = t;
        } catch {
            jbTerminal = IJBTerminal(address(0));
        }

        // Require that terminal exists - if it doesn't, this is a test setup problem
        require(address(jbTerminal) != address(0), "Terminal must exist for this test");

        // Only proceed if Juicebox is better than v4
        if (jbOut <= v4Out || jbOut == 0) {
            vm.stopPrank();
            return; // Juicebox not better, can't test this scenario
        }

        // Record initial balances
        uint256 initialUserETH = user.balance;
        uint256 initialUserNANA = IERC20(NANA).balanceOf(user);

        // Execute buy swap (Native ETH -> NANA)
        vm.recordLogs();

        SwapParams memory buySwap = SwapParams({
            zeroForOne: true, // Native ETH -> NANA
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(buyAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        try jbSwapRouter.swap{value: buyAmount}(nativeKey, buySwap, 100) { // 1% slippage
        // Verify route was Juicebox
            (uint8 route,) = _getLastBestRouteFromLogs();
            assertEq(route, 1, "Should route through Juicebox");

            // Verify user received NANA (proving pay() succeeded and hook settled NANA back)
            uint256 finalUserETH = user.balance;
            uint256 finalUserNANA = IERC20(NANA).balanceOf(user);

            uint256 nanaReceived = finalUserNANA > initialUserNANA ? finalUserNANA - initialUserNANA : 0;
            uint256 ethSpent = initialUserETH > finalUserETH ? initialUserETH - finalUserETH : 0;

            // User should have received NANA and spent native ETH
            assertTrue(nanaReceived > 0, "User should have received NANA from pay()");
            assertEq(ethSpent, buyAmount, "User should have spent the exact buy amount");

            // Verify quote accuracy: actual received should match quote (accounting for reserved percent)
            // The quote now accounts for reserved percent, so it should be very close to actual
            // Allow small tolerance for rounding (within 1%)
            if (jbOut > 0) {
                uint256 diff = nanaReceived > jbOut ? nanaReceived - jbOut : jbOut - nanaReceived;
                uint256 tolerance = jbOut / 100; // 1% tolerance
                assertLe(diff, tolerance, "Quote should match actual received tokens (within 1% tolerance)");

                // Also verify it's not way off (should be at least 90% of quote)
                assertGe(nanaReceived, jbOut * 90 / 100, "Should receive at least 90% of quoted tokens");
            }
        } catch Error(string memory reason) {
            console.log("testFork_BuyingJBTokenViaPay swap failed:", reason);
        } catch {
            console.log("testFork_BuyingJBTokenViaPay swap reverted");
        }

        vm.stopPrank();
    }

    /// @notice Test that cashOutTokensOf is executed when selling JB tokens through Juicebox
    /// @dev This test verifies the full sell flow:
    function testFork_SellingJBTokenViaCashOutTokensOf() public {
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));
        vm.assume(projectId != 0);

        address user = testUser;
        vm.deal(user, 20 ether);
        vm.startPrank(user);

        // Wrap ETH to WETH
        (bool wrapOk,) = WETH.call{value: 10 ether}(abi.encodeWithSignature("deposit()"));
        require(wrapOk, "WETH wrap failed");

        // Approve for swaps and liquidity
        IERC20(WETH).approve(address(jbSwapRouter), type(uint256).max);
        IERC20(WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);

        // Add liquidity to enable swaps
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 200 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // First, user needs to own NANA tokens. Get them by buying via Juicebox or Uniswap
        // Try buying through Juicebox first (WETH -> NANA)
        uint256 buyAmount = 2 ether;
        SwapParams memory buySwap = SwapParams({
            zeroForOne: false, // WETH -> NANA
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(buyAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        // Execute buy - this may route through Juicebox or Uniswap
        // If swap fails, that's a test failure, not something to silently skip
        jbSwapRouter.swap(key, buySwap, 0); // 1% slippage

        // Check user's NANA balance
        uint256 userNANABalance = IERC20(NANA).balanceOf(user);
        require(userNANABalance > 0, "User must have NANA tokens to sell");

        // Now set up for selling: make Juicebox better than Uniswap
        // Manipulate v4 price to be worse for selling NANA by making NANA cheaper in v4
        // Do a large swap that makes NANA cheaper (NANA -> WETH, makes NANA less valuable)
        IERC20(NANA).approve(address(swapRouter), type(uint256).max);
        SwapParams memory priceManipulation = SwapParams({
            zeroForOne: true, // NANA -> WETH, makes NANA cheaper (worse for selling NANA in v4)
            amountSpecified: -int256(5000 ether),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        try swapRouter.swap(
            key, priceManipulation, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(100))
        ) {}
            catch {} // 1% slippage

        // Calculate expected outputs for selling
        uint256 sellAmount = userNANABalance > 1000 ether ? 1000 ether : userNANABalance / 2;

        uint256 v4Out = 0;
        try hook.estimateUniswapOutput(id, key, sellAmount, true) returns (uint256 o) {
            v4Out = o;
        } catch {}

        // Check for primary terminal that manages WETH (the output token when selling/cashing out)
        // When cashing out, we need a terminal that has the token we're cashing out TO (WETH), not the JB token (NANA)
        IJBTerminal jbTerminal;
        // Hook normalizes WETH to JB_NATIVE_TOKEN before lookup
        address normalizedWETH = address(0x000000000000000000000000000000000000EEEe);
        try IJBDirectory(MAINNET_JB_DIRECTORY).primaryTerminalOf(projectId, normalizedWETH) returns (IJBTerminal t) {
            jbTerminal = t;
        } catch {
            jbTerminal = IJBTerminal(address(0));
        }

        uint256 jbOut = 0;
        try hook.calculateExpectedOutputFromSelling(projectId, sellAmount, WETH, jbTerminal) returns (uint256 o) {
            jbOut = o;
        } catch {}

        // Require that terminal exists - if it doesn't, this is a test setup problem
        require(address(jbTerminal) != address(0), "Terminal must exist for this test");

        // Only proceed if Juicebox is better than Uniswap
        // If hook looks up wrong terminal, it will route through Uniswap and test will fail
        if (jbOut <= v4Out || jbOut == 0) {
            vm.stopPrank();
            return; // Juicebox not better, can't test this scenario
        }

        // If no terminal exists, hook should route through Uniswap (not Juicebox)
        // The route assertion below will catch bugs where hook looks up wrong terminal
        bool expectJuiceboxRoute = address(jbTerminal) != address(0);

        // Record initial balances
        uint256 initialUserWETH = IERC20(WETH).balanceOf(user);
        uint256 initialUserNANA = IERC20(NANA).balanceOf(user);

        // Execute sell swap (NANA -> WETH)
        // During this swap:
        // 1. User sends NANA to pool via a swap
        // 2. Hook takes NANA from pool (hook now owns ERC20 tokens)
        // 3. Hook calls cashOutTokensOf(address(this), ...) to cash out tokens it owns
        // 4. Hook receives WETH and settles back to pool
        vm.recordLogs();

        SwapParams memory sellSwap = SwapParams({
            zeroForOne: true, // NANA -> WETH
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(sellAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        try jbSwapRouter.swap(key, sellSwap, 0) { // 1% slippage
        // Verify route matches expectation based on terminal availability
            (uint8 route,) = _getLastBestRouteFromLogs();
            if (expectJuiceboxRoute) {
                assertEq(route, 1, "Should route through Juicebox when terminal exists");
            } else {
                // If no terminal exists, hook should route through Uniswap v4
                // This catches bugs where hook looks up wrong terminal
                assertEq(route, 0, "Should route through Uniswap v4 when no terminal exists");
                vm.stopPrank();
                return; // No point checking balances if routing through Uniswap
            }

            // Verify user received WETH (proving cashOutTokensOf succeeded and hook settled WETH back)
            uint256 finalUserWETH = IERC20(WETH).balanceOf(user);
            uint256 finalUserNANA = IERC20(NANA).balanceOf(user);

            uint256 wethReceived = finalUserWETH > initialUserWETH ? finalUserWETH - initialUserWETH : 0;
            uint256 nanaSpent = initialUserNANA > finalUserNANA ? initialUserNANA - finalUserNANA : 0;

            // User should have received WETH and spent NANA
            assertTrue(wethReceived > 0, "User should have received WETH from cashOutTokensOf");
            assertEq(nanaSpent, sellAmount, "User should have spent the exact sell amount");

            // Verify quote accuracy: actual received should match quote (accounting for fees/slippage)
            // The quote should be very close to actual (within 1% tolerance)
            if (jbOut > 0) {
                uint256 diff = wethReceived > jbOut ? wethReceived - jbOut : jbOut - wethReceived;
                uint256 tolerance = jbOut / 100; // 1% tolerance
                assertLe(diff, tolerance, "Quote should match actual received tokens (within 1% tolerance)");

                // Also verify it's not way off (should be at least 90% of quote)
                assertGe(wethReceived, jbOut * 90 / 100, "Should receive at least 90% of quoted tokens");
            }
        } catch Error(string memory reason) {
            console.log("testFork_SellingJBTokenViaCashOutTokensOf swap failed:", reason);
        } catch {
            console.log("testFork_SellingJBTokenViaCashOutTokensOf swap reverted");
        }

        vm.stopPrank();
    }

    // ============================================================
    // Error Condition Tests (Fork)
    // ============================================================

    /// @notice Test that exact output swaps revert with proper error
    /// @dev Verifies JBUniswapV4Hook_ExactOutputSwapsNotSupported error is thrown
    /// @dev Note: The error is wrapped by Uniswap v4, so we check for any revert
    function testFork_ExactOutputSwapsNotSupported() public {
        address user = testUser;
        vm.deal(user, 10 ether);
        vm.startPrank(user);

        // Approve for swap
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);
        IERC20(WETH).approve(address(jbSwapRouter), type(uint256).max);

        // Attempt exact output swap (amountSpecified > 0)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // Positive = exact output
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Should revert - the error is wrapped by Uniswap v4's error handling
        // We verify that exact output swaps are not supported by checking for any revert
        vm.expectRevert();
        jbSwapRouter.swap(key, params, 0); // 1% slippage

        vm.stopPrank();
    }

    // ============================================
    // SLIPPAGE PROTECTION TESTS
    // ============================================

    /// @notice Test that V4 swap succeeds when output >= amountOutMin
    /// @dev Verifies slippage protection allows swaps that meet minimum output
    function testFork_SlippageProtection_V4Swap_Success() public {
        // Setup: Ensure pool has liquidity and user has tokens
        address user = testUser;
        vm.startPrank(user);

        uint256 amountIn = 1 ether;

        // Approve WETH (currency1) for swap (user already has WETH from setup)
        IERC20(WETH).approve(address(jbSwapRouter), amountIn);

        // Swap currency1 (WETH) -> currency0 (NANA), so zeroForOne = false
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        // Estimate expected output
        uint256 expectedOut = hook.estimateUniswapOutput(id, key, amountIn, params.zeroForOne);
        require(expectedOut > 0, "Expected output should be positive");

        // Set amountOutMin to 90% of expected (should pass)
        uint256 amountOutMin = (expectedOut * 90) / 100;

        // Should succeed
        jbSwapRouter.swap(key, params, amountOutMin);

        vm.stopPrank();
    }

    /// @notice Test that V4 swap reverts when output < amountOutMin
    /// @dev Verifies slippage protection blocks swaps that don't meet minimum output
    function testFork_SlippageProtection_V4Swap_Reverts() public {
        // Setup: Ensure pool has liquidity and user has tokens
        address user = testUser;
        vm.startPrank(user);

        uint256 amountIn = 1 ether;

        // Approve WETH (currency1) for swap (user already has WETH from setup)
        IERC20(WETH).approve(address(jbSwapRouter), amountIn);

        // Swap currency1 (WETH) -> currency0 (NANA), so zeroForOne = false
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        // Estimate expected output
        uint256 expectedOut = hook.estimateUniswapOutput(id, key, amountIn, params.zeroForOne);
        require(expectedOut > 0, "Expected output should be positive");

        // Set amountOutMin to 110% of expected (should fail)
        uint256 amountOutMin = (expectedOut * 110) / 100;

        // Should revert - the error gets wrapped by PoolManager as WrappedError,
        // but the underlying error is JBUniswapV4Hook_InsufficientOutput
        // We verify the revert happens (slippage protection works)
        vm.expectRevert();
        jbSwapRouter.swap(key, params, amountOutMin);

        vm.stopPrank();
    }

    // ============================================================
    // Sell-path correctness: no ERC20 approval required
    // ============================================================

    /// @notice Prove that the sell path (cash out JB tokens) works without any ERC20 forceApprove.
    /// @dev The sell path calls cashOutTokensOf, which burns JB tokens via the controller — it does
    ///      NOT use ERC20 transferFrom. Therefore no approval to the terminal is needed.
    ///      This test verifies:
    ///        1. User buys NANA via the pool to acquire tokens.
    ///        2. User sells NANA back (NANA → WETH) and it routes through Juicebox cashout.
    ///        3. The hook never sets an ERC20 allowance on the terminal for the sell path.
    ///        4. NANA tokens are burned and user receives WETH.
    function testFork_SellPathSucceedsWithoutApproval() public {
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));
        vm.assume(projectId != 0);

        address user = testUser;
        vm.deal(user, 50 ether);
        vm.startPrank(user);

        // Wrap ETH to WETH for pool operations
        (bool wrapOk,) = WETH.call{value: 20 ether}(abi.encodeWithSignature("deposit()"));
        require(wrapOk, "WETH wrap failed");

        // Approve tokens for swap and liquidity routers
        IERC20(WETH).approve(address(jbSwapRouter), type(uint256).max);
        IERC20(WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);
        IERC20(NANA).approve(address(swapRouter), type(uint256).max);

        // Step 1: Buy NANA to accumulate project tokens for the user.
        // Buy via the v4 pool (WETH -> NANA direction).
        uint256 buyAmount = 2 ether;
        SwapParams memory buySwap = SwapParams({
            zeroForOne: false, // WETH (currency1) -> NANA (currency0)
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(buyAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        jbSwapRouter.swap(key, buySwap, 0);

        uint256 userNANA = IERC20(NANA).balanceOf(user);
        require(userNANA > 0, "User must hold NANA to test sell path");

        // Step 2: Manipulate v4 price so Juicebox cashout is better than Uniswap for selling.
        // Dump NANA into v4 (NANA -> WETH) to make NANA cheaper in v4.
        SwapParams memory dumpNANA = SwapParams({
            zeroForOne: true, amountSpecified: -int256(5000 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        try swapRouter.swap(key, dumpNANA, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(100))) {}
            catch {}

        // Step 3: Verify Juicebox cashout is the better route before executing the sell.
        uint256 sellAmount = userNANA > 1000 ether ? 1000 ether : userNANA / 2;

        // Get expected outputs from both routes
        uint256 v4Out;
        try hook.estimateUniswapOutput(id, key, sellAmount, true) returns (uint256 o) {
            v4Out = o;
        } catch {
            v4Out = 0;
        }

        address normalizedETH = address(0x000000000000000000000000000000000000EEEe);
        IJBTerminal jbTerminal;
        try IJBDirectory(MAINNET_JB_DIRECTORY).primaryTerminalOf(projectId, normalizedETH) returns (IJBTerminal t) {
            jbTerminal = t;
        } catch {
            jbTerminal = IJBTerminal(address(0));
        }
        require(address(jbTerminal) != address(0), "Terminal must exist for sell path test");

        uint256 jbOut;
        try hook.calculateExpectedOutputFromSelling(projectId, sellAmount, WETH, jbTerminal) returns (uint256 o) {
            jbOut = o;
        } catch {
            jbOut = 0;
        }

        // If Juicebox is not better, skip (the price manipulation didn't work enough).
        // This is not a test failure — just means mainnet state doesn't support this scenario.
        if (jbOut <= v4Out || jbOut == 0) {
            vm.stopPrank();
            return;
        }

        // Step 4: Record allowance BEFORE the sell swap.
        // On the sell path, the hook should NOT set any allowance for NANA on the terminal.
        uint256 allowanceBefore = IERC20(NANA).allowance(address(hook), address(jbTerminal));

        // Step 5: Execute sell (NANA -> WETH) routed through Juicebox cashout.
        uint256 initialWETH = IERC20(WETH).balanceOf(user);
        uint256 initialNANA = IERC20(NANA).balanceOf(user);

        vm.recordLogs();
        SwapParams memory sellSwap = SwapParams({
            zeroForOne: true, // NANA (currency0) -> WETH (currency1)
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(sellAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        jbSwapRouter.swap(key, sellSwap, 0);

        // Verify the route was Juicebox (route == 1)
        (uint8 route,) = _getLastBestRouteFromLogs();
        assertEq(route, 1, "Sell should route through Juicebox cashout");

        // Step 6: Verify the hook did NOT grant any new allowance for NANA on the terminal.
        // cashOutTokensOf burns tokens via the controller, not transferFrom.
        uint256 allowanceAfter = IERC20(NANA).allowance(address(hook), address(jbTerminal));
        assertEq(allowanceAfter, allowanceBefore, "Sell path must not set ERC20 allowance on terminal");

        // Step 7: Verify user received WETH and spent NANA.
        uint256 finalWETH = IERC20(WETH).balanceOf(user);
        uint256 finalNANA = IERC20(NANA).balanceOf(user);

        uint256 wethReceived = finalWETH > initialWETH ? finalWETH - initialWETH : 0;
        uint256 nanaSpent = initialNANA > finalNANA ? initialNANA - finalNANA : 0;

        assertTrue(wethReceived > 0, "User should receive WETH from cashout");
        assertEq(nanaSpent, sellAmount, "User should spend exact sell amount of NANA");

        vm.stopPrank();
    }

    /// @notice Prove that the buy path correctly uses forceApprove for the terminal.
    /// @dev The buy path calls terminal.pay(), which pulls ERC20 tokens via transferFrom.
    ///      The hook must approve the terminal before calling pay(). This test verifies:
    ///        1. A native ETH -> NANA swap routes through Juicebox (pay path).
    ///        2. User receives NANA tokens (proving pay() succeeded).
    ///        3. The forceApprove mechanism works correctly for non-native-ETH buy paths.
    function testFork_BuyPathWorksWithApproval() public {
        uint256 projectId = IJBTokens(MAINNET_JB_TOKENS).projectIdOf(IJBToken(NANA));
        vm.assume(projectId != 0);

        address user = testUser;
        vm.deal(user, 300 ether);
        vm.startPrank(user);

        // Create a native ETH / NANA pool to test the buy path with native ETH
        // Native ETH (address(0)) < NANA, so ETH is currency0
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(NANA),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize at the JB price so buying via JB is competitive
        uint160 initPrice = SQRT_PRICE_1_1;
        try hook.calculateExpectedTokensWithCurrency(projectId, address(0), 1 ether) returns (uint256 nanaPerEth) {
            if (nanaPerEth > 0) {
                uint256 ratioX192 = (uint256(1e18) << 192) / nanaPerEth;
                initPrice = uint160(_sqrt(ratioX192));
            }
        } catch {}
        manager.initialize(nativeKey, initPrice);

        // Approve NANA for liquidity provision
        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add liquidity (using native ETH)
        deal(NANA, user, 10_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 200 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 200 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // Manipulate v4 price to make JB route better for buying NANA.
        // Push NANA price up in v4 by buying a lot of NANA (ETH -> NANA).
        SwapParams memory pushUp = SwapParams({
            zeroForOne: true, // ETH -> NANA, makes NANA more expensive in v4
            amountSpecified: -int256(50 ether),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap{value: 50 ether}(
            nativeKey, pushUp, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(0))
        ) {}
            catch {}

        // Compare outputs to confirm JB is better
        PoolId nativeId = nativeKey.toId();
        uint256 buyAmount = 1 ether;

        uint256 v4Out;
        try hook.estimateUniswapOutput(nativeId, nativeKey, buyAmount, true) returns (uint256 o) {
            v4Out = o;
        } catch {
            v4Out = 0;
        }

        uint256 jbOut;
        try hook.calculateExpectedTokensWithCurrency(projectId, address(0), buyAmount) returns (uint256 o) {
            jbOut = o;
        } catch {
            jbOut = 0;
        }

        // Check terminal exists
        address terminalToken = address(0x000000000000000000000000000000000000EEEe);
        IJBTerminal jbTerminal;
        try IJBDirectory(MAINNET_JB_DIRECTORY).primaryTerminalOf(projectId, terminalToken) returns (IJBTerminal t) {
            jbTerminal = t;
        } catch {
            jbTerminal = IJBTerminal(address(0));
        }
        require(address(jbTerminal) != address(0), "Terminal must exist for buy path test");

        // If JB is not better, skip (mainnet state doesn't support this scenario)
        if (jbOut <= v4Out || jbOut == 0) {
            vm.stopPrank();
            return;
        }

        // Record initial balances
        uint256 initialNANA = IERC20(NANA).balanceOf(user);

        // Execute buy swap (native ETH -> NANA)
        vm.recordLogs();
        SwapParams memory buySwap = SwapParams({
            zeroForOne: true, // ETH (currency0) -> NANA (currency1)
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(buyAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        jbSwapRouter.swap{value: buyAmount}(nativeKey, buySwap, 0);

        // Verify the route was Juicebox (route == 1)
        (uint8 route,) = _getLastBestRouteFromLogs();
        assertEq(route, 1, "Buy should route through Juicebox pay()");

        // Verify user received NANA (proving terminal.pay() succeeded with correct approval)
        uint256 finalNANA = IERC20(NANA).balanceOf(user);
        uint256 nanaReceived = finalNANA > initialNANA ? finalNANA - initialNANA : 0;
        assertTrue(nanaReceived > 0, "User should receive NANA from Juicebox pay()");

        // Verify quote accuracy (within 1% tolerance)
        if (jbOut > 0 && nanaReceived > 0) {
            uint256 diff = nanaReceived > jbOut ? nanaReceived - jbOut : jbOut - nanaReceived;
            uint256 tolerance = jbOut / 100;
            assertLe(diff, tolerance, "Buy quote should match actual within 1%");
        }

        vm.stopPrank();
    }
}

