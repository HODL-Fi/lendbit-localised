// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC173} from "../interfaces/IERC173.sol";

/// @title OwnershipFacet — ERC-173 ownership management for the diamond
contract OwnershipFacet is IERC173 {
    /// @notice Transfers diamond ownership to a new address; callable only by the current owner.
    /// @param _newOwner The address to set as the new contract owner.
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    /// @notice Returns the current owner of the diamond.
    /// @return owner_ The address of the current contract owner.
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }
}
