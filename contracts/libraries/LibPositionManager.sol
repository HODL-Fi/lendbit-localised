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

        emit PositionIdTransferred(_positionId, _oldAddress, _newAddress);
    }

    /// @notice Marks `_user` as whitelisted.
    function _whitelistAddress(LibAppStorage.StorageLayout storage s, address _user) internal {
        s.isWhitelisted[_user] = true;
    }

    /// @notice Removes `_user` from the whitelist.
    function _blacklistAddress(LibAppStorage.StorageLayout storage s, address _user) internal {
        s.isWhitelisted[_user] = false;
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
