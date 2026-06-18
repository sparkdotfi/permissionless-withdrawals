// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// PSM venue mock that holds the gem (USDC) liquidity and releases it to the proxy on swap.
contract MockPSM {

    address public immutable gem;

    constructor(address gem_) {
        gem = gem_;
    }

    function release(address to, uint256 amount) external {
        IERC20(gem).transfer(to, amount);
    }

}
