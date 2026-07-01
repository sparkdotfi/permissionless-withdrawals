// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { IAccessControl }  from "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { ReentrancyGuard } from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { Ethereum }  from "../../lib/spark-address-registry/src/Ethereum.sol";
import { SparkLend } from "../../lib/spark-address-registry/src/SparkLend.sol";

import { IPermissionlessWithdrawals } from "../../src/interfaces/IPermissionlessWithdrawals.sol";

import { MockERC721 } from "../mocks/MockERC721.sol";

interface IALMProxyLike {

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

    function CONTROLLER() external view returns (bytes32);

}

interface IATokenLike {

    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

}

interface IERC20Like {

    // NOTE: Omit return to be compatible with non-standard ERC20 tokens.
    function approve(address spender, uint256 amount) external;

    function balanceOf(address owner) external view returns (uint256);

}

interface IERC4626Like {

    function asset() external view returns (address);

}

interface IERC721Like {

    function safeTransferFrom(address from, address to, uint256 tokenId) external payable;

}

interface IPSMLike {

    function gem() external view returns (address);

}

interface ISparkVaultLike {

    function approve(address spender, uint256 amount) external returns (bool);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function allowance(address owner, address spender) external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

}

abstract contract PermissionlessWithdrawalsTestBase is Test {

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _REENTRANCY_GUARD_SLOT        = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 internal constant _REENTRANCY_GUARD_NOT_ENTERED = bytes32(uint256(1));
    bytes32 internal constant _REENTRANCY_GUARD_ENTERED     = bytes32(uint256(2));

    bytes32 internal constant DEFAULT_ADMIN_ROLE        = bytes32(0);
    uint256 internal constant USDS_CONVERSION_PRECISION = 1e12;

    uint256 internal constant SPETH_PENALTY_AMOUNT  = 10e18;
    uint256 internal constant SPUSDC_PENALTY_AMOUNT = 20_000e6;
    uint256 internal constant SPUSDT_PENALTY_AMOUNT = 20_000e6;

    address internal constant WETH = Ethereum.WETH;
    address internal constant USDC = Ethereum.USDC;
    address internal constant USDT = Ethereum.USDT;

    address internal constant SP_ETH_VAULT  = Ethereum.SPARK_VAULT_V2_SPETH;
    address internal constant SP_USDC_VAULT = Ethereum.SPARK_VAULT_V2_SPUSDC;
    address internal constant SP_USDT_VAULT = Ethereum.SPARK_VAULT_V2_SPUSDT;

    address internal admin            = Ethereum.SPARK_PROXY;
    address internal freezer          = Ethereum.ALM_FREEZER_MULTISIG;
    address internal penaltyRecipient = makeAddr("penaltyRecipient");
    address internal recipient        = makeAddr("recipient");
    address internal user             = makeAddr("user");
    address internal unauthorized     = makeAddr("unauthorized");

    address internal controller;
    address internal proxy;

    IPermissionlessWithdrawals internal withdrawals;

    constructor() {
        vm.createSelectFork(getChain("mainnet").rpcUrl, _getBlock());
    }

    function setUp() public virtual {
        // Step 1: Initialize the controller and deploy the withdrawals contract behind a proxy.

        withdrawals = IPermissionlessWithdrawals(_deployWithdrawals(admin, controller, penaltyRecipient));
        proxy       = _proxy();

        // Step 2: Grant the relayer/allocator role to the withdrawals contract.

        _grantRelayerRole(address(withdrawals));

        // Step 3: Configure the withdrawals contract.

        vm.startPrank(admin);

        withdrawals.setVaultConfig(SP_ETH_VAULT,  SPETH_PENALTY_AMOUNT,  true);
        withdrawals.setVaultConfig(SP_USDC_VAULT, SPUSDC_PENALTY_AMOUNT, true);
        withdrawals.setVaultConfig(SP_USDT_VAULT, SPUSDT_PENALTY_AMOUNT, true);

        withdrawals.setVenueType(SP_ETH_VAULT,  SparkLend.WETH_SPTOKEN, IPermissionlessWithdrawals.VenueType.AAVE);
        withdrawals.setVenueType(SP_USDC_VAULT, Ethereum.PSM,           IPermissionlessWithdrawals.VenueType.PSM);
        withdrawals.setVenueType(SP_USDT_VAULT, SparkLend.USDT_SPTOKEN, IPermissionlessWithdrawals.VenueType.AAVE);

        vm.stopPrank();
    }

    function _getBlock() internal pure virtual returns (uint256) {
        return 25345523; // Jun-18-2026 04:04:23 PM +UTC
    }

    /**********************************************************************************************/
    /*** Controller-specific deploy and role hooks                                              ***/
    /**********************************************************************************************/

    // Deploys a fresh instance of the permissionless withdrawals contract.
    function _deployWithdrawals(address admin_, address controller_, address penaltyRecipient_)
        internal
        virtual
        returns (address);

    // Returns the ALMProxy that custodies funds for the controller.
    function _proxy() internal view virtual returns (address);

    // Grants the relayer-equivalent role (legacy: RELAYER, diamond: ALLOCATOR_ROLE) to the account.
    function _grantRelayerRole(address account) internal virtual;

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
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

    function _mintSharesAndApprove(address vault, address asset, uint256 shares) internal {
        uint256 assets = ISparkVaultLike(vault).convertToAssets(shares) + 1; // Rounding

        deal(asset, user, assets);

        vm.startPrank(user);

        IERC20Like(asset).approve(vault,                     0);
        IERC20Like(asset).approve(vault,                     assets);
        ISparkVaultLike(vault).mint(shares,                  user);
        ISparkVaultLike(vault).approve(address(withdrawals), shares);

        vm.stopPrank();
    }

    // Mocks `asset_.balanceOf(proxy)` to return `before_` on the next read and `after_` on the read after that.
    function _mockProxyDelivery(address asset_, address proxy_, uint256 before_, uint256 after_) internal {
        bytes[] memory deliveries = new bytes[](2);
        deliveries[0] = abi.encode(before_);
        deliveries[1] = abi.encode(after_);

        vm.mockCalls(asset_, abi.encodeCall(IERC20Like.balanceOf, (proxy_)), deliveries);
    }

    function _assertBalances(
        address vault,
        address asset,
        uint256 userShares,
        uint256 userAllowance,
        uint256 recipientAssets,
        uint256 penaltyRecipientAssets,
        uint256 vaultAssets,
        uint256 proxyAssets
    ) internal view {
        assertEq(ISparkVaultLike(vault).balanceOf(user),                       userShares);
        assertEq(ISparkVaultLike(vault).balanceOf(address(withdrawals)),       0);
        assertEq(ISparkVaultLike(vault).allowance(user, address(withdrawals)), userAllowance);

        assertEq(IERC20Like(asset).balanceOf(recipient),            recipientAssets);
        assertEq(IERC20Like(asset).balanceOf(penaltyRecipient),     penaltyRecipientAssets);
        assertEq(IERC20Like(asset).balanceOf(vault),                vaultAssets);
        assertEq(IERC20Like(asset).balanceOf(proxy),                proxyAssets);
        assertEq(IERC20Like(asset).balanceOf(address(withdrawals)), 0);
    }

    function _revokeController() internal {
        vm.startPrank(Ethereum.SPARK_PROXY);
        IALMProxyLike(proxy).revokeRole(IALMProxyLike(proxy).CONTROLLER(), controller);
        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** Controller-specific hooks                                                              ***/
    /**********************************************************************************************/

    function _expectWithdrawAaveCall(uint64 count) internal virtual;

    function _expectWithdrawERC4626Call(uint64 count) internal virtual;

    function _expectMintUSDSCall(uint64 count) internal virtual;

    function _expectSwapUSDSToUSDCCall(uint64 count) internal virtual;

    function _expectTransferAssetCall(uint64 count) internal virtual;

    function _revokeRelayerRole(address account) internal virtual;

    function _relayerRole() internal view virtual returns (bytes32);

    /**********************************************************************************************/
    /*** constructor tests                                                                      ***/
    /**********************************************************************************************/

    function test_constructor_zeroAdminAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroAdminAddress.selector);
        _deployWithdrawals(address(0), address(0), address(0));
    }

    function test_constructor_zeroControllerAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroControllerAddress.selector);
        _deployWithdrawals(admin, address(0), address(0));
    }

    function test_constructor_zeroPenaltyRecipientAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroPenaltyRecipientAddress.selector);
        _deployWithdrawals(admin, controller, address(0));
    }

    function test_constructor_controllerProxyMismatch() external {
        _revokeController();

        vm.expectRevert(IPermissionlessWithdrawals.ControllerProxyMismatch.selector);
        _deployWithdrawals(admin, controller, penaltyRecipient);
    }

    function test_constructor() external {
        IPermissionlessWithdrawals newWithdrawals = IPermissionlessWithdrawals(_deployWithdrawals(admin, controller, penaltyRecipient));

        assertEq(newWithdrawals.hasRole(DEFAULT_ADMIN_ROLE, admin),     true);
        assertEq(newWithdrawals.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);

        assertEq(newWithdrawals.controller(),       controller);
        assertEq(newWithdrawals.penaltyRecipient(), penaltyRecipient);
    }

    /**********************************************************************************************/
    /*** setVaultConfig tests                                                                   ***/
    /**********************************************************************************************/

    function test_setVaultConfig_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.setVaultConfig(address(0), 0, true);
    }

    function test_setVaultConfig_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.setVaultConfig(address(0), 0, true);
    }

    function test_setVaultConfig_zeroVaultAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroVaultAddress.selector);
        vm.prank(admin);
        withdrawals.setVaultConfig(address(0), 0, true);
    }

    function test_setVaultConfig_zeroPenaltyAmount() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroPenaltyAmount.selector);
        vm.prank(admin);
        withdrawals.setVaultConfig(SP_ETH_VAULT, 0, true);
    }

    function test_setVaultConfig() external {
        address newVault = makeAddr("newVault");

        assertEq(withdrawals.getVaultIsWhitelisted(newVault), false);
        assertEq(withdrawals.getVaultPenaltyAmount(newVault), 0);

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VaultConfigSet(newVault, 50e18, true);

        vm.prank(admin);
        withdrawals.setVaultConfig(newVault, 50e18, true);

        assertEq(withdrawals.getVaultIsWhitelisted(newVault), true);
        assertEq(withdrawals.getVaultPenaltyAmount(newVault), 50e18);

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VaultConfigSet(newVault, 50e18, false);

        vm.prank(admin);
        withdrawals.setVaultConfig(newVault, 50e18, false);

        assertEq(withdrawals.getVaultIsWhitelisted(newVault), false);
        assertEq(withdrawals.getVaultPenaltyAmount(newVault), 50e18);
    }

    /**********************************************************************************************/
    /*** setVenueType tests                                                                     ***/
    /**********************************************************************************************/

    function test_setVenueType_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.setVenueType(address(0), address(0), IPermissionlessWithdrawals.VenueType.NONE);
    }

    function test_setVenueType_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.setVenueType(address(0), address(0), IPermissionlessWithdrawals.VenueType.NONE);
    }

    function test_setVenueType_zeroVaultAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroVaultAddress.selector);
        vm.prank(admin);
        withdrawals.setVenueType(address(0), address(0), IPermissionlessWithdrawals.VenueType.NONE);
    }

    function test_setVenueType_zeroVenueAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroVenueAddress.selector);
        vm.prank(admin);
        withdrawals.setVenueType(SP_ETH_VAULT, address(0), IPermissionlessWithdrawals.VenueType.NONE);
    }

    function test_setVenueType_outOfRangeVenueType() external {
        bytes memory badCall = abi.encodeWithSelector(
            IPermissionlessWithdrawals.setVenueType.selector,
            SP_ETH_VAULT,
            SparkLend.WETH_SPTOKEN,
            uint8(4)        // Out-of-range VenueType
        );

        vm.prank(admin);
        ( bool success, bytes memory returnData ) = address(withdrawals).call(badCall);

        // The ABI decoder rejects the out-of-range enum at the calldata boundary, reverting with
        // empty data before the function body (and its modifiers) runs.
        assertEq(success,           false);
        assertEq(returnData.length, 0);
    }

    function test_setVenueType_incorrectVenue() external {
        vm.expectRevert(IPermissionlessWithdrawals.IncorrectVenue.selector);
        vm.prank(admin);
        withdrawals.setVenueType(SP_ETH_VAULT, Ethereum.ATOKEN_CORE_USDC, IPermissionlessWithdrawals.VenueType.AAVE);

        vm.expectRevert(IPermissionlessWithdrawals.IncorrectVenue.selector);
        vm.prank(admin);
        withdrawals.setVenueType(SP_ETH_VAULT, Ethereum.MORPHO_VAULT_USDC_BC, IPermissionlessWithdrawals.VenueType.ERC4626);

        vm.expectRevert(IPermissionlessWithdrawals.IncorrectVenue.selector);
        vm.prank(admin);
        withdrawals.setVenueType(SP_ETH_VAULT, Ethereum.PSM, IPermissionlessWithdrawals.VenueType.PSM);
    }

    function test_setVenueType() external {
        // Setting the type of the venue to AAVE.

        assertEq(
            uint256(withdrawals.getVenueType(SP_USDC_VAULT, Ethereum.ATOKEN_CORE_USDC)),
            uint256(IPermissionlessWithdrawals.VenueType.NONE)
        );

        vm.expectCall(
            Ethereum.ATOKEN_CORE_USDC,
            abi.encodeWithSelector(IATokenLike.UNDERLYING_ASSET_ADDRESS.selector)
        );

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VenueTypeSet(
            SP_USDC_VAULT,
            Ethereum.ATOKEN_CORE_USDC,
            IPermissionlessWithdrawals.VenueType.AAVE
        );

        vm.prank(admin);
        withdrawals.setVenueType(SP_USDC_VAULT, Ethereum.ATOKEN_CORE_USDC, IPermissionlessWithdrawals.VenueType.AAVE);

        assertEq(
            uint256(withdrawals.getVenueType(SP_USDC_VAULT, Ethereum.ATOKEN_CORE_USDC)),
            uint256(IPermissionlessWithdrawals.VenueType.AAVE)
        );

        // Setting the type of the venue to ERC4626.

        assertEq(
            uint256(withdrawals.getVenueType(SP_USDC_VAULT, Ethereum.MORPHO_VAULT_USDC_BC)),
            uint256(IPermissionlessWithdrawals.VenueType.NONE)
        );

        vm.expectCall(
            Ethereum.MORPHO_VAULT_USDC_BC,
            abi.encodeWithSelector(IERC4626Like.asset.selector)
        );

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VenueTypeSet(
            SP_USDC_VAULT,
            Ethereum.MORPHO_VAULT_USDC_BC,
            IPermissionlessWithdrawals.VenueType.ERC4626
        );

        vm.prank(admin);
        withdrawals.setVenueType(SP_USDC_VAULT, Ethereum.MORPHO_VAULT_USDC_BC, IPermissionlessWithdrawals.VenueType.ERC4626);

        assertEq(
            uint256(withdrawals.getVenueType(SP_USDC_VAULT, Ethereum.MORPHO_VAULT_USDC_BC)),
            uint256(IPermissionlessWithdrawals.VenueType.ERC4626)
        );

        // Resetting the type of the venue to NONE (disabled).

        assertEq(
            uint256(withdrawals.getVenueType(SP_USDC_VAULT, Ethereum.PSM)),
            uint256(IPermissionlessWithdrawals.VenueType.PSM)
        );

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VenueTypeSet(
            SP_USDC_VAULT,
            Ethereum.PSM,
            IPermissionlessWithdrawals.VenueType.NONE
        );

        vm.prank(admin);
        withdrawals.setVenueType(SP_USDC_VAULT, Ethereum.PSM, IPermissionlessWithdrawals.VenueType.NONE);

        assertEq(
            uint256(withdrawals.getVenueType(SP_USDC_VAULT, Ethereum.PSM)),
            uint256(IPermissionlessWithdrawals.VenueType.NONE)
        );

        // Setting the type of the venue to PSM.

        vm.expectCall(Ethereum.PSM, abi.encodeWithSelector(IPSMLike.gem.selector));

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.VenueTypeSet(
            SP_USDC_VAULT,
            Ethereum.PSM,
            IPermissionlessWithdrawals.VenueType.PSM
        );

        vm.prank(admin);
        withdrawals.setVenueType(SP_USDC_VAULT, Ethereum.PSM, IPermissionlessWithdrawals.VenueType.PSM);

        assertEq(
            uint256(withdrawals.getVenueType(SP_USDC_VAULT, Ethereum.PSM)),
            uint256(IPermissionlessWithdrawals.VenueType.PSM)
        );
    }

    /**********************************************************************************************/
    /*** setMaxSharesInRatio tests                                                              ***/
    /**********************************************************************************************/

    function test_setMaxSharesInRatio_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.setMaxSharesInRatio(address(0), 0);
    }

    function test_setMaxSharesInRatio_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.setMaxSharesInRatio(address(0), 0);
    }

    function test_setMaxSharesInRatio() external {
        address venue = makeAddr("venue");

        assertEq(withdrawals.getMaxSharesInRatio(venue), 0);

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.MaxSharesInRatioSet(venue, 1e18);

        vm.prank(admin);
        withdrawals.setMaxSharesInRatio(venue, 1e18);

        assertEq(withdrawals.getMaxSharesInRatio(venue), 1e18);
    }

    /**********************************************************************************************/
    /*** setPenaltyRecipient tests                                                              ***/
    /**********************************************************************************************/

    function test_setPenaltyRecipient_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.setPenaltyRecipient(penaltyRecipient);
    }

    function test_setPenaltyRecipient_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.setPenaltyRecipient(penaltyRecipient);
    }

    function test_setPenaltyRecipient_zeroPenaltyRecipientAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroPenaltyRecipientAddress.selector);
        vm.prank(admin);
        withdrawals.setPenaltyRecipient(address(0));
    }

    function test_setPenaltyRecipient() external {
        address newPenaltyRecipient = makeAddr("newPenaltyRecipient");

        assertEq(withdrawals.penaltyRecipient(), penaltyRecipient);

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PenaltyRecipientSet(newPenaltyRecipient);

        vm.prank(admin);
        withdrawals.setPenaltyRecipient(newPenaltyRecipient);

        assertEq(withdrawals.penaltyRecipient(), newPenaltyRecipient);
    }

    /**********************************************************************************************/
    /*** recoverETH tests                                                                       ***/
    /**********************************************************************************************/

    function test_recoverETH_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.recoverETH(address(0));
    }

    function test_recoverETH_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.recoverETH(address(0));
    }

    function test_recoverETH_zeroRecipient() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroRecipientAddress.selector);
        vm.prank(admin);
        withdrawals.recoverETH(address(0));
    }

    function test_recoverETH_transferETHFailed() external {
        uint256 amount = 1 ether;

        deal(address(withdrawals), amount);

        vm.mockCallRevert(recipient, amount, new bytes(0), new bytes(0));

        vm.expectRevert(IPermissionlessWithdrawals.TransferETHFailed.selector);
        vm.prank(admin);
        withdrawals.recoverETH(recipient);
    }

    function test_recoverETH() external {
        uint256 amount = 1 ether;

        deal(address(withdrawals), amount);

        assertEq(recipient.balance, 0);

        vm.prank(admin);
        withdrawals.recoverETH(recipient);

        assertEq(address(withdrawals).balance, 0);
        assertEq(recipient.balance,            amount);
    }

    /**********************************************************************************************/
    /*** recoverERC20 tests                                                                     ***/
    /**********************************************************************************************/

    function test_recoverERC20_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.recoverERC20(address(0), address(0));
    }

    function test_recoverERC20_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.recoverERC20(address(0), address(0));
    }

    function test_recoverERC20_zeroToken() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroTokenAddress.selector);
        vm.prank(admin);
        withdrawals.recoverERC20(address(0), address(0));
    }

    function test_recoverERC20_zeroRecipient() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroRecipientAddress.selector);
        vm.prank(admin);
        withdrawals.recoverERC20(WETH, address(0));
    }

    function test_recoverERC20() external {
        uint256 amount = 1e18;

        deal(WETH, address(withdrawals), amount);

        assertEq(IERC20Like(WETH).balanceOf(recipient), 0);

        vm.prank(admin);
        withdrawals.recoverERC20(WETH, recipient);

        assertEq(IERC20Like(WETH).balanceOf(address(withdrawals)), 0);
        assertEq(IERC20Like(WETH).balanceOf(recipient),            amount);
    }

    /**********************************************************************************************/
    /*** recoverERC721 tests                                                                    ***/
    /**********************************************************************************************/

    function test_recoverERC721_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.recoverERC721(address(0), address(0), 0);
    }

    function test_recoverERC721_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            unauthorized,
            DEFAULT_ADMIN_ROLE
        ));
        vm.prank(unauthorized);
        withdrawals.recoverERC721(address(0), address(0), 0);
    }

    function test_recoverERC721_zeroToken() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroTokenAddress.selector);
        vm.prank(admin);
        withdrawals.recoverERC721(address(0), address(0), 0);
    }

    function test_recoverERC721_zeroRecipient() external {
        address token = makeAddr("token");

        vm.expectRevert(IPermissionlessWithdrawals.ZeroRecipientAddress.selector);
        vm.prank(admin);
        withdrawals.recoverERC721(token, address(0), 0);
    }

    function test_recoverERC721_withoutValue() external {
        MockERC721 token = new MockERC721();

        uint256 tokenId = 1;

        token.mint(address(withdrawals), tokenId);
        assertEq(token.ownerOf(tokenId), address(withdrawals));

        vm.expectCall(
            address(token),
            0,
            abi.encodeWithSelector(IERC721Like.safeTransferFrom.selector, address(withdrawals), recipient, tokenId)
        );

        vm.prank(admin);
        withdrawals.recoverERC721(address(token), recipient, tokenId);

        assertEq(token.ownerOf(tokenId), recipient);
    }

    function test_recoverERC721_withValue() external {
        MockERC721 token = new MockERC721();

        uint256 tokenId = 1;

        token.mint(address(withdrawals), tokenId);
        assertEq(token.ownerOf(tokenId), address(withdrawals));

        deal(admin, 1 ether);

        vm.expectCall(
            address(token),
            1 ether,
            abi.encodeWithSelector(IERC721Like.safeTransferFrom.selector, address(withdrawals), recipient, tokenId)
        );

        vm.prank(admin);
        withdrawals.recoverERC721{value: 1 ether}(address(token), recipient, tokenId);

        assertEq(token.ownerOf(tokenId), recipient);
    }

    /**********************************************************************************************/
    /*** permissionlessWithdraw tests                                                           ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_reentrancy() external {
        _setWithdrawalsEntered();

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(0), address(0), address(0), 0);
    }

    function test_permissionlessWithdraw_zeroVaultAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroVaultAddress.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(0), address(0), address(0), 0);
    }

    function test_permissionlessWithdraw_zeroRecipientAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroRecipientAddress.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, address(0), 0);
    }

    function test_permissionlessWithdraw_zeroShares() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroShares.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, 0);
    }

    function test_permissionlessWithdraw_controllerProxyMismatch() external {
        _revokeController();

        vm.expectRevert(IPermissionlessWithdrawals.ControllerProxyMismatch.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, 1);
    }

    function test_permissionlessWithdraw_vaultNotWhitelisted() external {
        address vault = makeAddr("vault");
        address venue = makeAddr("venue");

        vm.expectRevert(IPermissionlessWithdrawals.VaultNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(vault, venue, recipient, 1);

        // A previously whitelisted vault that has been de-whitelisted also reverts.

        vm.prank(admin);
        withdrawals.setVaultConfig(SP_ETH_VAULT, SPETH_PENALTY_AMOUNT, false);

        vm.expectRevert(IPermissionlessWithdrawals.VaultNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, venue, recipient, 1);
    }

    function test_permissionlessWithdraw_venueTypeNotSet() external {
        address venue = makeAddr("venue");

        vm.expectRevert(IPermissionlessWithdrawals.VenueTypeNotSet.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, venue, recipient, 1_000_000e18);

        // A previously configured venue whose type has been reset to NONE also reverts.

        vm.prank(admin);
        withdrawals.setVenueType(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, IPermissionlessWithdrawals.VenueType.NONE);

        vm.expectRevert(IPermissionlessWithdrawals.VenueTypeNotSet.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, 1_000_000e18);
    }

    function test_permissionlessWithdraw_notRelayer() external {
        uint256 shares = 10_000e18;

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(WETH, SP_ETH_VAULT, 0);

        // Proxy holds no idle, so the full amount must be withdrawn from the Aave venue.
        deal(WETH, proxy, 0);

        // Revoke the relayer role from the withdrawals contract.
        _revokeRelayerRole(address(withdrawals));

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(withdrawals),
            _relayerRole()
        ));
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);
    }

    function test_permissionlessWithdraw_sll_rateLimitExceeded() external {
        uint256 shares = 1_000_000_000e6;

        _mintSharesAndApprove(SP_USDC_VAULT, USDC, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(USDC, SP_USDC_VAULT, 0);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.PSM, recipient, shares);
    }

    function test_permissionlessWithdraw_insufficientVenueLiquidityBoundary() external {
        uint256 shares = 10_000e18;
        uint256 assets = ISparkVaultLike(SP_ETH_VAULT).convertToAssets(shares);

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        // Empty the vault and proxy so the full amount must be drawn from the Aave venue.
        deal(WETH, SP_ETH_VAULT, 0);
        deal(WETH, proxy,        0);

        // Neutralise the real venue call and simulate it delivering one wei short of the request:
        // the proxy reads zero before the withdrawal and `assets - 1` after.
        _mockProxyDelivery(WETH, proxy, 0, assets - 1);

        vm.expectRevert(abi.encodeWithSelector(
            IPermissionlessWithdrawals.InsufficientAssetsInALMProxy.selector,
            assets,
            assets - 1
        ));
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);

        // Delivering the full requested amount via the real venue succeeds.
        vm.clearMockedCalls();

        _mockProxyDelivery(WETH, proxy, 0, assets);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);
    }

    function test_permissionlessWithdraw_insufficientAssetsToCoverPenaltyBoundary() external {
        uint256 shares = ISparkVaultLike(SP_ETH_VAULT).previewWithdraw(SPETH_PENALTY_AMOUNT);

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        vm.expectRevert(abi.encodeWithSelector(
            IPermissionlessWithdrawals.InsufficientAssetsToCoverPenalty.selector,
            SPETH_PENALTY_AMOUNT,
            SPETH_PENALTY_AMOUNT - 1
        ));
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares - 1);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);
    }

    function test_permissionlessWithdraw_insufficientAllowanceBoundary() external {
        uint256 shares = 10_000e18;

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        // Resetting the allowance to one less share than the requested amount.
        vm.prank(user);
        ISparkVaultLike(SP_ETH_VAULT).approve(address(withdrawals), shares - 1);

        vm.expectRevert("SparkVault/insufficient-allowance");
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);

        // Approving the full amount succeeds.
        vm.prank(user);
        ISparkVaultLike(SP_ETH_VAULT).approve(address(withdrawals), shares);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);
    }

    function test_permissionlessWithdraw_insufficientShareBalanceBoundary() external {
        uint256 shares = 10_000e18;

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        // Resetting the shares balance to one less share than the requested amount.
        deal(SP_ETH_VAULT, user, shares - 1);

        vm.expectRevert("SparkVault/insufficient-balance");
        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);

        // Resetting the shares balance to the full amount succeeds.
        deal(SP_ETH_VAULT, user, shares);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);
    }

    /**********************************************************************************************/
    /*** Story 1: Vault covers full amount                                                      ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_vaultCoversFullAmount_spETH() external {
        uint256 shares          = 10_000e18;
        uint256 assets          = ISparkVaultLike(SP_ETH_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPETH_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 2_500e18 + assets + 1, // +1 Rounding from mint
            proxyAssets            : 0
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_ETH_VAULT,
            user,
            recipient,
            shares,
            SPETH_PENALTY_AMOUNT,
            recipientAmount
        );

        // No transferAsset call is expected, since the vault alone covers the full amount.
        _expectTransferAssetCall(0);

        vm.expectCall(SP_ETH_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPETH_PENALTY_AMOUNT,
            vaultAssets            : 2_500e18 + 1, // +1 Rounding from mint
            proxyAssets            : 0
        });
    }

    function test_permissionlessWithdraw_vaultCoversFullAmount_spUSDC() external {
        uint256 shares          = 1_000_000e6;
        uint256 assets          = ISparkVaultLike(SP_USDC_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_USDC_VAULT, USDC, shares);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 10_015_550.051522e6 + assets + 1, // +1 Rounding from mint
            proxyAssets            : 0
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            shares,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // No transferAsset call is expected, since the vault alone covers the full amount.
        _expectTransferAssetCall(0);

        vm.expectCall(SP_USDC_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.PSM, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDC_PENALTY_AMOUNT,
            vaultAssets            : 10_015_550.051522e6 + 1, // +1 Rounding from mint
            proxyAssets            : 0
        });
    }

    function test_permissionlessWithdraw_vaultCoversFullAmount_spUSDT() external {
        uint256 shares          = 1_000_000e6;
        uint256 assets          = ISparkVaultLike(SP_USDT_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDT_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_USDT_VAULT, USDT, shares);

        _assertBalances({
            vault                  : SP_USDT_VAULT,
            asset                  : USDT,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 10_002_184.939300e6 + assets + 1, // +1 Rounding from mint
            proxyAssets            : 151_783_893.169538e6
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDT_VAULT,
            user,
            recipient,
            shares,
            SPUSDT_PENALTY_AMOUNT,
            recipientAmount
        );

        // No transferAsset call is expected, since the vault alone covers the full amount.
        _expectTransferAssetCall(0);

        vm.expectCall(SP_USDT_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDT_VAULT, SparkLend.USDT_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDT_VAULT,
            asset                  : USDT,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDT_PENALTY_AMOUNT,
            vaultAssets            : 10_002_184.939300e6 + 1, // +1 Rounding from mint
            proxyAssets            : 151_783_893.169538e6
        });
    }

    /**********************************************************************************************/
    /*** Story 2: Proxy covers full amount                                                      ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_proxyCoversFullAmount_spETH() external {
        uint256 shares          = 10_000e18;
        uint256 assets          = ISparkVaultLike(SP_ETH_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPETH_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(WETH, SP_ETH_VAULT, 0);

        // Dealing assets to the proxy to cover the full amount.
        deal(WETH, proxy, assets);

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : assets
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_ETH_VAULT,
            user,
            recipient,
            shares,
            SPETH_PENALTY_AMOUNT,
            recipientAmount
        );

        // No venue withdrawal is needed, since the proxy covers the full amount.
        _expectWithdrawAaveCall(0);
        _expectWithdrawERC4626Call(0);
        _expectMintUSDSCall(0);
        _expectSwapUSDSToUSDCCall(0);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_ETH_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPETH_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    function test_permissionlessWithdraw_proxyCoversFullAmount_spUSDC() external {
        uint256 shares          = 1_000_000e6;
        uint256 assets          = ISparkVaultLike(SP_USDC_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_USDC_VAULT, USDC, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(USDC, SP_USDC_VAULT, 0);

        // Dealing assets to the proxy to cover the full amount.
        deal(USDC, proxy, assets);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : assets
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            shares,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // No venue withdrawal is needed, since the proxy covers the full amount.
        _expectWithdrawAaveCall(0);
        _expectWithdrawERC4626Call(0);
        _expectMintUSDSCall(0);
        _expectSwapUSDSToUSDCCall(0);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_USDC_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.PSM, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDC_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    function test_permissionlessWithdraw_proxyCoversFullAmount_spUSDT() external {
        uint256 shares          = 1_000_000e6;
        uint256 assets          = ISparkVaultLike(SP_USDT_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDT_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_USDT_VAULT, USDT, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(USDT, SP_USDT_VAULT, 0);

        // No deal to the proxy, since it already holds enough assets to cover the full amount.

        _assertBalances({
            vault                  : SP_USDT_VAULT,
            asset                  : USDT,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 151_783_893.169538e6
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDT_VAULT,
            user,
            recipient,
            shares,
            SPUSDT_PENALTY_AMOUNT,
            recipientAmount
        );

        // No venue withdrawal is needed, since the proxy covers the full amount.
        _expectWithdrawAaveCall(0);
        _expectWithdrawERC4626Call(0);
        _expectMintUSDSCall(0);
        _expectSwapUSDSToUSDCCall(0);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_USDT_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDT_VAULT, SparkLend.USDT_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDT_VAULT,
            asset                  : USDT,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDT_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 151_783_893.169538e6 - assets
        });
    }

    /**********************************************************************************************/
    /*** Story 3: Aave venue covers full amount                                                 ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_aaveVenueCoversFullAmount_spETH() external {
        uint256 shares          = 10_000e18;
        uint256 assets          = ISparkVaultLike(SP_ETH_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPETH_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(WETH, SP_ETH_VAULT, 0);

        // Proxy holds no idle, so the full amount must be withdrawn from the Aave venue.
        deal(WETH, proxy, 0);

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_ETH_VAULT,
            user,
            recipient,
            shares,
            SPETH_PENALTY_AMOUNT,
            recipientAmount
        );

        // The full amount is withdrawn from the Aave venue and transferred to the vault.
        _expectWithdrawAaveCall(1);
        _expectWithdrawERC4626Call(0);
        _expectMintUSDSCall(0);
        _expectSwapUSDSToUSDCCall(0);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_ETH_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPETH_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    function test_permissionlessWithdraw_aaveVenueCoversFullAmount_spUSDT() external {
        uint256 shares          = 1_000_000e6;
        uint256 assets          = ISparkVaultLike(SP_USDT_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDT_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_USDT_VAULT, USDT, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(USDT, SP_USDT_VAULT, 0);

        // Proxy holds no idle, so the full amount must be withdrawn from the Aave venue.
        deal(USDT, proxy, 0);

        _assertBalances({
            vault                  : SP_USDT_VAULT,
            asset                  : USDT,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDT_VAULT,
            user,
            recipient,
            shares,
            SPUSDT_PENALTY_AMOUNT,
            recipientAmount
        );

        // The full amount is withdrawn from the Aave venue and transferred to the vault.
        _expectWithdrawAaveCall(1);
        _expectWithdrawERC4626Call(0);
        _expectMintUSDSCall(0);
        _expectSwapUSDSToUSDCCall(0);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_USDT_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDT_VAULT, SparkLend.USDT_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDT_VAULT,
            asset                  : USDT,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDT_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    /**********************************************************************************************/
    /*** Story 4: ERC4626 venue covers full amount (spUSDC)                                     ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_erc4626VenueCoversFullAmount_spUSDC() external {
        uint256 shares           = 500_000e6;
        uint256 assets           = ISparkVaultLike(SP_USDC_VAULT).convertToAssets(shares);
        uint256 recipientAmount  = assets - SPUSDC_PENALTY_AMOUNT;

        // Whitelist the USDC ERC4626 venue (setUp uses the PSM venue for USDC).
        vm.startPrank(admin);
        withdrawals.setVenueType(SP_USDC_VAULT, Ethereum.MORPHO_VAULT_USDC_BC, IPermissionlessWithdrawals.VenueType.ERC4626);
        withdrawals.setMaxSharesInRatio(Ethereum.MORPHO_VAULT_USDC_BC, 1.1e18 * 1e12);
        vm.stopPrank();

        _mintSharesAndApprove(SP_USDC_VAULT, USDC, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(USDC, SP_USDC_VAULT, 0);

        // Proxy holds no idle, so the full amount must be withdrawn from the ERC4626 venue.
        deal(USDC, proxy, 0);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            shares,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // The full amount is withdrawn from the ERC4626 venue and transferred to the vault.
        _expectWithdrawAaveCall(0);
        _expectWithdrawERC4626Call(1);
        _expectMintUSDSCall(0);
        _expectSwapUSDSToUSDCCall(0);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_USDC_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.MORPHO_VAULT_USDC_BC, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDC_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    /**********************************************************************************************/
    /*** Story 5: PSM venue covers full amount (spUSDC)                                         ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_psmVenueCoversFullAmount_spUSDC() external {
        uint256 shares          = 1_000_000e6;
        uint256 assets          = ISparkVaultLike(SP_USDC_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_USDC_VAULT, USDC, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(USDC, SP_USDC_VAULT, 0);

        // Proxy holds no idle, so the full amount must be sourced from the PSM venue.
        deal(USDC, proxy, 0);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            shares,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // The full amount is sourced via the PSM (mint USDS, swap to USDC) and transferred to the vault.
        _expectWithdrawAaveCall(0);
        _expectWithdrawERC4626Call(0);
        _expectMintUSDSCall(1);
        _expectSwapUSDSToUSDCCall(1);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_USDC_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.PSM, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDC_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    /**********************************************************************************************/
    /*** Story 6: Vault + Proxy + Aave venue covers full amount (spETH, spUSDT)                 ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_vaultProxyAaveVenueCoversFullAmount_spETH() external {
        uint256 shares          = 10_000e18;
        uint256 assets          = ISparkVaultLike(SP_ETH_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPETH_PENALTY_AMOUNT;

        // The vault keeps a quarter, the proxy covers a quarter, the Aave venue draws the rest.
        uint256 vaultAmount      = assets / 4;
        uint256 proxyAmount      = assets / 4;
        uint256 assetsToTransfer = assets - vaultAmount;           // Moved into the vault
        uint256 assetsToWithdraw = assetsToTransfer - proxyAmount; // Drawn from the venue

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        // Simulate the SLL having moved most, but not all, of the vault's idle into the venue.
        deal(WETH, SP_ETH_VAULT, vaultAmount);

        // The proxy holds part of the shortfall, so the venue must cover the remainder.
        deal(WETH, proxy, proxyAmount);

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : vaultAmount,
            proxyAssets            : proxyAmount
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_ETH_VAULT,
            user,
            recipient,
            shares,
            SPETH_PENALTY_AMOUNT,
            recipientAmount
        );

        // The venue covers only the remaining shortfall, then the full shortfall is transferred to the vault.
        _expectWithdrawAaveCall(1);
        _expectWithdrawERC4626Call(0);
        _expectMintUSDSCall(0);
        _expectSwapUSDSToUSDCCall(0);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_ETH_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPETH_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    function test_permissionlessWithdraw_vaultProxyAaveVenueCoversFullAmount_spUSDT() external {
        uint256 shares          = 1_000_000e6;
        uint256 assets          = ISparkVaultLike(SP_USDT_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDT_PENALTY_AMOUNT;

        // The vault keeps a quarter, the proxy covers a quarter, the Aave venue draws the rest.
        uint256 vaultAmount      = assets / 4;
        uint256 proxyAmount      = assets / 4;
        uint256 assetsToTransfer = assets - vaultAmount;           // Moved into the vault
        uint256 assetsToWithdraw = assetsToTransfer - proxyAmount; // Drawn from the venue

        _mintSharesAndApprove(SP_USDT_VAULT, USDT, shares);

        // Simulate the SLL having moved most, but not all, of the vault's idle into the venue.
        deal(USDT, SP_USDT_VAULT, vaultAmount);

        // The proxy holds part of the shortfall, so the venue must cover the remainder.
        deal(USDT, proxy, proxyAmount);

        _assertBalances({
            vault                  : SP_USDT_VAULT,
            asset                  : USDT,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : vaultAmount,
            proxyAssets            : proxyAmount
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDT_VAULT,
            user,
            recipient,
            shares,
            SPUSDT_PENALTY_AMOUNT,
            recipientAmount
        );

        // The venue covers only the remaining shortfall, then the full shortfall is transferred to the vault.
        _expectWithdrawAaveCall(1);
        _expectWithdrawERC4626Call(0);
        _expectMintUSDSCall(0);
        _expectSwapUSDSToUSDCCall(0);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_USDT_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDT_VAULT, SparkLend.USDT_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDT_VAULT,
            asset                  : USDT,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDT_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    /**********************************************************************************************/
    /*** Story 7: Vault + Proxy + ERC4626 venue covers full amount (spUSDC)                     ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_vaultProxyERC4626VenueCoversFullAmount_spUSDC() external {
        uint256 shares          = 1_000_000e6;
        uint256 assets          = ISparkVaultLike(SP_USDC_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        // The vault keeps a quarter, the proxy covers a quarter, the ERC4626 venue draws the rest.
        uint256 vaultAmount      = assets / 4;
        uint256 proxyAmount      = assets / 4;
        uint256 assetsToTransfer = assets - vaultAmount;           // Moved into the vault
        uint256 assetsToWithdraw = assetsToTransfer - proxyAmount; // Drawn from the venue

        // Whitelist the USDC ERC4626 venue (setUp uses the PSM venue for USDC).
        vm.startPrank(admin);
        withdrawals.setVenueType(SP_USDC_VAULT, Ethereum.MORPHO_VAULT_USDC_BC, IPermissionlessWithdrawals.VenueType.ERC4626);
        withdrawals.setMaxSharesInRatio(Ethereum.MORPHO_VAULT_USDC_BC, 1.1e18 * 1e12);
        vm.stopPrank();

        _mintSharesAndApprove(SP_USDC_VAULT, USDC, shares);

        // Simulate the SLL having moved most, but not all, of the vault's idle into the venue.
        deal(USDC, SP_USDC_VAULT, vaultAmount);

        // The proxy holds part of the shortfall, so the venue must cover the remainder.
        deal(USDC, proxy, proxyAmount);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : vaultAmount,
            proxyAssets            : proxyAmount
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            shares,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // The venue covers only the remaining shortfall, then the full shortfall is transferred to the vault.
        _expectWithdrawAaveCall(0);
        _expectWithdrawERC4626Call(1);
        _expectMintUSDSCall(0);
        _expectSwapUSDSToUSDCCall(0);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_USDC_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.MORPHO_VAULT_USDC_BC, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDC_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    /**********************************************************************************************/
    /*** Story 8: Vault + Proxy + PSM venue covers full amount (spUSDC)                         ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_vaultProxyPsmVenueCoversFullAmount_spUSDC() external {
        uint256 shares          = 1_000_000e6;
        uint256 assets          = ISparkVaultLike(SP_USDC_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        // The vault keeps a quarter, the proxy covers a quarter, the PSM venue draws the rest.
        uint256 vaultAmount      = assets / 4;
        uint256 proxyAmount      = assets / 4;
        uint256 assetsToTransfer = assets - vaultAmount;           // Moved into the vault
        uint256 assetsToWithdraw = assetsToTransfer - proxyAmount; // Drawn from the venue

        _mintSharesAndApprove(SP_USDC_VAULT, USDC, shares);

        // Simulate the SLL having moved most, but not all, of the vault's idle into the venue.
        deal(USDC, SP_USDC_VAULT, vaultAmount);

        // The proxy holds part of the shortfall, so the venue must cover the remainder.
        deal(USDC, proxy, proxyAmount);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : vaultAmount,
            proxyAssets            : proxyAmount
        });

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            shares,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // The venue covers only the remaining shortfall, then the full shortfall is transferred to the vault.
        _expectWithdrawAaveCall(0);
        _expectWithdrawERC4626Call(0);
        _expectMintUSDSCall(1);
        _expectSwapUSDSToUSDCCall(1);
        _expectTransferAssetCall(1);

        vm.expectCall(SP_USDC_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.PSM, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDC_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    /**********************************************************************************************/
    /*** Story 9: User calls multiple withdrawals from different venues (spUSDC)                ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_multipleWithdrawals_spUSDC() external {
        uint256 sharesEach          = 500_000e6;
        uint256 totalShares         = sharesEach * 3;
        uint256 assetsEach          = ISparkVaultLike(SP_USDC_VAULT).convertToAssets(sharesEach);
        uint256 recipientAmountEach = assetsEach - SPUSDC_PENALTY_AMOUNT;

        // Whitelist the ERC4626 and Aave (spToken) USDC venues. The PSM venue is whitelisted in setUp.
        vm.startPrank(admin);
        withdrawals.setVenueType(SP_USDC_VAULT, SparkLend.USDC_SPTOKEN,        IPermissionlessWithdrawals.VenueType.AAVE);
        withdrawals.setVenueType(SP_USDC_VAULT, Ethereum.MORPHO_VAULT_USDC_BC, IPermissionlessWithdrawals.VenueType.ERC4626);
        withdrawals.setMaxSharesInRatio(Ethereum.MORPHO_VAULT_USDC_BC, 1.1e18 * 1e12);
        vm.stopPrank();

        _mintSharesAndApprove(SP_USDC_VAULT, USDC, totalShares);

        // Simulate the SLL having moved all of the vault's idle into the venues.
        deal(USDC, SP_USDC_VAULT, 0);
        deal(USDC, proxy,         0);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : totalShares,
            userAllowance          : totalShares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0
        });

        // Each venue supplies exactly one withdrawal in full.
        _expectWithdrawERC4626Call(1);
        _expectWithdrawAaveCall(1);
        _expectMintUSDSCall(1);
        _expectSwapUSDSToUSDCCall(1);
        _expectTransferAssetCall(3);

        vm.expectCall(SP_USDC_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (sharesEach, address(withdrawals), user)), 3);

        // Withdrawal 1: ERC4626 venue.
        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            sharesEach,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmountEach
        );

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.MORPHO_VAULT_USDC_BC, recipient, sharesEach);

        // Withdrawal 2: Aave venue (spUSDC token).
        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            sharesEach,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmountEach
        );

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, SparkLend.USDC_SPTOKEN, recipient, sharesEach);

        // Withdrawal 3: PSM venue.
        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            sharesEach,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmountEach
        );

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.PSM, recipient, sharesEach);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmountEach * 3,
            penaltyRecipientAssets : SPUSDC_PENALTY_AMOUNT * 3,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

    /**********************************************************************************************/
    /*** Fuzz Tests                                                                             ***/
    /**********************************************************************************************/

    function testFuzz_liquiditySplit(uint256 vaultBalance, uint256 proxyBalance) external {
        uint256 shares          = 1_000_000e6;
        uint256 assetsRequested = ISparkVaultLike(SP_USDC_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assetsRequested - SPUSDC_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_USDC_VAULT, USDC, shares);

        vaultBalance = bound(vaultBalance, 0, assetsRequested);
        proxyBalance = bound(proxyBalance, 0, assetsRequested);

        deal(USDC, SP_USDC_VAULT, vaultBalance);
        deal(USDC, proxy,         proxyBalance);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : vaultBalance,
            proxyAssets            : proxyBalance
        });

        uint256 assetsToTransfer = assetsRequested  > vaultBalance ? assetsRequested - vaultBalance  : 0;
        uint256 assetsToWithdraw = assetsToTransfer > proxyBalance ? assetsToTransfer - proxyBalance : 0;

        _expectMintUSDSCall(assetsToWithdraw > 0 ? 1 : 0);
        _expectSwapUSDSToUSDCCall(assetsToWithdraw > 0 ? 1 : 0);
        _expectTransferAssetCall(assetsToTransfer > 0 ? 1 : 0);

        vm.expectCall(SP_USDC_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_USDC_VAULT,
            user,
            recipient,
            shares,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_USDC_VAULT, Ethereum.PSM, recipient, shares);

        _assertBalances({
            vault                  : SP_USDC_VAULT,
            asset                  : USDC,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPUSDC_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : proxyBalance - (assetsToTransfer - assetsToWithdraw)
        });
    }

    function testFuzz_venueNotReachedWhenLiquiditySufficient(uint256 vaultBalance, uint256 proxyBalance) external {
        uint256 shares          = 100_000e18;
        uint256 assetsRequested = ISparkVaultLike(SP_ETH_VAULT).convertToAssets(shares);
        uint256 recipientAmount = assetsRequested - SPETH_PENALTY_AMOUNT;

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        vaultBalance = bound(vaultBalance, 0, assetsRequested);
        proxyBalance = bound(proxyBalance, 0, assetsRequested);

        deal(WETH, SP_ETH_VAULT, vaultBalance);
        deal(WETH, proxy,        proxyBalance);

        uint256 assetsToTransfer = assetsRequested  > vaultBalance ? assetsRequested - vaultBalance  : 0;
        uint256 assetsToWithdraw = assetsToTransfer > proxyBalance ? assetsToTransfer - proxyBalance : 0;

        // Unset the venue so that, if it is ever reached, the withdrawal reverts.
        vm.prank(admin);
        withdrawals.setVenueType(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, IPermissionlessWithdrawals.VenueType.NONE);

        // The venue withdrawal is reached but unset, so the call reverts before any venue interaction.
        if (assetsToWithdraw > 0) {
            vm.expectRevert(IPermissionlessWithdrawals.VenueTypeNotSet.selector);
            vm.prank(user);
            withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);
            return;
        }

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : vaultBalance,
            proxyAssets            : proxyBalance
        });

        // No shortfall: the venue is never touched and the withdrawal succeeds.

        _expectTransferAssetCall(assetsToTransfer > 0 ? 1 : 0);
        vm.expectCall(SP_ETH_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_ETH_VAULT, user, recipient, shares, SPETH_PENALTY_AMOUNT, recipientAmount
        );

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPETH_PENALTY_AMOUNT,
            vaultAssets            : 0,
            proxyAssets            : proxyBalance - assetsToTransfer
        });
    }

    function testFuzz_penaltyAmount(uint256 penaltyAmount) external {
        uint256 shares = 10_000e18;
        uint256 assets = ISparkVaultLike(SP_ETH_VAULT).convertToAssets(shares); // == redeemed fullAmount

        penaltyAmount = bound(penaltyAmount, 1, assets * 2);

        vm.prank(admin);
        withdrawals.setVaultConfig(SP_ETH_VAULT, penaltyAmount, true);

        _mintSharesAndApprove(SP_ETH_VAULT, WETH, shares);

        if (penaltyAmount > assets) {
            // The redeemed assets cannot cover the penalty.
            vm.expectRevert(abi.encodeWithSelector(
                IPermissionlessWithdrawals.InsufficientAssetsToCoverPenalty.selector,
                penaltyAmount,
                assets
            ));

            vm.prank(user);
            withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);
            return;
        }

        uint256 recipientAmount     = assets - penaltyAmount;
        uint256 vaultAssetsStarting = IERC20Like(WETH).balanceOf(SP_ETH_VAULT);

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : shares,
            userAllowance          : shares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : vaultAssetsStarting,
            proxyAssets            : 0
        });

        _expectTransferAssetCall(0); // Vault covers the full amount.

        vm.expectCall(SP_ETH_VAULT, abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            SP_ETH_VAULT, user, recipient, shares, penaltyAmount, recipientAmount
        );

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(SP_ETH_VAULT, SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : SP_ETH_VAULT,
            asset                  : WETH,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : penaltyAmount,
            vaultAssets            : vaultAssetsStarting - assets,
            proxyAssets            : 0
        });
    }

}
