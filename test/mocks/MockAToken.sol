// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

contract MockAToken {

    address public immutable UNDERLYING_ASSET_ADDRESS;

    constructor(address underlying_) {
        UNDERLYING_ASSET_ADDRESS = underlying_;
    }

}
