// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IPermissionlessWithdrawals } from "../../src/interfaces/IPermissionlessWithdrawals.sol";
import { PermissionlessWithdrawals }  from "../../src/PermissionlessWithdrawals.sol";

import { MockALMProxy }              from "../mocks/MockALMProxy.sol";
import { MockAToken }                from "../mocks/MockAToken.sol";
import { MockERC20 }                 from "../mocks/MockERC20.sol";
import { MockERC4626 }               from "../mocks/MockERC4626.sol";
import { MockMainnetControllerBase } from "../mocks/MockMainnetControllerBase.sol";
import { MockPSM }                   from "../mocks/MockPSM.sol";

abstract contract UnitTestBase is Test {

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

    MockERC20                 internal asset;
    MockERC4626               internal vault;
    MockAToken                internal aToken;
    MockERC4626               internal erc4626Venue;
    MockPSM                   internal psmVenue;
    MockMainnetControllerBase internal controller;
    MockALMProxy              internal almProxy;

    PermissionlessWithdrawals internal withdrawals;

    function setUp() public virtual {
        asset        = new MockERC20("USD Coin", "USDC", 18);
        vault        = new MockERC4626(address(asset));
        aToken       = new MockAToken(address(asset));
        erc4626Venue = new MockERC4626(address(asset));
        psmVenue     = new MockPSM(address(asset));
        controller   = _deployController(address(psmVenue));
        almProxy     = controller.almProxy();

        withdrawals = _deployWithdrawals(admin, address(controller), penaltyRecipient);

        // Configure the withdrawals contract.

        vm.startPrank(admin);
        withdrawals.updateVaultConfig(address(vault), PENALTY_AMOUNT, true);

        withdrawals.updateVenueConfig(address(vault), address(aToken),       IPermissionlessWithdrawals.VenueType.AAVE,    true);
        withdrawals.updateVenueConfig(address(vault), address(erc4626Venue), IPermissionlessWithdrawals.VenueType.ERC4626, true);
        withdrawals.updateVenueConfig(address(vault), address(psmVenue),     IPermissionlessWithdrawals.VenueType.PSM,     true);
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
    /*** Controller-specific deploy hooks                                                       ***/
    /**********************************************************************************************/

    // Deploys a fresh implementation of the concrete withdrawals contract under test.
    function _deployImplementation() internal virtual returns (PermissionlessWithdrawals);

    // Deploys the mock controller for the version under test.
    function _deployController(address psm) internal virtual returns (MockMainnetControllerBase);

    // Deploys the implementation behind an ERC1967 proxy and initializes it.
    function _deployWithdrawals(address admin_, address controller_, address penaltyRecipient_)
        internal
        returns (PermissionlessWithdrawals)
    {
        PermissionlessWithdrawals implementation = _deployImplementation();

        bytes memory initData = abi.encodeCall(
            PermissionlessWithdrawals.initialize,
            (admin_, controller_, penaltyRecipient_)
        );

        return PermissionlessWithdrawals(address(new ERC1967Proxy(address(implementation), initData)));
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
