// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev Contract helpers.
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
    int88 trigger;
    Standard std;
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
        int88 trigger
    );

    event Ragequit(
        address indexed redeemer,
        address indexed treasury,
        address indexed token,
        uint256 id,
        Withdrawal[] withdrawals,
        uint256 quitAmount
    );

    /// -----------------------------------------------------------------------
    /// Custom Errors
    /// -----------------------------------------------------------------------

    error Triggered();

    error InvalidAssetOrder();

    error NotOwner();

    error InvalidSig();

    /// -----------------------------------------------------------------------
    /// Ragequit Storage
    /// -----------------------------------------------------------------------

    mapping(address => mapping(address => mapping(uint256 => Redemption)))
        public redemptions;

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
    /// @param token The redemption asset that will be burnt.
    /// @param std The EIP interface for the redemption `token`.
    /// @param id The ID to set redemption configuration against.
    /// @param trigger The unix time at which redemption triggers.
    /// @dev The caller of this function will be set as the `treasury`.
    /// If `burner` is zero address, ragequit will trigger `token` burn.
    /// Otherwise, the user will have `token` pulled to `burner` and supply
    /// will be calculated with respect to `burner` balance before ragequit.
    /// `id` will be used if the `token` follows ERC1155 std. Kali slays Moloch.
    /// If negative `trigger`, it will be understood as deadline rather than start.
    function setRagequit(
        address burner,
        address token,
        Standard std,
        uint256 id,
        int88 trigger
    ) public payable virtual {
        redemptions[msg.sender][token][id] = Redemption({
            burner: burner,
            trigger: trigger,
            std: std
        });

        emit RagequitSet(msg.sender, burner, token, std, id, trigger);
    }

    /// -----------------------------------------------------------------------
    /// Configuration Signature Logic
    /// -----------------------------------------------------------------------

    /// @notice Configuration for ragequittable treasuries.
    /// @param treasury The vault with redemption 'assets'.
    /// @param burner The redemption sink for burnt `token`.
    /// @param token The redemption asset that will be burnt.
    /// @param std The EIP interface for the redemption `token`.
    /// @param id The ID to set redemption configuration against.
    /// @param trigger The unix time at which redemption triggers.
    /// @param v Must produce valid secp256k1 signature from the `owner` along with `r` and `s`.
    /// @param r Must produce valid secp256k1 signature from the `owner` along with `v` and `s`.
    /// @param s Must produce valid secp256k1 signature from the `owner` along with `r` and `v`.
    function setRagequit(
        address treasury,
        address burner,
        address token,
        Standard std,
        uint256 id,
        int88 trigger,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public payable virtual nonReentrant {
        // Unchecked because the only math done is incrementing
        // the treasury's nonce which cannot realistically overflow.
        unchecked {
            bytes32 hash = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "SetRagequit(address burner,address token,uint8 std,uint256 id,int88 trigger,uint256 nonce)"
                            ),
                            burner,
                            token,
                            std,
                            id,
                            trigger,
                            nonces[treasury]++
                        )
                    )
                )
            );

            // Check signature recovery.
            _recoverSig(hash, treasury, v, r, s);
        }

        redemptions[treasury][token][id] = Redemption({
            burner: burner,
            trigger: trigger,
            std: std
        });

        emit RagequitSet(treasury, burner, token, std, id, trigger);
    }

    /// -----------------------------------------------------------------------
    /// Ragequit Logic
    /// -----------------------------------------------------------------------

    /// @notice Allows asset redemption against `treasury`.
    /// @param treasury The vault with redemption `assets`.
    /// @param token The redemption asset that will be burnt.
    /// @param id The ID set for the burn of the redemption asset.
    /// @param withdrawals Withdrawal instructions for `treasury`.
    /// @param quitAmount The amount of redemption asset to be burned.
    /// @dev `quitAmount` acts as the token ID where redemption is ERC721.
    function ragequit(
        address treasury,
        address token,
        uint256 id,
        Withdrawal[] calldata withdrawals,
        uint256 quitAmount
    ) public payable virtual nonReentrant {
        Redemption storage red = redemptions[treasury][token][id];

        if (
            red.trigger >= 0
                ? block.timestamp < uint88(red.trigger)
                : block.timestamp > uint88(red.trigger)
        ) revert Triggered();

        emit Ragequit(msg.sender, treasury, token, id, withdrawals, quitAmount);

        uint256 supply;

        // Branch on `Standard` of `token` burned in redemption
        // and whether `burner` is zero address.
        if (red.std == Standard.ERC20) {
            if (red.burner == address(0)) {
                supply = TokenSupply(token).totalSupply();

                TokenBurn(token).burnFrom(msg.sender, quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(token).totalSupply() -
                        TokenSupply(token).balanceOf(red.burner);
                }

                safeTransferFrom(token, msg.sender, red.burner, quitAmount);
            }
        } else if (red.std == Standard.ERC721) {
            // Use `quitAmount` as `id`.
            if (msg.sender != TokenSupply(token).ownerOf(quitAmount))
                revert NotOwner();

            if (red.burner == address(0)) {
                supply = TokenSupply(token).totalSupply();

                TokenBurn(token).burn(quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(token).totalSupply() -
                        TokenSupply(token).balanceOf(red.burner);
                }

                safeTransferFrom(token, msg.sender, red.burner, quitAmount);
            }

            // Overwrite `quitAmount` `id` to 1 for single NFT burn.
            quitAmount = 1;
        } else {
            if (red.burner == address(0)) {
                supply = TokenSupply(token).totalSupply(id);

                TokenBurn(token).burn(msg.sender, id, quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(token).totalSupply(id) -
                        TokenSupply(token).balanceOf(red.burner, id);
                }

                ERC1155STF(token).safeTransferFrom(
                    msg.sender,
                    red.burner,
                    id,
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
    /// @param treasury The vault with redemption `assets`.
    /// @param token The redemption asset that will be burnt.
    /// @param id The ID set for the burn of the redemption asset.
    /// @param withdrawals Withdrawal instructions for `treasury`.
    /// @param quitAmount The amount of redemption asset to be burned.
    /// @param v Must produce valid secp256k1 signature from the `owner` along with `r` and `s`.
    /// @param r Must produce valid secp256k1 signature from the `owner` along with `v` and `s`.
    /// @param s Must produce valid secp256k1 signature from the `owner` along with `r` and `v`.
    function ragequit(
        address redeemer,
        address treasury,
        address token,
        uint256 id,
        Withdrawal[] calldata withdrawals,
        uint256 quitAmount,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public payable virtual nonReentrant {
        Redemption storage red = redemptions[treasury][token][id];

        if (
            red.trigger >= 0
                ? block.timestamp < uint88(red.trigger)
                : block.timestamp > uint88(red.trigger)
        ) revert Triggered();

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
                                "Ragequit(address treasury,address token,uint256 id,Withdrawal withdrawals,uint256 quitAmount,uint256 nonce)"
                            ),
                            treasury,
                            token,
                            id,
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

        emit Ragequit(redeemer, treasury, token, id, withdrawals, quitAmount);

        uint256 supply;

        // Branch on `Standard` of `token` burned in redemption
        // and whether `burner` is zero address.
        if (red.std == Standard.ERC20) {
            if (red.burner == address(0)) {
                supply = TokenSupply(token).totalSupply();

                TokenBurn(token).burnFrom(redeemer, quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(token).totalSupply() -
                        TokenSupply(token).balanceOf(red.burner);
                }

                safeTransferFrom(token, redeemer, red.burner, quitAmount);
            }
        } else if (red.std == Standard.ERC721) {
            // Use `quitAmount` as `id`.
            if (redeemer != TokenSupply(token).ownerOf(quitAmount))
                revert NotOwner();

            if (red.burner == address(0)) {
                supply = TokenSupply(token).totalSupply();

                TokenBurn(token).burn(quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(token).totalSupply() -
                        TokenSupply(token).balanceOf(red.burner);
                }

                safeTransferFrom(token, redeemer, red.burner, quitAmount);
            }

            // Overwrite `quitAmount` `id` to 1 for single NFT burn.
            quitAmount = 1;
        } else {
            if (red.burner == address(0)) {
                supply = TokenSupply(token).totalSupply(id);

                TokenBurn(token).burn(redeemer, id, quitAmount);
            } else {
                // The `burner` balance cannot exceed total supply.
                unchecked {
                    supply =
                        TokenSupply(token).totalSupply(id) -
                        TokenSupply(token).balanceOf(red.burner, id);
                }

                ERC1155STF(token).safeTransferFrom(
                    redeemer,
                    red.burner,
                    id,
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
        address user,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view virtual {
        if (user == address(0)) revert InvalidSig();

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

        // If recovery doesn't match `user`, verify contract signature with ERC1271.
        if (user != signer) {
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
                        user, // The `user` address.
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
