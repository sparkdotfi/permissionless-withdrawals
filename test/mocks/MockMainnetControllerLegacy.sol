// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { MockMainnetControllerBase } from "./MockMainnetControllerBase.sol";

// Legacy PAU MainnetController mock
contract MockMainnetControllerLegacy is MockMainnetControllerBase {

    constructor(address psm_) MockMainnetControllerBase(psm_) {}

    function transferAsset(address asset, address destination, uint256 amount) external {
        _transferAsset(asset, destination, amount);
    }

    function withdrawAave(address aToken, uint256 amount) external returns (uint256) {
        return _withdrawAave(aToken, amount);
    }

    function withdrawERC4626(address token, uint256 amount, uint256) external returns (uint256) {
        return _withdrawERC4626(token, amount);
    }

    function mintUSDS(uint256 usdsAmount) external {
        _mintUSDS(usdsAmount);
    }

    function swapUSDSToUSDC(uint256 usdcAmount) external {
        _swapUSDSToUSDC(usdcAmount);
    }

}
