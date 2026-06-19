// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { IERC20 }    from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { Ethereum }  from "../../lib/spark-address-registry/src/Ethereum.sol";
import { SparkLend } from "../../lib/spark-address-registry/src/SparkLend.sol";

import { IPermissionlessWithdrawals } from "../../src/interfaces/IPermissionlessWithdrawals.sol";
import { PermissionlessWithdrawals }  from "../../src/PermissionlessWithdrawals.sol";

interface IMainnetControllerLike {

    function mintUSDS(uint256 usdsAmount) external;

    function proxy() external view returns (address proxy);

    function swapUSDSToUSDC(uint256 usdcAmount) external;

    function transferAsset(address asset, address destination, uint256 amount) external;

    function withdrawAave(address aToken, uint256 amount) external returns (uint256);

    function withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn)
        external
        returns (uint256 shares);

}

interface ISparkVaultLike {

    function approve(address spender, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);

}

contract ForkTestBase is Test {

    using SafeERC20 for IERC20;

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _REENTRANCY_GUARD_SLOT        = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 internal constant _REENTRANCY_GUARD_NOT_ENTERED = bytes32(uint256(1));
    bytes32 internal constant _REENTRANCY_GUARD_ENTERED     = bytes32(uint256(2));

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    uint256 internal constant SPETH_PENALTY_AMOUNT   = 10e18;
    uint256 internal constant SPPYUSD_PENALTY_AMOUNT = 20_000e6;
    uint256 internal constant SPUSDC_PENALTY_AMOUNT  = 20_000e6;
    uint256 internal constant SPUSDT_PENALTY_AMOUNT  = 20_000e6;

    IERC20 internal WETH  = IERC20(Ethereum.WETH);
    IERC20 internal PYUSD = IERC20(Ethereum.PYUSD);
    IERC20 internal USDC  = IERC20(Ethereum.USDC);
    IERC20 internal USDT  = IERC20(Ethereum.USDT);

    ISparkVaultLike internal spETHVault   = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPETH);
    ISparkVaultLike internal spPYUSDVault = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPPYUSD);
    ISparkVaultLike internal spUSDCVault  = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDC);
    ISparkVaultLike internal spUSDTVault  = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDT);

    address internal admin            = Ethereum.SPARK_PROXY;
    address internal penaltyRecipient = makeAddr("penaltyRecipient");
    address internal user             = makeAddr("user");
    address internal recipient        = makeAddr("recipient");

    IMainnetControllerLike    internal mainnetController;
    PermissionlessWithdrawals internal withdrawals;

    function setUp() public {
        vm.createSelectFork(getChain("mainnet").rpcUrl, _getBlock());

        // Step 1: Initialize the mainnet controller and deploy the withdrawals contract.

        mainnetController = IMainnetControllerLike(Ethereum.ALM_CONTROLLER);
        withdrawals       = new PermissionlessWithdrawals(admin, address(mainnetController), penaltyRecipient);

        // Step 2: Configure the withdrawals contract.

        vm.startPrank(admin);
        withdrawals.updateVaultConfig(address(spETHVault),   SPETH_PENALTY_AMOUNT,   true);
        // withdrawals.updateVaultConfig(address(spPYUSDVault), SPPYUSD_PENALTY_AMOUNT, true); // TODO: Confirm that we are onboarding this vault or not
        withdrawals.updateVaultConfig(address(spUSDCVault),  SPUSDC_PENALTY_AMOUNT,  true);
        withdrawals.updateVaultConfig(address(spUSDTVault),  SPUSDT_PENALTY_AMOUNT,  true);

        withdrawals.updateVenueConfig(SparkLend.WETH_SPTOKEN,   IPermissionlessWithdrawals.VenueType.AAVE,    true);
        // withdrawals.updateVenueConfig(SparkLend.PYUSD_SPTOKEN, IPermissionlessWithdrawals.VenueType.ERC4626, true); // TODO: Confirm that we are onboarding this venue or not
        withdrawals.updateVenueConfig(SparkLend.USDC_SPTOKEN,  IPermissionlessWithdrawals.VenueType.PSM,     true);
        withdrawals.updateVenueConfig(SparkLend.USDT_SPTOKEN,  IPermissionlessWithdrawals.VenueType.AAVE,    true);
        vm.stopPrank();
    }

    function _getBlock() internal pure returns (uint256) {
        return 25345523; // Jun-18-2026 04:04:23 PM +UTC
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
        assertEq(asset.balanceOf(Ethereum.ALM_PROXY),   proxyAssets);
        assertEq(asset.balanceOf(address(withdrawals)), 0);
    }

}
