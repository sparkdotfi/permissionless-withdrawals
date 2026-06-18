// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Aave venue mock that holds the deployed underlying liquidity and releases it to the proxy.
contract MockAToken {

    address public immutable UNDERLYING_ASSET_ADDRESS;

    constructor(address underlying_) {
        UNDERLYING_ASSET_ADDRESS = underlying_;
    }

    function release(address to, uint256 amount) external {
        IERC20(UNDERLYING_ASSET_ADDRESS).transfer(to, amount);
    }

}
