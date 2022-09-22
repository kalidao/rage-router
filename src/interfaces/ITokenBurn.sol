// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Interface for remote token (ERC20/721/1155) burn.
interface ITokenBurn {
    /// @dev ERC20.

    function burn(address from, uint256 amount) external;

    function burnFrom(address from, uint256 amount) external;

    /// @dev ERC721.

    function burn(uint256 id) external;

    /// @dev ERC1155.

    function burn(
        address from,
        uint256 id,
        uint256 amount
    ) external;

    function burnBatch(
        address from,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external;
}
