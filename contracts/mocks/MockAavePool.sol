// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";

contract MockAavePool {
    IERC20 public immutable asset;
    ERC20Mock public immutable aToken;

    constructor(address _asset, uint8 _decimals) {
        asset = IERC20(_asset);
        aToken = new ERC20Mock(_decimals);
    }

    function supply(address _asset, uint256 _amount, address _onBehalfOf, uint16) external {
        require(_asset == address(asset), "asset mismatch");
        require(_onBehalfOf != address(0), "invalid recipient");

        bool success = asset.transferFrom(msg.sender, address(this), _amount);
        require(success, "transferFrom failed");

        aToken.mint(_onBehalfOf, _amount);
    }

    function withdraw(address _asset, uint256 _amount, address _to) external returns (uint256) {
        require(_asset == address(asset), "asset mismatch");
        require(_to != address(0), "invalid recipient");

        aToken.burn(msg.sender, _amount);
        bool success = asset.transfer(_to, _amount);
        require(success, "transfer failed");
        return _amount;
    }

    function simulateYield(address _recipient, uint256 _amount) external {
        aToken.mint(_recipient, _amount);
        ERC20Mock(address(asset)).mint(address(this), _amount);
    }

    function getReserveAToken(address _token) external view returns (address) {
        if (_token == address(asset)) {
            return address(aToken);
        }
        return address(0);
    }
}
