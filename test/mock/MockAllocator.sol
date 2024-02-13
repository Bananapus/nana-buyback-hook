// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "juice-contracts-v4/src/structs/JBSplitHookContext.sol";
import "juice-contracts-v4/src/structs/JBTokenAmount.sol";
import "juice-contracts-v4/src/interfaces/IJBPayHook.sol";
import "juice-contracts-v4/src/interfaces/IJBSplitHook.sol";

import "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";

contract MockSplitHook is ERC165, IJBSplitHook {
    IJBPayHook public immutable PAY_HOOK;

    constructor(IJBPayHook payHook) {
        PAY_HOOK = payHook;
    }

    function processSplitWith(JBSplitHookContext calldata) external payable override {
        JBAfterPayRecordedContext memory context = JBAfterPayRecordedContext(
            address(this),
            1,
            2,
            JBTokenAmount(address(this), 1 ether, 10 ** 18, 0),
            JBTokenAmount(address(this), 1 ether, 10 ** 18, 0),
            1,
            1,
            address(this),
            "",
            new bytes(0)
        );

        // Make a malicious delegate call to the buyback hook.
        (bool success,) =
            address(PAY_HOOK).delegatecall(abi.encodeWithSignature("afterPayRecordedWith(JBAfterPayRecordedContext)", context));
        assert(success);
    }

    function supportsInterface(bytes4 interfaceId) public view override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IJBSplitHook).interfaceId || super.supportsInterface(interfaceId);
    }
}
