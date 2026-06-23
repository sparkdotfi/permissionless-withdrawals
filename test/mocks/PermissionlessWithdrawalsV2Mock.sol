// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { PermissionlessWithdrawals } from "../../src/PermissionlessWithdrawals.sol";

// Minimal upgrade target used to prove a UUPS upgrade.
contract PermissionlessWithdrawalsV2Mock is PermissionlessWithdrawals {

    function isV2() external pure returns (bool) {
        return true;
    }

    function _proxy() internal view override returns (address) {}

    function _transferAsset(address, address, uint256) internal override {}

    function _withdrawAave(address, uint256) internal override {}

    function _withdrawERC4626(address, uint256, uint256) internal override {}

    function _mintUSDS(uint256) internal override {}

    function _swapUSDSToUSDC(uint256) internal override {}

}
