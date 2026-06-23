// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { PermissionlessWithdrawals } from "./PermissionlessWithdrawals.sol";

interface IMainnetControllerLegacy {

    function mintUSDS(uint256 usdsAmount) external;

    function proxy() external view returns (address proxy);

    function swapUSDSToUSDC(uint256 usdcAmount) external;

    function transferAsset(address asset, address destination, uint256 amount) external;

    function withdrawAave(address aToken, uint256 amount) external returns (uint256);

    function withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn) external returns (uint256 shares);

}

contract PermissionlessWithdrawalsLegacyPAU is PermissionlessWithdrawals {

    function _proxy() internal view override returns (address) {
        return IMainnetControllerLegacy(controller).proxy();
    }

    function _transferAsset(address asset, address destination, uint256 amount)
        internal
        override
    {
        IMainnetControllerLegacy(controller).transferAsset(asset, destination, amount);
    }

    function _withdrawAave(address aToken, uint256 amount) internal override {
        IMainnetControllerLegacy(controller).withdrawAave(aToken, amount);
    }

    function _withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn) internal override {
        IMainnetControllerLegacy(controller).withdrawERC4626(token, amount, maxSharesIn);
    }

    function _mintUSDS(uint256 usdsAmount) internal override {
        IMainnetControllerLegacy(controller).mintUSDS(usdsAmount);
    }

    function _swapUSDSToUSDC(uint256 usdcAmount) internal override {
        IMainnetControllerLegacy(controller).swapUSDSToUSDC(usdcAmount);
    }

}
