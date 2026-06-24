// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { IERC20 }       from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }    from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC1967Proxy } from "../../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum }  from "../../lib/spark-address-registry/src/Ethereum.sol";
import { SparkLend } from "../../lib/spark-address-registry/src/SparkLend.sol";

import { IPermissionlessWithdrawals } from "../../src/interfaces/IPermissionlessWithdrawals.sol";
import { PermissionlessWithdrawals }  from "../../src/PermissionlessWithdrawals.sol";

interface ISparkVaultLike {

    function approve(address spender, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

}

abstract contract ForkTestBase is Test {

    using SafeERC20 for IERC20;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _REENTRANCY_GUARD_SLOT        = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 internal constant _REENTRANCY_GUARD_NOT_ENTERED = bytes32(uint256(1));
    bytes32 internal constant _REENTRANCY_GUARD_ENTERED     = bytes32(uint256(2));

    bytes32 internal constant DEFAULT_ADMIN_ROLE        = bytes32(0);
    uint256 internal constant USDS_CONVERSION_PRECISION = 1e12;

    uint256 internal constant SPETH_PENALTY_AMOUNT  = 10e18;
    uint256 internal constant SPUSDC_PENALTY_AMOUNT = 20_000e6;
    uint256 internal constant SPUSDT_PENALTY_AMOUNT = 20_000e6;

    IERC20 internal WETH = IERC20(Ethereum.WETH);
    IERC20 internal USDC = IERC20(Ethereum.USDC);
    IERC20 internal USDT = IERC20(Ethereum.USDT);

    ISparkVaultLike internal spETHVault  = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPETH);
    ISparkVaultLike internal spUSDCVault = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDC);
    ISparkVaultLike internal spUSDTVault = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDT);

    address internal admin            = Ethereum.SPARK_PROXY;
    address internal freezer          = Ethereum.ALM_FREEZER_MULTISIG;
    address internal penaltyRecipient = makeAddr("penaltyRecipient");
    address internal user             = makeAddr("user");
    address internal recipient        = makeAddr("recipient");

    address                   internal controller;
    address                   internal proxy;
    PermissionlessWithdrawals internal withdrawals;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl, _getBlock());

        // Step 1: Initialize the controller and deploy the withdrawals contract behind a proxy.

        controller  = _controllerAddress();
        withdrawals = _deployWithdrawals(admin, controller, penaltyRecipient);
        proxy       = _proxy();

        // Step 2: Grant the relayer/allocator role to the withdrawals contract.

        _grantRelayerRole(address(withdrawals));

        // Step 3: Configure the withdrawals contract.

        vm.startPrank(admin);

        withdrawals.updateVaultConfig(address(spETHVault),  SPETH_PENALTY_AMOUNT,  true);
        withdrawals.updateVaultConfig(address(spUSDCVault), SPUSDC_PENALTY_AMOUNT, true);
        withdrawals.updateVaultConfig(address(spUSDTVault), SPUSDT_PENALTY_AMOUNT, true);

        withdrawals.setVenueType(address(spETHVault),  SparkLend.WETH_SPTOKEN, IPermissionlessWithdrawals.VenueType.AAVE);
        withdrawals.setVenueType(address(spUSDCVault), Ethereum.PSM,           IPermissionlessWithdrawals.VenueType.PSM);
        withdrawals.setVenueType(address(spUSDTVault), SparkLend.USDT_SPTOKEN, IPermissionlessWithdrawals.VenueType.AAVE);

        vm.stopPrank();
    }

    function _getBlock() internal pure virtual returns (uint256) {
        return 25345523; // Jun-18-2026 04:04:23 PM +UTC
    }

    /**********************************************************************************************/
    /*** Controller-specific deploy and role hooks                                              ***/
    /**********************************************************************************************/

    // Deploys a fresh implementation of the concrete withdrawals contract under test.
    function _deployImplementation() internal virtual returns (PermissionlessWithdrawals);

    // Returns the controller address for the version under test.
    function _controllerAddress() internal virtual returns (address);

    // Returns the ALMProxy that custodies funds for the controller under test.
    function _proxy() internal view virtual returns (address);

    // Grants the relayer-equivalent role (legacy: RELAYER, diamond: ALLOCATOR_ROLE) to the account.
    function _grantRelayerRole(address account) internal virtual;

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

    function _mintSharesAndApprove(
        ISparkVaultLike vault,
        IERC20          asset,
        uint256         shares
    ) internal {
        uint256 assets = vault.convertToAssets(shares) + 1; // Rounding

        deal(address(asset), user, assets);

        vm.startPrank(user);

        asset.forceApprove(address(vault),  assets);
        vault.mint(shares,                  user);
        vault.approve(address(withdrawals), shares);

        vm.stopPrank();
    }

    // Mocks `asset.balanceOf(proxy)` to return `before_` on the next read and `after_` on the read after that.
    function _mockProxyDelivery(IERC20 asset, address proxy_, uint256 before_, uint256 after_) internal {
        bytes[] memory deliveries = new bytes[](2);
        deliveries[0] = abi.encode(before_);
        deliveries[1] = abi.encode(after_);

        vm.mockCalls(address(asset), abi.encodeCall(IERC20.balanceOf, (proxy_)), deliveries);
    }

    function _assertBalances(
        ISparkVaultLike vault,
        IERC20          asset,
        uint256         userShares,
        uint256         userAllowance,
        uint256         recipientAssets,
        uint256         penaltyRecipientAssets,
        uint256         vaultAssets,
        uint256         proxyAssets
    ) internal view {
        assertEq(vault.balanceOf(user),                       userShares);
        assertEq(vault.balanceOf(address(withdrawals)),       0);
        assertEq(vault.allowance(user, address(withdrawals)), userAllowance);

        assertEq(asset.balanceOf(recipient),            recipientAssets);
        assertEq(asset.balanceOf(penaltyRecipient),     penaltyRecipientAssets);
        assertEq(asset.balanceOf(address(vault)),       vaultAssets);
        assertEq(asset.balanceOf(proxy),                proxyAssets);
        assertEq(asset.balanceOf(address(withdrawals)), 0);
    }

}
