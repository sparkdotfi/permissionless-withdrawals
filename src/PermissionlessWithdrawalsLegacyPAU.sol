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

    function hasRole(bytes32 role, address account) external view returns (bool);

    function psm() external view returns (address);

    function usdc() external view returns (address);

}

contract PermissionlessWithdrawalsLegacyPAU is PermissionlessWithdrawals {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    bytes32 internal constant _RELAYER_ROLE = keccak256("RELAYER");

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

    function _withdrawERC4626(address vault, uint256 amount, uint256 maxSharesIn)
        internal
        override
    {
        ILegacyControllerLike(controller).withdrawERC4626(vault, amount, maxSharesIn);
    }

    function _withdrawPSM(uint256 amount) internal override {
        ILegacyControllerLike(controller).mintUSDS(amount * _USDS_CONVERSION_PRECISION);
        ILegacyControllerLike(controller).swapUSDSToUSDC(amount);
    }

    function _getPSM() internal view override returns (address) {
        return ILegacyControllerLike(controller).psm();
    }

    function _getPSMUSDC() internal view override returns (address) {
        return ILegacyControllerLike(controller).usdc();
    }

    function _isRelayer() internal view override returns (bool) {
        return ILegacyControllerLike(controller).hasRole(_RELAYER_ROLE, address(this));
    }

}
