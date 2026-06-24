// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl }  from "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { ReentrancyGuard } from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { ERC1967Proxy }    from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Initializable }   from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "../../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import { IPermissionlessWithdrawals } from "../../src/interfaces/IPermissionlessWithdrawals.sol";
import { PermissionlessWithdrawals }  from "../../src/PermissionlessWithdrawals.sol";

import { MockERC4626 }                      from "../mocks/MockERC4626.sol";
import { PermissionlessWithdrawalsV2Mock }  from "../mocks/PermissionlessWithdrawalsV2Mock.sol";

import { UnitTestBase } from "./UnitTestBase.t.sol";

// Abstract scenario suite shared by both controller versions.
abstract contract PermissionlessWithdrawalsTestBase is UnitTestBase {

    /**********************************************************************************************/
    /*** Controller-specific call expectation hooks                                             ***/
    /**********************************************************************************************/

    function _expectWithdrawAaveCall(address aToken, uint256 amount, uint64 count) internal virtual;

    function _expectWithdrawERC4626Call(address token, uint256 amount, uint64 count) internal virtual;

    function _expectMintUSDSCall(uint256 usdsAmount, uint64 count) internal virtual;

    function _expectSwapUSDSToUSDCCall(uint256 usdcAmount, uint64 count) internal virtual;

    function _expectTransferAssetCall(address asset_, address destination, uint256 amount, uint64 count)
        internal
        virtual;

    /**********************************************************************************************/
    /*** permissionlessWithdraw: validation                                                     ***/
    /**********************************************************************************************/

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

    /**********************************************************************************************/
    /*** permissionlessWithdraw: venue flows                                                    ***/
    /**********************************************************************************************/

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

        _expectWithdrawAaveCall(address(aToken), assetsRequested,                  1);
        _expectTransferAssetCall(address(asset), address(vault),  assetsRequested, 1);
        vm.expectCall(address(vault), abi.encodeCall(MockERC4626.redeem, (shares, address(withdrawals), user)));

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
