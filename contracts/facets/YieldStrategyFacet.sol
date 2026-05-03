// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPositionManager} from "../libraries/LibPositionManager.sol";
import {LibYieldStrategy} from "../libraries/LibYieldStrategy.sol";

import {YieldStrategyConfig, YieldPosition} from "../models/Yield.sol";
import "../models/Error.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

contract YieldStrategyFacet is SecurityBase {
    using LibPositionManager for LibAppStorage.StorageLayout;

    function configureYieldToken(
        address _token,
        address _aavePool,
        address _aToken,
        uint16 _allocationBps,
        uint16 _protocolShareBps
    ) external onlySecurityCouncil {
        LibYieldStrategy._configureYieldToken(
            LibAppStorage.appStorage(), _token, _aavePool, _aToken, _allocationBps, _protocolShareBps
        );
    }

    function setYieldPause(address _token, bool _paused) external onlySecurityCouncil {
        LibYieldStrategy._setYieldPause(LibAppStorage.appStorage(), _token, _paused);
    }

    function rebalanceMyPosition(address _token) external nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) revert NO_POSITION_ID(msg.sender);
        LibYieldStrategy._rebalancePosition(s, _positionId, _token);
    }

    function claimYield(address _token, uint256 _amount, address _recipient)
        external
        nonReentrant
        returns (uint256 claimed)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) revert NO_POSITION_ID(msg.sender);
        address _to = _recipient == address(0) ? msg.sender : _recipient;
        claimed = LibYieldStrategy._claimYield(s, _positionId, _token, _to, _amount);
        return claimed;
    }

    function harvestProtocolYield(address _token, address _recipient, uint256 _amount)
        external
        nonReentrant
        onlySecurityCouncil
        returns (uint256 harvested)
    {
        address _to = _recipient == address(0) ? LibDiamond.contractOwner() : _recipient;
        harvested = LibYieldStrategy._harvestProtocolYield(LibAppStorage.appStorage(), _token, _to, _amount);
        return harvested;
    }

    function getYieldConfig(address _token) external view returns (YieldStrategyConfig memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_yieldConfigs[_token];
    }

    function getYieldPosition(address _user, address _token) external view returns (YieldPosition memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(_user);
        if (_positionId == 0) {
            return YieldPosition({principal: 0, userAccrued: 0, entryAccYieldPerPrincipalRay: 0});
        }
        return s.s_positionYield[_positionId][_token];
    }

    function getPendingYield(address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) {
            return 0;
        }
        return LibYieldStrategy._pendingYield(s, _positionId, _token);
    }
}
