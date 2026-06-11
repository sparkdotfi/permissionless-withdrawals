// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { PermissionlessWithdrawals } from "../../src/PermissionlessWithdrawals.sol";

import { MockAToken }            from "../mocks/MockAToken.sol";
import { MockERC20 }             from "../mocks/MockERC20.sol";
import { MockERC4626 }           from "../mocks/MockERC4626.sol";
import { MockMainnetController } from "../mocks/MockMainnetController.sol";

contract UnitTestBase is Test {

    uint256 internal constant USER_SHARES        = 1_000_000e18;
    uint256 internal constant CONTROLLER_BALANCE = 1e30;
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    address internal admin            = makeAddr("admin");
    address internal penaltyRecipient = makeAddr("penaltyRecipient");
    address internal recipient        = makeAddr("recipient");
    address internal user             = makeAddr("user");

    MockERC20             internal asset;
    MockERC4626           internal vault;
    MockAToken            internal aToken;
    MockMainnetController internal controller;

    PermissionlessWithdrawals internal withdrawals;

    function setUp() public virtual {
        asset      = new MockERC20("USD Coin", "USDC");
        vault      = new MockERC4626(address(asset));
        aToken     = new MockAToken(address(asset));
        controller = new MockMainnetController();

        withdrawals = new PermissionlessWithdrawals(admin, address(controller), penaltyRecipient);

        vm.prank(admin);
        withdrawals.updateVaultConfig(address(vault), address(aToken), true);

        vault.mint(user, USER_SHARES);

        vm.prank(user);
        vault.approve(address(withdrawals), USER_SHARES);

        asset.mint(address(controller), CONTROLLER_BALANCE);
    }

}
