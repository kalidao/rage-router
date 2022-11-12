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

    error InvalidSig();

    /// -----------------------------------------------------------------------
    /// Ragequit Storage
    /// -----------------------------------------------------------------------

    mapping(address => Redemption) public redemptions;

    /// -----------------------------------------------------------------------
    /// EIP-712 Storage/Logic
    /// -----------------------------------------------------------------------

    uint256 internal immutable INITIAL_CHAIN_ID;

    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    bytes32 internal constant MALLEABILITY_THRESHOLD =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    mapping(address => uint256) public nonces;

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return
            block.chainid == INITIAL_CHAIN_ID
                ? INITIAL_DOMAIN_SEPARATOR
                : _computeDomainSeparator();
    }

    function _computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes("Rage Router")),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor() payable {
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    /// -----------------------------------------------------------------------
    /// Configuration Logic
    /// -----------------------------------------------------------------------

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

    /// -----------------------------------------------------------------------
    /// Ragequit Signature Logic
    /// -----------------------------------------------------------------------

    /// @notice Allows ragequit redemption against `treasury`.
    /// @param treasury The vault holding `assets` for redemption.
    /// @param withdrawals Withdrawal instructions for `treasury`.
    /// @param quitAmount The amount of redemption tokens to be burned.
    /// @dev `quitAmount` acts as the token ID where redemption is ERC721.
    /// @param v Must produce valid secp256k1 signature from the `owner` along with `r` and `s`.
    /// @param r Must produce valid secp256k1 signature from the `owner` along with `v` and `s`.
    /// @param s Must produce valid secp256k1 signature from the `owner` along with `r` and `v`.
    function ragequitBySig(
        address redeemer,
        address treasury,
        Withdrawal[] calldata withdrawals,
        uint256 quitAmount,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public payable virtual nonReentrant {
        Redemption storage red = redemptions[treasury];

        if (block.timestamp < red.start) revert NotStarted();

        // Unchecked because the only math done is incrementing
        // the redeemer's nonce which cannot realistically overflow.
        unchecked {
            bytes32 hash = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "Ragequit(address treasury,Withdrawal withdrawals,uint256 quitAmount,uint256 nonce)"
                            ),
                            treasury,
                            withdrawals,
                            quitAmount,
                            nonces[redeemer]++
                        )
                    )
                )
            );

            // Check signature recovery.
            _recoverSig(hash, redeemer, v, r, s);
        }

        emit Ragequit(redeemer, treasury, withdrawals, quitAmount);

        uint256 supply;

        // Branch on `Standard` of `token` burned in redemption
        // and whether `burner` is zero address.
        if (red.std == Standard.ERC20) {
            if (red.burner == address(0)) {
                supply = TokenSupply(red.token).totalSupply();

                TokenBurn(red.token).burnFrom(redeemer, quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(red.token).totalSupply() -
                        TokenSupply(red.token).balanceOf(red.burner);
                }

                safeTransferFrom(red.token, redeemer, red.burner, quitAmount);
            }
        } else if (red.std == Standard.ERC721) {
            // Use `quitAmount` as `id`.
            if (redeemer != TokenSupply(red.token).ownerOf(quitAmount))
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

                safeTransferFrom(red.token, redeemer, red.burner, quitAmount);
            }

            // Overwrite `quitAmount` `id` to 1 for single NFT burn.
            quitAmount = 1;
        } else {
            if (red.burner == address(0)) {
                supply = TokenSupply(red.token).totalSupply(red.id);

                TokenBurn(red.token).burn(redeemer, red.id, quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(red.token).totalSupply(red.id) -
                        TokenSupply(red.token).balanceOf(red.burner, red.id);
                }

                ERC1155STF(red.token).safeTransferFrom(
                    redeemer,
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
                        redeemer,
                        amountToRedeem
                    )
                    : ERC1155STF(draw.asset).safeTransferFrom(
                        treasury,
                        redeemer,
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

    function _recoverSig(
        bytes32 hash,
        address redeemer,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view virtual {
        address signer;

        // Perform signature recovery via ecrecover.
        assembly {
            // Copy the free memory pointer so that we can restore it later.
            let m := mload(0x40)

            // If `s` in lower half order, such that the signature is not malleable.
            if iszero(gt(s, MALLEABILITY_THRESHOLD)) {
                mstore(0x00, hash)
                mstore(0x20, v)
                mstore(0x40, r)
                mstore(0x60, s)
                pop(
                    staticcall(
                        gas(), // Amount of gas left for the transaction.
                        0x01, // Address of `ecrecover`.
                        0x00, // Start of input.
                        0x80, // Size of input.
                        0x40, // Start of output.
                        0x20 // Size of output.
                    )
                )
                // Restore the zero slot.
                mstore(0x60, 0)
                // `returndatasize()` will be `0x20` upon success, and `0x00` otherwise.
                signer := mload(sub(0x60, returndatasize()))
            }
            // Restore the free memory pointer.
            mstore(0x40, m)
        }

        // If recovery doesn't match `redeemer`, verify contract signature with ERC1271.
        if (redeemer != signer) {
            bool valid;

            assembly {
                // Load the free memory pointer.
                // Simply using the free memory usually costs less if many slots are needed.
                let m := mload(0x40)

                // `bytes4(keccak256("isValidSignature(bytes32,bytes)"))`.
                let f := shl(224, 0x1626ba7e)
                // Write the abi-encoded calldata into memory, beginning with the function selector.
                mstore(m, f) // `bytes4(keccak256("isValidSignature(bytes32,bytes)"))`.
                mstore(add(m, 0x04), hash)
                mstore(add(m, 0x24), 0x40) // The offset of the `signature` in the calldata.
                mstore(add(m, 0x44), 65) // Store the length of the signature.
                mstore(add(m, 0x64), r) // Store `r` of the signature.
                mstore(add(m, 0x84), s) // Store `s` of the signature.
                mstore8(add(m, 0xa4), v) // Store `v` of the signature.

                valid := and(
                    and(
                        // Whether the returndata is the magic value `0x1626ba7e` (left-aligned).
                        eq(mload(0x00), f),
                        // Whether the returndata is exactly 0x20 bytes (1 word) long.
                        eq(returndatasize(), 0x20)
                    ),
                    // Whether the staticcall does not revert.
                    // This must be placed at the end of the `and` clause,
                    // as the arguments are evaluated from right to left.
                    staticcall(
                        gas(), // Remaining gas.
                        redeemer, // The `redeemer` address.
                        m, // Offset of calldata in memory.
                        0xa5, // Length of calldata in memory.
                        0x00, // Offset of returndata.
                        0x20 // Length of returndata to write.
                    )
                )
            }

            if (!valid) revert InvalidSig();
        }
    }
}
