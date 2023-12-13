// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "lib/forge-std/src/Test.sol";

import "lib/juice-contracts-v4/src/JBController.sol";
import "lib/juice-contracts-v4/src/JBDirectory.sol";
import "lib/juice-contracts-v4/src/JBMultiTerminal.sol";
import "lib/juice-contracts-v4/src/JBFundAccessLimits.sol";
import "lib/juice-contracts-v4/src/JBTerminalStore.sol";
import "lib/juice-contracts-v4/src/JBRulesets.sol";
import "lib/juice-contracts-v4/src/JBFeelessAddresses.sol";
import "lib/juice-contracts-v4/src/JBPermissions.sol";
import "lib/juice-contracts-v4/src/JBPrices.sol";
import "lib/juice-contracts-v4/src/JBProjects.sol";
import "lib/juice-contracts-v4/src/JBSplits.sol";
import "lib/juice-contracts-v4/src/JBTokens.sol";

import "lib/juice-contracts-v4/src/structs/JBDidPayData.sol";
import "lib/juice-contracts-v4/src/structs/JBDidRedeemData.sol";
import "lib/juice-contracts-v4/src/structs/JBFee.sol";
import "lib/juice-contracts-v4/src/structs/JBFundAccessLimitGroup.sol";
import "lib/juice-contracts-v4/src/structs/JBRuleset.sol";
import "lib/juice-contracts-v4/src/structs/JBRulesetData.sol";
import "lib/juice-contracts-v4/src/structs/JBRulesetMetadata.sol";
import "lib/juice-contracts-v4/src/structs/JBSplitGroup.sol";
import "lib/juice-contracts-v4/src/structs/JBPermissionsData.sol";
import "lib/juice-contracts-v4/src/structs/JBPayParamsData.sol";
import "lib/juice-contracts-v4/src/structs/JBRedeemParamsData.sol";
import "lib/juice-contracts-v4/src/structs/JBSplit.sol";
import "lib/juice-contracts-v4/src/interfaces/terminal/IJBTerminal.sol";
import "lib/juice-contracts-v4/src/interfaces/IJBToken.sol";
import "lib/juice-contracts-v4/src/libraries/JBConstants.sol";

import "lib/juice-contracts-v4/src/interfaces/IJBTerminalStore.sol";

import "./AccessJBLib.sol";
import "src/interfaces/external/IWETH9.sol";
import "src/JBBuybackHook.sol";

