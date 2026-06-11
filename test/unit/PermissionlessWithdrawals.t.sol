// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";

import { IPermissionlessWithdrawals } from "../../src/interfaces/IPermissionlessWithdrawals.sol";
import { PermissionlessWithdrawals }  from "../../src/PermissionlessWithdrawals.sol";

import { MockAToken }            from "../mocks/MockAToken.sol";
import { MockERC20 }             from "../mocks/MockERC20.sol";
import { MockERC4626 }           from "../mocks/MockERC4626.sol";
import { MockMainnetController } from "../mocks/MockMainnetController.sol";

import { UnitTestBase } from "./UnitTestBase.t.sol";

contract PermissionlessWithdrawalsTest is UnitTestBase {

    /**********************************************************************************************/
    /*** constructor                                                                            ***/
    /**********************************************************************************************/

    function test_constructor_invalidAdminAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.InvalidAdminAddress.selector);
        new PermissionlessWithdrawals(address(0), address(0), address(0));
    }

    function test_constructor_invalidMainnetControllerAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.InvalidMainnetControllerAddress.selector);
        new PermissionlessWithdrawals(admin, address(0), address(0));
    }

    function test_constructor_invalidPenaltyRecipientAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.InvalidPenaltyRecipientAddress.selector);
        new PermissionlessWithdrawals(admin, address(controller), address(0));
    }

    function test_constructor() external {
        PermissionlessWithdrawals newWithdrawals = new PermissionlessWithdrawals(
            admin,
            address(controller),
            penaltyRecipient
        );

        assertEq(newWithdrawals.hasRole(newWithdrawals.DEFAULT_ADMIN_ROLE(), admin),     true);
        assertEq(newWithdrawals.getRoleMemberCount(newWithdrawals.DEFAULT_ADMIN_ROLE()), 1);

        assertEq(address(newWithdrawals.mainnetController()), address(controller));
        assertEq(newWithdrawals.penaltyRecipient(),           penaltyRecipient);
        assertEq(newWithdrawals.PENALTY_BPS(),                200);
    }

    /**********************************************************************************************/
    /*** updateVaultConfig                                                                      ***/
    /**********************************************************************************************/

    function test_updateVaultConfig_unauthorized() external {
        address unauthorized = makeAddr("unauthorized");

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.updateVaultConfig(address(vault), address(aToken), true);
    }

    function test_updateVaultConfig_invalidVaultAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.InvalidVaultAddress.selector);
        vm.prank(admin);
        withdrawals.updateVaultConfig(address(0), address(0), true);
    }

    function test_updateVaultConfig_invalidATokenAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.InvalidATokenAddress.selector);
        vm.prank(admin);
        withdrawals.updateVaultConfig(address(vault), address(0), true);
    }

    function test_updateVaultConfig_invalidATokenUnderlying() external {
        MockERC20  otherAsset  = new MockERC20("Other", "OTHER");
        MockAToken wrongAToken = new MockAToken(address(otherAsset));

        vm.expectRevert(IPermissionlessWithdrawals.InvalidATokenUnderlying.selector);
        vm.prank(admin);
        withdrawals.updateVaultConfig(address(vault), address(wrongAToken), true);
    }

    function test_updateVaultConfig() external {
        MockERC4626 newVault  = new MockERC4626(address(asset));
        MockAToken  newAToken = new MockAToken(address(asset));

        ( bool whitelisted, address aToken_ ) = withdrawals.vaultConfig(address(newVault));

        assertEq(whitelisted, false);
        assertEq(aToken_,     address(0));

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VaultConfigUpdated(
            address(newVault),
            address(newAToken),
            true
        );

        vm.prank(admin);
        withdrawals.updateVaultConfig(address(newVault), address(newAToken), true);

        ( whitelisted, aToken_ ) = withdrawals.vaultConfig(address(newVault));

        assertEq(whitelisted, true);
        assertEq(aToken_,     address(newAToken));

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VaultConfigUpdated(
            address(newVault),
            address(newAToken),
            false
        );

        vm.prank(admin);
        withdrawals.updateVaultConfig(address(newVault), address(newAToken), false);

        ( whitelisted, aToken_ ) = withdrawals.vaultConfig(address(newVault));

        assertEq(whitelisted, false);
        assertEq(aToken_,     address(newAToken));
    }

    /**********************************************************************************************/
    /*** permissionlessWithdraw                                                                 ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_vaultNotWhitelisted() external {
        address randomVault = makeAddr("randomVault");

        vm.expectRevert(IPermissionlessWithdrawals.VaultNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(randomVault, recipient, USER_SHARES);

        // A previously whitelisted vault that has been de-whitelisted also reverts.

        vm.prank(admin);
        withdrawals.updateVaultConfig(address(vault), address(aToken), false);

        vm.expectRevert(IPermissionlessWithdrawals.VaultNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, USER_SHARES);
    }

    function test_permissionlessWithdraw_invalidRecipientAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.InvalidRecipientAddress.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(0), USER_SHARES);
    }

    function test_permissionlessWithdraw_insufficientSharesBoundary() external {
        vm.expectRevert(abi.encodeWithSelector(
            IPermissionlessWithdrawals.InsufficientShares.selector,
            USER_SHARES + 1,
            USER_SHARES
        ));

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, USER_SHARES + 1);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, USER_SHARES);
    }

    function test_permissionlessWithdraw_insufficientAllowanceBoundary() external {
        vm.prank(user);
        vault.approve(address(withdrawals), USER_SHARES - 1);

        vm.expectRevert(abi.encodeWithSelector(
            IPermissionlessWithdrawals.InsufficientAllowance.selector,
            USER_SHARES,
            USER_SHARES - 1
        ));

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, USER_SHARES);

        vm.prank(user);
        vault.approve(address(withdrawals), USER_SHARES);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, USER_SHARES);
    }

    function test_permissionlessWithdraw_insufficientATokenLiquidity() external {
        uint256 assetsRequested = vault.convertToAssets(USER_SHARES);

        controller.setWithdrawAaveReturn(assetsRequested - 1);

        vm.expectRevert(abi.encodeWithSelector(
            IPermissionlessWithdrawals.InsufficientATokenLiquidity.selector,
            assetsRequested,
            assetsRequested - 1
        ));

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, USER_SHARES);

        controller.setWithdrawAaveReturn(assetsRequested);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, USER_SHARES);
    }

    function test_permissionlessWithdraw_zeroPenalty() external {

        assertEq(asset.balanceOf(penaltyRecipient), 0);
        assertEq(asset.balanceOf(recipient),        0);
        assertEq(vault.balanceOf(user),             USER_SHARES);

        // 49 shares * 200 / 1e4 rounds down to zero penalty shares.
        // No call to redeem penalty shares.
        vm.expectCall(
            address(vault),
            abi.encodeCall(MockERC4626.redeem, (0, penaltyRecipient, user)),
            0
        );

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw({
            sender            : user,
            vault             : address(vault),
            assetsWithdrawn   : 49,
            recipient         : recipient,
            penaltyShares     : 0,
            sharesToRecipient : 49
        });

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, 49);

        assertEq(asset.balanceOf(penaltyRecipient), 0);
        assertEq(asset.balanceOf(recipient),        49);
        assertEq(vault.balanceOf(user),             USER_SHARES - 49);

        // 50 shares is the smallest amount that pays a non-zero penalty.

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, 50);

        assertEq(asset.balanceOf(penaltyRecipient), 1);
        assertEq(asset.balanceOf(recipient),        49 + 49);
        assertEq(vault.balanceOf(user),             USER_SHARES - 49 - 50);
    }

    function test_permissionlessWithdraw() external {
        uint256 shares            = USER_SHARES;
        uint256 assetsRequested   = vault.convertToAssets(shares);
        uint256 penaltyShares     = (shares * withdrawals.PENALTY_BPS()) / 1e4;
        uint256 sharesToRecipient = shares - penaltyShares;

        assertEq(vault.balanceOf(user),                       USER_SHARES);
        assertEq(vault.allowance(user, address(withdrawals)), USER_SHARES);

        assertEq(asset.balanceOf(recipient),           0);
        assertEq(asset.balanceOf(penaltyRecipient),    0);
        assertEq(asset.balanceOf(address(vault)),      0);
        assertEq(asset.balanceOf(address(controller)), CONTROLLER_BALANCE);

        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.withdrawAave, (address(aToken), assetsRequested)));
        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.transferAsset, (address(asset), address(vault), assetsRequested)));
        vm.expectCall(address(vault),      abi.encodeCall(MockERC4626.redeem, (penaltyShares, penaltyRecipient, user)));
        vm.expectCall(address(vault),      abi.encodeCall(MockERC4626.redeem, (sharesToRecipient, recipient, user)));

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            user,
            address(vault),
            assetsRequested,
            recipient,
            penaltyShares,
            sharesToRecipient
        );

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, shares);

        assertEq(vault.balanceOf(user),                       0);
        assertEq(vault.allowance(user, address(withdrawals)), 0);

        assertEq(asset.balanceOf(recipient),           980_000e18);
        assertEq(asset.balanceOf(penaltyRecipient),    20_000e18);
        assertEq(asset.balanceOf(address(vault)),      0);
        assertEq(asset.balanceOf(address(controller)), CONTROLLER_BALANCE - assetsRequested);
    }

    function test_permissionlessWithdraw_exchangeRateAboveOne() external {
        vault.setExchangeRate(2e18);

        assertEq(vault.balanceOf(user),                       USER_SHARES);
        assertEq(vault.allowance(user, address(withdrawals)), USER_SHARES);

        assertEq(asset.balanceOf(recipient),           0);
        assertEq(asset.balanceOf(penaltyRecipient),    0);
        assertEq(asset.balanceOf(address(vault)),      0);
        assertEq(asset.balanceOf(address(controller)), CONTROLLER_BALANCE);

        uint256 shares = 1000e18;

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, shares);

        assertEq(vault.balanceOf(user),                       USER_SHARES - shares);
        assertEq(vault.allowance(user, address(withdrawals)), USER_SHARES - shares);

        assertEq(asset.balanceOf(recipient),           1960e18);
        assertEq(asset.balanceOf(penaltyRecipient),    40e18);
        assertEq(asset.balanceOf(address(vault)),      0);
        assertEq(asset.balanceOf(address(controller)), CONTROLLER_BALANCE - 2000e18);
    }

    function test_permissionlessWithdraw_excessAssetsWithdrawn() external {
        uint256 shares          = 1000e18;
        uint256 assetsRequested = vault.convertToAssets(shares);
        uint256 assetsWithdrawn = assetsRequested + 1e18;

        controller.setWithdrawAaveReturn(assetsWithdrawn);

        assertEq(asset.balanceOf(recipient),           0);
        assertEq(asset.balanceOf(penaltyRecipient),    0);
        assertEq(asset.balanceOf(address(vault)),      0);
        assertEq(asset.balanceOf(address(controller)), CONTROLLER_BALANCE);

        vm.expectCall(
            address(controller),
            abi.encodeCall(MockMainnetController.transferAsset, (address(asset), address(vault), assetsWithdrawn))
        );

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            user,
            address(vault),
            assetsWithdrawn,
            recipient,
            20e18,
            980e18
        );

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, shares);

        // The full withdrawn amount is forwarded to the vault, so any excess over the
        // requested assets is left in the vault after both redeems.
        assertEq(asset.balanceOf(recipient),           980e18);
        assertEq(asset.balanceOf(penaltyRecipient),    20e18);
        assertEq(asset.balanceOf(address(vault)),      1e18);
        assertEq(asset.balanceOf(address(controller)), CONTROLLER_BALANCE - assetsWithdrawn);
    }

    function testFuzz_permissionlessWithdraw(uint256 shares, uint256 exchangeRate) external {
        shares       = bound(shares,       1,    USER_SHARES);
        exchangeRate = bound(exchangeRate, 1e15, 100e18);

        vault.setExchangeRate(exchangeRate);

        uint256 assetsRequested   = vault.convertToAssets(shares);
        uint256 penaltyShares     = (shares * withdrawals.PENALTY_BPS()) / 1e4;
        uint256 sharesToRecipient = shares - penaltyShares;

        uint256 penaltyAssets   = vault.convertToAssets(penaltyShares);
        uint256 recipientAssets = vault.convertToAssets(sharesToRecipient);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), recipient, shares);

        assertEq(vault.balanceOf(user),                       USER_SHARES - shares);
        assertEq(vault.allowance(user, address(withdrawals)), USER_SHARES - shares);

        assertEq(asset.balanceOf(recipient),           recipientAssets);
        assertEq(asset.balanceOf(penaltyRecipient),    penaltyAssets);
        assertEq(asset.balanceOf(address(controller)), CONTROLLER_BALANCE - assetsRequested);

        // Both redeems round down individually, so at most 1 wei of the funded assets
        // can be left in the vault.
        uint256 residual = assetsRequested - penaltyAssets - recipientAssets;

        assertLe(residual, 1);

        assertEq(asset.balanceOf(address(vault)), residual);
    }

}
