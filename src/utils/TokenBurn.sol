// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Contract helper for remote token (ERC20/721/1155) burns.
/// @dev These functions are opinionated to OpenZeppelin implementations.
abstract contract TokenBurn {
    /// @dev ERC20.
    function burnFrom(address from, uint256 amount) public virtual;

    /// @dev ERC721.
    function burn(uint256 id) public virtual;

    /// @dev ERC1155.
    function burn(address from, uint256 id, uint256 amount) public virtual;
}
