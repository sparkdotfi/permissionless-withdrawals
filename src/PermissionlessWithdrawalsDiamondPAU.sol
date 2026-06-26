// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { PermissionlessWithdrawals } from "./PermissionlessWithdrawals.sol";

interface IDiamondControllerLike {

    function aave_withdraw(address aToken, uint256 amount) external returns (uint256);

    function erc4626_withdraw(address token, uint256 amount, uint256 maxSharesIn)
        external
        returns (uint256);

    function psm_swapUSDSToUSDC(uint256 usdcAmount) external;

    function transferAsset_transfer(address asset, address destination, uint256 amount) external;

    function usds_mint(uint256 usdsAmount) external;

}

contract PermissionlessWithdrawalsDiamondPAU is PermissionlessWithdrawals {

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
        IDiamondControllerLike(controller).transferAsset_transfer(asset, destination, amount);
    }

    function _withdrawAave(address aToken, uint256 amount) internal override {
        IDiamondControllerLike(controller).aave_withdraw(aToken, amount);
    }

    function _withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn)
        internal
        override
    {
        IDiamondControllerLike(controller).erc4626_withdraw(token, amount, maxSharesIn);
    }

    function _mintUSDS(uint256 usdsAmount) internal override {
        IDiamondControllerLike(controller).usds_mint(usdsAmount);
    }

    function _swapUSDSToUSDC(uint256 usdcAmount) internal override {
        IDiamondControllerLike(controller).psm_swapUSDSToUSDC(usdcAmount);
    }

}
