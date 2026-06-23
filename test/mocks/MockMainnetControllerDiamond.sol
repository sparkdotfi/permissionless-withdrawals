// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { MockMainnetControllerBase } from "./MockMainnetControllerBase.sol";

// Diamond PAU MainnetController mock
contract MockMainnetControllerDiamond is MockMainnetControllerBase {

    constructor(address psm_) MockMainnetControllerBase(psm_) {}

    function transferAsset_transfer(address asset, address destination, uint256 amount) external {
        _transferAsset(asset, destination, amount);
    }

    function aave_withdraw(address aToken, uint256 amount) external returns (uint256) {
        return _withdrawAave(aToken, amount);
    }

    function erc4626_withdraw(address token, uint256 amount, uint256) external returns (uint256) {
        return _withdrawERC4626(token, amount);
    }

    function usds_mint(uint256 usdsAmount) external {
        _mintUSDS(usdsAmount);
    }

    function psm_swapUSDSToUSDC(uint256 usdcAmount) external {
        _swapUSDSToUSDC(usdcAmount);
    }

}
