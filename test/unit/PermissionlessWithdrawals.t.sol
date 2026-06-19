// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl }  from "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { ReentrancyGuard } from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IPermissionlessWithdrawals } from "../../src/interfaces/IPermissionlessWithdrawals.sol";
import { PermissionlessWithdrawals }  from "../../src/PermissionlessWithdrawals.sol";

import { MockERC4626 }           from "../mocks/MockERC4626.sol";
import { MockMainnetController } from "../mocks/MockMainnetController.sol";

import { UnitTestBase } from "./UnitTestBase.t.sol";

contract PermissionlessWithdrawalsTest is UnitTestBase {

    /**********************************************************************************************/
    /*** constructor                                                                            ***/
    /**********************************************************************************************/

    function test_constructor_zeroAdminAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroAdminAddress.selector);
        new PermissionlessWithdrawals(address(0), address(0), address(0));
    }

    function test_constructor_zeroMainnetControllerAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroMainnetControllerAddress.selector);
        new PermissionlessWithdrawals(admin, address(0), address(0));
    }

    function test_constructor_zeroPenaltyRecipientAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroPenaltyRecipientAddress.selector);
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
    }

    /**********************************************************************************************/
    /*** updateVaultConfig                                                                      ***/
    /**********************************************************************************************/

    function test_updateVaultConfig_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.updateVaultConfig(address(vault), PENALTY_AMOUNT, true);
    }

    function test_updateVaultConfig_unauthorized() external {
        address unauthorized = makeAddr("unauthorized");

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.updateVaultConfig(address(vault), PENALTY_AMOUNT, true);
    }

    function test_updateVaultConfig_zeroVaultAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroVaultAddress.selector);
        vm.prank(admin);
        withdrawals.updateVaultConfig(address(0), PENALTY_AMOUNT, true);
    }

    function test_updateVaultConfig_zeroPenaltyAmount() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroPenaltyAmount.selector);
        vm.prank(admin);
        withdrawals.updateVaultConfig(address(vault), 0, true);
    }

    function test_updateVaultConfig() external {
        MockERC4626 newVault = new MockERC4626(address(asset));

        ( bool whitelisted, uint256 penaltyAmount ) = withdrawals.vaultConfig(address(newVault));

        assertEq(whitelisted,   false);
        assertEq(penaltyAmount, 0);

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VaultConfigUpdated(address(newVault), 50e18, true);

        vm.prank(admin);
        withdrawals.updateVaultConfig(address(newVault), 50e18, true);

        ( whitelisted, penaltyAmount ) = withdrawals.vaultConfig(address(newVault));

        assertEq(whitelisted,   true);
        assertEq(penaltyAmount, 50e18);

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VaultConfigUpdated(address(newVault), 50e18, false);

        vm.prank(admin);
        withdrawals.updateVaultConfig(address(newVault), 50e18, false);

        ( whitelisted, penaltyAmount ) = withdrawals.vaultConfig(address(newVault));

        assertEq(whitelisted,   false);
        assertEq(penaltyAmount, 50e18);
    }

    /**********************************************************************************************/
    /*** updateVenueConfig                                                                      ***/
    /**********************************************************************************************/

    function test_updateVenueConfig_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.updateVenueConfig(address(aToken), IPermissionlessWithdrawals.VenueType.AAVE, true);
    }

    function test_updateVenueConfig_unauthorized() external {
        address unauthorized = makeAddr("unauthorized");

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.updateVenueConfig(address(aToken), IPermissionlessWithdrawals.VenueType.AAVE, true);
    }

    function test_updateVenueConfig_zeroVenueAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroVenueAddress.selector);
        vm.prank(admin);
        withdrawals.updateVenueConfig(address(0), IPermissionlessWithdrawals.VenueType.AAVE, true);
    }

    function test_updateVenueConfig() external {
        address newVenue = makeAddr("newVenue");

        ( bool whitelisted, IPermissionlessWithdrawals.VenueType venueType )
            = withdrawals.venueConfig(newVenue);

        assertEq(whitelisted,        false);
        assertEq(uint256(venueType), uint256(IPermissionlessWithdrawals.VenueType.AAVE));

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VenueConfigUpdated(
            newVenue,
            IPermissionlessWithdrawals.VenueType.PSM,
            true
        );

        vm.prank(admin);
        withdrawals.updateVenueConfig(newVenue, IPermissionlessWithdrawals.VenueType.PSM, true);

        ( whitelisted, venueType ) = withdrawals.venueConfig(newVenue);

        assertEq(whitelisted,        true);
        assertEq(uint256(venueType), uint256(IPermissionlessWithdrawals.VenueType.PSM));

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VenueConfigUpdated(
            newVenue,
            IPermissionlessWithdrawals.VenueType.ERC4626,
            false
        );

        vm.prank(admin);
        withdrawals.updateVenueConfig(newVenue, IPermissionlessWithdrawals.VenueType.ERC4626, false);

        ( whitelisted, venueType ) = withdrawals.venueConfig(newVenue);

        assertEq(whitelisted,        false);
        assertEq(uint256(venueType), uint256(IPermissionlessWithdrawals.VenueType.ERC4626));
    }

    /**********************************************************************************************/
    /*** permissionlessWithdraw                                                                 ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, USER_SHARES);
    }

    function test_permissionlessWithdraw_vaultNotWhitelisted() external {
        address randomVault = makeAddr("randomVault");

        vm.expectRevert(IPermissionlessWithdrawals.VaultNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(randomVault, address(aToken), recipient, USER_SHARES);

        // A previously whitelisted vault that has been de-whitelisted also reverts.

        vm.prank(admin);
        withdrawals.updateVaultConfig(address(vault), PENALTY_AMOUNT, false);

        vm.expectRevert(IPermissionlessWithdrawals.VaultNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, USER_SHARES);
    }

    function test_permissionlessWithdraw_venueNotWhitelisted() external {
        address randomVenue = makeAddr("randomVenue");

        vm.expectRevert(IPermissionlessWithdrawals.VenueNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), randomVenue, recipient, USER_SHARES);

        // A previously whitelisted venue that has been de-whitelisted also reverts.

        vm.prank(admin);
        withdrawals.updateVenueConfig(address(aToken), IPermissionlessWithdrawals.VenueType.AAVE, false);

        vm.expectRevert(IPermissionlessWithdrawals.VenueNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, USER_SHARES);
    }

    function test_permissionlessWithdraw_zeroRecipientAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroRecipientAddress.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), address(0), USER_SHARES);
    }

    function test_permissionlessWithdraw_insufficientVenueLiquidityBoundary() external {
        uint256 assetsRequested = vault.convertToAssets(USER_SHARES);

        // The venue delivers one wei short of the requested amount.
        controller.setVenueDelivery(assetsRequested - 1);

        vm.expectRevert(abi.encodeWithSelector(
            IPermissionlessWithdrawals.InsufficientVenueLiquidity.selector,
            assetsRequested,
            assetsRequested - 1
        ));
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, USER_SHARES);

        // Delivering the full requested amount succeeds.
        controller.setVenueDelivery(assetsRequested);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, USER_SHARES);
    }

    function test_permissionlessWithdraw_insufficientAssetsToCoverPenaltyBoundary() external {
        vm.expectRevert(abi.encodeWithSelector(
            IPermissionlessWithdrawals.InsufficientAssetsToCoverPenalty.selector,
            PENALTY_AMOUNT,
            PENALTY_AMOUNT - 1
        ));
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, PENALTY_AMOUNT - 1);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, PENALTY_AMOUNT);
    }

    function test_permissionlessWithdraw_aave() external {
        uint256 shares          = USER_SHARES;
        uint256 assetsRequested = vault.convertToAssets(shares);
        uint256 recipientAmount = assetsRequested - PENALTY_AMOUNT;

        _assertBalances({
            venue                  : address(aToken),
            userShares             : USER_SHARES,
            userAllowance          : USER_SHARES,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY
        });

        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.withdrawAave,  (address(aToken), assetsRequested)));
        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.transferAsset, (address(asset), address(vault), assetsRequested)));
        vm.expectCall(address(vault),      abi.encodeCall(MockERC4626.redeem, (shares, address(withdrawals), user)));

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            address(vault),
            user,
            recipient,
            PENALTY_AMOUNT,
            recipientAmount
        );

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            venue                  : address(aToken),
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY - assetsRequested
        });
    }

    function test_permissionlessWithdraw_erc4626() external {
        uint256 shares          = USER_SHARES;
        uint256 assetsRequested = vault.convertToAssets(shares);
        uint256 recipientAmount = assetsRequested - PENALTY_AMOUNT;

        _assertBalances({
            venue                  : address(erc4626Venue),
            userShares             : USER_SHARES,
            userAllowance          : USER_SHARES,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY
        });

        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.withdrawERC4626, (address(erc4626Venue), assetsRequested, type(uint256).max)));
        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.transferAsset,   (address(asset), address(vault), assetsRequested)));
        vm.expectCall(address(vault),      abi.encodeCall(MockERC4626.redeem, (shares, address(withdrawals), user)));

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            address(vault),
            user,
            recipient,
            PENALTY_AMOUNT,
            recipientAmount
        );

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(erc4626Venue), recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            venue                  : address(erc4626Venue),
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY - assetsRequested
        });
    }

    function test_permissionlessWithdraw_psm() external {
        uint256 shares          = USER_SHARES;
        uint256 assetsRequested = vault.convertToAssets(shares);
        uint256 recipientAmount = assetsRequested - PENALTY_AMOUNT;

        _assertBalances({
            venue                  : address(psmVenue),
            userShares             : USER_SHARES,
            userAllowance          : USER_SHARES,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY
        });

        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.mintUSDS,       (assetsRequested * withdrawals.USDS_CONVERSION_PRECISION())));
        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.swapUSDSToUSDC, (assetsRequested)));
        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.transferAsset,  (address(asset), address(vault), assetsRequested)));

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            address(vault),
            user,
            recipient,
            PENALTY_AMOUNT,
            recipientAmount
        );

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(psmVenue), recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            venue                  : address(psmVenue),
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY - assetsRequested
        });
    }

    function test_permissionlessWithdraw_proxyAlreadyFunded() external {
        uint256 shares          = USER_SHARES;
        uint256 assetsRequested = vault.convertToAssets(shares);
        uint256 recipientAmount = assetsRequested - PENALTY_AMOUNT;

        // Seed the proxy so the shortfall is zero and no venue withdrawal is needed.
        asset.mint(address(almProxy), assetsRequested);

        _assertBalances({
            venue                  : address(aToken),
            userShares             : USER_SHARES,
            userAllowance          : USER_SHARES,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : assetsRequested,
            venueAssets            : VENUE_LIQUIDITY
        });

        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.withdrawAave,  (address(aToken), assetsRequested)), 0); // No withdrawal needed.
        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.transferAsset, (address(asset), address(vault), assetsRequested)));
        vm.expectCall(address(vault),      abi.encodeCall(MockERC4626.redeem, (shares, address(withdrawals), user)));

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            venue                  : address(aToken),
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY
        });
    }

    function test_permissionlessWithdraw_vaultAlreadyFunded() external {
        uint256 shares          = USER_SHARES;
        uint256 assetsRequested = vault.convertToAssets(shares);
        uint256 recipientAmount = assetsRequested - PENALTY_AMOUNT;

        // Seed the vault so nothing needs to be withdrawn or transferred.
        asset.mint(address(vault), assetsRequested);

        _assertBalances({
            venue                  : address(aToken),
            userShares             : USER_SHARES,
            userAllowance          : USER_SHARES,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : assetsRequested,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY
        });

        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.withdrawAave,  (address(aToken), assetsRequested)), 0); // No withdrawal needed.
        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.transferAsset, (address(asset), address(vault), assetsRequested)), 0); // No transfer needed.
        vm.expectCall(address(vault),      abi.encodeCall(MockERC4626.redeem, (shares, address(withdrawals), user)));

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            venue                  : address(aToken),
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY
        });
    }

    function test_permissionlessWithdraw_partialLiquidity() external {
        uint256 shares          = USER_SHARES;
        uint256 assetsRequested = vault.convertToAssets(shares);
        uint256 recipientAmount = assetsRequested - PENALTY_AMOUNT;

        uint256 proxySeed = 100_000e18;
        uint256 vaultSeed = 200_000e18;

        asset.mint(address(almProxy), proxySeed);
        asset.mint(address(vault),    vaultSeed);

        uint256 assetsToTransfer = assetsRequested  - vaultSeed;
        uint256 assetsToWithdraw = assetsToTransfer - proxySeed;

        _assertBalances({
            venue                  : address(aToken),
            userShares             : USER_SHARES,
            userAllowance          : USER_SHARES,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : vaultSeed,
            proxyAssets            : proxySeed,
            venueAssets            : VENUE_LIQUIDITY
        });

        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.withdrawAave,  (address(aToken), assetsToWithdraw)));
        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.transferAsset, (address(asset), address(vault), assetsToTransfer)));
        vm.expectCall(address(vault),      abi.encodeCall(MockERC4626.redeem, (shares, address(withdrawals), user)));

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            venue                  : address(aToken),
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY - assetsToWithdraw
        });
    }

    function test_permissionlessWithdraw_excessAssetsWithdrawn() external {
        uint256 shares          = USER_SHARES;
        uint256 assetsRequested = vault.convertToAssets(shares);
        uint256 recipientAmount = assetsRequested - PENALTY_AMOUNT;
        uint256 excess          = 1e18;

        // The venue delivers more than requested, the surplus stays in the proxy.
        controller.setVenueDelivery(assetsRequested + excess);

        _assertBalances({
            venue                  : address(aToken),
            userShares             : USER_SHARES,
            userAllowance          : USER_SHARES,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0,
            venueAssets            : VENUE_LIQUIDITY
        });

        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.withdrawAave,  (address(aToken), assetsRequested)));
        vm.expectCall(address(controller), abi.encodeCall(MockMainnetController.transferAsset, (address(asset), address(vault), assetsRequested)));
        vm.expectCall(address(vault),      abi.encodeCall(MockERC4626.redeem, (shares, address(withdrawals), user)));

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(vault), address(aToken), recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            venue                  : address(aToken),
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : excess,
            venueAssets            : VENUE_LIQUIDITY - (assetsRequested + excess)
        });
    }

}
