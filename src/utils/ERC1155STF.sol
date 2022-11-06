// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Contract helper for ERC1155 safeTransferFrom.
abstract contract ERC1155STF {
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) public virtual;
}
