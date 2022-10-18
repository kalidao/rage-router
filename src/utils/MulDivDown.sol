// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

uint256 constant MAX_UINT256 = 2**256 - 1;

/// @dev Returns `floor(x * y / denominator)`.
/// Reverts if `x * y` overflows, or `denominator` is zero.
function mulDivDown(
    uint256 x,
    uint256 y,
    uint256 denominator
) pure returns (uint256 z) {
    assembly {
        // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
        if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
            revert(0, 0)
        }

        // Divide x * y by the denominator.
        z := div(mul(x, y), denominator)
    }
}
