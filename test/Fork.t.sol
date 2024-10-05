// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "src/interfaces/external/IWETH9.sol";
import /* {*} from */ "@bananapus/core/test/helpers/TestBaseWorkflow.sol";

import {MetadataResolverHelper} from "@bananapus/core/test/helpers/MetadataResolverHelper.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import "@exhausted-pigeon/uniswap-v3-forge-quoter/src/UniswapV3ForgeQuoter.sol";

import "src/JBBuybackHook.sol";

import {mulDiv, mulDiv18} from "@prb/math/src/Common.sol";

/**
 * @notice Buyback fork integration tests, using $jbx v3
 */
contract TestJBBuybackHook_Fork is TestBaseWorkflow, JBTest, UniswapV3ForgeQuoter {
    using JBRulesetMetadataResolver for JBRuleset;

    event Swap(uint256 indexed projectId, uint256 amountIn, IUniswapV3Pool pool, uint256 amountOut, address caller);
    event Mint(
        address indexed holder,
        uint256 indexed projectId,
        uint256 amount,
        bool tokensWereClaimed,
        bool preferClaimedTokens,
        address caller
    );

    // Constants
    uint256 constant TWAP_SLIPPAGE_DENOMINATOR = 10_000;

    IUniswapV3Factory constant factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IJBToken jbx;
    IWETH9 constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // 1 - 1*10**18

    uint256 constant price = 69_420 ether;
    uint32 constant cardinality = 100_000;
    uint256 constant twapDelta = 500;
    uint24 constant fee = 10_000;

    uint256 constant amountPaid = 1 ether;

    // Contracts needed
    IUniswapV3Pool pool;

    // Structure needed
    JBRulesetMetadata _metadata;
    JBFundAccessLimitGroup[] fundAccessLimitGroups;
    IJBTerminal[] terminals;
    JBSplitGroup[] groupedSplits;

    // Target contract
    JBBuybackHook delegate;

    // sqrtPriceX96 = sqrt(1*10**18 << 192 / 69420*10**18) = 300702666377442711115399168 (?)
    uint160 sqrtPriceX96 = 300_702_666_377_442_711_115_399_168;

    uint256 amountOutQuoted;

    function initMetadata() public {
        _metadata = JBRulesetMetadata({
            reservedPercent: JBConstants.MAX_RESERVED_PERCENT / 2, //50%
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE, //50%
            baseCurrency: uint32(uint160(address(JBConstants.NATIVE_TOKEN))),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: true,
            allowAddPriceFeed: true,
            allowCrosschainSuckerExtension: true,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(delegate),
            metadata: 0
        });
    }

    function launchAndConfigureL1Project() public {
        // Setup: terminal / project
        // Package up the limits for the given terminal.
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            // Specify a payout limit.
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](0);

            // Specify a surplus allowance.
            JBCurrencyAmount[] memory _surplusAllowances = new JBCurrencyAmount[](1);
            _surplusAllowances[0] =
                JBCurrencyAmount({amount: 5 * 10 ** 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(jbMultiTerminal()),
                token: JBConstants.NATIVE_TOKEN,
                payoutLimits: _payoutLimits,
                surplusAllowances: _surplusAllowances
            });
        }

        {
            // Package up the ruleset configuration.
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].duration = 0;
            _rulesetConfigurations[0].weight = 1000 * 10 ** 18;
            _rulesetConfigurations[0].decayPercent = 0;
            _rulesetConfigurations[0].approvalHook = IJBRulesetApprovalHook(address(0));
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContext[] memory _tokensToAccept = new JBAccountingContext[](1);

            _tokensToAccept[0] = JBAccountingContext({
                token: JBConstants.NATIVE_TOKEN,
                decimals: 18,
                currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
            });

            _terminalConfigurations[0] =
                JBTerminalConfig({terminal: jbMultiTerminal(), accountingContextsToAccept: _tokensToAccept});

            // Create a first project to collect fees.
            jbController().launchProjectFor({
                owner: multisig(),
                projectUri: "whatever",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations, // Set terminals to receive fees.
                memo: ""
            });

            // Setup an erc20 for the project
            vm.prank(multisig());
            jbx = jbController().deployERC20For(1, "JUICEBOX", "JBX", bytes32(0));
        }
    }

    function setUp() public override {
        vm.createSelectFork("https://rpc.ankr.com/eth");

        super.setUp();

        delegate = new JBBuybackHook({
            directory: jbDirectory(),
            controller: jbController(),
            weth: weth,
            factory: address(factory)
        });

        initMetadata();
        launchAndConfigureL1Project();

        // JBX V3 pool wasn't deployed at that block
        pool = IUniswapV3Pool(factory.createPool(address(weth), address(jbx), fee));
        pool.initialize(sqrtPriceX96); // 1 eth <=> 69420 jbx

        address LP = makeAddr("LP");
        vm.startPrank(LP, LP);
        deal(address(weth), LP, 10_000_000 ether);
        deal(address(jbx), LP, 10_000_000 ether);

        // create a full range position
        address POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
        IERC20(address(jbx)).approve(POSITION_MANAGER, 10_000_000 ether);
        weth.approve(POSITION_MANAGER, 10_000_000 ether);

        // mint concentrated position
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(jbx),
            token1: address(weth),
            fee: fee,
            // considering a max valid range
            tickLower: -840_000,
            tickUpper: 840_000,
            amount0Desired: 10_000_000 ether,
            amount1Desired: 10_000_000 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: LP,
            deadline: block.timestamp
        });

        INonfungiblePositionManager(POSITION_MANAGER).mint(params);

        vm.stopPrank();

        vm.prank(jbProjects().ownerOf(1));
        delegate.setPoolFor(1, fee, cardinality, twapDelta, address(weth));

        amountOutQuoted = getAmountOut(pool, 1 ether, address(weth));

        vm.label(address(pool), "uniswapPool");
        vm.label(address(factory), "uniswapFactory");
        vm.label(address(weth), "$WETH");
        vm.label(address(jbx), "$JBX");
    }

    // placeholder so that our setup actually runs
    function test_isSetup() external {}
}
