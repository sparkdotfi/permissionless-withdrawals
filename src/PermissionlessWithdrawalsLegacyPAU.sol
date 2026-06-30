// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { PermissionlessWithdrawals } from "./PermissionlessWithdrawals.sol";

interface ILegacyControllerLike {

    function mintUSDS(uint256 usdsAmount) external;

    function swapUSDSToUSDC(uint256 usdcAmount) external;

    function transferAsset(address asset, address destination, uint256 amount) external;

    function withdrawAave(address aToken, uint256 amount) external returns (uint256);

    function withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn)
        external
        returns (uint256);

}

contract PermissionlessWithdrawalsLegacyPAU is PermissionlessWithdrawals {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant _USDS_CONVERSION_PRECISION = 1e12;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(address admin_, address controller_, address penaltyRecipient_)
        PermissionlessWithdrawals(admin_, controller_, penaltyRecipient_) {}

    /**********************************************************************************************/
    /*** Controller Interaction Hooks                                                           ***/
    /**********************************************************************************************/

    function _transferAsset(address asset, address destination, uint256 amount)
        internal
        override
    {
        ILegacyControllerLike(controller).transferAsset(asset, destination, amount);
    }

    function _withdrawAave(address aToken, uint256 amount) internal override {
        ILegacyControllerLike(controller).withdrawAave(aToken, amount);
    }

    function _withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn)
        internal
        override
    {
        ILegacyControllerLike(controller).withdrawERC4626(token, amount, maxSharesIn);
    }

    function _withdrawPSM(uint256 amount) internal override {
        ILegacyControllerLike(controller).mintUSDS(amount * _USDS_CONVERSION_PRECISION);
        ILegacyControllerLike(controller).swapUSDSToUSDC(amount);
    }

}
