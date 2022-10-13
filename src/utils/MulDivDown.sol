// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev Returns `floor(x * y / denominator)`.
/// Reverts if `x * y` overflows, or `denominator` is zero.
function mulDivDown(
    uint256 x,
    uint256 y,
    uint256 denominator
) pure returns (uint256 z) {
    assembly {
        // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
        if iszero(mul(denominator, iszero(mul(y, gt(x, div(not(0), y)))))) {
            // Store the function selector of `MulDivFailed()`.
            mstore(0x00, 0xad251c27)
            // Revert with (offset, size).
            revert(0x1c, 0x04)
        }
        z := div(mul(x, y), denominator)
    }
}
