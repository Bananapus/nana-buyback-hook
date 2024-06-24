// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IJBTerminal} from "@bananapus/core/src/interfaces/IJBTerminal.sol";
import {IJBMultiTerminal} from "@bananapus/core/src/interfaces/IJBMultiTerminal.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core/src/structs/JBAfterPayRecordedContext.sol";
import {JBPermissioned} from "@bananapus/core/src/abstract/JBPermissioned.sol";
import {IJBDirectory} from "@bananapus/core/src/interfaces/IJBDirectory.sol";
import {IJBController} from "@bananapus/core/src/interfaces/IJBController.sol";
import {IJBProjects} from "@bananapus/core/src/interfaces/IJBController.sol";
import {IJBPermissioned} from "@bananapus/core/src/interfaces/IJBPermissioned.sol";
import {IJBRulesetDataHook} from "@bananapus/core/src/interfaces/IJBRulesetDataHook.sol";
import {IJBPayHook} from "@bananapus/core/src/interfaces/IJBPayHook.sol";
import {JBPayHookSpecification} from "@bananapus/core/src/structs/JBPayHookSpecification.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core/src/structs/JBBeforePayRecordedContext.sol";
import {JBBeforeRedeemRecordedContext} from "@bananapus/core/src/structs/JBBeforeRedeemRecordedContext.sol";
import {JBRedeemHookSpecification} from "@bananapus/core/src/structs/JBRedeemHookSpecification.sol";
import {JBConstants} from "@bananapus/core/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core/src/libraries/JBMetadataResolver.sol";
import {JBPermissionIds} from "@bananapus/permission-ids/src/JBPermissionIds.sol";
import {IJBBuybackHook} from "./interfaces/IJBBuybackHook.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice The buyback hook allows beneficiaries of a payment to a project to either:
/// - Get tokens by paying the project through its terminal OR
/// - Buy tokens from the configured Uniswap v3 pool.
/// Depending on which route would yield more tokens for the beneficiary. The project's reserved rate applies to either
/// route.
/// @dev Compatible with any `JBTerminal` and any project token that can be pooled on Uniswap v3.
contract JBBuybackHook is JBPermissioned, IJBBuybackHook {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error SpecifiedSlippageExceeded();
    error InsufficientPayAmount();
    error NoProjectToken();
    error PoolAlreadySet();
    error InvalidTwapSlippageTolerance();
    error InvalidTwapWindow();
    error Unauthorized();

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The TWAP parameters used for the given project when the payer does not specify a quote.
    /// See the README for further information.
    /// @dev This includes the TWAP slippage tolerance and TWAP window, packed into a `uint256`.
    /// @custom:param projectId The ID of the project to get the twap parameters for.
    mapping(uint256 projectId => uint256) internal twapParamsOf;

    //*********************************************************************//
    // --------------------- public constant properties ------------------ //
    //*********************************************************************//

    /// @notice The denominator used when calculating TWAP slippage percent values.
    uint256 public constant TWAP_SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice Projects cannot specify a TWAP slippage tolerance smaller than this constant (out of `MAX_SLIPPAGE`).
    /// @dev This prevents TWAP slippage tolerances so low that the swap always reverts to default behavior unless a
    /// quote is specified in the payment metadata.
    uint256 public constant MIN_TWAP_SLIPPAGE_TOLERANCE = 100;

    /// @notice Projects cannot specify a TWAP slippage tolerance larger than this constant (out of `MAX_SLIPPAGE`).
    /// @dev This prevents TWAP slippage tolerances so high that they would result in highly unfavorable trade
    /// conditions for the payer unless a quote was specified in the payment metadata.
    uint256 public constant MAX_TWAP_SLIPPAGE_TOLERANCE = 9000;

    /// @notice Projects cannot specify a TWAP window shorter than this constant.
    /// @dev This serves to avoid  extremely short TWAP windows that could be manipulated or subject to high volatility.
    uint256 public constant MIN_TWAP_WINDOW = 2 minutes;

    /// @notice Projects cannot specify a TWAP window longer than this constant.
    /// @dev This serves to avoid excessively long TWAP windows that could lead to outdated pricing information and
    /// higher gas costs due to increased computational requirements.
    uint256 public constant MAX_TWAP_WINDOW = 2 days;

    //*********************************************************************//
    // -------------------- public immutable properties ------------------ //
    //*********************************************************************//

    /// @notice The address of the Uniswap v3 factory. Used to calculate pool addresses.
    address public immutable UNISWAP_V3_FACTORY;

    /// @notice The directory of terminals and controllers.
    IJBDirectory public immutable DIRECTORY;

    /// @notice The controller used to mint and burn tokens.
    IJBController public immutable CONTROLLER;

    /// @notice The project registry.
    IJBProjects public immutable PROJECTS;

    /// @notice The wETH contract.
    IWETH9 public immutable WETH;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The Uniswap pool where a given project's token and terminal token pair are traded.
    /// @custom:param projectId The ID of the project whose token is traded in the pool.
    /// @custom:param terminalToken The address of the terminal token that the project accepts for payments (and is
    /// traded in the pool).
    mapping(uint256 projectId => mapping(address terminalToken => IUniswapV3Pool)) public poolOf;

    /// @notice The address of each project's token.
    /// @custom:param projectId The ID of the project the token belongs to.
    mapping(uint256 projectId => address) public projectTokenOf;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Required by the `IJBRulesetDataHook` interfaces. Return false to not leak any permissions.
    function hasMintPermissionFor(uint256, address) external pure returns (bool) {
        return false;
    }

    /// @notice The `IJBRulesetDataHook` implementation which determines whether tokens should be minted from the
    /// project or bought from the pool.
    /// @param context Payment context passed to the data hook by `terminalStore.recordPaymentFrom(...)`.
    /// `context.metadata` can specify a Uniswap quote and specify how much of the payment should be used to swap.
    /// If `context.metadata` does not specify a quote, one will be calculated based on the TWAP.
    /// If `context.metadata` does not specify how much of the payment should be used, the hook uses the full amount
    /// paid in.
    /// @return weight The weight to use. If tokens are being minted from the project, this is the original weight.
    /// If tokens are being bought from the pool, the weight is 0.
    /// If tokens are being minted AND bought from the pool, this weight is adjusted to take both into account.
    /// @return hookSpecifications Specifications containing pay hooks, as well as the amount and metadata to send to
    /// them. Fulfilled by the terminal.
    /// If tokens are only being minted, `hookSpecifications` will be empty.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Keep a reference to the amount paid in.
        uint256 totalPaid = context.amount.value;

        // Keep a reference to the weight.
        weight = context.weight;

        // Keep a reference to the minimum number of tokens expected from the swap.
        uint256 minimumSwapAmountOut;

        // Keep a reference to the amount to be used to swap (out of `totalPaid`).
        uint256 amountToSwapWith;

        // Scoped section to prevent stack too deep.
        {
            // The metadata ID is the first 4 bytes of this contract's address.
            bytes4 metadataId = JBMetadataResolver.getId("quote");

            // Unpack the quote specified by the payer/client (typically from the pool).
            (bool quoteExists, bytes memory metadata) = JBMetadataResolver.getDataFor(metadataId, context.metadata);
            if (quoteExists) (amountToSwapWith, minimumSwapAmountOut) = abi.decode(metadata, (uint256, uint256));
        }

        // If the amount to swap with is greater than the actual amount paid in, revert.
        if (amountToSwapWith > totalPaid) revert InsufficientPayAmount();

        // If the payer/client did not specify an amount to use towards the swap, use the `totalPaid`.
        if (amountToSwapWith == 0) amountToSwapWith = totalPaid;

        // Calculate how many tokens would be minted by a direct payment to the project.
        // `tokenCountWithoutHook` is a fixed point number with 18 decimals.
        uint256 tokenCountWithoutHook = mulDiv(amountToSwapWith, weight, 10 ** context.amount.decimals);

        // Keep a reference to the project's token.
        address projectToken = projectTokenOf[context.projectId];

        // Keep a reference to the token being used by the terminal that is calling this hook. Default to wETH if the
        // terminal uses the native token.
        address terminalToken = context.amount.token == JBConstants.NATIVE_TOKEN ? address(WETH) : context.amount.token;

        // If a minimum amount of tokens to swap for wasn't specified by the player/client, calculate a minimum based on
        // the TWAP.
        if (minimumSwapAmountOut == 0) {
            minimumSwapAmountOut = _getQuote(context.projectId, projectToken, amountToSwapWith, terminalToken);
        }

        // If the minimum amount of tokens from the swap exceeds the amount that paying the project directly would
        // yield, swap.
        if (tokenCountWithoutHook < minimumSwapAmountOut) {
            // Keep a reference to a flag indicating whether the Uniswap pool will reference the project token first in
            // the pair.
            bool projectTokenIs0 = address(projectToken) < terminalToken;

            // Specify this hook as the one to use, the amount to swap with, and metadata which allows the swap to be
            // executed.
            hookSpecifications = new JBPayHookSpecification[](1);
            hookSpecifications[0] = JBPayHookSpecification({
                hook: IJBPayHook(this),
                amount: amountToSwapWith,
                metadata: abi.encode(
                    projectTokenIs0, totalPaid == amountToSwapWith ? 0 : totalPaid - amountToSwapWith, minimumSwapAmountOut
                )
            });

            // All the minting will be done in `afterPayRecordedWith`. Return a weight of 0 to any additional minting
            // from the terminal.
            return (0, hookSpecifications);
        }
    }

    /// @notice Get the TWAP window for a given project ID.
    /// @dev The "TWAP window" is the period over which the TWAP is computed.
    /// @param  projectId The ID of the project which the TWAP window applies to.
    /// @return secondsAgo The TWAP window in seconds.
    function twapWindowOf(uint256 projectId) external view returns (uint32) {
        return uint32(twapParamsOf[projectId]);
    }

    /// @notice Get the TWAP slippage tolerance for a given project ID.
    /// @dev The "TWAP slippage tolerance" is the maximum negative spread between the TWAP and the expected return from
    /// a swap.
    /// If the expected return unfavourably exceeds the TWAP slippage tolerance, the swap will revert.
    /// @param  projectId The ID of the project which the TWAP slippage tolerance applies to.
    /// @return tolerance The maximum slippage allowed relative to the TWAP, as a percent out of
    /// `TWAP_SLIPPAGE_DENOMINATOR`.
    function twapSlippageToleranceOf(uint256 projectId) external view returns (uint256) {
        return twapParamsOf[projectId] >> 128;
    }

    /// @notice To fulfill the `IJBRulesetDataHook` interface.
    /// @dev Pass redeem context back to the terminal without changes.
    /// @param context The redeem context passed in by the terminal.
    function beforeRedeemRecordedWith(JBBeforeRedeemRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, uint256, uint256, JBRedeemHookSpecification[] memory hookSpecifications)
    {
        return (context.redemptionRate, context.redeemCount, context.totalSupply, hookSpecifications);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IJBBuybackHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param weth The WETH contract.
    /// @param factory The address of the Uniswap v3 factory. Used to calculate pool addresses.
    /// @param directory The directory of terminals and controllers.
    /// @param controller The controller used to mint and burn tokens.
    constructor(
        IWETH9 weth,
        address factory,
        IJBDirectory directory,
        IJBController controller
    )
        JBPermissioned(IJBPermissioned(address(controller)).PERMISSIONS())
    {
        WETH = weth;
        DIRECTORY = directory;
        CONTROLLER = controller;
        UNISWAP_V3_FACTORY = factory;
        PROJECTS = controller.PROJECTS();
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Swap the specified amount of terminal tokens for project tokens, using any leftover terminal tokens to
    /// mint from the project.
    /// @dev This function is only called if the minimum return from the swap exceeds the return from minting by paying
    /// the project.
    /// If the swap reverts (due to slippage, insufficient liquidity, or something else),
    /// then the hook mints the number of tokens which a payment to the project would have minted.
    /// @param context The pay context passed in by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        // Make sure only the project's payment terminals can access this function.
        if (!DIRECTORY.isTerminalOf(context.projectId, IJBTerminal(msg.sender))) {
            revert Unauthorized();
        }

        // Parse the metadata forwarded from the data hook.
        (bool projectTokenIs0, uint256 amountToMintWith, uint256 minimumSwapAmountOut) =
            abi.decode(context.hookMetadata, (bool, uint256, uint256));

        // If the token paid in isn't the native token, pull the amount to swap from the terminal.
        if (context.forwardedAmount.token != JBConstants.NATIVE_TOKEN) {
            IERC20(context.forwardedAmount.token).transferFrom(msg.sender, address(this), context.forwardedAmount.value);
        }

        // Get a reference to the number of project tokens that was swapped for.
        uint256 exactSwapAmountOut = _swap(context, projectTokenIs0);

        // If the payer/client specified a minimum amount to receive, make sure the swap meets that minimum.
        if (exactSwapAmountOut < minimumSwapAmountOut) revert SpecifiedSlippageExceeded();

        // Get a reference to any terminal tokens which were paid in and are still held by this contract.
        uint256 terminalTokensInThisContract = context.forwardedAmount.token == JBConstants.NATIVE_TOKEN
            ? address(this).balance
            : IERC20(context.forwardedAmount.token).balanceOf(address(this));

        // Mint a corresponding number of project tokens using any terminal tokens left over.
        // Keep a reference to the number of tokens being minted.
        uint256 partialMintTokenCount;
        if (terminalTokensInThisContract != 0) {
            partialMintTokenCount = mulDiv(terminalTokensInThisContract, context.weight, 10 ** context.amount.decimals);

            // If the token paid in wasn't the native token, grant the terminal permission to pull them back into its
            // balance.
            if (context.forwardedAmount.token != JBConstants.NATIVE_TOKEN) {
                IERC20(context.forwardedAmount.token).approve(msg.sender, terminalTokensInThisContract);
            }

            // Keep a reference to the amount being paid as `msg.value`.
            uint256 payValue =
                context.forwardedAmount.token == JBConstants.NATIVE_TOKEN ? terminalTokensInThisContract : 0;

            // Add the paid amount back to the project's balance in the terminal.
            IJBMultiTerminal(msg.sender).addToBalanceOf{value: payValue}({
                projectId: context.projectId,
                token: context.forwardedAmount.token,
                amount: terminalTokensInThisContract,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes("")
            });

            emit Mint(context.projectId, terminalTokensInThisContract, partialMintTokenCount, msg.sender);
        }

        // Add the amount to mint to the leftover mint amount (avoiding stack too deep here).
        partialMintTokenCount += mulDiv(amountToMintWith, context.weight, 10 ** context.amount.decimals);

        // Mint the calculated amount of tokens for the beneficiary, including any leftover amount.
        // This takes the reserved rate into account.
        CONTROLLER.mintTokensOf({
            projectId: context.projectId,
            tokenCount: exactSwapAmountOut + partialMintTokenCount,
            beneficiary: address(context.beneficiary),
            memo: "",
            useReservedRate: true
        });
    }

    /// @notice The Uniswap v3 pool callback where the token transfer is expected to happen.
    /// @param amount0Delta The amount of token 0 being used for the swap.
    /// @param amount1Delta The amount of token 1 being used for the swap.
    /// @param data Data passed in by the swap operation.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Unpack the data passed in through the swap hook.
        (uint256 projectId, address terminalToken) = abi.decode(data, (uint256, address));

        // Get the terminal token, using wETH if the token paid in is the native token.
        address terminalTokenWithWETH = terminalToken == JBConstants.NATIVE_TOKEN ? address(WETH) : terminalToken;

        // Make sure this call is being made from the right pool.
        if (msg.sender != address(poolOf[projectId][terminalTokenWithWETH])) revert Unauthorized();

        // Keep a reference to the number of tokens that should be sent to fulfill the swap (the positive delta).
        uint256 amountToSendToPool = amount0Delta < 0 ? uint256(amount1Delta) : uint256(amount0Delta);

        // Wrap native tokens as needed.
        if (terminalToken == JBConstants.NATIVE_TOKEN) WETH.deposit{value: amountToSendToPool}();

        // Transfer the token to the pool.
        IERC20(terminalTokenWithWETH).transfer(msg.sender, amountToSendToPool);
    }

    /// @notice Set the pool to use for a given project and terminal token (the default for the project's token <->
    /// terminal token pair).
    /// @dev Uses create2 for callback auth and to allow adding pools which haven't been deployed yet.
    /// This can be called by the project's owner or an address which has the `JBPermissionIds.SET_BUYBACK_POOL`
    /// permission from the owner.
    /// @param projectId The ID of the project to set the pool for.
    /// @param fee The fee used in the pool being set, as a fixed-point number of basis points with 2 decimals. A 0.01%
    /// fee is `100`, a 0.05% fee is `500`, a 0.3% fee is `3000`, and a 1% fee is `10000`.
    /// @param twapWindow The period of time over which the TWAP is computed.
    /// @param twapSlippageTolerance The maximum spread allowed between the amount received and the TWAP.
    /// @param terminalToken The address of the terminal token that payments to the project are made in.
    /// @return newPool The pool that was set for the project and terminal token.
    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        uint32 twapWindow,
        uint256 twapSlippageTolerance,
        address terminalToken
    )
        external
        returns (IUniswapV3Pool newPool)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_POOL
        });

        // Make sure the provided TWAP slippage tolerance is within reasonable bounds.
        if (twapSlippageTolerance < MIN_TWAP_SLIPPAGE_TOLERANCE || twapSlippageTolerance > MAX_TWAP_SLIPPAGE_TOLERANCE)
        {
            revert InvalidTwapSlippageTolerance();
        }

        // Make sure the provided TWAP window is within reasonable bounds.
        if (twapWindow < MIN_TWAP_WINDOW || twapWindow > MAX_TWAP_WINDOW) revert InvalidTwapWindow();

        // Keep a reference to the project's token.
        address projectToken = address(CONTROLLER.TOKENS().tokenOf(projectId));

        // Make sure the project has issued a token.
        if (projectToken == address(0)) revert NoProjectToken();

        // If the specified terminal token is the native token, use wETH instead.
        if (terminalToken == JBConstants.NATIVE_TOKEN) terminalToken = address(WETH);

        // Keep a reference to a flag indicating whether the pool will reference the project token first in the pair.
        bool projectTokenIs0 = address(projectToken) < terminalToken;

        // Compute the pool's address, which is a function of the factory, both tokens, and the fee.
        newPool = IUniswapV3Pool(
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                UNISWAP_V3_FACTORY,
                                keccak256(
                                    abi.encode(
                                        projectTokenIs0 ? projectToken : terminalToken,
                                        projectTokenIs0 ? terminalToken : projectToken,
                                        fee
                                    )
                                ),
                                // POOL_INIT_CODE_HASH from
                                // https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/PoolAddress.sol
                                bytes32(0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54)
                            )
                        )
                    )
                )
            )
        );

        // Make sure this pool hasn't already been set in this hook.
        if (poolOf[projectId][terminalToken] == newPool) revert PoolAlreadySet();

        // Store the pool.
        poolOf[projectId][terminalToken] = newPool;

        // Pack and store the TWAP window and the TWAP slippage tolerance in `twapParamsOf`.
        twapParamsOf[projectId] = twapSlippageTolerance << 128 | twapWindow;
        projectTokenOf[projectId] = address(projectToken);

        emit TwapWindowChanged(projectId, 0, twapWindow, msg.sender);
        emit TwapSlippageToleranceChanged(projectId, 0, twapSlippageTolerance, msg.sender);
        emit PoolAdded(projectId, terminalToken, address(newPool), msg.sender);
    }

    /// @notice Change the TWAP window for a project.
    /// The TWAP window is the period of time over which the TWAP is computed.
    /// @dev This can be called by the project's owner or an address with `JBPermissionIds.SET_BUYBACK_TWAP`
    /// permission from the owner.
    /// @param projectId The ID of the project to set the TWAP window of.
    /// @param newWindow The new TWAP window.
    function setTwapWindowOf(uint256 projectId, uint32 newWindow) external {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_TWAP
        });

        // Make sure the specified window is within reasonable bounds.
        if (newWindow < MIN_TWAP_WINDOW || newWindow > MAX_TWAP_WINDOW) {
            revert InvalidTwapWindow();
        }

        // Keep a reference to the stored TWAP params.
        uint256 twapParams = twapParamsOf[projectId];

        // Keep a reference to the old window value.
        uint256 oldWindow = uint128(twapParams);

        // Store the new packed value of the TWAP params (with the updated window).
        twapParamsOf[projectId] = uint256(newWindow) | ((twapParams >> 128) << 128);

        emit TwapWindowChanged(projectId, oldWindow, newWindow, msg.sender);
    }

    /// @notice Set the TWAP slippage tolerance for a project.
    /// The TWAP slippage tolerance is the maximum spread allowed between the amount received and the TWAP.
    /// @dev This can be called by the project's owner or an address with `JBPermissionIds.SET_BUYBACK_TWAP`
    /// permission from the owner.
    /// @param projectId The ID of the project to set the TWAP slippage tolerance of.
    /// @param newSlippageTolerance The new TWAP slippage tolerance, out of `TWAP_SLIPPAGE_DENOMINATOR`.
    function setTwapSlippageToleranceOf(uint256 projectId, uint256 newSlippageTolerance) external {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_BUYBACK_TWAP
        });

        // Make sure the provided TWAP slippage tolerance is within reasonable bounds.
        if (newSlippageTolerance < MIN_TWAP_SLIPPAGE_TOLERANCE || newSlippageTolerance > MAX_TWAP_SLIPPAGE_TOLERANCE) {
            revert InvalidTwapSlippageTolerance();
        }

        // Keep a reference to the currently stored TWAP params.
        uint256 twapParams = twapParamsOf[projectId];

        // Keep a reference to the old TWAP slippage tolerance.
        uint256 oldSlippageTolerance = twapParams >> 128;

        // Store the new packed value of the TWAP params (with the updated tolerance).
        twapParamsOf[projectId] = newSlippageTolerance << 128 | ((twapParams << 128) >> 128);

        emit TwapSlippageToleranceChanged(projectId, oldSlippageTolerance, newSlippageTolerance, msg.sender);
    }

    //*********************************************************************//
    // ---------------------- internal functions ------------------------- //
    //*********************************************************************//

    /// @notice Get a quote based on the TWAP, using the TWAP window and slippage tolerance for the specified project.
    /// @param projectId The ID of the project which the swap is associated with.
    /// @param projectToken The project token being swapped for.
    /// @param amountIn The number of terminal tokens being used to swap.
    /// @param terminalToken The terminal token being paid in and used to swap.
    /// @return amountOut The minimum number of tokens to receive based on the TWAP and its params.
    function _getQuote(
        uint256 projectId,
        address projectToken,
        uint256 amountIn,
        address terminalToken
    )
        internal
        view
        returns (uint256 amountOut)
    {
        // Get a reference to the pool that'll be used to make the swap.
        IUniswapV3Pool pool = poolOf[projectId][address(terminalToken)];

        // Make sure the pool exists, if not, return an empty quote.
        if (address(pool).code.length == 0) return 0;

        // If there is a contract at the address, try to get the pool's slot 0.
        try pool.slot0() returns (uint160, int24, uint16, uint16, uint16, uint8, bool unlocked) {
            // If the pool hasn't been initialized, return an empty quote.
            if (!unlocked) return 0;
        } catch {
            // If the address is invalid, return an empty quote.
            return 0;
        }

        // Unpack the TWAP params and get a reference to the period and slippage.
        uint256 twapParams = twapParamsOf[projectId];
        uint32 twapWindow = uint32(twapParams);
        uint256 twapSlippageTolerance = twapParams >> 128;

        // Keep a reference to the TWAP tick.
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(pool), twapWindow);

        // Get a quote based on this TWAP tick.
        amountOut = OracleLibrary.getQuoteAtTick({
            tick: arithmeticMeanTick,
            baseAmount: uint128(amountIn),
            baseToken: terminalToken,
            quoteToken: address(projectToken)
        });

        // Return the lowest acceptable return based on the TWAP and its parameters.
        amountOut -= (amountOut * twapSlippageTolerance) / TWAP_SLIPPAGE_DENOMINATOR;
    }

    /// @notice Swap the terminal token to receive project tokens.
    /// @param context The `afterPayRecordedContext` passed in by the terminal.
    /// @param projectTokenIs0 A flag indicating whether the pool references the project token as the first in the pair.
    /// @return amountReceived The amount of project tokens received from the swap.
    function _swap(
        JBAfterPayRecordedContext calldata context,
        bool projectTokenIs0
    )
        internal
        returns (uint256 amountReceived)
    {
        // The number of terminal tokens being used for the swap.
        uint256 amountToSwapWith = context.forwardedAmount.value;

        // Get the terminal token. Use wETH if the terminal token is the native token.
        address terminalTokenWithWETH =
            context.forwardedAmount.token == JBConstants.NATIVE_TOKEN ? address(WETH) : context.forwardedAmount.token;

        // Get a reference to the pool that'll be used to make the swap.
        IUniswapV3Pool pool = poolOf[context.projectId][terminalTokenWithWETH];

        // Try swapping.
        try pool.swap({
            recipient: address(this),
            zeroForOne: !projectTokenIs0,
            amountSpecified: int256(amountToSwapWith),
            sqrtPriceLimitX96: projectTokenIs0 ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
            data: abi.encode(context.projectId, context.forwardedAmount.token)
        }) returns (int256 amount0, int256 amount1) {
            // If the swap succeded, take note of the amount of tokens received.
            // This will be returned as a negative value, which Uniswap uses to represent the outputs of exact input
            // swaps.
            amountReceived = uint256(-(projectTokenIs0 ? amount0 : amount1));
        } catch {
            // If the swap failed, return.
            return 0;
        }

        // Burn the whole amount received.
        CONTROLLER.burnTokensOf({
            holder: address(this),
            projectId: context.projectId,
            tokenCount: amountReceived,
            memo: ""
        });

        // Return the amount we received/burned, which we will mint to the beneficiary later.
        emit Swap(context.projectId, amountToSwapWith, pool, amountReceived, msg.sender);
    }
}
