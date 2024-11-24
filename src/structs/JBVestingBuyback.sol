// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member amount The amount of tokens to be streamed to the beneficiary.
/// @custom:member startsTime The start time of the vesting period.
/// @custom:member endTime The end time of the vesting period.
/// @custom:member lastClaimedAt The time at which the vested tokens were last claimed.
struct JBVestingBuyback {
    uint160 amount;
    uint48 startsAt;
    uint48 endsAt;
    uint48 lastClaimedAt;
}