// Base contract for Juicebox system tests.
//
// Provides common functionality, such as deploying contracts on test setup for v3.
contract TestBaseWorkflowV3 is Test {
    using stdStorage for StdStorage;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    // Multisig address used for testing.
    address internal multisig = makeAddr("mooltichig");
    address internal beneficiary = makeAddr("benefishary");

    JBPermissions internal jbPermissions;
    JBProjects internal jbProjects;
    JBPrices internal jbPrices;
    JBDirectory internal jbDirectory;
    JBFundAccessLimits internal jbFundAccessLimits;
    JBRulesets internal jbRulesets;
    JBFeelessAddresses internal jbFeelessAddresses;
    JBTokens internal jbTokens;
    JBSplits internal jbSplits;
    JBController internal jbController;
    JBTerminalStore internal jbTerminalStore;
    JBMultiTerminal internal jbMultiTerminal;

    JBBuybackHook hook;

    uint256 projectId;
    uint256 reservedRate = 4500;
    uint256 weight = 10 ether; // Minting 10 token per eth
    uint32 cardinality = 1000;
    uint256 twapDelta = 500;

    JBRulesetData data;
    JBRulesetData dataReconfiguration;
    JBRulesetData dataWithoutHook;
    JBRulesetMetadata metadata;

    // Use the L1 UniswapV3Pool jbx/eth 1% fee for create2 magic
    // IUniswapV3Pool pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);
    IJBToken jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);
    IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address uniswapFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    uint24 fee = 10;

    IUniswapV3Pool pool;

    //*********************************************************************//
    // --------------------------- test setup ---------------------------- //
    //*********************************************************************//

    // Deploys and initializes contracts for testing.
    function setUp() public virtual {
        // Labels
        vm.label(multisig, "projectOwner");
        vm.label(beneficiary, "beneficiary");
        vm.label(address(pool), "uniswapPool");
        vm.label(address(uniswapFactory), "uniswapFactory");
        vm.label(address(weth), "$WETH");
        vm.label(address(jbx), "$JBX");

        // mock
        vm.etch(address(pool), "0x69");
        vm.etch(address(weth), "0x69");

        // JBPermissions
        jbPermissions = new JBPermissions();
        vm.label(address(jbPermissions), "JBPermissions");

        // JBProjects
        jbProjects = new JBProjects(jbPermissions);
        vm.label(address(jbProjects), "JBProjects");

        // JBPrices
        jbPrices = new JBPrices(multisig);
        vm.label(address(jbPrices), "JBPrices");

        address contractAtNoncePlusOne = computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        // JBRulesets
        jbRulesets = new JBRulesets(IJBDirectory(contractAtNoncePlusOne));
        vm.label(address(jbRulesets), "JBRulesets");

        // JBDirectory
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, jbRulesets, multisig);
        vm.label(address(jbDirectory), "JBDirectory");

        // JBTokens
        jbTokens = new JBTokens(jbPermissions, jbProjects, jbDirectory, jbRulesets);
        vm.label(address(jbTokens), "JBTokens");

        // JBSplits
        jbSplits = new JBSplits(jbPermissions, jbProjects, jbDirectory);
        vm.label(address(jbSplits), "JBSplits");

        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);
        vm.label(address(jbFundAccessLimits), "JBFundAccessLimits");

        jbFeelessAddresses = new JBFeelessAddresses(address(69));
        vm.label(address(jbFeelessAddresses), "JBFeelessAddresses");

        // JBController
        jbController = new JBController(
            jbPermissions, jbProjects, jbDirectory, jbRulesets, jbTokens, jbSplits, jbFundAccessLimits
        );
        vm.label(address(jbController), "JBController");

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        // JBETHPaymentTerminalStore
        jbTerminalStore = new JBTerminalStore(jbDirectory, jbRulesets, jbPrices);
        vm.label(address(jbTerminalStore), "JBTerminalStore");

        // JBETHPaymentTerminal
        jbMultiTerminal = new JBMultiTerminal(
            jbPermissions,
            jbProjects,
            jbDirectory,
            jbSplits,
            address(jbTerminalStore),
            address(0),
            address(0)
        );
        vm.label(address(jbMultiTerminal), "JBMultiTerminal");

        // Deploy the delegate
        hook = new JBBuybackHook({
            weth: weth,
            factory: uniswapFactory,
            directory: IJBDirectory(address(jbDirectory)),
            controller: jbController,
            delegateId: bytes4(hex"69")
        });

        data = JBRulesetData({
            duration: 6 days,
            weight: weight,
            decayRate: 0,
            hook: IJBRulesetApprovalHook(address(0))
        });

        metadata = JBRulesetMetadata({
            reservedRate: reservedRate,
            redemptionRate: 5000,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowControllerMigration: false,
            allowSetController: false,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: true,
            useDataHookForRedeem: false,
            dataHook: address(hook),
            metadata: 0
        });

        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        JBCurrencyAmount[] memory surplusAllowances = new JBCurrencyAmount[](1);
        payoutLimits[0] =
            JBCurrencyAmount({amount: 2 ether, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        surplusAllowances[0] = JBCurrencyAmount({amount: type(uint232).max, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: surplusAllowances
        });

        // Package up the ruleset configuration.
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0].mustStartAtOrAfter = 0;
        rulesetConfigurations[0].data = data;
        rulesetConfigurations[0].metadata = metadata;
        rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
        rulesetConfigurations[0].fundAccessLimitGroups = fundAccessLimitGroups;

        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContextConfig[] memory accountingContextConfigs = new JBAccountingContextConfig[](1);
        accountingContextConfigs[0] =
            JBAccountingContextConfig({token: JBConstants.NATIVE_TOKEN, standard: JBTokenStandards.NATIVE});
        terminalConfigurations[0] =
            JBTerminalConfig({terminal: jbMultiTerminal, accountingContextConfigs: accountingContextConfigs});

        projectId = jbController.launchProjectFor({
            owner: multisig,
            projectMetadata: "myIPFSHash",
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations, // Set terminals to receive fees.
            memo: ""
        });

        vm.prank(multisig);
        jbController.deployERC20For(projectId, "jbx", "jbx");

        vm.prank(multisig);
        pool = hook.setPoolFor(projectId, fee, uint32(cardinality), twapDelta, address(weth));
    }
}