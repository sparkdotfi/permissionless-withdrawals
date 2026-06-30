// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { PermissionlessWithdrawalsLegacyPAU } from "../../src/PermissionlessWithdrawalsLegacyPAU.sol";

import { PermissionlessWithdrawalsTestBase } from "./PermissionlessWithdrawalsTestBase.t.sol";

interface ILegacyControllerLike {

    function grantRole(bytes32 role, address account) external;

    function mintUSDS(uint256 usdsAmount) external;

    function proxy() external view returns (address proxy);

    function RELAYER() external view returns (bytes32);

    function removeRelayer(address relayer) external;

    function swapUSDSToUSDC(uint256 usdcAmount) external;

    function transferAsset(address asset, address destination, uint256 amount) external;

    function withdrawAave(address aToken, uint256 amount) external returns (uint256);

    function withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn)
        external
        returns (uint256 shares);

}

// Runs the full fork scenario suite against the live legacy controller (Ethereum.ALM_CONTROLLER)
// and PermissionlessWithdrawalsLegacyPAU.
contract PermissionlessWithdrawalsLegacyPAUForkTest is PermissionlessWithdrawalsTestBase {

    function setUp() public override {
        controller = Ethereum.ALM_CONTROLLER;

        super.setUp();
    }

    /**********************************************************************************************/
    /*** Deploy and role hooks                                                                  ***/
    /**********************************************************************************************/

    function _deployWithdrawals(address admin_, address controller_, address penaltyRecipient_)
        internal
        override
        returns (address)
    {
        return address(new PermissionlessWithdrawalsLegacyPAU(admin_, controller_, penaltyRecipient_));
    }

    function _proxy() internal view override returns (address) {
        return ILegacyControllerLike(controller).proxy();
    }

    function _grantRelayerRole(address account) internal override {
        bytes32 role = ILegacyControllerLike(controller).RELAYER();

        vm.prank(admin);
        ILegacyControllerLike(controller).grantRole(role, account);
    }

    function _revokeRelayerRole(address account) internal override {
        vm.prank(freezer);
        ILegacyControllerLike(controller).removeRelayer(account);
    }

    function _relayerRole() internal view override returns (bytes32) {
        return ILegacyControllerLike(controller).RELAYER();
    }

    /**********************************************************************************************/
    /*** Controller call expectation hooks                                                      ***/
    /**********************************************************************************************/

    function _expectWithdrawAaveCall(uint64 count) internal override {
        vm.expectCall(
            controller,
            abi.encodeWithSelector(ILegacyControllerLike.withdrawAave.selector),
            count
        );
    }

    function _expectWithdrawERC4626Call(uint64 count) internal override {
        vm.expectCall(
            controller,
            abi.encodeWithSelector(ILegacyControllerLike.withdrawERC4626.selector),
            count
        );
    }

    function _expectMintUSDSCall(uint64 count) internal override {
        vm.expectCall(
            controller,
            abi.encodeWithSelector(ILegacyControllerLike.mintUSDS.selector),
            count
        );
    }

    function _expectSwapUSDSToUSDCCall(uint64 count) internal override {
        vm.expectCall(
            controller,
            abi.encodeWithSelector(ILegacyControllerLike.swapUSDSToUSDC.selector),
            count
        );
    }

    function _expectTransferAssetCall(uint64 count) internal override {
        vm.expectCall(
            controller,
            abi.encodeWithSelector(ILegacyControllerLike.transferAsset.selector),
            count
        );
    }

}
