// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev Interfaces.
import {IERC1155STF} from "./interfaces/IERC1155STF.sol";
import {ITokenBurn} from "./interfaces/ITokenBurn.sol";
import {ITokenSupply} from "./interfaces/ITokenSupply.sol";

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

    event SetRagequit(
        address indexed treasury,
        address indexed burner,
        address indexed token,
        Standard std,
        uint256 id,
        uint256 start
    );

    event Ragequit(
        address indexed redeemer,
        address indexed treasury,
        address[] assets,
        uint256 amount
    );

    /// -----------------------------------------------------------------------
    /// Custom Errors
    /// -----------------------------------------------------------------------

    error NotStarted();

    error InvalidAssetOrder();

    error NotOwner();

    /// -----------------------------------------------------------------------
    /// Storage
    /// -----------------------------------------------------------------------

    mapping(address => Redemption) public redemptions;

    struct Redemption {
        address burner;
        address token;
        Standard std;
        uint256 id;
        uint256 start;
    }

    /// -----------------------------------------------------------------------
    /// Configuration Logic
    /// -----------------------------------------------------------------------

    /// @dev Gas savings.
    constructor() payable {}

    /// @notice Configuration for redeemable treasuries.
    /// @param burner The redemption sink for burnt token.
    /// @param token The redemption token that will be burnt.
    /// @param id The ID to set redemption configuration against.
    /// @param start The unix timestamp at which redemption starts.
    /// @dev The caller of this function will be set as the `treasury`.
    /// @dev If `burner` is zero, then normal ragequit will be triggered.
    function setRagequit(
        address burner,
        address token,
        Standard std,
        uint256 id,
        uint256 start
    ) public payable virtual {
        redemptions[msg.sender] = Redemption({
            burner: burner,
            token: token,
            std: std,
            id: id,
            start: start
        });

        emit SetRagequit(msg.sender, burner, token, std, id, start);
    }

    /// -----------------------------------------------------------------------
    /// Redemption Logic
    /// -----------------------------------------------------------------------

    function ragequit(
        address treasury,
        address[] calldata assets,
        uint256 amount
    ) public payable virtual nonReentrant {
        Redemption storage red = redemptions[treasury];

        if (block.timestamp < red.start) revert NotStarted();

        uint256 supply;

        // Branch on `Standard` of `token` burned in redemption.
        // If `burner` is zero, we burn - else, we transfer to `burner`.
        if (red.std == Standard.ERC20) {
            supply = ITokenSupply(red.token).totalSupply();

            if (red.burner == address(0)) {
                supply = ITokenSupply(red.token).totalSupply();

                ITokenBurn(red.token).burnFrom(msg.sender, amount);
            } else {
                supply =
                    ITokenSupply(red.token).totalSupply() -
                    ITokenSupply(red.token).balanceOf(red.burner);

                safeTransferFrom(red.token, msg.sender, red.burner, amount);
            }
        } else if (red.std == Standard.ERC721) {
            if (msg.sender != ITokenSupply(red.token).ownerOf(red.id))
                revert NotOwner();

            if (amount != 1) amount = 1;

            if (red.burner == address(0)) {
                supply = ITokenSupply(red.token).totalSupply();

                ITokenBurn(red.token).burn(red.id);
            } else {
                supply =
                    ITokenSupply(red.token).totalSupply() -
                    ITokenSupply(red.token).balanceOf(red.burner);

                safeTransferFrom(red.token, msg.sender, red.burner, red.id);
            }
        } else {
            if (red.burner == address(0)) {
                supply = ITokenSupply(red.token).totalSupply(red.id);

                ITokenBurn(red.token).burn(msg.sender, red.id, amount);
            } else {
                supply =
                    ITokenSupply(red.token).totalSupply(red.id) -
                    ITokenSupply(red.token).balanceOf(red.burner, red.id);

                IERC1155STF(red.token).safeTransferFrom(
                    msg.sender,
                    red.burner,
                    red.id,
                    amount,
                    ""
                );
            }
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
                ITokenSupply(asset).balanceOf(treasury),
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

        emit Ragequit(msg.sender, treasury, assets, amount);
    }
}
