// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibAppStorage} from "./LibAppStorage.sol";
import "../models/Error.sol";
import "../models/Event.sol";

library LibPositionManager {
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

    function _transferPositionId(LibAppStorage.StorageLayout storage s, address _oldAddress, address _newAddress)
        internal
        returns (uint256 _positionId)
    {
        _positionId = _validateUserExists(s, _oldAddress);
        _addressIsWhitelisted(s, _oldAddress);
        _addressIsWhitelisted(s, _newAddress);

        s.s_ownerPosition[_newAddress] = _positionId;
        s.s_positionOwner[_positionId] = _newAddress;

        delete s.s_ownerPosition[_oldAddress];
        delete s.isWhitelisted[_oldAddress];

        emit PositionIdTransferred(_positionId, _oldAddress, _newAddress);
    }

    function _whitelistAddress(LibAppStorage.StorageLayout storage s, address _user) internal {
        s.isWhitelisted[_user] = true;
    }

    function _blacklistAddress(LibAppStorage.StorageLayout storage s, address _user) internal {
        s.isWhitelisted[_user] = false;
    }

    function _userAddressExists(LibAppStorage.StorageLayout storage s, address _user) internal view returns (bool) {
        if (s.s_ownerPosition[_user] == 0) {
            return false;
        }
        return true;
    }

    function _getNextPositionId(LibAppStorage.StorageLayout storage s) internal view returns (uint256) {
        return s.s_nextPositionId + 1;
    }

    function _getPositionIdForUser(LibAppStorage.StorageLayout storage s, address _user)
        internal
        view
        returns (uint256)
    {
        return s.s_ownerPosition[_user];
    }

    function _getUserForPositionId(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (address)
    {
        return s.s_positionOwner[_positionId];
    }

    // Validators
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

    function _addressIsWhitelisted(LibAppStorage.StorageLayout storage s, address _user) internal view {
        if (!s.isWhitelisted[_user]) {
            revert ADDRESS_NOT_WHITELISTED(_user);
        }
    }
}
