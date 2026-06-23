// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { PermissionlessWithdrawals }         from "../../src/PermissionlessWithdrawals.sol";
import { PermissionlessWithdrawalsLegacyPAU } from "../../src/PermissionlessWithdrawalsLegacyPAU.sol";

import { MockMainnetControllerBase }   from "../mocks/MockMainnetControllerBase.sol";
import { MockMainnetControllerLegacy } from "../mocks/MockMainnetControllerLegacy.sol";

import { PermissionlessWithdrawalsTestBase } from "./PermissionlessWithdrawalsTestBase.t.sol";

// Runs the full scenario suite against the legacy controller and PermissionlessWithdrawalsLegacyPAU.
contract PermissionlessWithdrawalsLegacyPAUTest is PermissionlessWithdrawalsTestBase {

    function _deployImplementation() internal override returns (PermissionlessWithdrawals) {
        return new PermissionlessWithdrawalsLegacyPAU();
    }

    function _deployController(address psm) internal override returns (MockMainnetControllerBase) {
        return new MockMainnetControllerLegacy(psm);
    }

    function _expectWithdrawAaveCall(address aToken, uint256 amount, uint64 count) internal override {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerLegacy.withdrawAave, (aToken, amount)),
            count
        );
    }

    function _expectWithdrawERC4626Call(address token, uint256 amount, uint64 count) internal override {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerLegacy.withdrawERC4626, (token, amount, type(uint256).max)),
            count
        );
    }

    function _expectMintUSDSCall(uint256 usdsAmount, uint64 count) internal override {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerLegacy.mintUSDS, (usdsAmount)),
            count
        );
    }

    function _expectSwapUSDSToUSDCCall(uint256 usdcAmount, uint64 count) internal override {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerLegacy.swapUSDSToUSDC, (usdcAmount)),
            count
        );
    }

    function _expectTransferAssetCall(address asset_, address destination, uint256 amount, uint64 count)
        internal
        override
    {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerLegacy.transferAsset, (asset_, destination, amount)),
            count
        );
    }

}
