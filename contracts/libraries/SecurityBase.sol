// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibDiamond} from "./LibDiamond.sol";
import {ONLY_SECURITY_COUNCIL, NOT_GUARDIAN} from "../models/Error.sol";

/// @title SecurityBase — Reentrancy guard and Security Council access-control modifiers backed by diamond storage
abstract contract SecurityBase {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        // Handle uninitialized state gracefully (saves gas in init)
        if (s.s_reentrancyStatus == 0) {
            s.s_reentrancyStatus = _NOT_ENTERED;
        }
        
        require(s.s_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        s.s_reentrancyStatus = _ENTERED;
        _;
        s.s_reentrancyStatus = _NOT_ENTERED;
    }

    /**
     * @dev Restricts access to only the Diamond owner (Security Council)
     */
    modifier onlySecurityCouncil() {
        _onlySecurityCouncil();
        _;
    }

    /// @notice Reverts with ONLY_SECURITY_COUNCIL unless the caller is the Diamond owner (Security Council).
    function _onlySecurityCouncil() internal view {
        if (msg.sender != LibDiamond.contractOwner()) revert ONLY_SECURITY_COUNCIL();
    }

    /// @dev Restricts access to a delegated guardian OR the Diamond owner. Used for
    ///      PAUSE-direction actions only; unpause/resume keep `onlySecurityCouncil`.
    modifier onlyGuardianOrCouncil() {
        _onlyGuardianOrCouncil();
        _;
    }

    /// @notice Reverts with NOT_GUARDIAN unless the caller is a guardian or the owner.
    function _onlyGuardianOrCouncil() internal view {
        if (msg.sender != LibDiamond.contractOwner() && !LibAppStorage.appStorage().s_isGuardian[msg.sender]) {
            revert NOT_GUARDIAN(msg.sender);
        }
    }
}
