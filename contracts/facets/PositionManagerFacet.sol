// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPositionManager} from "../libraries/LibPositionManager.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

import {UNAUTHORIZED_POSITION_CREATION, NOT_WHITELISTER} from "../models/Error.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

/// @title PositionManagerFacet — position creation, ownership transfer, and whitelist administration
contract PositionManagerFacet is SecurityBase {
    using LibPositionManager for LibAppStorage.StorageLayout;

    /// @notice Create a new position for a whitelisted user; reverts if the user already owns a position.
    /// @dev Restricted to the user themselves or the security council. An arbitrary
    ///      caller could otherwise pre-create a whitelisted victim's single position
    ///      slot, blocking that victim from accepting a pending position transfer
    ///      (report 2026-07-02 18:17 #9). Self-service and council-run onboarding are
    ///      both preserved; the deposit paths still auto-create for the depositor.
    /// @param _user The address to create a position for
    /// @return The newly created position ID
    function createPositionFor(address _user) external returns (uint256) {
        if (msg.sender != _user && msg.sender != LibDiamond.contractOwner()) {
            revert UNAUTHORIZED_POSITION_CREATION(msg.sender);
        }
        return LibPositionManager._createPositionFor(LibAppStorage.appStorage(), _user);
    }

    /// @notice Propose transferring the caller's position to a new address (step 1 of 2). Ownership does not move until the recipient calls `acceptPositionTransfer`; both addresses must be whitelisted and the new address must not already own a position.
    /// @param _newAddress The address proposed to receive the caller's position
    /// @return _positionId The position proposed for transfer
    function transferPositionOwnership(address _newAddress) external returns (uint256 _positionId) {
        _positionId = LibPositionManager._initiatePositionTransfer(LibAppStorage.appStorage(), msg.sender, _newAddress);
    }

    /// @notice Accept a pending position transfer addressed to the caller (step 2 of 2), pulling ownership of the position and its attached debt/collateral.
    /// @param _positionId The position to accept
    /// @return The transferred position ID
    function acceptPositionTransfer(uint256 _positionId) external returns (uint256) {
        return LibPositionManager._acceptPositionTransfer(LibAppStorage.appStorage(), _positionId, msg.sender);
    }

    /// @notice Cancel a pending transfer proposal for the caller's position.
    /// @return The position whose proposal was cleared
    function cancelPositionTransfer() external returns (uint256) {
        return LibPositionManager._cancelPositionTransfer(LibAppStorage.appStorage(), msg.sender);
    }

    /// @notice Force-transfer a position from its current owner to a new address (only security council), resolving the current owner from the position ID.
    /// @param _positionId The position to transfer
    /// @param _newAddress The address to receive the position
    /// @return The transferred position ID
    function adminForceTransferPositionOwnership(uint256 _positionId, address _newAddress)
        external
        onlySecurityCouncil
        returns (uint256)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        address _user = s._getUserForPositionId(_positionId);
        _positionId = s._transferPositionId(_user, _newAddress);
        return _positionId;
    }

    /// @notice Add an address to the whitelist, permitting it to interact with the protocol.
    /// @dev Callable by the security council OR a delegated whitelister (e.g. an
    ///      automated onboarding backend). Delegating to a hot key is safe because
    ///      whitelisting CANNOT reverse a council blacklist: `_whitelistAddress`
    ///      reverts on any address carrying the council tombstone (#M-05). Only the
    ///      council can clear that tombstone (`unblacklistAddress`). Blacklisting
    ///      itself is NOT delegated (see `blacklistAddress`).
    /// @param _user The address to whitelist
    function whitelistAddress(address _user) external {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        if (msg.sender != LibDiamond.contractOwner() && !s.s_isWhitelister[msg.sender]) {
            revert NOT_WHITELISTER(msg.sender);
        }
        LibPositionManager._whitelistAddress(s, _user);
    }

    /// @notice Remove an address from the whitelist and set the council blacklist
    ///         tombstone (only security council).
    /// @dev NOT delegated to whitelisters: a blacklist freezes the user's deposits,
    ///      borrows, collateral, yield claims, and vault withdrawals, so its blast
    ///      radius is kept off any automated hot key. The tombstone additionally
    ///      prevents the whitelister path from silently re-admitting the user (#M-05).
    /// @param _user The address to blacklist
    function blacklistAddress(address _user) external onlySecurityCouncil {
        LibPositionManager._blacklistAddress(LibAppStorage.appStorage(), _user);
    }

    /// @notice Clear the council blacklist tombstone for `_user` (only security council).
    /// @dev Does NOT re-whitelist. Re-admission is a separate, deliberate
    ///      `whitelistAddress` call after the tombstone is cleared, keeping the
    ///      asymmetric council-only reversal explicit (#M-05).
    /// @param _user The address to un-blacklist
    function unblacklistAddress(address _user) external onlySecurityCouncil {
        LibPositionManager._unblacklistAddress(LibAppStorage.appStorage(), _user);
    }

    /// @notice Grant or revoke the delegated whitelister capability (only security council).
    /// @param _user The address whose whitelister status is set
    /// @param _status True to grant, false to revoke
    function setWhitelister(address _user, bool _status) external onlySecurityCouncil {
        LibPositionManager._setWhitelister(LibAppStorage.appStorage(), _user, _status);
    }

    /// @notice Return whether an address holds the delegated whitelister capability.
    /// @param _user The address to check
    /// @return True if the address is a whitelister
    function isWhitelister(address _user) external view returns (bool) {
        return LibPositionManager._isWhitelister(LibAppStorage.appStorage(), _user);
    }

    /// @notice Set the trusted signer whose signature authorizes cross-chain borrow requests (only security council).
    /// @param _signer The new request-borrow signer address
    function setRequestBorrowSigner(address _signer) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s.s_requestBorrowSigner = _signer;
    }

    // Getter functions

    /// @notice Return the position ID that the next created position will receive.
    /// @return The next position ID
    function getNextPositionId() external view returns (uint256) {
        return LibPositionManager._getNextPositionId(LibAppStorage.appStorage());
    }

    /// @notice Return the position ID owned by a given user, or zero if none.
    /// @param _user The user address to look up
    /// @return The user's position ID (zero if the user owns no position)
    function getPositionIdForUser(address _user) external view returns (uint256) {
        return LibPositionManager._getPositionIdForUser(LibAppStorage.appStorage(), _user);
    }

    /// @notice Return the owner address of a given position ID.
    /// @param _positionId The position ID to look up
    /// @return The position owner's address
    function getUserForPositionId(uint256 _positionId) external view returns (address) {
        return LibPositionManager._getUserForPositionId(LibAppStorage.appStorage(), _positionId);
    }

    /// @notice Return the pending recipient of a position transfer, or zero if none is pending.
    /// @param _positionId The position ID to look up
    /// @return The proposed recipient address (zero if no pending transfer)
    function getPendingPositionTransfer(uint256 _positionId) external view returns (address) {
        return LibPositionManager._getPendingPositionTransfer(LibAppStorage.appStorage(), _positionId);
    }

    /// @notice Return the currently configured cross-chain borrow-request signer.
    /// @return The request-borrow signer address
    function getRequestBorrowSigner() external view returns (address) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_requestBorrowSigner;
    }
}
