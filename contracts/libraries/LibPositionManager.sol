// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "./LibAppStorage.sol";
import "../models/Error.sol";
import "../models/Event.sol";

/// @title LibPositionManager — Creates, transfers, and looks up user lending positions and their whitelist status
library LibPositionManager {
    /// @notice Creates a new position for a whitelisted `_user` that has no existing position and emits PositionIdCreated.
    /// @param _user The address to create a position for; must be whitelisted and not already own a position.
    /// @return The newly assigned position ID.
    function _createPositionFor(LibAppStorage.StorageLayout storage s, address _user) internal returns (uint256) {
        _addressIsWhitelisted(s, _user);
        if (_userAddressExists(s, _user)) revert ADDRESS_EXISTS(_user);
        uint256 _positionId = s.s_nextPositionId + 1;
        s.s_nextPositionId += 1;

        s.s_positionOwner[_positionId] = _user;
        s.s_ownerPosition[_user] = _positionId;

        emit PositionIdCreated(_positionId, _user);
        return _positionId;
    }

    /// @notice Moves an existing position from `_oldAddress` to `_newAddress`, clearing the old owner's mapping and whitelist, and emits PositionIdTransferred.
    /// @param _oldAddress The current owner; must exist and be whitelisted.
    /// @param _newAddress The new owner; must be whitelisted and not already own a position.
    /// @return _positionId The transferred position ID.
    function _transferPositionId(LibAppStorage.StorageLayout storage s, address _oldAddress, address _newAddress)
        internal
        returns (uint256 _positionId)
    {
        _positionId = _validateUserExists(s, _oldAddress);
        _addressIsWhitelisted(s, _oldAddress);
        _addressIsWhitelisted(s, _newAddress);
        if (_userAddressExists(s, _newAddress)) revert ADDRESS_EXISTS(_newAddress);

        s.s_ownerPosition[_newAddress] = _positionId;
        s.s_positionOwner[_positionId] = _newAddress;

        delete s.s_ownerPosition[_oldAddress];
        delete s.isWhitelisted[_oldAddress];
        // Any completed transfer (accepted pull OR admin force-transfer) clears a
        // stale pending proposal so it can never be replayed against a new owner.
        delete s.s_pendingPositionTransfer[_positionId];

        emit PositionIdTransferred(_positionId, _oldAddress, _newAddress);
    }

    /// @notice Step 1 of a two-step transfer: `_from` proposes handing its position to `_newAddress`.
    /// @dev Records the proposal only; ownership does not move until the recipient accepts. Both
    ///      addresses must be whitelisted and `_newAddress` must not already own a position. These
    ///      preconditions are re-checked at accept time, when they are authoritative.
    /// @param _from The current owner initiating the transfer (the caller).
    /// @param _newAddress The proposed recipient.
    /// @return _positionId The position proposed for transfer.
    function _initiatePositionTransfer(LibAppStorage.StorageLayout storage s, address _from, address _newAddress)
        internal
        returns (uint256 _positionId)
    {
        _positionId = _validateUserExists(s, _from);
        _addressIsWhitelisted(s, _from);
        _addressIsWhitelisted(s, _newAddress);
        if (_userAddressExists(s, _newAddress)) revert ADDRESS_EXISTS(_newAddress);

        s.s_pendingPositionTransfer[_positionId] = _newAddress;

        emit PositionTransferInitiated(_positionId, _from, _newAddress);
    }

    /// @notice Step 2 of a two-step transfer: the proposed recipient accepts and pulls the position.
    /// @dev Reverts unless a proposal for `_positionId` exists and names `_caller`. Delegates to
    ///      `_transferPositionId`, which re-validates all preconditions and clears the proposal.
    /// @param _positionId The position being accepted.
    /// @param _caller The recipient accepting the transfer (the caller).
    /// @return The transferred position ID.
    function _acceptPositionTransfer(LibAppStorage.StorageLayout storage s, uint256 _positionId, address _caller)
        internal
        returns (uint256)
    {
        address _pending = s.s_pendingPositionTransfer[_positionId];
        if (_pending == address(0)) revert NO_PENDING_TRANSFER(_positionId);
        if (_pending != _caller) revert NOT_PENDING_RECIPIENT(_caller);

        address _from = _getUserForPositionId(s, _positionId);
        return _transferPositionId(s, _from, _caller);
    }

    /// @notice Cancels a pending transfer proposal for the caller's position.
    /// @param _from The current owner cancelling the proposal (the caller).
    /// @return _positionId The position whose proposal was cleared.
    function _cancelPositionTransfer(LibAppStorage.StorageLayout storage s, address _from)
        internal
        returns (uint256 _positionId)
    {
        _positionId = _validateUserExists(s, _from);
        if (s.s_pendingPositionTransfer[_positionId] == address(0)) revert NO_PENDING_TRANSFER(_positionId);

        delete s.s_pendingPositionTransfer[_positionId];

        emit PositionTransferCancelled(_positionId, _from);
    }

    /// @notice Returns the pending recipient of a position transfer (address(0) if none).
    function _getPendingPositionTransfer(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (address)
    {
        return s.s_pendingPositionTransfer[_positionId];
    }

    /// @notice Marks `_user` as whitelisted.
    /// @dev Refuses to re-whitelist an address the council has blacklisted (#M-05).
    ///      Whitelisting is delegable to a hot-key whitelister, but blacklisting is
    ///      council-only; without this guard the whitelister path — or any stray
    ///      re-registration/backfill call — silently reverses a council blacklist.
    ///      The council clears the tombstone via `_unblacklistAddress` before any
    ///      re-admission.
    function _whitelistAddress(LibAppStorage.StorageLayout storage s, address _user) internal {
        if (s.s_blacklisted[_user]) revert ADDRESS_BLACKLISTED(_user);
        s.isWhitelisted[_user] = true;
    }

    /// @notice Blacklists `_user`: removes whitelist membership and sets the council
    ///         tombstone so the whitelister path cannot silently re-admit them.
    function _blacklistAddress(LibAppStorage.StorageLayout storage s, address _user) internal {
        s.isWhitelisted[_user] = false;
        s.s_blacklisted[_user] = true;
    }

    /// @notice Clears the council blacklist tombstone for `_user` (council-only at the
    ///         facet). Does NOT re-whitelist — re-admission is a separate, deliberate
    ///         `whitelistAddress` call.
    function _unblacklistAddress(LibAppStorage.StorageLayout storage s, address _user) internal {
        s.s_blacklisted[_user] = false;
    }

    /// @notice Returns whether `_user` carries the council blacklist tombstone.
    function _isBlacklisted(LibAppStorage.StorageLayout storage s, address _user) internal view returns (bool) {
        return s.s_blacklisted[_user];
    }

    /// @notice Grants or revokes the delegated whitelister capability for `_user`.
    /// @dev Council-gated at the facet. A whitelister may ADD users to the whitelist
    ///      (automated onboarding) but not blacklist — blacklisting stays council-only.
    function _setWhitelister(LibAppStorage.StorageLayout storage s, address _user, bool _status) internal {
        s.s_isWhitelister[_user] = _status;
        emit WhitelisterSet(_user, _status);
    }

    /// @notice Returns true if `_user` holds the delegated whitelister capability.
    function _isWhitelister(LibAppStorage.StorageLayout storage s, address _user) internal view returns (bool) {
        return s.s_isWhitelister[_user];
    }

    /// @notice Returns true if `_user` already owns a position.
    function _userAddressExists(LibAppStorage.StorageLayout storage s, address _user) internal view returns (bool) {
        if (s.s_ownerPosition[_user] == 0) {
            return false;
        }
        return true;
    }

    /// @notice Returns the position ID that would be assigned to the next created position.
    function _getNextPositionId(LibAppStorage.StorageLayout storage s) internal view returns (uint256) {
        return s.s_nextPositionId + 1;
    }

    /// @notice Returns the position ID owned by `_user` (0 if none).
    function _getPositionIdForUser(LibAppStorage.StorageLayout storage s, address _user)
        internal
        view
        returns (uint256)
    {
        return s.s_ownerPosition[_user];
    }

    /// @notice Returns the owner address of `_positionId`.
    function _getUserForPositionId(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (address)
    {
        return s.s_positionOwner[_positionId];
    }

    // Validators
    /// @notice Reverts with NO_POSITION_ID if `_user` owns no position; otherwise returns that position ID.
    /// @return _positionId The position ID owned by `_user`.
    function _validateUserExists(LibAppStorage.StorageLayout storage s, address _user)
        internal
        view
        returns (uint256 _positionId)
    {
        _positionId = _getPositionIdForUser(s, _user);
        if (_positionId == 0) {
            revert NO_POSITION_ID(_user);
        }
    }

    /// @notice Reverts with ADDRESS_NOT_WHITELISTED unless `_user` is whitelisted.
    function _addressIsWhitelisted(LibAppStorage.StorageLayout storage s, address _user) internal view {
        if (!s.isWhitelisted[_user]) {
            revert ADDRESS_NOT_WHITELISTED(_user);
        }
    }
}
