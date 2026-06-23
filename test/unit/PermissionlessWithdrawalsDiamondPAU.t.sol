// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { PermissionlessWithdrawals }           from "../../src/PermissionlessWithdrawals.sol";
import { PermissionlessWithdrawalsDiamondPAU } from "../../src/PermissionlessWithdrawalsDiamondPAU.sol";

import { MockMainnetControllerBase }    from "../mocks/MockMainnetControllerBase.sol";
import { MockMainnetControllerDiamond } from "../mocks/MockMainnetControllerDiamond.sol";

import { PermissionlessWithdrawalsTestBase } from "./PermissionlessWithdrawalsTestBase.t.sol";

// Runs the full scenario suite against the diamond PAU controller and PermissionlessWithdrawalsDiamondPAU.
contract PermissionlessWithdrawalsDiamondPAUTest is PermissionlessWithdrawalsTestBase {

    function _deployImplementation() internal override returns (PermissionlessWithdrawals) {
        return new PermissionlessWithdrawalsDiamondPAU();
    }

    function _deployController(address psm) internal override returns (MockMainnetControllerBase) {
        return new MockMainnetControllerDiamond(psm);
    }

    function _expectWithdrawAaveCall(address aToken, uint256 amount, uint64 count) internal override {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerDiamond.aave_withdraw, (aToken, amount)),
            count
        );
    }

    function _expectWithdrawERC4626Call(address token, uint256 amount, uint64 count) internal override {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerDiamond.erc4626_withdraw, (token, amount, type(uint256).max)),
            count
        );
    }

    function _expectMintUSDSCall(uint256 usdsAmount, uint64 count) internal override {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerDiamond.usds_mint, (usdsAmount)),
            count
        );
    }

    function _expectSwapUSDSToUSDCCall(uint256 usdcAmount, uint64 count) internal override {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerDiamond.psm_swapUSDSToUSDC, (usdcAmount)),
            count
        );
    }

    function _expectTransferAssetCall(address asset_, address destination, uint256 amount, uint64 count)
        internal
        override
    {
        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetControllerDiamond.transferAsset_transfer, (asset_, destination, amount)),
            count
        );
    }

}
