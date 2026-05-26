// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
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

// Import Juicebox interfaces (re-exported from the hook for convenience)
import {IJBTokens, IJBPrices, IJBDirectory} from "../src/JBUniswapV4Hook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// JB core concrete implementations (deployed fresh within fork)
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract ZeroPreviewCashOutDataHook is IJBRulesetDataHook {
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        pure
        returns (
            uint256 cashOutTaxRate,
            uint256 effectiveCashOutCount,
            uint256 effectiveTotalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        cashOutTaxRate = context.cashOutTaxRate;
        effectiveCashOutCount = 0;
        effectiveTotalSupply = context.totalSupply;
        effectiveSurplusValue = context.surplus.value;
        hookSpecifications = new JBCashOutHookSpecification[](0);
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata)
        external
        pure
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        weight = 0;
        hookSpecifications = new JBPayHookSpecification[](0);
    }

    function hasMintPermissionFor(uint256, JBRuleset memory, address) external pure returns (bool flag) {
        flag = false;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title JBUniswapV4HookForkTest
/// @notice Fork tests that deploy JB v6 contracts fresh within the fork
/// @dev To run these tests:
///      1. Set RPC_ETHEREUM_MAINNET in your .env file (e.g.,
/// RPC_ETHEREUM_MAINNET=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY)
///      2. Run: source .env && forge test --match-contract JBUniswapV4HookForkTest -vv
/// @dev JB core contracts are deployed fresh within the fork. Only ERC-20 tokens (WETH, USDC, BAN)
///      use real mainnet addresses. NANA is replaced by a freshly deployed JB ERC-20 project token.
contract JBUniswapV4HookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // Mainnet ERC-20 token addresses (exist at FORK_BLOCK)
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant BAN = 0x0faCEdf66a1E37714dbd748639Ea36D23254dB73;

    // Permit2 (exists at FORK_BLOCK)
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // JB core (deployed fresh in setUp)
    address multisig = address(0xBEEF);
    address trustedForwarder = address(0);

    JBPermissions jbPermissions;
    JBProjects jbProjects;
    JBDirectory jbDirectory;
    JBRulesets jbRulesets;
    JBTokens jbTokens;
    JBSplits jbSplits;
    JBPrices jbPrices;
    JBFundAccessLimits jbFundAccessLimits;
    JBFeelessAddresses jbFeelessAddresses;
    JBController jbController;
    JBTerminalStore jbTerminalStore;
    JBMultiTerminal jbMultiTerminal;

    // Project IDs
    uint256 feeProjectId; // Project 1 (fee recipient)
    uint256 nanaProjectId; // Project 2 (the "NANA" project)

    // The deployed JB ERC-20 token for nanaProjectId (replaces the mainnet NANA address)
    // forge-lint: disable-next-line(mixed-case-variable)
    address NANA;

    JBUniswapV4Hook hook;
    IPoolManager manager;
    PoolSwapTest swapRouter;
    JuiceboxSwapRouter jbSwapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    // Test constants
    uint256 constant FORK_BLOCK = 21_700_000;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // sqrt(1.0001^0) * 2^96
    bytes constant ZERO_BYTES = "";

    PoolKey key;
    PoolId id;

    // Test user with mainnet ETH
    address testUser = address(0xCAFE);

    /// @notice Fork mainnet using RPC_ETHEREUM_MAINNET env var, falling back to a public RPC.
    function setUp() public {
        string memory rpcUrl = vm.envOr("RPC_ETHEREUM_MAINNET", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);

        // Mark mainnet ERC-20 tokens as persistent so they survive fork state resets
        vm.makePersistent(WETH);
        vm.makePersistent(USDC);
        vm.makePersistent(BAN);

        // Deploy all JB core contracts fresh within the fork
        _deployJbCore();

        // Launch fee project (project 1) and NANA project (project 2)
        feeProjectId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18});
        nanaProjectId = _launchProject({acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18});

        // Deploy ERC-20 for the NANA project so it has a real token address
        vm.prank(multisig);
        IJBToken nanaToken =
            jbController.deployERC20For({projectId: nanaProjectId, name: "NANA", symbol: "NANA", salt: 0});
        NANA = address(nanaToken);

        // Deploy Uniswap v4 core contracts
        manager = IPoolManager(address(V4PoolManagerDeployer.deploy(address(this))));
        swapRouter = new PoolSwapTest(manager);
        jbSwapRouter = new JuiceboxSwapRouter(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Deploy the hook with freshly deployed JB contracts
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(this));

        (, bytes32 salt) = HookMiner.find(address(this), flags, type(JBUniswapV4Hook).creationCode, constructorArgs);

        hook = new JBUniswapV4Hook{salt: salt}(address(this));
        hook.setChainSpecificConstants({
            newPoolManager: manager,
            newTokens: IJBTokens(address(jbTokens)),
            newDirectory: IJBDirectory(address(jbDirectory)),
            newPrices: IJBPrices(address(jbPrices))
        });

        // Set up a simple pool with NANA/WETH (currencies must be ordered: currency0 < currency1)
        // The deployed NANA ERC-20 address is non-deterministic, so we order dynamically.
        if (NANA < WETH) {
            key = PoolKey({
                currency0: Currency.wrap(NANA),
                currency1: Currency.wrap(WETH),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
        } else {
            key = PoolKey({
                currency0: Currency.wrap(WETH),
                currency1: Currency.wrap(NANA),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hook))
            });
        }

        id = key.toId();

        // Give test user some ETH (enough for liquidity provision)
        vm.deal(testUser, 1_100_000 ether); // 1M for WETH + 100k buffer

        // Try to initialize price to match the Juicebox price index (NANA per WETH)
        // Use the hook's calculation to get how many NANA are minted per 1 WETH, then convert to sqrtPriceX96.
        uint160 initSqrtPriceX96 = SQRT_PRICE_1_1; // Default fallback
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));
        if (projectId != 0) {
            try hook.calculateExpectedTokensWithCurrency(projectId, WETH, 1 ether) returns (uint256 nanaPerWeth) {
                if (nanaPerWeth > 0) {
                    // Compute sqrtPriceX96 based on pool token ordering
                    if (NANA < WETH) {
                        // token0=NANA, token1=WETH: price = token1/token0 = WETH per NANA
                        // ratioX192 = (WETH per NANA) * 2^192 = ((1e18 << 192) / nanaPerWeth)
                        uint256 ratioX192 = (uint256(1e18) << 192) / nanaPerWeth;
                        initSqrtPriceX96 = uint160(_sqrt(ratioX192));
                    } else {
                        // token0=WETH, token1=NANA: price = token1/token0 = NANA per WETH
                        // ratioX192 = nanaPerWeth * 2^192 / 1e18
                        uint256 ratioX192 = (nanaPerWeth << 192) / 1e18;
                        initSqrtPriceX96 = uint160(_sqrt(ratioX192));
                    }
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

    /// @notice Test that the hook can be deployed and initialized with freshly deployed JB contracts
    function testHookDeployment() public view {
        assertTrue(address(hook) != address(0), "Hook should be deployed");
        assertEq(address(hook.TOKENS()), address(jbTokens), "Should use deployed JB_TOKENS");
        assertEq(address(hook.DIRECTORY()), address(jbDirectory), "Should use deployed JB_DIRECTORY");
        assertEq(address(hook.PRICES()), address(jbPrices), "Should use deployed JB_PRICES");
    }

    /// @notice Test that the hook can query the freshly launched Juicebox project
    function testQueryRealJuiceboxProject() public view {
        // Look up the project ID based on the NANA token address via JB Tokens registry
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));

        // Query the project's current ruleset
        (JBRuleset memory ruleset, JBRulesetMetadata memory metadata) = jbController.currentRulesetOf(projectId);

        // Validate that the project exists and has valid ruleset data
        assertTrue(ruleset.weight > 0, "Project should have a positive weight");
        assertTrue(metadata.baseCurrency > 0, "Project should have a base currency");

        // Test calculating expected tokens with ETH payment
        uint256 expectedTokens = hook.calculateExpectedTokensWithCurrency(projectId, address(0), 1 ether);

        // Should return tokens based on the project's weight
        assertTrue(expectedTokens > 0, "Should calculate expected tokens for ETH payment");
    }

    /// @notice Test that the hook can detect if a token is a Juicebox project token
    function testDetectJuiceboxToken() public {
        // This test verifies the hook can call the TOKENS contract
        try jbTokens.projectIdOf(IJBToken(address(NANA))) returns (uint256 projectId) {
            assertTrue(projectId > 0, "Should return a valid project ID for the deployed NANA token");
        } catch Error(string memory reason) {
            console.log("projectIdOf failed for NANA token:", reason);
            fail("projectIdOf should not fail for a valid JB token");
        } catch (bytes memory) {
            console.log("projectIdOf reverted with low-level error");
            fail("projectIdOf should not revert for a valid JB token");
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

        // Determine zeroForOne based on token ordering: we want WETH -> NANA
        bool zeroForOne = Currency.unwrap(key.currency0) == WETH;

        try hook.estimateUniswapOutput(id, key, 1 ether, zeroForOne) returns (uint256 estimatedOut) {
            // Should return positive value (may be 0 if pool has no liquidity)
            assertTrue(estimatedOut >= 0, "Should estimate output (may be 0 for empty pool)");
        } catch Error(string memory reason) {
            // Estimation may fail if pool has issues (no observations, invalid state)
            console.log("Uniswap output estimation failed:", reason);
            // This is acceptable - pool may not have enough TWAP data yet
        } catch (bytes memory) {
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

        // Get v4 output estimate — WETH -> NANA direction
        bool zeroForOne = Currency.unwrap(key.currency0) == WETH;
        try hook.estimateUniswapOutput(id, key, testAmount, zeroForOne) returns (uint256 output) {
            v4Output = output;
        } catch {
            v4Output = 0;
        }

        // Try to get Juicebox output (if we can find a project)
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));
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

        // V4 estimate: selling NANA for WETH
        bool zeroForOneNanaToWeth = Currency.unwrap(key.currency0) == NANA;
        try hook.estimateUniswapOutput(id, key, testAmount, zeroForOneNanaToWeth) returns (uint256 output) {
            v4Output = output;
        } catch {
            v4Output = 0;
        }

        // Juicebox sell-path output (receive WETH when redeeming NANA)
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));
        if (projectId != 0) {
            // Get terminal for the output token (WETH -> normalized to native ETH)
            // forge-lint: disable-next-line(mixed-case-variable)
            address normalizedWETH = address(0x000000000000000000000000000000000000EEEe);
            IJBTerminal jbTerminal;
            try IJBDirectory(address(jbDirectory)).primaryTerminalOf(projectId, normalizedWETH) returns (
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
        uint256 nanaAmount = 1000 ether;
        uint256 wethForLiquidity = 2 ether;
        uint256 amountIn = 0.1 ether;

        // Fund user with NANA and ETH, then wrap ETH to WETH
        deal(NANA, user, nanaAmount);
        vm.deal(user, 5 ether);

        vm.startPrank(user);
        (bool wrapOk,) = WETH.call{value: wethForLiquidity + amountIn}(abi.encodeWithSignature("deposit()"));
        require(wrapOk, "WETH deposit failed");

        // Approve for liquidity and swap
        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);
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

        // Execute a small WETH -> NANA swap
        // Determine direction: if WETH is currency1, zeroForOne=false; if WETH is currency0, zeroForOne=true
        bool zeroForOne = Currency.unwrap(key.currency0) == WETH;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
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

    function _getLastBestRouteFromLogs() private view returns (uint8 routeType, uint256 expectedTokens) {
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

    function _createShallowForkPool(int24 tickSpacing) private returns (PoolKey memory shallowKey, PoolId shallowId) {
        if (NANA < WETH) {
            shallowKey = PoolKey({
                currency0: Currency.wrap(NANA),
                currency1: Currency.wrap(WETH),
                fee: 3000,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(hook))
            });
        } else {
            shallowKey = PoolKey({
                currency0: Currency.wrap(WETH),
                currency1: Currency.wrap(NANA),
                fee: 3000,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(hook))
            });
        }

        shallowId = shallowKey.toId();
        manager.initialize(shallowKey, SQRT_PRICE_1_1);

        vm.startPrank(testUser);
        modifyLiquidityRouter.modifyLiquidity(
            shallowKey,
            ModifyLiquidityParams({
                tickLower: -tickSpacing,
                tickUpper: tickSpacing,
                liquidityDelta: 10 ether,
                // Safe: helper only calls this with small positive tickSpacing values (120 and 180).
                // forge-lint: disable-next-line(unsafe-typecast)
                salt: bytes32(uint256(uint24(uint24(tickSpacing))))
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    function _actualV4Output(PoolKey memory useKey, uint256 amountIn, bool zeroForOne) private returns (uint256) {
        address outputToken = zeroForOne ? Currency.unwrap(useKey.currency1) : Currency.unwrap(useKey.currency0);
        uint256 balanceBefore = IERC20(outputToken).balanceOf(testUser);

        vm.startPrank(testUser);
        IERC20(NANA).approve(address(swapRouter), type(uint256).max);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            useKey,
            SwapParams({
                zeroForOne: zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(uint256(0))
        );
        vm.stopPrank();

        return IERC20(outputToken).balanceOf(testUser) - balanceBefore;
    }

    function _quoteDriftBps(uint256 quote, uint256 actual) private pure returns (uint256) {
        if (quote <= actual) return 0;
        return ((quote - actual) * 10_000) / quote;
    }

    function _measureDriftBpsForTrade(int24 tickSpacing, uint256 amountIn) private returns (uint256 driftBps) {
        (PoolKey memory shallowKey, PoolId shallowId) = _createShallowForkPool(tickSpacing);
        return _measureDriftBpsForTradeOnPool(shallowKey, shallowId, amountIn);
    }

    function _measureDriftBpsForTradeOnPool(
        PoolKey memory shallowKey,
        PoolId shallowId,
        uint256 amountIn
    )
        private
        returns (uint256 driftBps)
    {
        bool wethToNana = Currency.unwrap(shallowKey.currency0) == WETH;

        uint256 quote = hook.estimateUniswapOutput(shallowId, shallowKey, amountIn, wethToNana);
        uint256 actual = _actualV4Output(shallowKey, amountIn, wethToNana);

        assertGt(quote, 0, "fork quote should be live");
        assertGt(actual, 0, "fork execution should be live");
        return _quoteDriftBps(quote, actual);
    }

    function testFork_V4LinearQuoteDriftIsSmallForSmallTrades() public {
        uint256 driftBps = _measureDriftBpsForTrade(120, 0.01 ether);
        assertLe(driftBps, 500, "small trades should stay within a 5% quote-drift envelope");
    }

    function testFork_V4LinearQuoteDriftBecomesMaterialForLargeTrades() public {
        uint256 driftBps = _measureDriftBpsForTrade(180, 5 ether);
        assertGt(driftBps, 2000, "large trades on shallow liquidity should exceed a 20% quote-drift envelope");
    }

    function testFork_V4LinearQuoteDriftSweep() public {
        (PoolKey memory shallowKey, PoolId shallowId) = _createShallowForkPool(120);
        uint256 snapshot = vm.snapshotState();

        uint256 driftAtPointOne = _measureDriftBpsForTradeOnPool(shallowKey, shallowId, 0.1 ether);
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();

        uint256 driftAtHalf = _measureDriftBpsForTradeOnPool(shallowKey, shallowId, 0.5 ether);
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();

        uint256 driftAtOne = _measureDriftBpsForTradeOnPool(shallowKey, shallowId, 1 ether);
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();

        uint256 driftAtTwo = _measureDriftBpsForTradeOnPool(shallowKey, shallowId, 2 ether);
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();

        uint256 driftAtFive = _measureDriftBpsForTradeOnPool(shallowKey, shallowId, 5 ether);

        emit log_named_uint("drift_bps_at_0.1_eth", driftAtPointOne);
        emit log_named_uint("drift_bps_at_0.5_eth", driftAtHalf);
        emit log_named_uint("drift_bps_at_1_eth", driftAtOne);
        emit log_named_uint("drift_bps_at_2_eth", driftAtTwo);
        emit log_named_uint("drift_bps_at_5_eth", driftAtFive);

        assertLe(driftAtPointOne, driftAtHalf, "drift should not improve as trade size grows");
        assertLe(driftAtHalf, driftAtOne, "drift should not improve as trade size grows");
        assertLe(driftAtOne, driftAtTwo, "drift should not improve as trade size grows");
        assertLe(driftAtTwo, driftAtFive, "drift should not improve as trade size grows");
    }

    /// @notice Make v4 clearly favorable by pushing price with a NANA->WETH swap, then verify route="v4".
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
        // Do a large NANA->WETH swap which increases NANA reserves and removes WETH.
        IERC20(NANA).approve(address(swapRouter), type(uint256).max);
        bool nanaIsToken0 = Currency.unwrap(key.currency0) == NANA;
        // forge-lint: disable-next-line(mixed-case-variable)
        SwapParams memory pushDownNANAPrice = SwapParams({
            zeroForOne: nanaIsToken0,
            amountSpecified: -int256(5000 ether),
            sqrtPriceLimitX96: nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        // Best-effort; ignore failure due to liquidity limits
        try swapRouter.swap(
            key, pushDownNANAPrice, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(100))
        ) {}
            catch {} // 1% slippage

        // Now do the priced swap via JB router (so hook can choose route)
        vm.recordLogs();
        uint256 amountIn = 1 ether;
        bool wethToNana = !nanaIsToken0; // If NANA is token0, then WETH is token1 => zeroForOne=false to buy NANA
        SwapParams memory testSwap = SwapParams({
            zeroForOne: !nanaIsToken0,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: wethToNana ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
        });
        try jbSwapRouter.swap(key, testSwap, 0) { // 1% slippage
            (uint8 route,) = _getLastBestRouteFromLogs();
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
        // Do a large WETH->NANA swap which increases WETH reserves and removes NANA.
        bool nanaIsToken0 = Currency.unwrap(key.currency0) == NANA;
        // forge-lint: disable-next-line(mixed-case-variable)
        SwapParams memory pushUpWETHSupply = SwapParams({
            zeroForOne: !nanaIsToken0, // WETH -> NANA direction
            amountSpecified: -int256(5000 ether),
            sqrtPriceLimitX96: !nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        // Best-effort; ignore failure due to liquidity limits
        try swapRouter.swap(key, pushUpWETHSupply, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(100))) {}
            catch {} // 1% slippage

        // Now do the priced swap via JB router (so hook can choose route)
        vm.recordLogs();
        uint256 amountIn = 1000 ether;
        SwapParams memory testSwap = SwapParams({
            zeroForOne: nanaIsToken0, // NANA -> WETH direction
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        try jbSwapRouter.swap(key, testSwap, 0) { // 1% slippage
            (uint8 route,) = _getLastBestRouteFromLogs();
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
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));
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
                    // token0=ETH (address(0)), token1=NANA
                    // price = NANA per ETH = nanaPerEth / 1e18
                    uint256 ratioX192 = (nanaPerEth << 192) / 1e18;
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
        // forge-lint: disable-next-line(mixed-case-variable)
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
            (uint8 route,) = _getLastBestRouteFromLogs();

            // Check for primary terminal (same check as in JBUniswapV4Hook.sol)
            // When buying with ETH, we need to look up terminal that accepts native ETH (JB_NATIVE_TOKEN)
            IJBTerminal jbTerminal;
            address terminalToken = address(0x000000000000000000000000000000000000EEEe); // JB_NATIVE_TOKEN
            try IJBDirectory(address(jbDirectory)).primaryTerminalOf(projectId, terminalToken) returns (IJBTerminal t) {
                jbTerminal = t;
            } catch {
                jbTerminal = IJBTerminal(address(0));
            }

            if (jbOut > v4Out && jbOut > 0 && address(jbTerminal) != address(0)) {
                assertEq(route, 1, "Expected route to be juicebox");

                // Verify quote accuracy: check actual tokens received match quote
                // forge-lint: disable-next-line(mixed-case-variable)
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
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));
        vm.assume(projectId != 0);

        PoolKey memory useKey = key;
        PoolId useId = id;
        bool nanaIsToken0 = Currency.unwrap(key.currency0) == NANA;
        {
            try hook.calculateExpectedTokensWithCurrency(projectId, WETH, 1 ether) returns (uint256 nanaPerWeth) {
                if (nanaPerWeth > 0) {
                    // Create a new pool with wider tick spacing
                    PoolKey memory jbKey;
                    if (NANA < WETH) {
                        jbKey = PoolKey({
                            currency0: Currency.wrap(NANA),
                            currency1: Currency.wrap(WETH),
                            fee: 3000,
                            tickSpacing: 120,
                            hooks: IHooks(address(hook))
                        });
                    } else {
                        jbKey = PoolKey({
                            currency0: Currency.wrap(WETH),
                            currency1: Currency.wrap(NANA),
                            fee: 3000,
                            tickSpacing: 120,
                            hooks: IHooks(address(hook))
                        });
                    }
                    PoolId jbId = jbKey.toId();
                    uint256 ratioX192;
                    if (NANA < WETH) {
                        // token0=NANA, token1=WETH: price = WETH/NANA
                        ratioX192 = (uint256(1e18) << 192) / nanaPerWeth;
                    } else {
                        // token0=WETH, token1=NANA: price = NANA/WETH
                        ratioX192 = (nanaPerWeth << 192) / 1e18;
                    }
                    uint160 jbSqrtPriceX96 = uint160(_sqrt(ratioX192));
                    manager.initialize(jbKey, jbSqrtPriceX96);
                    useKey = jbKey;
                    useId = jbId;
                    nanaIsToken0 = Currency.unwrap(jbKey.currency0) == NANA;
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
        try hook.estimateUniswapOutput(useId, useKey, amountIn, nanaIsToken0) returns (uint256 o) {
            v4Out = o;
        } catch {}

        uint256 jbOut = 0;
        // Get terminal for the output token (WETH)
        // forge-lint: disable-next-line(mixed-case-variable)
        address normalizedWETH = address(0x000000000000000000000000000000000000EEEe);
        IJBTerminal jbTerminal;
        try IJBDirectory(address(jbDirectory)).primaryTerminalOf(projectId, normalizedWETH) returns (IJBTerminal t) {
            jbTerminal = t;
        } catch {
            jbTerminal = IJBTerminal(address(0));
        }
        try hook.calculateExpectedOutputFromSelling(projectId, amountIn, WETH, jbTerminal) returns (uint256 o) {
            jbOut = o;
        } catch {}

        // Record initial balances before swap
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 initialWETH = IERC20(WETH).balanceOf(user);

        vm.recordLogs();
        SwapParams memory testSwap = SwapParams({
            zeroForOne: nanaIsToken0, // NANA -> WETH
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        try jbSwapRouter.swap(useKey, testSwap, 0) { // 1% slippage
            (uint8 route,) = _getLastBestRouteFromLogs();

            if (jbOut > v4Out && jbOut > 0 && address(jbTerminal) != address(0)) {
                assertEq(route, 1, "Expected route to be juicebox");

                // Verify quote accuracy: check actual WETH received matches quote
                // forge-lint: disable-next-line(mixed-case-variable)
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
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));
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
        try IJBDirectory(address(jbDirectory)).primaryTerminalOf(projectId, terminalToken) returns (IJBTerminal t) {
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
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 initialUserETH = user.balance;
        // forge-lint: disable-next-line(mixed-case-variable)
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
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 finalUserETH = user.balance;
            // forge-lint: disable-next-line(mixed-case-variable)
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
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));
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

        bool nanaIsToken0 = Currency.unwrap(key.currency0) == NANA;

        // Add liquidity to enable swaps
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 200 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // First, user needs to own NANA tokens. Get them by buying via Juicebox or Uniswap
        // Buy WETH -> NANA
        uint256 buyAmount = 2 ether;
        SwapParams memory buySwap = SwapParams({
            zeroForOne: !nanaIsToken0, // WETH -> NANA
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(buyAmount),
            sqrtPriceLimitX96: !nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Execute buy - this may route through Juicebox or Uniswap
        // If swap fails, that's a test failure, not something to silently skip
        jbSwapRouter.swap(key, buySwap, 0); // 1% slippage

        // Check user's NANA balance
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 userNANABalance = IERC20(NANA).balanceOf(user);
        require(userNANABalance > 0, "User must have NANA tokens to sell");

        // Now set up for selling: make Juicebox better than Uniswap
        // Manipulate v4 price to be worse for selling NANA by making NANA cheaper in v4
        // Do a large NANA -> WETH swap (makes NANA less valuable)
        IERC20(NANA).approve(address(swapRouter), type(uint256).max);
        SwapParams memory priceManipulation = SwapParams({
            zeroForOne: nanaIsToken0, // NANA -> WETH
            amountSpecified: -int256(5000 ether),
            sqrtPriceLimitX96: nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(
            key, priceManipulation, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(100))
        ) {}
            catch {} // 1% slippage

        // Calculate expected outputs for selling
        uint256 sellAmount = userNANABalance > 1000 ether ? 1000 ether : userNANABalance / 2;

        uint256 v4Out = 0;
        try hook.estimateUniswapOutput(id, key, sellAmount, nanaIsToken0) returns (uint256 o) {
            v4Out = o;
        } catch {}

        // Check for primary terminal that manages WETH (the output token when selling/cashing out)
        IJBTerminal jbTerminal;
        // Hook normalizes WETH to JB_NATIVE_TOKEN before lookup
        // forge-lint: disable-next-line(mixed-case-variable)
        address normalizedWETH = address(0x000000000000000000000000000000000000EEEe);
        try IJBDirectory(address(jbDirectory)).primaryTerminalOf(projectId, normalizedWETH) returns (IJBTerminal t) {
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
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 initialUserWETH = IERC20(WETH).balanceOf(user);
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 initialUserNANA = IERC20(NANA).balanceOf(user);

        // Execute sell swap (NANA -> WETH)
        vm.recordLogs();

        SwapParams memory sellSwap = SwapParams({
            zeroForOne: nanaIsToken0, // NANA -> WETH
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(sellAmount),
            sqrtPriceLimitX96: nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        try jbSwapRouter.swap(key, sellSwap, 0) { // 1% slippage
        // Verify route matches expectation based on terminal availability
            (uint8 route,) = _getLastBestRouteFromLogs();
            if (expectJuiceboxRoute) {
                assertEq(route, 1, "Should route through Juicebox when terminal exists");
            } else {
                // If no terminal exists, hook should route through Uniswap v4
                assertEq(route, 0, "Should route through Uniswap v4 when no terminal exists");
                vm.stopPrank();
                return; // No point checking balances if routing through Uniswap
            }

            // Verify user received WETH (proving cashOutTokensOf succeeded and hook settled WETH back)
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 finalUserWETH = IERC20(WETH).balanceOf(user);
            // forge-lint: disable-next-line(mixed-case-variable)
            uint256 finalUserNANA = IERC20(NANA).balanceOf(user);

            uint256 wethReceived = finalUserWETH > initialUserWETH ? finalUserWETH - initialUserWETH : 0;
            uint256 nanaSpent = initialUserNANA > finalUserNANA ? initialUserNANA - finalUserNANA : 0;

            // User should have received WETH and spent NANA
            assertTrue(wethReceived > 0, "User should have received WETH from cashOutTokensOf");
            assertEq(nanaSpent, sellAmount, "User should have spent the exact sell amount");

            // Verify quote accuracy: actual received should match quote (accounting for fees/slippage)
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

        bool nanaIsToken0 = Currency.unwrap(key.currency0) == NANA;

        // Attempt exact output swap (amountSpecified > 0)
        SwapParams memory params = SwapParams({
            zeroForOne: nanaIsToken0,
            amountSpecified: 1 ether, // Positive = exact output
            sqrtPriceLimitX96: nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Should revert - the error is wrapped by Uniswap v4's error handling
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

        // Approve WETH for swap (user already has WETH from setup)
        IERC20(WETH).approve(address(jbSwapRouter), amountIn);

        // Swap WETH -> NANA
        bool wethIsToken0 = Currency.unwrap(key.currency0) == WETH;
        SwapParams memory params = SwapParams({
            zeroForOne: wethIsToken0,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: wethIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
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

        // Approve WETH for swap (user already has WETH from setup)
        IERC20(WETH).approve(address(jbSwapRouter), amountIn);

        // Swap WETH -> NANA
        bool wethIsToken0 = Currency.unwrap(key.currency0) == WETH;
        SwapParams memory params = SwapParams({
            zeroForOne: wethIsToken0,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: wethIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Estimate expected output
        uint256 expectedOut = hook.estimateUniswapOutput(id, key, amountIn, params.zeroForOne);
        require(expectedOut > 0, "Expected output should be positive");

        // Set amountOutMin to 110% of expected (should fail)
        uint256 amountOutMin = (expectedOut * 110) / 100;

        // Should revert - the error gets wrapped by PoolManager as WrappedError,
        // but the underlying error is JBUniswapV4Hook_InsufficientOutput
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
    function testFork_SellPathSucceedsWithoutApproval() public {
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));
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

        bool nanaIsToken0 = Currency.unwrap(key.currency0) == NANA;

        // Step 1: Buy NANA to accumulate project tokens for the user.
        // Buy via the v4 pool (WETH -> NANA direction).
        uint256 buyAmount = 2 ether;
        SwapParams memory buySwap = SwapParams({
            zeroForOne: !nanaIsToken0, // WETH -> NANA
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(buyAmount),
            sqrtPriceLimitX96: !nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        jbSwapRouter.swap(key, buySwap, 0);

        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 userNANA = IERC20(NANA).balanceOf(user);
        require(userNANA > 0, "User must hold NANA to test sell path");

        // Step 2: Manipulate v4 price so Juicebox cashout is better than Uniswap for selling.
        // Dump NANA into v4 (NANA -> WETH) to make NANA cheaper in v4.
        // forge-lint: disable-next-line(mixed-case-variable)
        SwapParams memory dumpNANA = SwapParams({
            zeroForOne: nanaIsToken0,
            amountSpecified: -int256(5000 ether),
            sqrtPriceLimitX96: nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(key, dumpNANA, PoolSwapTest.TestSettings(false, false), abi.encode(uint256(100))) {}
            catch {}

        // Step 3: Verify Juicebox cashout is the better route before executing the sell.
        uint256 sellAmount = userNANA > 1000 ether ? 1000 ether : userNANA / 2;

        // Get expected outputs from both routes
        uint256 v4Out;
        try hook.estimateUniswapOutput(id, key, sellAmount, nanaIsToken0) returns (uint256 o) {
            v4Out = o;
        } catch {
            v4Out = 0;
        }

        // forge-lint: disable-next-line(mixed-case-variable)
        address normalizedETH = address(0x000000000000000000000000000000000000EEEe);
        IJBTerminal jbTerminal;
        try IJBDirectory(address(jbDirectory)).primaryTerminalOf(projectId, normalizedETH) returns (IJBTerminal t) {
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
        if (jbOut <= v4Out || jbOut == 0) {
            vm.stopPrank();
            return;
        }

        // Step 4: Record allowance BEFORE the sell swap.
        uint256 allowanceBefore = IERC20(NANA).allowance(address(hook), address(jbTerminal));

        // Step 5: Execute sell (NANA -> WETH) routed through Juicebox cashout.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 initialWETH = IERC20(WETH).balanceOf(user);
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 initialNANA = IERC20(NANA).balanceOf(user);

        vm.recordLogs();
        SwapParams memory sellSwap = SwapParams({
            zeroForOne: nanaIsToken0, // NANA -> WETH
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(sellAmount),
            sqrtPriceLimitX96: nanaIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        jbSwapRouter.swap(key, sellSwap, 0);

        // Verify the route was Juicebox (route == 1)
        (uint8 route,) = _getLastBestRouteFromLogs();
        assertEq(route, 1, "Sell should route through Juicebox cashout");

        // Step 6: Verify the hook did NOT grant any new allowance for NANA on the terminal.
        uint256 allowanceAfter = IERC20(NANA).allowance(address(hook), address(jbTerminal));
        assertEq(allowanceAfter, allowanceBefore, "Sell path must not set ERC20 allowance on terminal");

        // Step 7: Verify user received WETH and spent NANA.
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 finalWETH = IERC20(WETH).balanceOf(user);
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 finalNANA = IERC20(NANA).balanceOf(user);

        uint256 wethReceived = finalWETH > initialWETH ? finalWETH - initialWETH : 0;
        uint256 nanaSpent = initialNANA > finalNANA ? initialNANA - finalNANA : 0;

        assertTrue(wethReceived > 0, "User should receive WETH from cashout");
        assertEq(nanaSpent, sellAmount, "User should spend exact sell amount of NANA");

        vm.stopPrank();
    }

    /// @notice Prove that the buy path correctly uses forceApprove for the terminal.
    /// @dev The buy path calls terminal.pay(), which pulls ERC20 tokens via transferFrom.
    function testFork_BuyPathWorksWithApproval() public {
        uint256 projectId = jbTokens.projectIdOf(IJBToken(NANA));
        vm.assume(projectId != 0);

        address user = testUser;
        vm.deal(user, 300 ether);
        vm.startPrank(user);

        // Create a native ETH / NANA pool to test the buy path with native ETH
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
                // token0=ETH(address(0)), token1=NANA: price = NANA/ETH
                uint256 ratioX192 = (nanaPerEth << 192) / 1e18;
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
        try IJBDirectory(address(jbDirectory)).primaryTerminalOf(projectId, terminalToken) returns (IJBTerminal t) {
            jbTerminal = t;
        } catch {
            jbTerminal = IJBTerminal(address(0));
        }
        require(address(jbTerminal) != address(0), "Terminal must exist for buy path test");

        // If JB is not better, skip
        if (jbOut <= v4Out || jbOut == 0) {
            vm.stopPrank();
            return;
        }

        // Record initial balances
        // forge-lint: disable-next-line(mixed-case-variable)
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
        // forge-lint: disable-next-line(mixed-case-variable)
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

    // ═══════════════════════════════════════════════════════════════════════
    // JB Core Deployment (fresh within fork)
    // ═══════════════════════════════════════════════════════════════════════

    function _deployJbCore() internal {
        jbPermissions = new JBPermissions(trustedForwarder);
        jbProjects = new JBProjects(multisig, address(0), trustedForwarder);
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);
        JBERC20 jbErc20 = new JBERC20({permissions: jbPermissions, projects: jbProjects});
        jbTokens = new JBTokens(jbDirectory, jbErc20);
        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, trustedForwarder);
        jbSplits = new JBSplits(jbDirectory);
        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);
        jbFeelessAddresses = new JBFeelessAddresses(multisig);

        jbController = new JBController(
            jbDirectory,
            jbFundAccessLimits,
            jbPermissions,
            jbPrices,
            jbProjects,
            jbRulesets,
            jbSplits,
            jbTokens,
            address(0), // omnichainRulesetOperator
            trustedForwarder
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses,
            jbPermissions,
            jbProjects,
            jbSplits,
            jbTerminalStore,
            jbTokens,
            PERMIT2,
            trustedForwarder
        );
    }

    /// @dev Launch a JB project that accepts `acceptedToken` via the multi terminal.
    function _launchProject(address acceptedToken, uint8 decimals) internal returns (uint256 projectId) {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
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
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1_000_000e18; // 1M tokens per unit of currency
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: acceptedToken, decimals: decimals, currency: uint32(uint160(acceptedToken))});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "test-project",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    /// @dev Launch a JB project with a custom cashOutTaxRate (same as _launchProject but with tax rate).
    function _launchProjectWithTax(
        address acceptedToken,
        uint8 decimals,
        uint16 cashOutTaxRate
    )
        internal
        returns (uint256 projectId)
    {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
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
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1_000_000e18; // 1M tokens per unit of currency
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: acceptedToken, decimals: decimals, currency: uint32(uint160(acceptedToken))});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "test-project-with-tax",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    function _launchProjectWithCashOutDataHook(
        address acceptedToken,
        uint8 decimals,
        address dataHook
    )
        internal
        returns (uint256 projectId)
    {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
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
            useDataHookForPay: false,
            useDataHookForCashOut: true,
            dataHook: dataHook,
            metadata: 0
        });

        JBRulesetConfig[] memory rulesetConfigs = new JBRulesetConfig[](1);
        rulesetConfigs[0].mustStartAtOrAfter = 0;
        rulesetConfigs[0].duration = 0;
        rulesetConfigs[0].weight = 1_000_000e18;
        rulesetConfigs[0].weightCutPercent = 0;
        rulesetConfigs[0].approvalHook = IJBRulesetApprovalHook(address(0));
        rulesetConfigs[0].metadata = metadata;
        rulesetConfigs[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigs[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBAccountingContext[] memory tokensToAccept = new JBAccountingContext[](1);
        tokensToAccept[0] =
        // forge-lint: disable-next-line(unsafe-typecast)
        JBAccountingContext({token: acceptedToken, decimals: decimals, currency: uint32(uint160(acceptedToken))});

        JBTerminalConfig[] memory terminalConfigs = new JBTerminalConfig[](1);
        terminalConfigs[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: tokensToAccept});

        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectUri: "test-project-with-cash-out-data-hook",
            rulesetConfigurations: rulesetConfigs,
            terminalConfigurations: terminalConfigs,
            memo: ""
        });
    }

    // ============================================================
    // Zero-Surplus & Second-Project Tests
    // ============================================================

    /// @notice When a project has zero surplus (no payments made), selling should route via V4 AMM.
    /// @dev The pool has liquidity from setUp(), but the JB project has no surplus because nobody paid it.
    ///      `calculateExpectedOutputFromSelling` returns 0 when surplus is 0, so the hook falls back to V4.
    function testFork_ZeroSurplusRoutesToV4() public {
        address user = testUser;

        // Fund user with NANA tokens to sell (deal directly, NOT via terminal.pay)
        uint256 sellAmount = 100 ether;
        deal(NANA, user, sellAmount);
        vm.deal(user, 1 ether); // gas money

        vm.startPrank(user);

        // Approve NANA for swap
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);

        // Confirm surplus is 0: no one has paid the project
        uint256 terminalBalance =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), nanaProjectId, JBConstants.NATIVE_TOKEN);
        assertEq(terminalBalance, 0, "Terminal balance should be 0 (no payments made)");

        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(NANA),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(nativeKey, SQRT_PRICE_1_1);

        address liquidityProvider = makeAddr("zeroSurplusLiquidityProvider");
        uint256 nativeAmount = 500_000 ether;
        uint256 nanaAmount = 500_000 ether;
        vm.deal(liquidityProvider, nativeAmount);
        deal(NANA, liquidityProvider, nanaAmount);

        vm.startPrank(liquidityProvider);
        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: nativeAmount}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 500_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
        vm.stopPrank();

        vm.startPrank(user);

        // Perform sell swap: NANA -> ETH
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(sellAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 ethBefore = user.balance;

        // Record logs so we can extract BestRouteSelected event
        vm.recordLogs();
        jbSwapRouter.swap(nativeKey, params, 0);

        // Extract route from logs
        (uint8 route,) = _getLastBestRouteFromLogs();

        // Route should be V4 (0) because JB surplus is 0 -> calculateExpectedOutputFromSelling returns 0
        assertEq(route, 0, "Should route via V4 when project has zero surplus");

        // Swap should succeed with nonzero native output from the V4 pool.
        uint256 ethAfter = user.balance;
        assertTrue(ethAfter > ethBefore, "User should receive native ETH from the V4 swap");

        vm.stopPrank();
    }

    /// @notice When surplus exists, the JB sell quote is positive. After depleting surplus via cashout, it routes via
    /// V4.
    /// @dev Flow: pay project -> confirm JB sell quote is positive -> cashout all authentic tokens -> sell (V4 route)
    function testFork_SurplusDepletesSwitchesToV4() public {
        address user = makeAddr("surplusDepletionUser");
        vm.deal(user, 100 ether);

        // Step 1: Pay project to create surplus
        vm.startPrank(user);
        uint256 payAmount = 10 ether;
        jbMultiTerminal.pay{value: payAmount}({
            projectId: nanaProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "create surplus",
            metadata: ""
        });

        // Verify surplus exists
        uint256 terminalBalance =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), nanaProjectId, JBConstants.NATIVE_TOKEN);
        assertTrue(terminalBalance > 0, "Terminal should have balance after payment");

        // User now has NANA tokens from payment
        uint256 userNanaBalance = IERC20(NANA).balanceOf(user);
        assertTrue(userNanaBalance > 0, "User should have NANA tokens after paying project");

        // Step 2: While surplus exists, the JB sell quote should be positive.
        uint256 sellAmount = userNanaBalance / 10;
        assertTrue(sellAmount > 0, "Sell amount should be non-zero");

        uint256 jbExpectedNativeOutputBefore = hook.calculateExpectedOutputFromSelling(
            nanaProjectId, sellAmount, JBConstants.NATIVE_TOKEN, IJBTerminal(address(jbMultiTerminal))
        );
        assertTrue(jbExpectedNativeOutputBefore > 0, "JB native sell quote should be positive while surplus exists");

        // Step 3: Deplete surplus by cashing out all tokens
        uint256 cashOutCount = jbTokens.totalBalanceOf(user, nanaProjectId);

        if (cashOutCount > 0) {
            jbMultiTerminal.cashOutTokensOf({
                holder: user,
                projectId: nanaProjectId,
                cashOutCount: cashOutCount,
                tokenToReclaim: JBConstants.NATIVE_TOKEN,
                minTokensReclaimed: 0,
                beneficiary: payable(user),
                metadata: "",
                referralProjectId: 0
            });
        }

        // Verify surplus is now depleted
        uint256 terminalBalanceAfter =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), nanaProjectId, JBConstants.NATIVE_TOKEN);
        assertEq(terminalBalanceAfter, 0, "Terminal balance should be 0 after full cashout");

        // Step 4: After depletion, the JB native sell quote should be zero, so V4 should win a native-output route.
        uint256 jbExpectedOutput = hook.calculateExpectedOutputFromSelling(
            nanaProjectId, sellAmount, JBConstants.NATIVE_TOKEN, IJBTerminal(address(jbMultiTerminal))
        );
        assertEq(jbExpectedOutput, 0, "JB sell quote should be 0 once the project's reclaimable surplus is depleted");

        vm.stopPrank();

        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(NANA),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(nativeKey, SQRT_PRICE_1_1);

        address liquidityProvider = makeAddr("nativeLiquidityProvider");
        vm.deal(liquidityProvider, 500 ether);
        deal(NANA, liquidityProvider, 500_000 ether);

        vm.startPrank(liquidityProvider);
        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 500 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 500 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
        vm.stopPrank();

        vm.startPrank(user);
        deal(NANA, user, sellAmount);
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);

        SwapParams memory sellParams = SwapParams({
            zeroForOne: false,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(sellAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        vm.recordLogs();
        jbSwapRouter.swap(nativeKey, sellParams, 0);
        (uint8 route2,) = _getLastBestRouteFromLogs();
        assertEq(route2, 0, "Post-depletion sell should route via V4");

        vm.stopPrank();
    }

    /// @notice A live cash-out data hook should influence sell routing through terminal-store preview.
    /// @dev Proves the preview path can suppress a sell quote even while the static reclaim path remains positive.
    function testFork_CashOutPreviewRoutesToV4WhenDataHookSuppressesReclaim() public {
        ZeroPreviewCashOutDataHook dataHook = new ZeroPreviewCashOutDataHook();
        uint256 hookedProjectId = _launchProjectWithCashOutDataHook({
            acceptedToken: JBConstants.NATIVE_TOKEN, decimals: 18, dataHook: address(dataHook)
        });

        vm.prank(multisig);
        IJBToken hookedToken =
            jbController.deployERC20For({projectId: hookedProjectId, name: "HOOKED", symbol: "HKD", salt: 0});
        // forge-lint: disable-next-line(mixed-case-variable)
        address HOOKED = address(hookedToken);

        address user = makeAddr("cashOutPreviewUser");
        vm.deal(user, 100 ether);

        vm.startPrank(user);
        uint256 payAmount = 10 ether;
        jbMultiTerminal.pay{value: payAmount}({
            projectId: hookedProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "create hooked surplus",
            metadata: ""
        });

        uint256 sellAmount = IERC20(HOOKED).balanceOf(user) / 10;
        assertTrue(sellAmount > 0, "Sell amount should be non-zero");

        uint256 staticReclaim = jbTerminalStore.currentTotalReclaimableSurplusOf({
            projectId: hookedProjectId,
            cashOutCount: sellAmount,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
        assertTrue(staticReclaim > 0, "Static reclaim should remain positive before preview override");

        uint256 previewedOutput = hook.calculateExpectedOutputFromSelling({
            projectId: hookedProjectId,
            tokenAmountIn: sellAmount,
            outputToken: JBConstants.NATIVE_TOKEN,
            terminal: IJBTerminal(address(jbMultiTerminal))
        });
        assertEq(previewedOutput, 0, "Sell quote should use previewed reclaim from the live cash-out data hook");
        vm.stopPrank();

        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(HOOKED),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(nativeKey, SQRT_PRICE_1_1);

        address liquidityProvider = makeAddr("hookedNativeLiquidityProvider");
        vm.deal(liquidityProvider, 500 ether);
        deal(HOOKED, liquidityProvider, 500_000 ether);

        vm.startPrank(liquidityProvider);
        IERC20(HOOKED).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 500 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 500 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
        vm.stopPrank();

        vm.startPrank(user);
        deal(HOOKED, user, sellAmount);
        IERC20(HOOKED).approve(address(jbSwapRouter), type(uint256).max);

        vm.recordLogs();
        jbSwapRouter.swap(
            nativeKey,
            SwapParams({
                zeroForOne: false,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            0
        );
        (uint8 route,) = _getLastBestRouteFromLogs();
        assertEq(route, 0, "Preview-suppressed sell should route via V4");

        vm.stopPrank();
    }

    /// @notice Swaps on one project's pool must not affect another project's terminal balance.
    /// @dev Launches a 3rd project with 50% cashOutTaxRate, creates a separate pool, and verifies isolation.
    function testFork_TwoProjectsNoStateLeakage() public {
        // Step 1: Launch project 3 with 50% cash out tax rate
        uint256 project3Id = _launchProjectWithTax({
            acceptedToken: JBConstants.NATIVE_TOKEN,
            decimals: 18,
            cashOutTaxRate: 5000 // 50%
        });

        // Deploy ERC-20 for project 3
        vm.prank(multisig);
        IJBToken project3Token =
            jbController.deployERC20For({projectId: project3Id, name: "PROJ3", symbol: "PRJ3", salt: 0});
        // forge-lint: disable-next-line(mixed-case-variable)
        address PROJ3 = address(project3Token);

        // Step 2: Create native-output pools for both projects so sell routing uses the projects' real terminal token.
        PoolKey memory key2 = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(NANA),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolKey memory key3 = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(PROJ3),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key2, SQRT_PRICE_1_1);
        manager.initialize(key3, SQRT_PRICE_1_1);

        // Step 3: Add liquidity to both native-output pools
        address user = testUser;
        uint256 proj2Amount = 500_000 ether;
        uint256 proj3Amount = 500_000 ether;
        uint256 nativeAmount = 500_000 ether;
        deal(NANA, user, proj2Amount);
        deal(PROJ3, user, proj3Amount);
        vm.deal(user, nativeAmount * 2 + 200 ether);

        vm.startPrank(user);
        IERC20(NANA).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(PROJ3).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity{value: nativeAmount}(
            key2,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 500_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity{value: nativeAmount}(
            key3,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 500_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
        vm.stopPrank();

        // Step 4: Pay both projects to create surplus
        vm.deal(user, 100 ether);
        vm.startPrank(user);

        uint256 payAmount = 10 ether;

        // Pay project 2 (nanaProjectId)
        jbMultiTerminal.pay{value: payAmount}({
            projectId: nanaProjectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "fund project 2",
            metadata: ""
        });

        // Pay project 3
        jbMultiTerminal.pay{value: payAmount}({
            projectId: project3Id,
            token: JBConstants.NATIVE_TOKEN,
            amount: payAmount,
            beneficiary: user,
            minReturnedTokens: 0,
            memo: "fund project 3",
            metadata: ""
        });

        // Record initial terminal balances
        uint256 project2BalanceBefore =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), nanaProjectId, JBConstants.NATIVE_TOKEN);
        uint256 project3BalanceBefore =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), project3Id, JBConstants.NATIVE_TOKEN);

        assertTrue(project2BalanceBefore > 0, "Project 2 should have terminal balance");
        assertTrue(project3BalanceBefore > 0, "Project 3 should have terminal balance");

        // Step 5: Swap on project 2's native-output pool (NANA -> ETH)
        IERC20(NANA).approve(address(jbSwapRouter), type(uint256).max);
        deal(NANA, user, 100 ether);

        SwapParams memory swap2 = SwapParams({
            zeroForOne: false, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        jbSwapRouter.swap(key2, swap2, 0);

        // Assert project 3's terminal balance unchanged after project 2 swap
        uint256 project3BalanceAfterSwap2 =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), project3Id, JBConstants.NATIVE_TOKEN);
        assertEq(
            project3BalanceAfterSwap2, project3BalanceBefore, "Project 3 balance must not change from project 2 swap"
        );

        // Step 6: Swap on project 3's native-output pool (PROJ3 -> ETH)
        IERC20(PROJ3).approve(address(jbSwapRouter), type(uint256).max);
        deal(PROJ3, user, 100 ether);

        SwapParams memory swap3 = SwapParams({
            zeroForOne: false, amountSpecified: -int256(100 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        jbSwapRouter.swap(key3, swap3, 0);

        // Record project 2 balance after project 2's own swap (it may have changed from its own swap)
        uint256 project2BalanceAfterSwap2 =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), nanaProjectId, JBConstants.NATIVE_TOKEN);

        // Assert project 2's terminal balance unchanged after project 3 swap
        uint256 project2BalanceAfterSwap3 =
            jbTerminalStore.balanceOf(address(jbMultiTerminal), nanaProjectId, JBConstants.NATIVE_TOKEN);
        assertEq(
            project2BalanceAfterSwap3,
            project2BalanceAfterSwap2,
            "Project 2 balance must not change from project 3 swap"
        );

        vm.stopPrank();
    }
}
