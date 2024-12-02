// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBController} from "@bananapus/core/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core/src/interfaces/IJBPayHook.sol";
import {IJBPrices} from "@bananapus/core/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core/src/interfaces/IJBRulesetDataHook.sol";
import {IJBToken} from "@bananapus/core/src/interfaces/IJBToken.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import {IWETH9} from "./external/IWETH9.sol";
import {JBVestedBuybackClaims} from "../structs/JBVestedBuybackClaims.sol";

interface IJBBuybackHook is IJBPayHook, IJBRulesetDataHook, IUniswapV3SwapCallback {
    event Swap(
        uint256 indexed projectId, uint256 amountToSwapWith, IUniswapV3Pool pool, uint256 amountReceived, address caller
    );
    event Mint(uint256 indexed projectId, uint256 leftoverAmount, uint256 tokenCount, address caller);
    event PoolAdded(uint256 indexed projectId, address indexed terminalToken, address pool, address caller);
    event StartVestingBuyback(
        uint256 indexed projectId,
        address indexed beneficiary,
        uint256 indexed index,
        uint256 amount,
        uint256 startsAt,
        uint256 endsAt,
        address caller
    );
    event TwapWindowChanged(uint256 indexed projectId, uint256 oldWindow, uint256 newWindow, address caller);
    event TwapSlippageToleranceChanged(
        uint256 indexed projectId, uint256 oldTolerance, uint256 newTolerance, address caller
    );
    event ClaimVestedBuybacks(
        address indexed token,
        address indexed beneficiary,
        uint256 indexed index,
        uint256 amountVested,
        uint256 amountLeft,
        address caller
    );

    function CONTROLLER() external view returns (IJBController);
    function DIRECTORY() external view returns (IJBDirectory);
    function PRICES() external view returns (IJBPrices);
    function MAX_TWAP_SLIPPAGE_TOLERANCE() external view returns (uint256);
    function MIN_TWAP_SLIPPAGE_TOLERANCE() external view returns (uint256);
    function MAX_TWAP_WINDOW() external view returns (uint256);
    function MIN_TWAP_WINDOW() external view returns (uint256);
    function TWAP_SLIPPAGE_DENOMINATOR() external view returns (uint256);
    function PROJECTS() external view returns (IJBProjects);
    function UNISWAP_V3_FACTORY() external view returns (address);
    function WETH() external view returns (IWETH9);
    function VESTING_PERIOD() external view returns (uint256);

    function poolOf(uint256 projectId, address terminalToken) external view returns (IUniswapV3Pool pool);
    function projectTokenOf(uint256 projectId) external view returns (address projectTokenOf);
    function twapSlippageToleranceOf(uint256 projectId) external view returns (uint256 slippageTolerance);
    function twapWindowOf(uint256 projectId) external view returns (uint32 window);

    function claimVestedBuybacksFor(JBVestedBuybackClaims[] calldata claims) external;
    function claimVestedBuybacksFor(
        address token,
        address beneficiary,
        uint256[] calldata indices
    )
        external
        returns (uint256 amount);
    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        uint32 twapWindow,
        uint256 twapSlippageTolerance,
        address terminalToken
    )
        external
        returns (IUniswapV3Pool newPool);
    function setTwapSlippageToleranceOf(uint256 projectId, uint256 newSlippageTolerance) external;
    function setTwapWindowOf(uint256 projectId, uint32 newWindow) external;
}
