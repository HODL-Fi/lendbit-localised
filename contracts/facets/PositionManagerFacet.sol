// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPositionManager} from "../libraries/LibPositionManager.sol";

import "../models/Error.sol";

contract PositionManagerFacet {
    using LibPositionManager for LibAppStorage.StorageLayout;

    function createPositionFor(address _user) external returns (uint256) {
        return LibPositionManager._createPositionFor(LibAppStorage.appStorage(), _user);
    }

    function transferPositionOwnership(address _newAddress) external returns (uint256 _positionId) {
        _positionId = LibPositionManager._transferPositionId(LibAppStorage.appStorage(), msg.sender, _newAddress);
    }

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

    function whitelistAddress(address _user) external onlySecurityCouncil {
        LibPositionManager._whitelistAddress(LibAppStorage.appStorage(), _user);
    }

    function blacklistAddress(address _user) external onlySecurityCouncil {
        LibPositionManager._blacklistAddress(LibAppStorage.appStorage(), _user);
    }

    // Getter functions

    function getNextPositionId() external view returns (uint256) {
        return LibPositionManager._getNextPositionId(LibAppStorage.appStorage());
    }

    function getPositionIdForUser(address _user) external view returns (uint256) {
        return LibPositionManager._getPositionIdForUser(LibAppStorage.appStorage(), _user);
    }

    function getUserForPositionId(uint256 _positionId) external view returns (address) {
        return LibPositionManager._getUserForPositionId(LibAppStorage.appStorage(), _positionId);
    }

    // Modifiers
    modifier onlySecurityCouncil() {
        _onlySecurityCouncil();
        _;
    }

    function _onlySecurityCouncil() internal view {
        if (msg.sender != LibDiamond.contractOwner()) revert ONLY_SECURITY_COUNCIL();
    }
}
