// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Interface for ERC1155 safeTransferFrom.
interface IERC1155STF {
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;
}
