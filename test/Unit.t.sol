// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "src/interfaces/external/IWETH9.sol";
import /* {*} from */ "@bananapus/core/test/helpers/TestBaseWorkflow.sol";

import "@bananapus/core/src/interfaces/IJBController.sol";
import "@bananapus/core/src/interfaces/IJBDirectory.sol";
import "@bananapus/core/src/interfaces/IJBRedeemHook.sol";
import "@bananapus/core/src/libraries/JBConstants.sol";
import "@bananapus/permission-ids/src/JBPermissionIds.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core/src/libraries/JBRulesetMetadataResolver.sol";

import /* {*} from */ "@bananapus/core/test/helpers/TestBaseWorkflow.sol";

import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "forge-std/Test.sol";

import "./helpers/PoolAddress.sol";
import "src/JBBuybackHook.sol";

/// @notice Unit tests for `JBBuybackHook`.
contract Test_BuybackHook_Unit is TestBaseWorkflow, JBTest {
    using stdStorage for StdStorage;
    using JBRulesetMetadataResolver for JBRulesetMetadata;

    ForTest_JBBuybackHook hook;

    event Swap(uint256 indexed projectId, uint256 amountIn, IUniswapV3Pool pool, uint256 amountOut, address caller);
    event Mint(uint256 indexed projectId, uint256 amount, uint256 tokenCount, address caller);
    event TwapWindowChanged(uint256 indexed projectId, uint256 oldSecondsAgo, uint256 newSecondsAgo, address caller);
    event TwapSlippageToleranceChanged(
        uint256 indexed projectId, uint256 oldTwapTolerance, uint256 newTwapTolerance, address caller
    );
    event PoolAdded(uint256 indexed projectId, address indexed terminalToken, address newPool, address caller);

    // Use the old JBX<->ETH pair with a 1% fee as the `UniswapV3Pool` throughout tests.
    // This deterministically comes out to the address below.
    IUniswapV3Pool pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);
    IERC20 projectToken = IERC20(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66); // JBX
    IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint24 fee = 10_000;

    // A random non-wETH pool: The PulseDogecoin Staking Carnival Token <-> HEX @ 0.3% fee
    IERC20 otherRandomProjectToken = IERC20(0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39);
    IERC20 randomTerminalToken = IERC20(0x488Db574C77dd27A07f9C97BAc673BC8E9fC6Bf3);
    IUniswapV3Pool randomPool = IUniswapV3Pool(0x7668B2Ea8490955F68F5c33E77FE150066c94fb9);
    uint24 randomFee = 3000;
    uint256 randomId = 420;

    // The Uniswap factory address. Used when calculating pool addresses.
    address uniswapFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    IJBMultiTerminal multiTerminal = IJBMultiTerminal(makeAddr("IJBMultiTerminal"));
    IJBProjects projects = IJBProjects(makeAddr("IJBProjects"));
    IJBPermissions permissions = IJBPermissions(makeAddr("IJBPermissions"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBPrices prices = IJBPrices(makeAddr("prices"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));

    address terminalStore = makeAddr("terminalStore");

    address dude = makeAddr("dude");
    address owner = makeAddr("owner");

    uint32 twapWindow = 100; // 100 seconds ago.
    uint256 twapTolerance = 100; // only 1% slippage from TWAP tolerated.

    uint256 projectId = 69;

    JBBeforePayRecordedContext beforePayRecordedContext = JBBeforePayRecordedContext({
        terminal: address(multiTerminal),
        payer: dude,
        amount: JBTokenAmount({
            token: address(weth),
            value: 1 ether,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        }),
        projectId: projectId,
        rulesetId: 0,
        beneficiary: dude,
        weight: 69,
        reservedPercent: 0,
        metadata: ""
    });

    JBAfterPayRecordedContext afterPayRecordedContext = JBAfterPayRecordedContext({
        payer: dude,
        projectId: projectId,
        rulesetId: 0,
        amount: JBTokenAmount({
            token: JBConstants.NATIVE_TOKEN,
            value: 1 ether,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        }),
        forwardedAmount: JBTokenAmount({
            token: JBConstants.NATIVE_TOKEN,
            value: 1 ether,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        }),
        weight: 1,
        projectTokenCount: 69,
        beneficiary: dude,
        hookMetadata: "",
        payerMetadata: ""
    });

    function setUp() public override {
        super.setUp();

        vm.etch(address(projectToken), "6969");
        vm.etch(address(weth), "6969");
        vm.etch(address(pool), "6969");
        vm.etch(address(multiTerminal), "6969");
        vm.etch(address(projects), "6969");
        vm.etch(address(permissions), "6969");
        vm.etch(address(controller), "6969");
        vm.etch(address(directory), "6969");

        vm.label(address(pool), "pool");
        vm.label(address(projectToken), "projectToken");
        vm.label(address(weth), "weth");

        vm.mockCall(address(multiTerminal), abi.encodeCall(multiTerminal.STORE, ()), abi.encode(terminalStore));
        vm.mockCall(address(controller), abi.encodeCall(IJBPermissioned.PERMISSIONS, ()), abi.encode(permissions));
        vm.mockCall(address(controller), abi.encodeCall(controller.PROJECTS, ()), abi.encode(projects));

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(owner));

        vm.mockCall(address(controller), abi.encodeCall(controller.TOKENS, ()), abi.encode(tokens));

        vm.prank(owner);
        hook = new ForTest_JBBuybackHook({
            weth: weth,
            factory: uniswapFactory,
            directory: directory,
            controller: controller,
            prices: prices
        });

        hook.ForTest_initPool(pool, projectId, twapWindow, twapTolerance, address(projectToken), address(weth));
        hook.ForTest_initPool(
            randomPool,
            randomId,
            twapWindow,
            twapTolerance,
            address(otherRandomProjectToken),
            address(randomTerminalToken)
        );
    }

    /// @notice Test `beforePayRecordedWith` when a quote (minimum return amount) is specified in the payment metadata.
    /// @dev `tokenCount == weight` because we use a value of 1 (in `beforePayRecordedContext`.
    function test_beforePayRecordedWith_callWithQuote(
        uint256 weight,
        uint256 swapOutCount,
        uint256 amountIn,
        uint8 decimals
    )
        public
    {
        // Avoid accidentally using the TWAP (triggered if `out == 0`).
        swapOutCount = bound(swapOutCount, 1, type(uint256).max);

        // Avoid `mulDiv` overflow.
        weight = bound(weight, 1, 1 ether);

        // Use between 1 wei and the whole amount from `pay(...)`.
        amountIn = bound(amountIn, 1, beforePayRecordedContext.amount.value);

        // The terminal token decimals.
        decimals = uint8(bound(decimals, 1, 18));

        // Calculate the number of project tokens that a direct payment of `amountIn` terminal tokens would yield.
        uint256 tokenCount = mulDiv(amountIn, weight, 10 ** decimals);

        // Pass the quote as metadata.
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(amountIn, swapOutCount);

        // Pass the hook ID in the metadata.
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = JBMetadataResolver.getId("quote", address(hook));

        // Generate the metadata.
        bytes memory metadata = metadataHelper().createMetadata(ids, data);

        // Set the relevant context.
        beforePayRecordedContext.weight = weight;
        beforePayRecordedContext.metadata = metadata;
        beforePayRecordedContext.amount = JBTokenAmount({
            token: address(weth),
            value: 1 ether,
            decimals: decimals,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Return values to catch:
        JBPayHookSpecification[] memory specificationsReturned;
        uint256 weightReturned;

        // Package data for ruleset call.
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        JBRuleset memory _ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 1e18,
            decayPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });

        // Mock call to controller grabbing the current ruleset
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (projectId)),
            abi.encode(_ruleset, _rulesMetadata)
        );

        // Test: call `beforePayRecordedWith`.
        vm.prank(terminalStore);
        (weightReturned, specificationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);

        // If minting would yield more tokens, mint:
        if (tokenCount >= swapOutCount) {
            // No hook specifications should be returned.
            assertEq(specificationsReturned.length, 0, "Wrong number of hook specifications returned");

            // The weight should be returned unchanged.
            assertEq(weightReturned, weight, "Weight isn't unchanged");
        }
        // Otherwise, swap (with the appropriate hook specification):
        else {
            // There should be 1 hook specification,
            assertEq(specificationsReturned.length, 1, "Wrong number of hook specifications returned");
            // with the correct hook address,
            assertEq(address(specificationsReturned[0].hook), address(hook), "Wrong hook address returned");
            // the full amount paid in,
            assertEq(specificationsReturned[0].amount, amountIn, "Wrong amount returned in hook specification");
            // the correct metadata,
            assertEq(
                specificationsReturned[0].metadata,
                abi.encode(
                    address(projectToken) < address(weth),
                    beforePayRecordedContext.amount.value - amountIn,
                    swapOutCount
                ),
                "Wrong metadata returned in hook specification"
            );
            // and a weight of 0 to prevent additional minting from the terminal.
            assertEq(weightReturned, 0, "Wrong weight returned in hook specification (should be 0 if swapping)");
        }
    }

    /// @notice Test `beforePayRecordedContext` when no quote is provided.
    /// @dev This means the hook must calculate its own quote based on the TWAP.
    /// @dev This bypasses testing the Uniswap Oracle lib by re-using the internal `_getQuote(...)`.
    function test_beforePayRecordedWith_useTwap_OldestObservationZero(uint256 tokenCount) public {
        // Set the relevant context.
        beforePayRecordedContext.weight = tokenCount;
        beforePayRecordedContext.metadata = "";

        // Mock the pool being unlocked.
        vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 1, 0, 0, true));
        vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

        // Return the oldest observationTimestamp as the current block, making oldest observation 0.
        mockExpect(address(pool), abi.encodeCall(pool.observations, (0)), abi.encode(block.timestamp, 0, 0, true));

        // Return values to catch:
        JBPayHookSpecification[] memory specificationsReturned;
        uint256 weightReturned;

        // Test: call `beforePayRecordedWith`.
        vm.prank(terminalStore);
        (weightReturned, specificationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);

        // Bypass testing the Uniswap oracle lib by using the internal function `_getQuote(...)`.
        uint256 twapAmountOut = hook.ForTest_getQuote(projectId, address(projectToken), 1 ether, address(weth));

        // If minting would yield more tokens, mint:
        if (tokenCount >= twapAmountOut) {
            // No hook specifications should be returned.
            assertEq(specificationsReturned.length, 0);

            // The weight should be returned unchanged.
            assertEq(weightReturned, tokenCount);
        }
        // Otherwise, swap (with the appropriate hook specification):
        else {
            // There should be 1 hook specification,
            assertEq(specificationsReturned.length, 1);
            // with the correct hook address,
            assertEq(address(specificationsReturned[0].hook), address(hook));
            // the full amount paid in,
            assertEq(specificationsReturned[0].amount, 1 ether);
            // the correct metadata,
            assertEq(
                specificationsReturned[0].metadata,
                abi.encode(address(projectToken) < address(weth), 0, twapAmountOut),
                "Wrong metadata returned in hook specification"
            );
            // and a weight of 0 to prevent additional minting from the terminal.
            assertEq(weightReturned, 0);
        }
    }

    /// @notice Test `beforePayRecordedContext` when no quote is provided.
    /// @dev This means the hook must calculate its own quote based on the TWAP.
    /// @dev This bypasses testing the Uniswap Oracle lib by re-using the internal `_getQuote(...)`.
    function test_beforePayRecordedWith_useTwap_OldestObservationLT_Twap(uint256 tokenCount) public {
        // Set the relevant context.
        beforePayRecordedContext.weight = tokenCount;
        beforePayRecordedContext.metadata = "";

        // Mock the pool being unlocked.
        vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 1, 0, 0, true));
        vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

        // Return the oldest observationTimestamp as the current block, making oldest observation 0.
        mockExpect(address(pool), abi.encodeCall(pool.observations, (0)), abi.encode(block.timestamp - 1, 0, 0, true));

        // Mock the pool's TWAP.
        // Set up the two points in time to mock the TWAP at.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 1;
        secondsAgos[1] = 0;

        // Mock the seconds per liquidity for those two points.
        // Each represents the amount of time the pool spent at the corresponding level of liquidity.
        uint160[] memory secondsPerLiquidity = new uint160[](2);
        secondsPerLiquidity[0] = 0;
        secondsPerLiquidity[1] = 1;

        // Mock the tick cumulative values for the two mock TWAP points.
        // Tick cumulatives are running totals of tick values.
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 100;
        tickCumulatives[1] = 1000;

        // Mock a call to the pool's `observe` function, passing in the `secondsAgo` array and returning the
        // `tickCumulatives` and `secondsPerLiquidity` arrays.
        vm.mockCall(
            address(pool), abi.encodeCall(pool.observe, (secondsAgos)), abi.encode(tickCumulatives, secondsPerLiquidity)
        );
        // Expect a call to the pool's `observe` function with the `secondsAgo` array.
        vm.expectCall(address(pool), abi.encodeCall(pool.observe, (secondsAgos)));

        // Return values to catch:
        JBPayHookSpecification[] memory specificationsReturned;
        uint256 weightReturned;

        // Package data for ruleset call.
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        JBRuleset memory _ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 1e18,
            decayPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });

        // Mock call to controller grabbing the current ruleset
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (projectId)),
            abi.encode(_ruleset, _rulesMetadata)
        );

        // Test: call `beforePayRecordedWith`.
        vm.prank(terminalStore);
        (weightReturned, specificationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);

        // Bypass testing the Uniswap oracle lib by using the internal function `_getQuote(...)`.
        uint256 twapAmountOut = hook.ForTest_getQuote(projectId, address(projectToken), 1 ether, address(weth));

        // If minting would yield more tokens, mint:
        if (tokenCount >= twapAmountOut) {
            // No hook specifications should be returned.
            assertEq(specificationsReturned.length, 0);

            // The weight should be returned unchanged.
            assertEq(weightReturned, tokenCount);
        }
        // Otherwise, swap (with the appropriate hook specification):
        else {
            // There should be 1 hook specification,
            assertEq(specificationsReturned.length, 1);
            // with the correct hook address,
            assertEq(address(specificationsReturned[0].hook), address(hook));
            // the full amount paid in,
            assertEq(specificationsReturned[0].amount, 1 ether);
            // the correct metadata,
            assertEq(
                specificationsReturned[0].metadata,
                abi.encode(address(projectToken) < address(weth), 0, twapAmountOut),
                "Wrong metadata returned in hook specification"
            );
            // and a weight of 0 to prevent additional minting from the terminal.
            assertEq(weightReturned, 0);
        }
    }

    /// @notice Test `beforePayRecordedWith` with a TWAP but a locked pool, which should lead to the payment minting
    /// from the terminal.
    function test_beforePayRecordedContext_useTwapLockedPool(uint256 tokenCount) public {
        tokenCount = bound(tokenCount, 1, type(uint120).max);

        // Set the relevant context.
        beforePayRecordedContext.weight = tokenCount;
        beforePayRecordedContext.metadata = "";

        // Mock the pool being locked.
        vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 0, 0, 0, false));
        vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

        // Return values to catch:
        JBPayHookSpecification[] memory specificationsReturned;
        uint256 weightReturned;

        // Package data for ruleset call.
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        JBRuleset memory _ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 1e18,
            decayPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });

        // Mock call to controller grabbing the current ruleset
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (projectId)),
            abi.encode(_ruleset, _rulesMetadata)
        );

        // Test: call `beforePayRecordedWith`.
        vm.prank(terminalStore);
        (weightReturned, specificationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);

        // No hook specifications should be returned.
        assertEq(specificationsReturned.length, 0);

        // The weight should be returned unchanged.
        assertEq(weightReturned, tokenCount);
    }

    /// @notice Test `beforePayRecordedWith` with a TWAP but a non-deployed pool, which should lead to the payment
    /// minting
    /// from the terminal.
    function test_beforePayRecordedContext_useTwapNonDeployedPool(uint256 tokenCount) public {
        // The pool address as no bytecode (yet)
        vm.etch(address(pool), "");
        assert(address(pool).code.length == 0);

        tokenCount = bound(tokenCount, 1, type(uint120).max);

        // Set the relevant context.
        beforePayRecordedContext.weight = tokenCount;
        beforePayRecordedContext.metadata = "";

        // Return values to catch:
        JBPayHookSpecification[] memory specificationsReturned;
        uint256 weightReturned;

        // Package data for ruleset call.
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        JBRuleset memory _ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 1e18,
            decayPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });

        // Mock call to controller grabbing the current ruleset
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (projectId)),
            abi.encode(_ruleset, _rulesMetadata)
        );

        // Test: call `beforePayRecordedWith` - notice we don't mock the pool, as the address should remain empty
        vm.prank(terminalStore);
        (weightReturned, specificationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);

        // No hook specifications should be returned.
        assertEq(specificationsReturned.length, 0);

        // The weight should be returned unchanged.
        assertEq(weightReturned, tokenCount);
    }

    /// @notice Test `beforePayRecordedWith` with a TWAP but an invalid pool address, which should lead to the payment
    /// minting from the terminal.
    function test_beforePayRecordedContext_useTwapInvalidPool(uint256 tokenCount) public {
        // Invalid bytecode at the pool address - notice it shouldn't be possible, as we rely on create2 pool address
        vm.etch(address(pool), "12345678");
        vm.expectRevert();
        pool.slot0();

        tokenCount = bound(tokenCount, 1, type(uint120).max);

        // Set the relevant context.
        beforePayRecordedContext.weight = tokenCount;
        beforePayRecordedContext.metadata = "";

        // Return values to catch:
        JBPayHookSpecification[] memory specificationsReturned;
        uint256 weightReturned;

        // Package data for ruleset call.
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        JBRuleset memory _ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 1e18,
            decayPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });

        // Mock call to controller grabbing the current ruleset
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (projectId)),
            abi.encode(_ruleset, _rulesMetadata)
        );

        // Test: call `beforePayRecordedWith` - notice we don't mock the pool, as the address should remain empty
        vm.prank(terminalStore);
        (weightReturned, specificationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);

        // No hook specifications should be returned.
        assertEq(specificationsReturned.length, 0);

        // The weight should be returned unchanged.
        assertEq(weightReturned, tokenCount);
    }

    /// @notice Test the `beforePayRecordedWith` function when the amount to use for the swap is greater than the amount
    /// of tokens sent (should revert).
    function test_beforePayRecordedWith_RevertIfTryingToOverspend(uint256 swapOutCount, uint256 amountIn) public {
        // Use any number greater than the amount paid in.
        amountIn = bound(amountIn, beforePayRecordedContext.amount.value + 1, type(uint128).max);

        uint256 weight = 1 ether;

        uint256 tokenCount = mulDiv(amountIn, weight, 10 ** 18);

        // Avoid accidentally using the TWAP-based quote (triggered if `out == 0`)
        swapOutCount = bound(swapOutCount, tokenCount + 1, type(uint256).max);

        // Pass the quote as metadata
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(amountIn, swapOutCount);

        // Pass the hook ID.
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = JBMetadataResolver.getId("quote", address(hook));

        // Generate the metadata.
        bytes memory metadata = metadataHelper().createMetadata(ids, data);

        // Set the relevant context.
        beforePayRecordedContext.weight = weight;
        beforePayRecordedContext.metadata = metadata;

        // Return values to catch:
        JBPayHookSpecification[] memory specificationsReturned;
        uint256 weightReturned;

        // Expect revert on account of the pay amount being too low.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InsufficientPayAmount.selector,
                amountIn,
                beforePayRecordedContext.amount.value
            )
        );

        // Test: call `beforePayRecordedWith`.
        vm.prank(terminalStore);
        (weightReturned, specificationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);
    }

    /// @notice Test the `afterPayRecordedWith` function by swapping ETH/wETH for project tokens, ensuring that the
    /// right number of project tokens are burned from the hook and minted to the beneficiary.
    function test_afterPayRecordedWith_swapETH(uint256 tokenCount, uint256 twapQuote) public {
        // Account for MSB as sign when casting to int256 later.
        uint256 intMax = type(uint256).max / 2;

        // Bound to avoid overflow and ensure that the swap quote exceeds the mint quote.
        tokenCount = bound(tokenCount, 2, intMax - 1);
        twapQuote = bound(twapQuote, tokenCount, intMax);

        afterPayRecordedContext.weight = twapQuote;

        // The metadata coming from `beforePayRecordedWith(...)`
        afterPayRecordedContext.hookMetadata = abi.encode(
            address(projectToken) < address(weth),
            0,
            tokenCount // The token count is used.
        );

        // Mock and expect the swap call.
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, JBConstants.NATIVE_TOKEN)
                )
            ),
            abi.encode(-int256(twapQuote), -int256(twapQuote))
        );
        vm.expectCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, JBConstants.NATIVE_TOKEN)
                )
            )
        );

        // Mock and expect a `isTerminalOf` call to pass the authorization check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // Mock and expect the call to burn tokens from the hook.
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, "")),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, ""))
        );

        // Mock and expect the call to mint tokens to the beneficiary.
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            )
        );

        // Package data for ruleset call.
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        JBRuleset memory _ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 1e18,
            decayPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });

        // Mock call to controller grabbing the current ruleset
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (projectId)),
            abi.encode(_ruleset, _rulesMetadata)
        );

        // Expect the swap event.
        vm.expectEmit(true, true, true, true);
        emit Swap(
            afterPayRecordedContext.projectId,
            afterPayRecordedContext.amount.value,
            pool,
            twapQuote,
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));

        // Test: call `afterPayRecordedWith`.
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    // TODO: I don't fully understand how this one differs from the previous test (aside from the TWAP quote being used
    // in the hook metadata). Would love input (and a clearer comment).
    /// @notice Test the `afterPayRecordedWith` function by swapping ETH/wETH for project tokens, ensuring that the
    /// right number of project tokens are burned from the hook and minted to the beneficiary.
    function test_afterPayRecordedWith_swapETHWithExtraFunds(uint256 tokenCount, uint256 twapQuote) public {
        // Account for MSB as sign when casting to int256 later.
        uint256 intMax = type(uint256).max / 2;

        // Bound to avoid overflow and ensure that the swap quote exceeds the mint quote.
        tokenCount = bound(tokenCount, 2, intMax - 1);
        twapQuote = bound(twapQuote, tokenCount, intMax);

        afterPayRecordedContext.weight = twapQuote;

        // The metadata coming from `beforePayRecordedWith(...)`
        afterPayRecordedContext.hookMetadata = abi.encode(
            address(projectToken) < address(weth),
            0,
            twapQuote // The TWAP quote, which exceeds the token count, is used.
        );

        // Mock and expect the swap call.
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, JBConstants.NATIVE_TOKEN)
                )
            ),
            abi.encode(-int256(twapQuote), -int256(twapQuote))
        );
        vm.expectCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, JBConstants.NATIVE_TOKEN)
                )
            )
        );

        // Mock and expect a `isTerminalOf` call to pass the authorization check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // Mock and expect the call to burn tokens from the hook.
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, "")),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, ""))
        );

        // Mock and expect the call to mint tokens to the beneficiary.
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            )
        );

        // Package data for ruleset call.
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        JBRuleset memory _ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 1e18,
            decayPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });

        // Mock call to controller grabbing the current ruleset
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (projectId)),
            abi.encode(_ruleset, _rulesMetadata)
        );

        // Expect the swap event.
        vm.expectEmit(true, true, true, true);
        emit Swap(
            afterPayRecordedContext.projectId,
            afterPayRecordedContext.amount.value,
            pool,
            twapQuote,
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));

        // Test: call `afterPayRecordedWith`.
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /// @notice Test the `afterPayRecordedWith` function by swapping ERC-20 tokens for project tokens, ensuring that the
    /// right number of project tokens are burned from the hook and minted to the beneficiary.
    function test_afterPayRecordedWith_swapERC20(uint256 tokenCount, uint256 twapQuote, uint8 decimals) public {
        // Account for MSB as sign when casting to int256 later.
        uint256 intMax = type(uint256).max / 2;

        // Bound to avoid overflow and ensure that the swap quote exceeds the mint quote.
        tokenCount = bound(tokenCount, 2, intMax - 1);
        twapQuote = bound(twapQuote, tokenCount, intMax);

        decimals = uint8(bound(decimals, 1, 18));

        // Set up the context with the amount of ERC-20 tokens to swap and other information.
        afterPayRecordedContext.amount =
            JBTokenAmount({token: address(randomTerminalToken), value: 1 ether, decimals: decimals, currency: 1});
        afterPayRecordedContext.forwardedAmount =
            JBTokenAmount({token: address(randomTerminalToken), value: 1 ether, decimals: decimals, currency: 1});
        afterPayRecordedContext.projectId = randomId;
        afterPayRecordedContext.weight = twapQuote;

        // The metadata coming from `beforePayRecordedWith(...)`.
        afterPayRecordedContext.hookMetadata = abi.encode(address(projectToken) < address(weth), 0, tokenCount);

        // Mock and expect the swap call.
        vm.mockCall(
            address(randomPool),
            abi.encodeCall(
                randomPool.swap,
                (
                    address(hook),
                    address(randomTerminalToken) < address(otherRandomProjectToken),
                    int256(1 ether),
                    address(otherRandomProjectToken) < address(randomTerminalToken)
                        ? TickMath.MAX_SQRT_RATIO - 1
                        : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(randomId, randomTerminalToken)
                )
            ),
            abi.encode(-int256(twapQuote), -int256(twapQuote))
        );
        vm.expectCall(
            address(randomPool),
            abi.encodeCall(
                randomPool.swap,
                (
                    address(hook),
                    address(randomTerminalToken) < address(otherRandomProjectToken),
                    int256(1 ether),
                    address(otherRandomProjectToken) < address(randomTerminalToken)
                        ? TickMath.MAX_SQRT_RATIO - 1
                        : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(randomId, randomTerminalToken)
                )
            )
        );

        // Mock and expect a `isTerminalOf` call to pass the authorization check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // Mock and expect the transferFrom from the terminal to the hook
        vm.mockCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.transferFrom, (address(multiTerminal), address(hook), 1 ether)),
            abi.encode(true)
        );
        vm.expectCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.transferFrom, (address(multiTerminal), address(hook), 1 ether))
        );

        // Mock and expect the call to burn tokens from the hook.
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, "")),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, ""))
        );

        // Mock and expect the call to mint tokens to the beneficiary.
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            )
        );

        // Mock and expect the call to check the balance of the hook. There should be no tokens left over.
        vm.mockCall(
            address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(hook))), abi.encode(0)
        );
        vm.expectCall(address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(hook))));

        // Package data for ruleset call.
        JBRulesetMetadata memory _rulesMetadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: true,
            allowSetTerminals: true,
            ownerMustSendPayouts: false,
            allowSetController: true,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        uint256 packed = _rulesMetadata.packRulesetMetadata();

        JBRuleset memory _ruleset = JBRuleset({
            cycleNumber: 1,
            id: 1,
            basedOnId: 0,
            start: uint48(block.timestamp),
            duration: 10 days,
            weight: 1e18,
            decayPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: packed
        });

        // Mock call to controller grabbing the current ruleset
        mockExpect(
            address(controller),
            abi.encodeCall(IJBController.currentRulesetOf, (randomId)),
            abi.encode(_ruleset, _rulesMetadata)
        );

        // Mock call to prices that normalizes the mint ratios per the ERC20 paid and the base currency.
        mockExpect(
            address(prices),
            abi.encodeCall(prices.pricePerUnitOf, (randomId, 1, uint32(uint160(JBConstants.NATIVE_TOKEN)), decimals)),
            abi.encode(1e18)
        );

        // Expect the swap event.
        vm.expectEmit(true, true, true, true);
        emit Swap(
            afterPayRecordedContext.projectId,
            afterPayRecordedContext.amount.value,
            randomPool,
            twapQuote,
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));

        // Test: call `afterPayRecordedWith`.
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /// @notice Test the `afterPayRecordedWith` function when the swap operation reverts or returns 0, despite a
    /// non-zero quote being provided.
    function test_afterPayRecordedWith_swapRevertWithQuote(uint256 tokenCount) public {
        // Bound the token count to avoid overflow.
        tokenCount = bound(tokenCount, 1, type(uint256).max - 1);

        afterPayRecordedContext.weight = 1 ether; // weight - unused

        // The metadata coming from `beforePayRecordedWith(...)`.
        afterPayRecordedContext.hookMetadata = abi.encode(address(projectToken) < address(weth), 0, tokenCount);

        // Mock the swap call reverting.
        vm.mockCallRevert(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, weth)
                )
            ),
            abi.encode("no swap")
        );

        // Mock and expect a `isTerminalOf` call to pass the authorization check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // Expect a revert on account of the swap failing.
        vm.expectRevert(
            abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector, 0, tokenCount)
        );

        vm.prank(address(multiTerminal));

        // Test: call `afterPayRecordedWith`.
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /// @notice ~DEPRECATED~ Test `afterPayRecordedWith`: if the swap reverts while using the TWAP-based quote, the hook
    /// should then
    /// mint tokens based on the hook's balance and the weight. In this test, an ERC-20 token is used as the terminal
    /// token.
    function test_afterPayRecordedWith_ERC20SwapRevertWithoutQuote(
        uint256 tokenCount,
        uint256 weight,
        uint8 decimals,
        uint256 extraMint
    )
        public
    {
        // deprecated as spec has been modified
        vm.skip(true);

        // The current weight.
        weight = bound(weight, 1, 1 ether);

        // The amount of terminal tokens in this hook. Bounded to avoid overflow when multiplied by the weight.
        tokenCount = bound(tokenCount, 2, type(uint128).max);

        // An extra amount of project tokens to mint, based on funds which stayed in the terminal.
        extraMint = bound(extraMint, 2, type(uint128).max);

        // The number of decimals that the terminal token uses.
        decimals = uint8(bound(decimals, 1, 18));

        // Set up the context with the amount of ERC-20 tokens to use and other information.
        afterPayRecordedContext.amount =
            JBTokenAmount({token: address(randomTerminalToken), value: tokenCount, decimals: decimals, currency: 1});
        afterPayRecordedContext.forwardedAmount =
            JBTokenAmount({token: address(randomTerminalToken), value: tokenCount, decimals: decimals, currency: 1});
        afterPayRecordedContext.projectId = randomId;
        afterPayRecordedContext.weight = weight;

        // The metadata coming from `beforePayRecordedWith(...)`.
        afterPayRecordedContext.hookMetadata = abi.encode(
            address(otherRandomProjectToken) < address(randomTerminalToken),
            extraMint, // extra amount to mint with
            tokenCount
        );

        // Mock and expect the call to transferFrom to pull token from the terminal to the hook
        vm.mockCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.transferFrom, (address(multiTerminal), address(hook), tokenCount)),
            abi.encode(true)
        );
        vm.expectCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.transferFrom, (address(multiTerminal), address(hook), tokenCount))
        );

        // Mock the swap call reverting.
        vm.mockCallRevert(
            address(randomPool),
            abi.encodeCall(
                randomPool.swap,
                (
                    address(hook),
                    address(randomTerminalToken) < address(otherRandomProjectToken),
                    int256(tokenCount),
                    address(otherRandomProjectToken) < address(randomTerminalToken)
                        ? TickMath.MAX_SQRT_RATIO - 1
                        : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(randomId, randomTerminalToken)
                )
            ),
            abi.encode("no swap")
        );

        // Mock and expect a `isTerminalOf` call to pass the authorization check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // Mock and expect the call to check the terminal token balance of the hook. These will be used to mint project
        // tokens.
        vm.mockCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.balanceOf, (address(hook))),
            abi.encode(tokenCount)
        );
        vm.expectCall(address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(hook))));

        // Mock and expect the call to `mintTokensOf`. This uses the weight and not the (potentially faulty) specified
        // or TWAP-based quote.
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (
                    afterPayRecordedContext.projectId,
                    mulDiv(tokenCount, weight, 10 ** decimals) + mulDiv(extraMint, weight, 10 ** decimals),
                    afterPayRecordedContext.beneficiary,
                    "",
                    true
                )
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (
                    afterPayRecordedContext.projectId,
                    mulDiv(tokenCount, weight, 10 ** decimals) + mulDiv(extraMint, weight, 10 ** decimals),
                    afterPayRecordedContext.beneficiary,
                    "",
                    true
                )
            )
        );

        // Mock and expect the call to `approve` the terminal token for the terminal.
        // This will be used with the `addToBalanceOf` call below.
        vm.mockCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.approve, (address(multiTerminal), tokenCount)),
            abi.encode(true)
        );
        vm.expectCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.approve, (address(multiTerminal), tokenCount))
        );

        // Mock and expect the call to `addToBalanceOf` to add the terminal token back to the terminal.
        vm.mockCall(
            address(multiTerminal),
            abi.encodeCall(
                IJBTerminal(address(multiTerminal)).addToBalanceOf,
                (afterPayRecordedContext.projectId, address(randomTerminalToken), tokenCount, false, "", "")
            ),
            ""
        );
        vm.expectCall(
            address(multiTerminal),
            abi.encodeCall(
                IJBTerminal(address(multiTerminal)).addToBalanceOf,
                (afterPayRecordedContext.projectId, address(randomTerminalToken), tokenCount, false, "", "")
            )
        );

        // Expect the mint event (only for the non-extra mint).
        vm.expectEmit(true, true, true, true);
        emit Mint(
            afterPayRecordedContext.projectId,
            tokenCount,
            mulDiv(tokenCount, weight, 10 ** decimals),
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));

        // Test: call `afterPayRecordedWith`.
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /// @notice ~DEPRECATED~ Test `afterPayRecordedWith`: if the swap reverts while using the TWAP-based quote, the hook
    /// should then
    /// mint tokens based on the hook's balance and the weight. In this test, ETH is used as the terminal token.
    function test_afterPayRecordedWith_ETHSwapRevertWithoutQuote(
        uint256 tokenCount,
        uint256 weight,
        uint8 decimals,
        uint256 extraMint
    )
        public
    {
        // deprecated as spec has been modified
        vm.skip(true);

        // The current weight.
        weight = bound(weight, 1, 1 ether);

        // The amount of terminal tokens in this hook. Bounded to avoid overflow when multiplied by the weight.
        tokenCount = bound(tokenCount, 2, type(uint128).max);

        // An extra amount of project tokens to mint, based on funds which stayed in the terminal.
        extraMint = bound(extraMint, 2, type(uint128).max);

        // The number of decimals that the terminal token uses.
        decimals = uint8(bound(decimals, 1, 18));

        // Set up the context with the amount of ETH to use and other information.
        afterPayRecordedContext.amount =
            JBTokenAmount({token: JBConstants.NATIVE_TOKEN, value: tokenCount, decimals: decimals, currency: 1});

        afterPayRecordedContext.forwardedAmount =
            JBTokenAmount({token: JBConstants.NATIVE_TOKEN, value: tokenCount, decimals: decimals, currency: 1});

        afterPayRecordedContext.weight = weight;

        // The metadata coming from `beforePayRecordedWith(...)`.
        afterPayRecordedContext.hookMetadata = abi.encode(address(projectToken) < address(weth), extraMint, tokenCount);

        // Mock the swap call reverting.
        vm.mockCallRevert(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(tokenCount),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, JBConstants.NATIVE_TOKEN)
                )
            ),
            abi.encode("no swap")
        );

        // Mock and expect a `isTerminalOf` call to pass the authorization check.
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // Mock the balance check.
        vm.deal(address(hook), tokenCount);

        // Mock and expect the call to `mintTokensOf`. This uses the weight and not the (potentially faulty) specified
        // or TWAP-based quote.
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (
                    afterPayRecordedContext.projectId,
                    mulDiv(tokenCount, weight, 10 ** decimals) + mulDiv(extraMint, weight, 10 ** decimals),
                    afterPayRecordedContext.beneficiary,
                    "",
                    true
                )
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (
                    afterPayRecordedContext.projectId,
                    mulDiv(tokenCount, weight, 10 ** decimals) + mulDiv(extraMint, weight, 10 ** decimals),
                    afterPayRecordedContext.beneficiary,
                    "",
                    true
                )
            )
        );

        // Mock and expect the call to `addToBalanceOf` to add the terminal token (ETH) back to the terminal.
        vm.mockCall(
            address(multiTerminal),
            tokenCount,
            abi.encodeCall(
                IJBTerminal(address(multiTerminal)).addToBalanceOf,
                (afterPayRecordedContext.projectId, JBConstants.NATIVE_TOKEN, tokenCount, false, "", "")
            ),
            ""
        );
        vm.expectCall(
            address(multiTerminal),
            tokenCount,
            abi.encodeCall(
                IJBTerminal(address(multiTerminal)).addToBalanceOf,
                (afterPayRecordedContext.projectId, JBConstants.NATIVE_TOKEN, tokenCount, false, "", "")
            )
        );

        // Expect the mint event.
        vm.expectEmit(true, true, true, true);
        emit Mint(
            afterPayRecordedContext.projectId,
            tokenCount,
            mulDiv(tokenCount, weight, 10 ** decimals),
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));

        // Test: call `afterPayRecordedWith`.
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /// @notice Test `afterPayRecordedWith` to ensure it reverts when called by an unauthorized address.
    function test_afterPayRecordedWith_revertIfWrongCaller(address notTerminal) public {
        vm.assume(notTerminal != address(multiTerminal));

        // Mock and expact the `isTerminalOf` call to fail the authorization check (since directory has no bytecode).
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(notTerminal)))
            ),
            abi.encode(false)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(notTerminal)))
            )
        );

        // Expect revert on account of the caller not being the terminal.
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_Unauthorized.selector, notTerminal));

        vm.prank(notTerminal);

        // Test: call `afterPayRecordedWith`.
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /// @notice Test `uniswapV3SwapCallback`.
    /// @dev Tests 2 branches: project token is 0 or 1 in the pool's `slot0`.
    function test_uniswapV3SwapCallback() public {
        int256 delta0 = -2 ether;
        int256 delta1 = 1 ether;

        IWETH9 terminalToken = weth;

        /**
         * First branch: the terminal token is ETH, and the project token is a random `IERC20`.
         */
        hook = new ForTest_JBBuybackHook({
            weth: terminalToken,
            factory: uniswapFactory,
            directory: directory,
            controller: controller,
            prices: prices
        });

        // Initialize the pool with wETH (if you pass in the `NATIVE_TOKEN` address, the pool is initialized with wETH).
        hook.ForTest_initPool(pool, projectId, twapWindow, twapTolerance, address(projectToken), address(terminalToken));

        // If the terminal token is `token0`, then the change in the terminal token amount is `delta0` (the negative
        // value).
        (delta0, delta1) = address(projectToken) < address(terminalToken) ? (delta0, delta1) : (delta1, delta0);

        // Mock and expect `terminalToken` calls.
        // This should transfer from the hook to the pool (positive delta in the callback).
        vm.mockCall(address(terminalToken), abi.encodeCall(terminalToken.deposit, ()), "");
        vm.expectCall(address(terminalToken), abi.encodeCall(terminalToken.deposit, ()));

        vm.mockCall(
            address(terminalToken),
            abi.encodeCall(
                terminalToken.transfer,
                (address(pool), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(terminalToken),
            abi.encodeCall(
                terminalToken.transfer,
                (address(pool), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0))
            )
        );

        vm.deal(address(hook), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0));
        vm.prank(address(pool));

        // Test: call `uniswapCallback`.
        hook.uniswapV3SwapCallback(delta0, delta1, abi.encode(projectId, JBConstants.NATIVE_TOKEN));

        /**
         * Second branch: the terminal token is a random `IERC20`, and the project token is wETH (as another random
         * `IERC20`).
         */

        // Invert both contract addresses (to swap `token0` and `token1`).
        (projectToken, terminalToken) = (JBERC20(address(terminalToken)), IWETH9(address(projectToken)));

        // If the project token is `token0`, then the received value is `delta0` (the negative value).
        (delta0, delta1) = address(projectToken) < address(terminalToken) ? (delta0, delta1) : (delta1, delta0);

        hook = new ForTest_JBBuybackHook({
            weth: terminalToken,
            factory: uniswapFactory,
            directory: directory,
            controller: controller,
            prices: prices
        });

        hook.ForTest_initPool(pool, projectId, twapWindow, twapTolerance, address(projectToken), address(terminalToken));

        // Mock and expect `terminalToken` calls.
        vm.mockCall(
            address(terminalToken),
            abi.encodeCall(
                terminalToken.transfer,
                (address(pool), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(terminalToken),
            abi.encodeCall(
                terminalToken.transfer,
                (address(pool), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0))
            )
        );

        vm.deal(address(hook), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0));
        vm.prank(address(pool));

        // Test: call `uniswapCallback`.
        hook.uniswapV3SwapCallback(delta0, delta1, abi.encode(projectId, address(terminalToken)));
    }

    /// @notice Test `uniswapV3SwapCallback` to ensure it reverts when called by an unauthorized address.
    function test_uniswapV3SwapCallback_revertIfWrongCaller() public {
        int256 delta0 = -1 ether;
        int256 delta1 = 1 ether;

        // Expect revert on account of the caller not being the pool.
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_CallerNotPool.selector, address(this)));
        hook.uniswapV3SwapCallback(delta0, delta1, abi.encode(projectId, weth, address(projectToken) < address(weth)));
    }

    /// @notice ~DEPRECATED~ Test adding a new pool, whether it has been deployed or not.
    function test_setPoolFor(
        uint256 twapWindowOverride,
        uint256 twapToleranceOverride,
        address terminalToken,
        address projectTokenOverride,
        uint24 feeOverride
    )
        public
    {
        // Deprecated due to change in spec
        vm.skip(true);

        vm.assume(terminalToken != address(0) && projectTokenOverride != address(0) && feeOverride != 0);
        vm.assume(terminalToken != projectTokenOverride);

        // Get references to the hook's bounds for the TWAP window and slippage tolerance.
        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();

        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        // Keep the TWAP delta and TWAP window within the hook's bounds.
        twapToleranceOverride = bound(twapToleranceOverride, MIN_TWAP_SLIPPAGE_TOLERANCE, MAX_TWAP_SLIPPAGE_TOLERANCE);
        twapWindowOverride = bound(twapWindowOverride, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);

        // Compute the pool address. This is deterministic.
        address _pool = PoolAddress.computeAddress(
            hook.UNISWAP_V3_FACTORY(), PoolAddress.getPoolKey(terminalToken, projectTokenOverride, feeOverride)
        );

        // Mock the call to get the project's token.
        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(projectTokenOverride));

        // Check: correct events emitted?
        vm.expectEmit(true, true, true, true);
        emit TwapWindowChanged(projectId, 0, twapWindowOverride, owner);

        vm.expectEmit(true, true, true, true);
        emit TwapSlippageToleranceChanged(projectId, 0, twapToleranceOverride, owner);

        vm.expectEmit(true, true, true, true);
        emit PoolAdded(
            projectId, terminalToken == JBConstants.NATIVE_TOKEN ? address(weth) : terminalToken, address(_pool), owner
        );

        // Test: call `setPoolFor`.
        vm.prank(owner);
        address newPool = address(
            hook.setPoolFor(projectId, feeOverride, uint32(twapWindowOverride), twapToleranceOverride, terminalToken)
        );

        // Check: were the correct params stored in the hook?
        assertEq(hook.twapWindowOf(projectId), twapWindowOverride);
        assertEq(hook.twapSlippageToleranceOf(projectId), twapToleranceOverride);
        assertEq(
            address(hook.poolOf(projectId, terminalToken == JBConstants.NATIVE_TOKEN ? address(weth) : terminalToken)),
            _pool
        );
        assertEq(newPool, _pool);
    }

    /// @notice Test whether calling `setPoolFor` with the same parameters as an existing pool reverts.
    /// @dev This is to avoid bypassing the TWAP delta and TWAP window authorization.
    /// @dev A new fee tier results in a new pool.
    function test_setPoolFor_revertIfPoolAlreadyExists(
        uint256 _twapWindow,
        uint256 _twapTolerance,
        address _projectToken,
        uint24 _fee
    )
        public
    {
        address _terminalToken = address(weth);

        vm.assume(_projectToken != address(0) && _fee != 0);
        vm.assume(_terminalToken != _projectToken);

        // Get references to the hook's bounds for the TWAP window and slippage tolerance.
        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();

        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        // Keep the TWAP delta and TWAP window within the hook's bounds.
        _twapTolerance = bound(_twapTolerance, MIN_TWAP_SLIPPAGE_TOLERANCE, MAX_TWAP_SLIPPAGE_TOLERANCE);
        _twapWindow = bound(_twapWindow, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);

        // Mock the call to get the project's token.
        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, projectId), abi.encode(_projectToken));

        // Test: call `setPoolFor`.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JBBuybackHook_PoolAlreadySet.selector, pool));
        hook.setPoolFor(projectId, _fee, uint32(_twapWindow), _twapTolerance, _terminalToken);
    }

    /// @notice `setPoolFor` should revert if the caller is not authorized to set the pool.
    function test_setPoolFor_revertIfWrongCaller() public {
        // Mock and expect calls to check the permissions of the caller.
        vm.mockCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (dude, owner, projectId, JBPermissionIds.SET_BUYBACK_POOL, true, true)
            ),
            abi.encode(false)
        );
        vm.expectCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (dude, owner, projectId, JBPermissionIds.SET_BUYBACK_POOL, true, true)
            )
        );

        // Expect revert on account of the caller not being authorized.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                dude,
                projectId,
                JBPermissionIds.SET_BUYBACK_POOL
            )
        );

        // Test: call `setPoolFor` from an unauthorized address (`dude`).
        vm.prank(dude);
        hook.setPoolFor(projectId, 100, uint32(10), 10, address(0));
    }

    /// @notice Ensure that only TWAP slippage tolerances and TWAP windows between the hook's minimum/maximum bounds are
    /// allowed.
    function test_setPoolFor_revertIfWrongParams(address _terminalToken, address _projectToken, uint24 _fee) public {
        vm.assume(_terminalToken != address(0) && _projectToken != address(0) && _fee != 0);
        vm.assume(_terminalToken != _projectToken);

        // Get references to the hook's bounds for the TWAP window and slippage tolerance.
        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();

        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        // Mock the call to get the project's token.
        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(_projectToken));

        // Check: is the TWAP window too small?
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector,
                uint32(MIN_TWAP_WINDOW - 1),
                MIN_TWAP_WINDOW,
                MAX_TWAP_WINDOW
            )
        );
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(MIN_TWAP_WINDOW - 1), MIN_TWAP_SLIPPAGE_TOLERANCE + 1, _terminalToken);

        // Check: is the TWAP window too large?
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector,
                uint32(MAX_TWAP_WINDOW + 1),
                MIN_TWAP_WINDOW,
                MAX_TWAP_WINDOW
            )
        );
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(MAX_TWAP_WINDOW + 1), MIN_TWAP_SLIPPAGE_TOLERANCE + 1, _terminalToken);

        // Check: is the TWAP slippage tolerance too small?
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapSlippageTolerance.selector,
                MIN_TWAP_SLIPPAGE_TOLERANCE - 1,
                MIN_TWAP_SLIPPAGE_TOLERANCE,
                MAX_TWAP_SLIPPAGE_TOLERANCE
            )
        );
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(MIN_TWAP_WINDOW + 1), MIN_TWAP_SLIPPAGE_TOLERANCE - 1, _terminalToken);

        // Check: is the TWAP slippage tolerance too large?
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapSlippageTolerance.selector,
                MAX_TWAP_SLIPPAGE_TOLERANCE + 1,
                MIN_TWAP_SLIPPAGE_TOLERANCE,
                MAX_TWAP_SLIPPAGE_TOLERANCE
            )
        );
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(MIN_TWAP_WINDOW + 1), MAX_TWAP_SLIPPAGE_TOLERANCE + 1, _terminalToken);
    }

    /// @notice Test whether `setPoolFor` reverts if the project hasn't launched a token yet.
    /// @dev This should revert because the pool's address cannot be calculated.
    function test_setPoolFor_revertIfNoProjectToken(
        uint256 _twapWindow,
        uint256 _twapTolerance,
        address _terminalToken,
        address _projectToken,
        uint24 _fee
    )
        public
    {
        vm.assume(_terminalToken != address(0) && _projectToken != address(0) && _fee != 0);
        vm.assume(_terminalToken != _projectToken);

        // Get references to the hook's bounds for the TWAP window and slippage tolerance.
        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();

        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        // Keep the TWAP delta and TWAP window within the hook's bounds.
        _twapTolerance = bound(_twapTolerance, MIN_TWAP_SLIPPAGE_TOLERANCE, MAX_TWAP_SLIPPAGE_TOLERANCE);
        _twapWindow = bound(_twapWindow, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);

        // Mock the call to get the project's token.
        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(address(0)));

        // Expect revert on account of the project not having a token.
        vm.expectRevert(JBBuybackHook.JBBuybackHook_ZeroProjectToken.selector);
        vm.prank(owner);

        // Test: call `setPoolFor`.
        hook.setPoolFor(projectId, _fee, uint32(_twapWindow), _twapTolerance, _terminalToken);
    }

    /// @notice Test whether `setTwapWindowOf` works correctly.
    function test_setTwapWindowOf(uint256 newValue) public {
        // Get references to the hook's bounds for the TWAP window.
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();
        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();

        // Keep the TWAP window within the hook's bounds.
        newValue = bound(newValue, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);

        // Check: was the correct event emitted?
        vm.expectEmit(true, true, true, true);
        emit TwapWindowChanged(projectId, hook.twapWindowOf(projectId), newValue, owner);

        // Test: set the new TWAP window.
        vm.prank(owner);
        hook.setTwapWindowOf(projectId, uint32(newValue));

        // Check: was the TWAP window set correctly?
        assertEq(hook.twapWindowOf(projectId), newValue);
    }

    /// @notice Test whether `setTwapWindowOf` reverts if the caller is not authorized to set the TWAP window.
    function test_setTwapWindowOf_revertIfWrongCaller(address notOwner) public {
        // Assume that the caller is not the owner.
        vm.assume(owner != notOwner);

        // Mock and expect calls to check the permissions of the caller.
        vm.mockCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (notOwner, owner, projectId, JBPermissionIds.SET_BUYBACK_TWAP, true, true)
            ),
            abi.encode(false)
        );
        vm.expectCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (notOwner, owner, projectId, JBPermissionIds.SET_BUYBACK_TWAP, true, true)
            )
        );

        // Expect revert on account of the caller not being authorized to set the TWAP window.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                notOwner,
                projectId,
                JBPermissionIds.SET_BUYBACK_TWAP
            )
        );

        // Test: call `setTwapWindowOf` from an unauthorized address (`notOwner`).
        vm.startPrank(notOwner);
        hook.setTwapWindowOf(projectId, 999);
    }

    /// @notice Test whether `setTwapWindowOf` reverts if the new TWAP window is too big or too small.
    function test_setTwapWindowOf_revertIfNewValueTooBigOrTooLow(uint256 newValueSeed) public {
        // Get references to the hook's bounds for the TWAP window.
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();
        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();

        // Make sure the new value is too big.
        uint256 newValue = bound(newValueSeed, MAX_TWAP_WINDOW + 1, type(uint32).max);

        // Expect revert on account of the new TWAP window being too big.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector, newValue, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW
            )
        );

        // Test: try to set the TWAP window to the too-big value.
        vm.prank(owner);
        hook.setTwapWindowOf(projectId, uint32(newValue));

        // Make sure the new value is too small.
        newValue = bound(newValueSeed, 0, MIN_TWAP_WINDOW - 1);

        // Expect revert on account of the new TWAP window being too small.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapWindow.selector, newValue, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW
            )
        );

        // Test: try to set the TWAP window to the too-small value.
        vm.prank(owner);
        hook.setTwapWindowOf(projectId, uint32(newValue));
    }

    /// @notice Test setting the TWAP slippage tolerance.
    function test_setTwapSlippageToleranceOf(uint256 newTolerance) public {
        // Get references to the hook's bounds for the TWAP slippage tolerance.
        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        // Keep the TWAP slippage tolerance within the hook's bounds.
        newTolerance = bound(newTolerance, MIN_TWAP_SLIPPAGE_TOLERANCE, MAX_TWAP_SLIPPAGE_TOLERANCE);

        // Check: was the correct event emitted?
        vm.expectEmit(true, true, true, true);
        emit TwapSlippageToleranceChanged(projectId, hook.twapSlippageToleranceOf(projectId), newTolerance, owner);

        // Test: set the new TWAP slippage tolerance.
        vm.prank(owner);
        hook.setTwapSlippageToleranceOf(projectId, newTolerance);

        // Check: was the TWAP slippage tolerance set correctly?
        assertEq(hook.twapSlippageToleranceOf(projectId), newTolerance);
    }

    /// @notice Test whether `setTwapSlippageToleranceOf` reverts if the caller is not authorized to set the TWAP
    /// slippage tolerance.
    function test_setTwapSlippageToleranceOf_revertWrongCaller(address notOwner) public {
        // Assume that the caller is not the owner.
        vm.assume(owner != notOwner);

        // Mock and expect calls to check the permissions of the caller.
        vm.mockCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (notOwner, owner, projectId, JBPermissionIds.SET_BUYBACK_TWAP, true, true)
            ),
            abi.encode(false)
        );
        vm.expectCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (notOwner, owner, projectId, JBPermissionIds.SET_BUYBACK_TWAP, true, true)
            )
        );

        // Expect revert on account of the caller not being authorized to set the TWAP slippage tolerance.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                notOwner,
                projectId,
                JBPermissionIds.SET_BUYBACK_TWAP
            )
        );

        // Test: call `setTwapSlippageToleranceOf` from an unauthorized address (`notOwner`).
        vm.prank(notOwner);
        hook.setTwapSlippageToleranceOf(projectId, 1);
    }

    /// @notice Test whether `setTwapSlippageToleranceOf` reverts if the new TWAP slippage tolerance is too big or too
    /// small.
    function test_setTwapSlippageToleranceOf_revertIfInvalidNewValue(uint256 newToleranceSeed) public {
        // Get references to the hook's bounds for the TWAP slippage tolerance.
        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        // Make sure the new value is too small.
        uint256 newTolerance = bound(newToleranceSeed, 0, MIN_TWAP_SLIPPAGE_TOLERANCE - 1);

        // Expect revert on account of the new TWAP slippage tolerance being too small.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapSlippageTolerance.selector,
                newTolerance,
                MIN_TWAP_SLIPPAGE_TOLERANCE,
                MAX_TWAP_SLIPPAGE_TOLERANCE
            )
        );

        // Test: try to set the TWAP slippage tolerance to the too-small value.
        vm.prank(owner);
        hook.setTwapSlippageToleranceOf(projectId, newTolerance);

        // Make sure the new value is too big.
        newTolerance = bound(newToleranceSeed, MAX_TWAP_SLIPPAGE_TOLERANCE + 1, type(uint256).max);

        // Expect revert on account of the new TWAP slippage tolerance being too big.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBBuybackHook.JBBuybackHook_InvalidTwapSlippageTolerance.selector,
                newTolerance,
                MIN_TWAP_SLIPPAGE_TOLERANCE,
                MAX_TWAP_SLIPPAGE_TOLERANCE
            )
        );

        // Test: try to set the TWAP slippage tolerance to the too-big value.
        vm.prank(owner);
        hook.setTwapSlippageToleranceOf(projectId, newTolerance);
    }

    /// @notice Test whether redemption functionality is left unchanged by the hook.
    function test_beforeRedeemRecordedWith_unchangedRedeem(
        uint256 redemptionRateIn,
        uint256 redeemCountIn,
        uint256 totalSupplyIn
    )
        public
    {
        // Set up basic redemption context.
        JBBeforeRedeemRecordedContext memory beforeRedeemRecordedContext = JBBeforeRedeemRecordedContext({
            terminal: makeAddr("terminal"),
            holder: makeAddr("hooldooor"),
            projectId: 69,
            rulesetId: 420,
            redeemCount: redeemCountIn,
            totalSupply: totalSupplyIn,
            surplus: JBTokenAmount(address(1), 6, 2, 3),
            useTotalSurplus: true,
            redemptionRate: redemptionRateIn,
            metadata: ""
        });

        (
            uint256 redemptionRateOut,
            uint256 redeemCountOut,
            uint256 totalSupplyOut,
            JBRedeemHookSpecification[] memory redeemSpecifications
        ) = hook.beforeRedeemRecordedWith(beforeRedeemRecordedContext);

        // Make sure the redemption amount is unchanged and that no specifications were returned.
        assertEq(redemptionRateOut, redemptionRateIn);
        assertEq(redeemCountOut, redeemCountIn);
        assertEq(totalSupplyOut, totalSupplyIn);
        assertEq(redeemSpecifications.length, 0);
    }

    function test_supportsInterface(bytes4 random) public view {
        vm.assume(
            random != type(IJBBuybackHook).interfaceId && random != type(IJBRulesetDataHook).interfaceId
                && random != type(IJBPayHook).interfaceId && random != type(IERC165).interfaceId
        );

        assertTrue(ERC165Checker.supportsInterface(address(hook), type(IJBRulesetDataHook).interfaceId));
        assertTrue(ERC165Checker.supportsInterface(address(hook), type(IJBPayHook).interfaceId));
        assertTrue(ERC165Checker.supportsInterface(address(hook), type(IJBBuybackHook).interfaceId));
        assertTrue(ERC165Checker.supportsERC165(address(hook)));

        assertFalse(ERC165Checker.supportsInterface(address(hook), random));
    }
}

/// @notice A mock version of `JBBuybackHook` which exposes internal functions for testing purposes.
contract ForTest_JBBuybackHook is JBBuybackHook {
    constructor(
        IWETH9 weth,
        address factory,
        IJBDirectory directory,
        IJBController controller,
        IJBPrices prices
    )
        JBBuybackHook(directory, controller, prices, weth, factory)
    {}

    function ForTest_getQuote(
        uint256 projectId,
        address projectToken,
        uint256 amountIn,
        address terminalToken
    )
        external
        view
        returns (uint256 amountOut)
    {
        return _getQuote(projectId, projectToken, amountIn, terminalToken);
    }

    function ForTest_initPool(
        IUniswapV3Pool pool,
        uint256 projectId,
        uint32 secondsAgo,
        uint256 twapDelta,
        address projectToken,
        address terminalToken
    )
        external
    {
        _twapParamsOf[projectId] = twapDelta << 128 | secondsAgo;
        projectTokenOf[projectId] = projectToken;
        poolOf[projectId][terminalToken] = pool;
    }
}
