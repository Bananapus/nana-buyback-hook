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
    IERC20 jbx = IERC20(0x4554CC10898f92D45378b98D6D6c2dD54c687Fb2);
    IWETH9 constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // 1 - 1*10**18

    uint256 constant price = 69_420 ether;
    uint32 constant cardinality = 100_000;
    uint256 constant twapDelta = 5000;
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
            allowSetCustomToken: true,
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
            jbController().setTokenFor(1, IJBToken(address(jbx)));
        }
    }

    function setUp() public override {
        vm.createSelectFork("https://rpc.ankr.com/eth", 17_962_427);

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

        vm.warp(block.timestamp + 60);
        pool.increaseObservationCardinalityNext(60);

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

    function _getTwapQuote(
        uint256 _amountIn,
        uint32 _twapWindow,
        uint256 _twapTolerance
    )
        internal
        view
        returns (uint256 _amountOut)
    {
        // Get the twap tick
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(pool), _twapWindow);

        // Get a quote based on this twap tick
        _amountOut = OracleLibrary.getQuoteAtTick(arithmeticMeanTick, uint128(_amountIn), address(weth), address(jbx));

        // Return the lowest twap accepted
        _amountOut -= (_amountOut * _twapTolerance) / TWAP_SLIPPAGE_DENOMINATOR;
    }

    /**
     * @notice If the amount of token returned by minting is greater than by swapping, mint
     *
     * @dev    Should mint for both multisig() and reserve
     */
    function test_mintIfWeightGreatherThanPrice(uint256 _weight, uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 100, 100 ether);

        uint256 _amountOutQuoted = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight bigger than the price implied by the quote
        _weight = bound(_weight, (_amountOutQuoted * 10 ** 18 / _amountIn) + 1, type(uint88).max);

        _reconfigure(1, address(delegate), _weight, 5000);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        // This shouldn't mint via the delegate
        vm.expectEmit(true, true, true, true);
        emit Mint({
            holder: multisig(),
            projectId: 1,
            amount: mulDiv18(_weight, _amountIn) / 2, // Half is reserved
            tokensWereClaimed: true,
            preferClaimedTokens: true,
            caller: address(jbController())
        });

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        // Pay the project
        jbMultiTerminal().pay{value: _amountIn}(
            1,
            JBConstants.NATIVE_TOKEN,
            _amountIn,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        uint256 _balAfterPayment = jbx.balanceOf(multisig());
        uint256 _diff = _balAfterPayment - _balBeforePayment;

        // Check: token received by the multisig()
        assertEq(_diff, mulDiv18(_weight, _amountIn) / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(
            jbController().pendingReservedTokenBalanceOf(1),
            _reservedBalanceBefore + mulDiv18(_weight, _amountIn) / 2,
            1
        );
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap
     *
     * @dev    Should swap for both multisig() and reserve (by burning/minting)
     */
    function test_swapIfQuoteBetter(uint256 _weight, uint256 _amountIn, uint256 _reservedPercent) public {
        _amountIn = bound(_amountIn, 100, 100 ether);

        uint256 _amountOutQuoted = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight smaller than the price implied by the quote
        _weight = bound(_weight, 1, (_amountOutQuoted * 10 ** 18 / _amountIn) - 1);

        _reservedPercent = bound(_reservedPercent, 0, 10_000);

        _reconfigure(1, address(delegate), _weight, _reservedPercent);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        vm.expectEmit(true, true, true, true);
        emit Swap(1, _amountIn, pool, _amountOutQuoted, address(jbMultiTerminal()));

        // Pay the project
        jbMultiTerminal().pay{value: _amountIn}(
            1, JBConstants.NATIVE_TOKEN, _amountIn, multisig(), 0, "Take my money!", _delegateMetadata
        );

        // Check: token received by the multisig()
        assertApproxEqAbs(
            jbx.balanceOf(multisig()) - _balBeforePayment,
            _amountOutQuoted - (_amountOutQuoted * _reservedPercent / 10_000),
            1,
            "wrong balance"
        );

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(
            jbController().pendingReservedTokenBalanceOf(1),
            _reservedBalanceBefore + _amountOutQuoted * _reservedPercent / 10_000,
            1,
            "wrong reserve"
        );
    }

    /**
     * @notice Use the delegate multiple times to swap, with different quotes
     */
    function test_swapMultiple() public {
        // Reconfigure with a weight of 1 wei, to force swapping
        uint256 _weight = 1;
        _reconfigure(1, address(delegate), _weight, 5000);

        // Build the metadata using the quote at that block
        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(amountPaid, amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        // Pay the project
        jbMultiTerminal().pay{value: amountPaid}(
            1,
            JBConstants.NATIVE_TOKEN,
            amountPaid,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        uint256 _balanceBene = jbx.balanceOf(multisig());

        uint256 _reserveBalance = jbController().pendingReservedTokenBalanceOf(1);

        // Update the quote, this is now a different one as we already swapped
        uint256 _previousQuote = amountOutQuoted;
        amountOutQuoted = getAmountOut(pool, 1 ether, address(weth));

        // Sanity check
        assert(_previousQuote != amountOutQuoted);

        // Update the metadata
        _data[0] = abi.encode(amountPaid, amountOutQuoted);

        // Generate the metadata
        _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        vm.roll(block.timestamp + 1);

        // Pay the project
        jbMultiTerminal().pay{value: amountPaid}(
            1,
            JBConstants.NATIVE_TOKEN,
            amountPaid,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        // Check: token received by the multisig()
        assertEq(jbx.balanceOf(multisig()), _balanceBene + amountOutQuoted / 2);

        // Check: token added to the reserve - 1 wei sensitivity for rounding errors
        assertApproxEqAbs(jbController().pendingReservedTokenBalanceOf(1), _reserveBalance + amountOutQuoted / 2, 1);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap
     *
     * @dev    Should swap for both multisig() and reserve (by burning/minting)
     */
    function test_swapRandomAmountIn(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 100, 100 ether);

        uint256 _quote = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight of 1
        _reconfigure(1, address(delegate), 1, 0);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Build the metadata using the quote
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, _quote);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        vm.expectEmit(true, true, true, true);
        emit Swap(1, _amountIn, pool, _quote, address(jbMultiTerminal()));

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        // Pay the project
        jbMultiTerminal().pay{value: _amountIn}(
            1,
            JBConstants.NATIVE_TOKEN,
            _amountIn,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        uint256 _balAfterPayment = jbx.balanceOf(multisig());
        uint256 _diff = _balAfterPayment - _balBeforePayment;

        // Check: token received by the multisig()
        assertEq(_diff, _quote);

        // Check: reserve unchanged
        assertEq(jbController().pendingReservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting, swap & use quote from uniswap
     * lib
     * rather than a user provided quote
     *
     * @dev    Should swap for both multisig() and reserve (by burning/minting)
     */
    function test_swapWhenQuoteNotProvidedInMetadata(uint256 _amountIn, uint256 _reservedPercent) public {
        _amountIn = bound(_amountIn, 10, 10 ether);
        _reservedPercent = bound(_reservedPercent, 0, 10_000);

        uint256 _weight = 10 ether;

        _reconfigure(1, address(delegate), _weight, _reservedPercent);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // The twap which is going to be used
        uint256 _twap = _getTwapQuote(_amountIn, cardinality, twapDelta);

        // The actual quote, here for test only
        uint256 _quote = getAmountOut(pool, _amountIn, address(weth));

        // for checking balance difference after payment
        uint256 _balanceBeforePayment = jbx.balanceOf(multisig());

        // Pay the project
        jbMultiTerminal().pay{value: _amountIn}(
            1,
            JBConstants.NATIVE_TOKEN,
            _amountIn,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            new bytes(0)
        );

        uint256 _balanceAfterPayment = jbx.balanceOf(multisig());
        uint256 _tokenReceived = _balanceAfterPayment - _balanceBeforePayment;

        uint256 _tokenCount = mulDiv18(_amountIn, _weight);

        // 1 wei sensitivity for rounding errors
        if (_twap > _tokenCount) {
            // Path is picked based on twap, but the token received are the one quoted
            assertApproxEqAbs(_tokenReceived, _quote - (_quote * _reservedPercent) / 10_000, 1, "wrong swap");
            assertApproxEqAbs(
                jbController().pendingReservedTokenBalanceOf(1),
                _reservedBalanceBefore + (_quote * _reservedPercent) / 10_000,
                1,
                "Reserve"
            );
        } else {
            assertApproxEqAbs(_tokenReceived, _tokenCount - (_tokenCount * _reservedPercent) / 10_000, 1, "Wrong mint");
            assertApproxEqAbs(
                jbController().pendingReservedTokenBalanceOf(1),
                _reservedBalanceBefore + (_tokenCount * _reservedPercent) / 10_000,
                1,
                "Reserve"
            );
        }
    }

    /**
     * @notice If the amount of token returned by minting is greater than by swapping, we mint outside of the delegate
     * &
     * when there is no user provided quote presemt in metadata
     *
     * @dev    Should mint for both multisig() and reserve
     */
    function test_swapWhenMintIsPreferredEvenWhenMetadataIsNotPresent(uint256 _amountIn) public {
        _amountIn = bound(_amountIn, 1 ether, 1000 ether);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Reconfigure with a weight of amountOutQuoted + 1
        _reconfigure(1, address(delegate), amountOutQuoted + 1, 0);

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        // Pay the project
        jbMultiTerminal().pay{value: _amountIn}(
            1, JBConstants.NATIVE_TOKEN, _amountIn, multisig(), 0, "Take my money!", new bytes(0)
        );

        uint256 expectedTokenCount = mulDiv(_amountIn, amountOutQuoted + 1, 10 ** 18);

        uint256 _balAfterPayment = jbx.balanceOf(multisig());
        uint256 _diff = _balAfterPayment - _balBeforePayment;

        // Check: token received by the multisig()
        assertEq(_diff, expectedTokenCount);

        // Check: reserve unchanged
        assertEq(jbController().pendingReservedTokenBalanceOf(1), _reservedBalanceBefore);
    }

    /**
     * @notice If the amount of token returned by swapping is greater than by minting but slippage is too high,
     *         revert if a quote was passed in the pay data
     */
    function test_revertIfSlippageTooHighAndQuote() public {
        uint256 _weight = 50;
        // Reconfigure with a weight smaller than the quote, slippage included
        _reconfigure(1, address(delegate), _weight, 5000);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(
            0,
            69_412_820_131_620_254_304_865 + 10 // 10 more than quote at that block
        );

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        vm.expectRevert(JBBuybackHook.JBBuybackHook_SpecifiedSlippageExceeded.selector);

        // Pay the project
        jbMultiTerminal().pay{value: 1 ether}(
            1,
            JBConstants.NATIVE_TOKEN,
            1 ether,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );
    }

    function test_mintWithExtraFunds(uint256 _amountIn, uint256 _amountInExtra) public {
        _amountIn = bound(_amountIn, 100, 10 ether);
        _amountInExtra = bound(_amountInExtra, 100, 10 ether);

        // Refresh the quote
        amountOutQuoted = getAmountOut(pool, _amountIn, address(weth));

        // Reconfigure with a weight smaller than the quote
        uint256 _weight = amountOutQuoted * 10 ** 18 / _amountIn - 1;
        _reconfigure(1, address(delegate), _weight, 5000);

        uint256 _reservedBalanceBefore = jbController().pendingReservedTokenBalanceOf(1);

        // Build the metadata using the quote at that block
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_amountIn, amountOutQuoted);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _delegateMetadata = metadataHelper().createMetadata(_ids, _data);

        uint256 _balBeforePayment = jbx.balanceOf(multisig());

        vm.expectEmit(true, true, true, true);
        emit Swap(1, _amountIn, pool, amountOutQuoted, address(jbMultiTerminal()));

        // Pay the project
        jbMultiTerminal().pay{value: _amountIn + _amountInExtra}(
            1,
            JBConstants.NATIVE_TOKEN,
            _amountIn + _amountInExtra,
            multisig(),
            /* _minReturnedTokens */
            0,
            /* _preferClaimedTokens */
            /* _memo */
            "Take my money!",
            /* _delegateMetadata */
            _delegateMetadata
        );

        // Check: token received by the multisig()
        assertApproxEqAbs(
            jbx.balanceOf(multisig()) - _balBeforePayment,
            amountOutQuoted / 2 + mulDiv18(_amountInExtra, _weight) / 2,
            10
        );

        // Check: token added to the reserve
        assertApproxEqAbs(
            jbController().pendingReservedTokenBalanceOf(1),
            _reservedBalanceBefore + amountOutQuoted / 2 + mulDiv18(_amountInExtra, _weight) / 2,
            10
        );
    }

    function _reconfigure(uint256 _projectId, address _delegate, uint256 _weight, uint256 _reservedPercent) internal {
        address _projectOwner = jbProjects().ownerOf(_projectId);

        JBRuleset memory _fundingCycle = jbRulesets().currentOf(_projectId);
        _metadata = _fundingCycle.expandMetadata();

        JBSplitGroup[] memory _groupedSplits = new JBSplitGroup[](1);
        _groupedSplits[0] = JBSplitGroup({
            groupId: 1,
            splits: jbSplits().splitsOf(_projectId, _fundingCycle.id, uint256(uint160(JBConstants.NATIVE_TOKEN)) /*group*/ )
        });

        _metadata.useDataHookForPay = true;
        _metadata.dataHook = _delegate;

        _metadata.reservedPercent = uint16(_reservedPercent);

        // reconfigure
        vm.prank(_projectOwner);

        JBRulesetConfig[] memory rulesetConfig = new JBRulesetConfig[](1);
        rulesetConfig[0] = JBRulesetConfig({
            mustStartAtOrAfter: uint48(block.timestamp),
            duration: 14 days,
            weight: uint112(_weight),
            decayPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: _metadata,
            splitGroups: _groupedSplits,
            fundAccessLimitGroups: fundAccessLimitGroups
        });

        jbController().queueRulesetsOf(_projectId, rulesetConfig, "");

        // Move to next fc
        vm.warp(block.timestamp + _fundingCycle.duration * 2 + 1);
    }
}
