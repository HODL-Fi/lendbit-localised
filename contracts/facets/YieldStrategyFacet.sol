// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPositionManager} from "../libraries/LibPositionManager.sol";
import {LibYieldStrategy} from "../libraries/LibYieldStrategy.sol";

import {YieldStrategyConfig, YieldPosition} from "../models/Yield.sol";
import "../models/Error.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

/// @title YieldStrategyFacet — Aave-backed yield strategy configuration and yield claiming for collateral
contract YieldStrategyFacet is SecurityBase {
    using LibPositionManager for LibAppStorage.StorageLayout;

    /// @notice Enable and configure an Aave yield strategy for a token (only security council), validating that the aToken matches the pool's reserve aToken; rejects the native token.
    /// @param _token The collateral token to configure yield for
    /// @param _aavePool The Aave pool used to supply and withdraw the token
    /// @param _aToken The Aave aToken expected for the token in that pool
    /// @param _allocationBps The fraction of collateral allocated to the strategy, in basis points
    /// @param _protocolShareBps The protocol's share of accrued yield, in basis points
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

    /// @notice Pause or resume an enabled token's yield strategy; reverts if yield is not enabled for the token.
    /// @dev Pausing (`_paused == true`) is allowed for guardians or the council;
    ///      un-pausing (`_paused == false`) is council-only.
    /// @param _token The token whose strategy to pause or resume
    /// @param _paused True to pause, false to resume
    function setYieldPause(address _token, bool _paused) external {
        if (_paused) {
            _onlyGuardianOrCouncil();
        } else {
            _onlySecurityCouncil();
        }
        LibYieldStrategy._setYieldPause(LibAppStorage.appStorage(), _token, _paused);
    }

    /// @notice Rebalance the caller's yield position for a token, accruing yield and moving collateral to or from Aave to hit the configured allocation target; reverts if the caller has no position.
    /// @param _token The token to rebalance
    function rebalanceMyPosition(address _token) external nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        // Honour the whitelist/blacklist freeze for parity with `claimYield` and every
        // other position-touching entrypoint (#M-07). Rebalance moves a blacklisted
        // user's collateral to/from Aave; a frozen position must stay inert.
        s._addressIsWhitelisted(msg.sender);
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) revert NO_POSITION_ID(msg.sender);
        LibYieldStrategy._rebalancePosition(s, _positionId, _token);
    }

    /// @notice Claim the caller's accrued user yield for a token, withdrawing it from Aave and transferring it to the recipient (defaults to the caller when zero); reverts if the caller has no position or nothing to claim.
    /// @param _token The token to claim yield for
    /// @param _amount The amount to claim (zero or above the available amount claims the full available balance)
    /// @param _recipient The address to receive the claimed yield (defaults to the caller if zero)
    /// @return claimed The amount of yield actually claimed
    function claimYield(address _token, uint256 _amount, address _recipient)
        external
        nonReentrant
        returns (uint256 claimed)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        // Claiming yield moves value out of the protocol, so it must honour the
        // whitelist/blacklist freeze like every other value-extracting entrypoint
        // (`_borrow`, `_withdraw`, collateral deposit). Without this a user
        // blacklisted after opening a position could still pull accrued yield,
        // defeating the freeze (see lead: yield claim bypasses whitelist). Mirrors
        // the deposit-side gate added for the prior blacklist finding.
        s._addressIsWhitelisted(msg.sender);
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) revert NO_POSITION_ID(msg.sender);
        address _to = _recipient == address(0) ? msg.sender : _recipient;
        claimed = LibYieldStrategy._claimYield(s, _positionId, _token, _to, _amount);
        return claimed;
    }

    /// @notice Harvest the protocol's accrued yield share for a token, withdrawing it from Aave and transferring it to the recipient (defaults to the diamond owner when zero) (only security council).
    /// @param _token The token to harvest protocol yield for
    /// @param _recipient The address to receive the harvested yield (defaults to the contract owner if zero)
    /// @param _amount The amount to harvest (zero or above the available amount harvests the full available balance)
    /// @return harvested The amount of protocol yield actually harvested
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

    /// @notice Return the stored yield strategy configuration for a token.
    /// @param _token The token whose yield config to read
    /// @return The token's yield strategy configuration struct
    function getYieldConfig(address _token) external view returns (YieldStrategyConfig memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_yieldConfigs[_token];
    }

    /// @notice Return a user's yield position for a token, or a zeroed position if the user owns no position.
    /// @param _user The user whose yield position to read
    /// @param _token The token whose yield position to read
    /// @return The user's yield position struct for the token
    function getYieldPosition(address _user, address _token) external view returns (YieldPosition memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(_user);
        if (_positionId == 0) {
            return YieldPosition({principal: 0, userAccrued: 0, entryAccYieldPerPrincipalRay: 0});
        }
        return s.s_positionYield[_positionId][_token];
    }

    /// @notice Return the caller's currently claimable yield for a token, including yield accrued but not yet settled; returns zero if the caller has no position.
    /// @param _token The token to query pending yield for
    /// @return The caller's pending claimable yield
    function getPendingYield(address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) {
            return 0;
        }
        return LibYieldStrategy._pendingYield(s, _positionId, _token);
    }
}
