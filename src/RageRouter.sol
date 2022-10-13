// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev Interfaces.
import {IERC1155STF} from "./interfaces/IERC1155STF.sol";
import {ITokenBurn} from "./interfaces/ITokenBurn.sol";
import {ITokenSupply} from "./interfaces/ITokenSupply.sol";

/// @dev Free functions.
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
        uint88 start;
        Standard std;
        uint256 id;
    }

    /// -----------------------------------------------------------------------
    /// Configuration Logic
    /// -----------------------------------------------------------------------

    /// @dev Gas savings.
    constructor() payable {}

    /// @notice Configuration for redeemable treasuries.
    /// @param burner The redemption sink for burnt `token`.
    /// @param token The redemption `token` that will be burnt.
    /// @param std The EIP interface for the redemption `token`.
    /// @param id The ID to set redemption configuration against.
    /// @dev `id` will be used if the `token` follows ERC721/1155.
    /// @param start The unix timestamp at which redemption starts.
    /// @dev The caller of this function will be set as the `treasury`.
    /// @dev If `burner` is zero, ragequit will trigger the `token` burn.
    /// Otherwise, the user will have `token` pulled to `burner` and supply
    /// will be calculated with respect to `burner` balance before ragequit.
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
            start: uint88(start),
            std: std,
            id: id
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

        // Branch on `Standard` of `token` burned in redemption
        // and whether `burner` is zero address.
        if (red.std == Standard.ERC20) {
            if (red.burner == address(0)) {
                supply = ITokenSupply(red.token).totalSupply();

                ITokenBurn(red.token).burnFrom(msg.sender, amount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        ITokenSupply(red.token).totalSupply() -
                        ITokenSupply(red.token).balanceOf(red.burner);
                }

                safeTransferFrom(red.token, msg.sender, red.burner, amount);
            }
        } else if (red.std == Standard.ERC721) {
            // We ensure that user passes in single NFT as `amount`.
            // This prevents gaming the ratio by burning NFT and spoofing
            // greater share from total.
            if (amount != 1) amount = 1;

            if (red.burner == address(0)) {
                supply = ITokenSupply(red.token).totalSupply();

                ITokenBurn(red.token).burn(red.id);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        ITokenSupply(red.token).totalSupply() -
                        ITokenSupply(red.token).balanceOf(red.burner);
                }

                safeTransferFrom(red.token, msg.sender, red.burner, red.id);
            }
        } else {
            if (red.burner == address(0)) {
                supply = ITokenSupply(red.token).totalSupply(red.id);

                ITokenBurn(red.token).burn(msg.sender, red.id, amount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        ITokenSupply(red.token).totalSupply(red.id) -
                        ITokenSupply(red.token).balanceOf(red.burner, red.id);
                }

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
