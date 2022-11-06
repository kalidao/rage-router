// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Contract helper for fetching token (ERC20/721/1155) balances and supply.
abstract contract TokenSupply {
    /// @dev ERC20/721.

    function balanceOf(address account) public view virtual returns (uint256);

    function totalSupply() public view virtual returns (uint256);

    /// @dev ERC721.

    function ownerOf(uint256 id) public view virtual returns (address);

    /// @dev ERC1155.

    function balanceOf(
        address account,
        uint256 id
    ) public view virtual returns (uint256);

    function totalSupply(uint256 id) public view virtual returns (uint256);
}
