// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @notice Interface for checking token (ERC20/721/1155) balance and supply.
interface ITokenBalanceSupply {
    /// @dev ERC20/721.

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    /// @dev ERC721.

    function ownerOf(uint256 id) external view returns (address);

    /// @dev ERC1155.

    function balanceOf(address account, uint256 id)
        external
        view
        returns (uint256);

    function totalSupply(uint256 id) external view returns (uint256);
}
