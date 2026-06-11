// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { MockERC20 } from "./MockERC20.sol";

// Minimal ERC4626 vault with a fixed exchange rate, so that funding the vault with
// assets does not move the share price. Shares are converted at `exchangeRate`
// (assets per share, WAD precision).
contract MockERC4626 {

    address public immutable asset;

    uint256 public exchangeRate = 1e18;

    mapping(address owner => uint256 shares) public balanceOf;

    mapping(address owner => mapping(address spender => uint256 shares)) public allowance;

    constructor(address asset_) {
        asset = asset_;
    }

    function mint(address to, uint256 shares) external {
        balanceOf[to] += shares;
    }

    function setExchangeRate(uint256 exchangeRate_) external {
        exchangeRate = exchangeRate_;
    }

    function approve(address spender, uint256 shares) external returns (bool) {
        allowance[msg.sender][spender] = shares;
        return true;
    }

    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        return (shares * exchangeRate) / 1e18;
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        if (msg.sender != owner) {
            allowance[owner][msg.sender] -= shares;
        }

        balanceOf[owner] -= shares;

        assets = convertToAssets(shares);

        MockERC20(asset).transfer(receiver, assets);
    }

}
