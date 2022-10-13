// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev Interfaces.
import {ITokenBalanceSupply} from "./interfaces/ITokenBalanceSupply.sol";
import {ITokenBurn} from "./interfaces/ITokenBurn.sol";

/// @dev Libraries.
import {mulDivDown} from "./utils/MulDivDown.sol";
import {safeTransferFrom} from "./utils/SafeTransferFrom.sol";

/// @dev Contracts.
import {Multicallable} from "./utils/Multicallable.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title Rage Router
/// @notice Fair share redemptions for treasury token (ERC20/721/1155) burns.
/// @dev Modified from Moloch Ventures (https://github.com/MolochVentures/moloch)

enum Standard {
    ERC20,
    ERC721,
    ERC1155
}

contract RageRouter is Multicallable, ReentrancyGuard {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event SetRedemption(
        address indexed treasury,
        address indexed token,
        uint256 id,
        uint256 start
    );

    event Redeem(
        address indexed redeemer,
        address indexed treasury,
        address[] assets,
        address indexed token,
        uint256 id,
        uint256 amount
    );

    /// -----------------------------------------------------------------------
    /// Custom Errors
    /// -----------------------------------------------------------------------

    error NotStarted();

    error InvalidAssetOrder();

    error NotIdOwner();

    /// -----------------------------------------------------------------------
    /// Storage
    /// -----------------------------------------------------------------------

    mapping(address => mapping(address => mapping(uint256 => uint256)))
        public redemptions;

    /// -----------------------------------------------------------------------
    /// Configuration Logic
    /// -----------------------------------------------------------------------

    /// @dev Gas savings.
    constructor() payable {}

    /// @notice Configuration for redeemable treasuries.
    /// @param token The redemption token that will be burnt.
    /// @param id The ID to set redemption configuration against.
    /// @param start The unix timestamp at which redemption starts.
    /// @dev The caller of this function will be set as the `treasury`.
    function setRedemption(
        address token,
        uint256 id,
        uint256 start
    ) public payable virtual {
        redemptions[msg.sender][token][id] = start;

        emit SetRedemption(msg.sender, token, id, start);
    }

    /// -----------------------------------------------------------------------
    /// Redemption Logic
    /// -----------------------------------------------------------------------

    function ragequit(
        address treasury,
        address[] calldata assets,
        address token,
        Standard std,
        uint256 id,
        uint256 amount
    ) public payable virtual nonReentrant {
        if (block.timestamp < redemptions[treasury][token][id])
            revert NotStarted();

        uint256 supply;

        // Branch on `Standard` of `token` burned in redemption.
        if (std == Standard.ERC20) {
            supply = ITokenBalanceSupply(token).totalSupply();

            ITokenBurn(token).burnFrom(msg.sender, amount);
        } else if (std == Standard.ERC721) {
            if (msg.sender != ITokenBalanceSupply(token).ownerOf(id))
                revert NotIdOwner();

            if (amount != 1) amount = 1;

            supply = ITokenBalanceSupply(token).totalSupply();

            ITokenBurn(token).burn(id);
        } else {
            supply = ITokenBalanceSupply(token).totalSupply(id);

            ITokenBurn(token).burn(msg.sender, id, amount);
        }

        address prevAddr;
        address asset;

        for (uint256 i; i < assets.length; ) {
            asset = assets[i];

            // Prevent null and duplicate `asset`.
            if (prevAddr >= asset) revert InvalidAssetOrder();

            prevAddr = asset;

            // Calculate fair share of given `asset` for `amount`.
            uint256 amountToRedeem = mulDivDown(
                amount,
                ITokenBalanceSupply(asset).balanceOf(treasury),
                supply
            );

            // Transfer fair share from `treasury` to caller.
            if (amountToRedeem != 0) {
                safeTransferFrom(asset, treasury, msg.sender, amountToRedeem);
            }

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
            }
        }

        emit Redeem(msg.sender, treasury, assets, token, id, amount);
    }
}
