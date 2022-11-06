// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev Contract Helpers.
import {ERC1155STF} from "./utils/ERC1155STF.sol";
import {TokenBurn} from "./utils/TokenBurn.sol";
import {TokenSupply} from "./utils/TokenSupply.sol";

/// @dev Free functions.
import {mulDivDown} from "@solbase/src/utils/FixedPointMath.sol";
import {safeTransferFrom} from "@solbase/src/utils/SafeTransfer.sol";

/// @dev Contracts.
import {SelfPermit} from "@solbase/src/utils/SelfPermit.sol";
import {Multicallable} from "@solbase/src/utils/Multicallable.sol";
import {ReentrancyGuard} from "@solbase/src/utils/ReentrancyGuard.sol";

/// @title Rage Router
/// @notice Fair share ragequit redemption for any token burn.

enum Standard {
    ERC20,
    ERC721,
    ERC1155
}

struct Redemption {
    address burner;
    address token;
    uint88 start;
    Standard std;
    uint256 id;
}

struct Withdrawal {
    address asset;
    Standard std;
    uint256 id;
}

/// @author z0r0z.eth
/// @custom:coauthor ameen.eth
/// @custom:coauthor mick.eth
contract RageRouter is SelfPermit, Multicallable, ReentrancyGuard {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event RagequitSet(
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
        Withdrawal[] withdrawals,
        uint256 amount
    );

    /// -----------------------------------------------------------------------
    /// Custom Errors
    /// -----------------------------------------------------------------------

    error NotStarted();

    error InvalidAssetOrder();

    error NotOwner();

    /// -----------------------------------------------------------------------
    /// Ragequit Storage
    /// -----------------------------------------------------------------------

    mapping(address => Redemption) public redemptions;

    /// -----------------------------------------------------------------------
    /// Configuration Logic
    /// -----------------------------------------------------------------------

    /// @dev Gas savings.
    constructor() payable {}

    /// @notice Configuration for ragequittable treasuries.
    /// @param burner The redemption sink for burnt `token`.
    /// @param token The redemption `token` that will be burnt.
    /// @param std The EIP interface for the redemption `token`.
    /// @param id The ID to set redemption configuration against.
    /// @param start The unix timestamp at which redemption starts.
    /// @dev The caller of this function will be set as the `treasury`.
    /// If `burner` is zero address, ragequit will trigger `token` burn.
    /// Otherwise, the user will have `token` pulled to `burner` and supply
    /// will be calculated with respect to `burner` balance before ragequit.
    /// `id` will be used if the `token` follows ERC1155 std. Kali slays Moloch.
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

        emit RagequitSet(msg.sender, burner, token, std, id, start);
    }

    /// -----------------------------------------------------------------------
    /// Ragequit Logic
    /// -----------------------------------------------------------------------

    /// @notice Allows ragequit redemption against `treasury`.
    /// @param treasury The vault holding `assets` for redemption.
    /// @param withdrawals Withdrawal instructions for `treasury`.
    /// @param quitAmount The amount of redemption tokens to be burned.
    /// @dev `quitAmount` acts as the token ID where redemption is ERC721.
    function ragequit(
        address treasury,
        Withdrawal[] calldata withdrawals,
        uint256 quitAmount
    ) public payable virtual nonReentrant {
        Redemption storage red = redemptions[treasury];

        if (block.timestamp < red.start) revert NotStarted();

        emit Ragequit(msg.sender, treasury, withdrawals, quitAmount);

        uint256 supply;

        // Branch on `Standard` of `token` burned in redemption
        // and whether `burner` is zero address.
        if (red.std == Standard.ERC20) {
            if (red.burner == address(0)) {
                supply = TokenSupply(red.token).totalSupply();

                TokenBurn(red.token).burnFrom(msg.sender, quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(red.token).totalSupply() -
                        TokenSupply(red.token).balanceOf(red.burner);
                }

                safeTransferFrom(red.token, msg.sender, red.burner, quitAmount);
            }
        } else if (red.std == Standard.ERC721) {
            // Use `quitAmount` as `id`.
            if (msg.sender != TokenSupply(red.token).ownerOf(quitAmount))
                revert NotOwner();

            if (red.burner == address(0)) {
                supply = TokenSupply(red.token).totalSupply();

                TokenBurn(red.token).burn(quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(red.token).totalSupply() -
                        TokenSupply(red.token).balanceOf(red.burner);
                }

                safeTransferFrom(red.token, msg.sender, red.burner, quitAmount);
            }

            // Overwrite `quitAmount` `id` to 1 for single NFT burn.
            quitAmount = 1;
        } else {
            if (red.burner == address(0)) {
                supply = TokenSupply(red.token).totalSupply(red.id);

                TokenBurn(red.token).burn(msg.sender, red.id, quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(red.token).totalSupply(red.id) -
                        TokenSupply(red.token).balanceOf(red.burner, red.id);
                }

                ERC1155STF(red.token).safeTransferFrom(
                    msg.sender,
                    red.burner,
                    red.id,
                    quitAmount,
                    ""
                );
            }
        }

        address prevAddr;
        Withdrawal calldata draw;

        for (uint256 i; i < withdrawals.length; ) {
            draw = withdrawals[i];

            // Prevent null and duplicate `asset`.
            if (prevAddr >= draw.asset) revert InvalidAssetOrder();

            prevAddr = draw.asset;

            // Calculate fair share of given `asset` for `quitAmount`.
            uint256 amountToRedeem = mulDivDown(
                quitAmount,
                draw.std == Standard.ERC20
                    ? TokenSupply(draw.asset).balanceOf(treasury)
                    : TokenSupply(draw.asset).balanceOf(treasury, draw.id),
                supply
            );

            // Transfer fair share from `treasury` to caller.
            if (amountToRedeem != 0) {
                draw.std == Standard.ERC20
                    ? safeTransferFrom(
                        draw.asset,
                        treasury,
                        msg.sender,
                        amountToRedeem
                    )
                    : ERC1155STF(draw.asset).safeTransferFrom(
                        treasury,
                        msg.sender,
                        draw.id,
                        amountToRedeem,
                        ""
                    );
            }

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
            }
        }
    }
}
