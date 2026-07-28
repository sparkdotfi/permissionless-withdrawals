// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { PermissionlessWithdrawals } from "./PermissionlessWithdrawals.sol";

interface IAccessControls {

    function hasRole(bytes32 role, address account) external view returns (bool);

}

interface IAdministeredAgent {

    function call(address target, bytes memory data) external payable returns (bytes memory result);

    function getIsActor(address account) external view returns (bool isActor);

}

// NOTE: While this interface depends on how the PAU Beacon and Controller is wired, it is the
//       assumed wiring for this iteration.
interface IDiamondControllerLike {

    function aave_withdraw(address aToken, uint256 amount) external returns (uint256);

    function erc4626_withdraw(address token, uint256 amount, uint256 maxSharesIn)
        external
        returns (uint256);

    function psm_swapUSDSToUSDC(uint256 usdcAmount) external;

    function transferAsset_transfer(address asset, address destination, uint256 amount) external;

    function accessControls() external view returns (address);

    function usds_mint(uint256 usdsAmount) external;

    function psm_psm() external view returns (address);

    function psm_usdc() external view returns (address);

}

contract PermissionlessWithdrawalsDiamondPAU is PermissionlessWithdrawals {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    bytes32 internal constant _ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    /**********************************************************************************************/
    /*** Declarations                                                                           ***/
    /**********************************************************************************************/

    address internal immutable _accessControls;
    address internal immutable _administeredAgent;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(
        address admin_,
        address controller_,
        address penaltyRecipient_,
        address administeredAgent_
    )
        PermissionlessWithdrawals(admin_, controller_, penaltyRecipient_)
    {
        _accessControls    = IDiamondControllerLike(controller).accessControls();
        _administeredAgent = administeredAgent_;
    }

    /**********************************************************************************************/
    /*** Controller Interaction Hooks                                                           ***/
    /**********************************************************************************************/

    function _transferAsset(address asset, address destination, uint256 amount)
        internal
        override
    {
        IAdministeredAgent(_administeredAgent).call(
            controller,
            abi.encodeCall(
                IDiamondControllerLike.transferAsset_transfer,
                (asset, destination, amount)
            )
        );
    }

    function _withdrawAave(address aToken, uint256 amount) internal override {
        IAdministeredAgent(_administeredAgent).call(
            controller,
            abi.encodeCall(IDiamondControllerLike.aave_withdraw, (aToken, amount))
        );
    }

    function _withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn)
        internal
        override
    {
        IAdministeredAgent(_administeredAgent).call(
            controller,
            abi.encodeCall(IDiamondControllerLike.erc4626_withdraw, (token, amount, maxSharesIn))
        );
    }

    function _withdrawPSM(uint256 amount) internal override {
        IAdministeredAgent(_administeredAgent).call(
            controller,
            abi.encodeCall(IDiamondControllerLike.usds_mint, (amount * _USDS_CONVERSION_PRECISION))
        );

        IAdministeredAgent(_administeredAgent).call(
            controller,
            abi.encodeCall(IDiamondControllerLike.psm_swapUSDSToUSDC, (amount))
        );
    }

    function _getPSM() internal view override returns (address) {
        return IDiamondControllerLike(controller).psm_psm();
    }

    function _getPSMUSDC() internal view override returns (address) {
        return IDiamondControllerLike(controller).psm_usdc();
    }

    function _isRelayer() internal view override returns (bool) {
        return
            IAccessControls(_accessControls).hasRole(_ALLOCATOR_ROLE, _administeredAgent) &&
            IAdministeredAgent(_administeredAgent).getIsActor(address(this));
    }

}
