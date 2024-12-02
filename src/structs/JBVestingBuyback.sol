// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member amount The amount of tokens to be streamed to the beneficiary.
/// @custom:member lastClaimedAt The time at which the vested tokens were last claimed.
/// @custom:member endTime The end time of the vesting period.
struct JBVestingBuyback {
    uint160 amount;
    uint48 lastClaimedAt;
    uint48 endsAt;
}
