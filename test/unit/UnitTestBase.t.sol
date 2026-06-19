// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { IPermissionlessWithdrawals } from "../../src/interfaces/IPermissionlessWithdrawals.sol";
import { PermissionlessWithdrawals }  from "../../src/PermissionlessWithdrawals.sol";

import { MockALMProxy }          from "../mocks/MockALMProxy.sol";
import { MockAToken }            from "../mocks/MockAToken.sol";
import { MockERC20 }             from "../mocks/MockERC20.sol";
import { MockERC4626 }           from "../mocks/MockERC4626.sol";
import { MockMainnetController } from "../mocks/MockMainnetController.sol";
import { MockPSM }               from "../mocks/MockPSM.sol";

contract UnitTestBase is Test {

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _REENTRANCY_GUARD_SLOT        = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 internal constant _REENTRANCY_GUARD_NOT_ENTERED = bytes32(uint256(1));
    bytes32 internal constant _REENTRANCY_GUARD_ENTERED     = bytes32(uint256(2));

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    uint256 internal constant USER_SHARES     = 1_000_000e18;
    uint256 internal constant VENUE_LIQUIDITY = 1e30;
    uint256 internal constant PENALTY_AMOUNT  = 20_000e18;

    address internal admin            = makeAddr("admin");
    address internal penaltyRecipient = makeAddr("penaltyRecipient");
    address internal recipient        = makeAddr("recipient");
    address internal user             = makeAddr("user");

    MockERC20             internal asset;
    MockERC4626           internal vault;
    MockAToken            internal aToken;
    MockERC4626           internal erc4626Venue;
    MockPSM               internal psmVenue;
    MockMainnetController internal controller;
    MockALMProxy          internal almProxy;

    PermissionlessWithdrawals internal withdrawals;

    function setUp() public virtual {
        asset        = new MockERC20("USD Coin", "USDC", 18);
        vault        = new MockERC4626(address(asset));
        aToken       = new MockAToken(address(asset));
        erc4626Venue = new MockERC4626(address(asset));
        psmVenue     = new MockPSM(address(asset));
        controller   = new MockMainnetController(address(psmVenue));
        almProxy     = controller.almProxy();

        withdrawals = new PermissionlessWithdrawals(admin, address(controller), penaltyRecipient);

        // Configure the withdrawals contract.

        vm.startPrank(admin);
        withdrawals.updateVaultConfig(address(vault),        PENALTY_AMOUNT,                               true);
        withdrawals.updateVenueConfig(address(aToken),       IPermissionlessWithdrawals.VenueType.AAVE,    true);
        withdrawals.updateVenueConfig(address(erc4626Venue), IPermissionlessWithdrawals.VenueType.ERC4626, true);
        withdrawals.updateVenueConfig(address(psmVenue),     IPermissionlessWithdrawals.VenueType.PSM,     true);
        vm.stopPrank();

        vault.mint(user, USER_SHARES);

        vm.prank(user);
        vault.approve(address(withdrawals), USER_SHARES);

        // Fund the venues with deployed liquidity.
        asset.mint(address(aToken),       VENUE_LIQUIDITY);
        asset.mint(address(erc4626Venue), VENUE_LIQUIDITY);
        asset.mint(address(psmVenue),     VENUE_LIQUIDITY);
    }

    /**********************************************************************************************/
    /*** Assertion helpers                                                                      ***/
    /**********************************************************************************************/

    function _setWithdrawalsEntered() internal virtual {
        vm.store(address(withdrawals), _REENTRANCY_GUARD_SLOT, _REENTRANCY_GUARD_ENTERED);
    }

    function _assertReentrancyGuardWrittenToTwice() internal view {
        _assertReentrancyGuardWrittenToTwice(address(withdrawals));
    }

    function _assertReentrancyGuardWrittenToTwice(address withdrawals_) internal view {
        ( , bytes32[] memory writeSlots ) = vm.accesses(withdrawals_);

        uint256 count = 0;

        for (uint256 i = 0; i < writeSlots.length; ++i) {
            if (writeSlots[i] != _REENTRANCY_GUARD_SLOT) continue;

            ++count;
        }

        assertEq(count, 2);
        assertEq(vm.load(withdrawals_, _REENTRANCY_GUARD_SLOT), _REENTRANCY_GUARD_NOT_ENTERED);
    }

    function _assertBalances(
        address venue,
        uint256 userShares,
        uint256 userAllowance,
        uint256 recipientAssets,
        uint256 penaltyRecipientAssets,
        uint256 vaultAssets,
        uint256 proxyAssets,
        uint256 venueAssets
    ) internal view {
        assertEq(vault.balanceOf(user),                       userShares);
        assertEq(vault.balanceOf(address(withdrawals)),       0);
        assertEq(vault.allowance(user, address(withdrawals)), userAllowance);

        assertEq(asset.balanceOf(recipient),            recipientAssets);
        assertEq(asset.balanceOf(penaltyRecipient),     penaltyRecipientAssets);
        assertEq(asset.balanceOf(address(vault)),       vaultAssets);
        assertEq(asset.balanceOf(address(almProxy)),    proxyAssets);
        assertEq(asset.balanceOf(venue),                venueAssets);
        assertEq(asset.balanceOf(address(withdrawals)), 0);
    }

}
