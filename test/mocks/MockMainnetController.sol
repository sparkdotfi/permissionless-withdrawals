// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { MockERC20 } from "./MockERC20.sol";

// Minimal MainnetController that returns the requested amount from `withdrawAave` unless
// an override is set, and transfers assets from its own balance on `transferAsset`.
contract MockMainnetController {

    bool    internal withdrawAaveReturnOverridden;
    uint256 internal withdrawAaveReturnAmount;

    function setWithdrawAaveReturn(uint256 amount) external {
        withdrawAaveReturnOverridden = true;
        withdrawAaveReturnAmount     = amount;
    }

    function withdrawAave(address, uint256 amount) external view returns (uint256) {
        return withdrawAaveReturnOverridden ? withdrawAaveReturnAmount : amount;
    }

    function transferAsset(address asset, address destination, uint256 amount) external {
        MockERC20(asset).transfer(destination, amount);
    }

}
