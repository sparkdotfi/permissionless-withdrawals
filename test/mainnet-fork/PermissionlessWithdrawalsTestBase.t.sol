// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ReentrancyGuard } from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { Ethereum }  from "../../lib/spark-address-registry/src/Ethereum.sol";
import { SparkLend } from "../../lib/spark-address-registry/src/SparkLend.sol";

import { IPermissionlessWithdrawals } from "../../src/interfaces/IPermissionlessWithdrawals.sol";

import { ForkTestBase, IERC20, ISparkVaultLike } from "./ForkTestBase.t.sol";

abstract contract PermissionlessWithdrawalsTestBase is ForkTestBase {

    /**********************************************************************************************/
    /*** Controller-specific hooks                                                              ***/
    /**********************************************************************************************/

    function _expectWithdrawAaveCall(address aToken, uint256 amount, uint64 count) internal virtual;

    function _expectWithdrawERC4626Call(address token, uint256 amount, uint64 count) internal virtual;

    function _expectMintUSDSCall(uint256 usdsAmount, uint64 count) internal virtual;

    function _expectSwapUSDSToUSDCCall(uint256 usdcAmount, uint64 count) internal virtual;

    function _expectTransferAssetCall(address asset_, address destination, uint256 amount, uint64 count)
        internal
        virtual;

    function _revokeRelayerRole(address account) internal virtual;

    function _relayerRole() internal view virtual returns (bytes32);

    function _mockWithdrawAaveReturnsZero(address aToken, uint256 amount) internal virtual;

    function _expectRateLimitExceededRevert() internal virtual;

    /**********************************************************************************************/
    /*** Failure tests                                                                          ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_reentrancy() external {
        _setWithdrawalsEntered();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        withdrawals.permissionlessWithdraw(address(0), address(0), address(0), 0);
    }

    function test_permissionlessWithdraw_vaultNotWhitelisted() external {
        address randomVault = makeAddr("randomVault");

        vm.expectRevert(IPermissionlessWithdrawals.VaultNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(randomVault, address(0), address(0), 0);

        // A previously whitelisted vault that has been de-whitelisted also reverts.

        vm.prank(admin);
        withdrawals.updateVaultConfig(address(spETHVault), SPETH_PENALTY_AMOUNT, false);

        vm.expectRevert(IPermissionlessWithdrawals.VaultNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), address(0), address(0), 0);
    }

    function test_permissionlessWithdraw_venueNotWhitelisted() external {
        address randomVenue = makeAddr("randomVenue");

        vm.expectRevert(IPermissionlessWithdrawals.VenueNotWhitelisted.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), randomVenue, address(0), 0);
    }

    function test_permissionlessWithdraw_zeroRecipientAddress() external {
        vm.expectRevert(IPermissionlessWithdrawals.ZeroRecipientAddress.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.WETH_SPTOKEN, address(0), 0);
    }

    function test_permissionlessWithdraw_notRelayer() external {
        uint256 shares = 10_000e18;

        _mintSharesAndApprove(spETHVault, WETH, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(WETH), address(spETHVault), 0);

        // Proxy holds no idle, so the full amount must be withdrawn from the Aave venue.
        deal(address(WETH), proxy, 0);

        // Revoke the relayer role from the withdrawals contract.
        _revokeRelayerRole(address(withdrawals));

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(withdrawals),
            _relayerRole()
        ));
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.WETH_SPTOKEN, recipient, shares);
    }

    function test_permissionlessWithdraw_insufficientVenueLiquidity() external {
        uint256 shares = 400_000e18;
        uint256 assets = spETHVault.convertToAssets(shares);

        _mintSharesAndApprove(spETHVault, WETH, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(WETH), address(spETHVault), 0);

        // Proxy holds no idle, so the full amount must be withdrawn from the Aave venue.
        deal(address(WETH), proxy, 0);

        // Mock the Aave venue withdrawal to deliver zero assets.
        _mockWithdrawAaveReturnsZero(SparkLend.WETH_SPTOKEN, assets);

        vm.expectRevert(abi.encodeWithSelector(
            IPermissionlessWithdrawals.InsufficientVenueLiquidity.selector,
            assets,
            0
        ));
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.WETH_SPTOKEN, recipient, shares);
    }

    function test_permissionlessWithdraw_sll_rateLimitExceeded() external {
        uint256 shares = 1_000_000_000e6;

        _mintSharesAndApprove(spUSDCVault, USDC, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(USDC), address(spUSDCVault), 0);

        _expectRateLimitExceededRevert();
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), Ethereum.PSM, recipient, shares);
    }

    function test_permissionlessWithdraw_insufficientAssetsToCoverPenaltyBoundary() external {
        uint256 shares = spETHVault.convertToShares(SPETH_PENALTY_AMOUNT) + 1; // Rounding

        _mintSharesAndApprove(spETHVault, WETH, shares);

        vm.expectRevert(abi.encodeWithSelector(
            IPermissionlessWithdrawals.InsufficientAssetsToCoverPenalty.selector,
            SPETH_PENALTY_AMOUNT,
            SPETH_PENALTY_AMOUNT - 1
        ));
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.WETH_SPTOKEN, recipient, shares - 1);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.WETH_SPTOKEN, recipient, shares);
    }

    function test_permissionlessWithdraw_incorrectVenue() external {
        uint256 shares = 10_000e18;

        // Admin incorrectly whitelists a USDC Aave venue (underlying USDC) for the WETH vault.
        vm.prank(admin);
        withdrawals.updateVenueConfig(
            address(spETHVault),
            SparkLend.USDC_SPTOKEN,
            IPermissionlessWithdrawals.VenueType.AAVE,
            true
        );

        _mintSharesAndApprove(spETHVault, WETH, shares);

        // The vault and proxy are empty, so the full amount must be drawn from the venue.
        deal(address(WETH), address(spETHVault), 0);
        deal(address(WETH), proxy,               0);

        vm.expectRevert(IPermissionlessWithdrawals.IncorrectVenue.selector);
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.USDC_SPTOKEN, recipient, shares);
    }

    /**********************************************************************************************/
    /*** Story 0: Success with incorrect venue configuration                                    ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_incorrectVenueNotReached() external {
        uint256 shares          = 10_000e18;
        uint256 assets          = spETHVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPETH_PENALTY_AMOUNT;

        // Admin incorrectly whitelists a USDC Aave venue (underlying USDC) for the WETH vault.
        vm.prank(admin);
        withdrawals.updateVenueConfig(
            address(spETHVault),
            SparkLend.USDC_SPTOKEN,
            IPermissionlessWithdrawals.VenueType.AAVE,
            true
        );

        _mintSharesAndApprove(spETHVault, WETH, shares);

        // The vault keeps the full minted amount, so the shortfall is zero and the incorrect venue is never reached.
        _assertBalances({
            vault                  : spETHVault,
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
            address(spETHVault),
            user,
            recipient,
            SPETH_PENALTY_AMOUNT,
            recipientAmount
        );

        // The incorrect venue is never called and no top-up transfer is needed.
        _expectWithdrawAaveCall(SparkLend.USDC_SPTOKEN, assets, 0);
        _expectTransferAssetCall(address(WETH), address(spETHVault), assets, 0);
        vm.expectCall(address(spETHVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.USDC_SPTOKEN, recipient, shares);

        _assertBalances({
            vault                  : spETHVault,
            asset                  : WETH,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmount,
            penaltyRecipientAssets : SPETH_PENALTY_AMOUNT,
            vaultAssets            : 2_500e18 + 1, // +1 Rounding from mint
            proxyAssets            : 0
        });
    }

    /**********************************************************************************************/
    /*** Story 1: Vault covers full amount                                                      ***/
    /**********************************************************************************************/

    function test_permissionlessWithdraw_vaultCoversFullAmount_spETH() external {
        uint256 shares          = 10_000e18;
        uint256 assets          = spETHVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPETH_PENALTY_AMOUNT;

        _mintSharesAndApprove(spETHVault, WETH, shares);

        _assertBalances({
            vault                  : spETHVault,
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
            address(spETHVault),
            user,
            recipient,
            SPETH_PENALTY_AMOUNT,
            recipientAmount
        );

        // No transferAsset call is expected, since the vault alone covers the full amount.
        _expectTransferAssetCall(address(WETH), address(spETHVault), assets, 0);
        vm.expectCall(address(spETHVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spETHVault,
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
        uint256 assets          = spUSDCVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        _mintSharesAndApprove(spUSDCVault, USDC, shares);

        _assertBalances({
            vault                  : spUSDCVault,
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
            address(spUSDCVault),
            user,
            recipient,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // No transferAsset call is expected, since the vault alone covers the full amount.
        _expectTransferAssetCall(address(USDC), address(spUSDCVault), assets, 0);
        vm.expectCall(address(spUSDCVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), Ethereum.PSM, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDCVault,
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
        uint256 assets          = spUSDTVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDT_PENALTY_AMOUNT;

        _mintSharesAndApprove(spUSDTVault, USDT, shares);

        _assertBalances({
            vault                  : spUSDTVault,
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
            address(spUSDTVault),
            user,
            recipient,
            SPUSDT_PENALTY_AMOUNT,
            recipientAmount
        );

        // No transferAsset call is expected, since the vault alone covers the full amount.
        _expectTransferAssetCall(address(USDT), address(spUSDTVault), assets, 0);
        vm.expectCall(address(spUSDTVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDTVault), SparkLend.USDT_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDTVault,
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
        uint256 assets          = spETHVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPETH_PENALTY_AMOUNT;

        _mintSharesAndApprove(spETHVault, WETH, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(WETH), address(spETHVault), 0);

        // Dealing assets to the proxy to cover the full amount.
        deal(address(WETH), proxy, assets);

        _assertBalances({
            vault                  : spETHVault,
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
            address(spETHVault),
            user,
            recipient,
            SPETH_PENALTY_AMOUNT,
            recipientAmount
        );

        // No venue withdrawal is needed, since the proxy covers the full amount.
        _expectWithdrawAaveCall(SparkLend.WETH_SPTOKEN, assets, 0);
        _expectWithdrawERC4626Call(SparkLend.WETH_SPTOKEN, assets, 0);
        _expectSwapUSDSToUSDCCall(assets, 0);
        _expectTransferAssetCall(address(WETH), address(spETHVault), assets, 1);
        vm.expectCall(address(spETHVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spETHVault,
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
        uint256 assets          = spUSDCVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        _mintSharesAndApprove(spUSDCVault, USDC, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(USDC), address(spUSDCVault), 0);

        // Dealing assets to the proxy to cover the full amount.
        deal(address(USDC), proxy, assets);

        _assertBalances({
            vault                  : spUSDCVault,
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
            address(spUSDCVault),
            user,
            recipient,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // No venue withdrawal is needed, since the proxy covers the full amount.
        _expectWithdrawAaveCall(Ethereum.PSM, assets, 0);
        _expectWithdrawERC4626Call(Ethereum.PSM, assets, 0);
        _expectSwapUSDSToUSDCCall(assets, 0);
        _expectTransferAssetCall(address(USDC), address(spUSDCVault), assets, 1);
        vm.expectCall(address(spUSDCVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), Ethereum.PSM, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDCVault,
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
        uint256 assets          = spUSDTVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDT_PENALTY_AMOUNT;

        _mintSharesAndApprove(spUSDTVault, USDT, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(USDT), address(spUSDTVault), 0);

        // No deal to the proxy, since it already holds enough assets to cover the full amount.

        _assertBalances({
            vault                  : spUSDTVault,
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
            address(spUSDTVault),
            user,
            recipient,
            SPUSDT_PENALTY_AMOUNT,
            recipientAmount
        );

        // No venue withdrawal is needed, since the proxy covers the full amount.
        _expectWithdrawAaveCall(SparkLend.USDT_SPTOKEN, assets, 0);
        _expectWithdrawERC4626Call(SparkLend.USDT_SPTOKEN, assets, 0);
        _expectSwapUSDSToUSDCCall(assets, 0);
        _expectTransferAssetCall(address(USDT), address(spUSDTVault), assets, 1);
        vm.expectCall(address(spUSDTVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDTVault), SparkLend.USDT_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDTVault,
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
        uint256 assets          = spETHVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPETH_PENALTY_AMOUNT;

        _mintSharesAndApprove(spETHVault, WETH, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(WETH), address(spETHVault), 0);

        // Proxy holds no idle, so the full amount must be withdrawn from the Aave venue.
        deal(address(WETH), proxy, 0);

        _assertBalances({
            vault                  : spETHVault,
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
            address(spETHVault),
            user,
            recipient,
            SPETH_PENALTY_AMOUNT,
            recipientAmount
        );

        // The full amount is withdrawn from the Aave venue and transferred to the vault.
        _expectWithdrawAaveCall(SparkLend.WETH_SPTOKEN, assets, 1);
        _expectTransferAssetCall(address(WETH), address(spETHVault), assets, 1);
        vm.expectCall(address(spETHVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spETHVault,
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
        uint256 assets          = spUSDTVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDT_PENALTY_AMOUNT;

        _mintSharesAndApprove(spUSDTVault, USDT, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(USDT), address(spUSDTVault), 0);

        // Proxy holds no idle, so the full amount must be withdrawn from the Aave venue.
        deal(address(USDT), proxy, 0);

        _assertBalances({
            vault                  : spUSDTVault,
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
            address(spUSDTVault),
            user,
            recipient,
            SPUSDT_PENALTY_AMOUNT,
            recipientAmount
        );

        // The full amount is withdrawn from the Aave venue and transferred to the vault.
        _expectWithdrawAaveCall(SparkLend.USDT_SPTOKEN, assets, 1);
        _expectTransferAssetCall(address(USDT), address(spUSDTVault), assets, 1);
        vm.expectCall(address(spUSDTVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDTVault), SparkLend.USDT_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDTVault,
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
        uint256 shares          = 500_000e6;
        uint256 assets          = spUSDCVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        // Whitelist the USDC ERC4626 venue (setUp uses the PSM venue for USDC).
        vm.prank(admin);
        withdrawals.updateVenueConfig(address(spUSDCVault), Ethereum.MORPHO_VAULT_USDC_BC, IPermissionlessWithdrawals.VenueType.ERC4626, true);

        _mintSharesAndApprove(spUSDCVault, USDC, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(USDC), address(spUSDCVault), 0);

        // Proxy holds no idle, so the full amount must be withdrawn from the ERC4626 venue.
        deal(address(USDC), proxy, 0);

        _assertBalances({
            vault                  : spUSDCVault,
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
            address(spUSDCVault),
            user,
            recipient,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // The full amount is withdrawn from the ERC4626 venue and transferred to the vault.
        _expectWithdrawERC4626Call(Ethereum.MORPHO_VAULT_USDC_BC, assets, 1);
        _expectTransferAssetCall(address(USDC), address(spUSDCVault), assets, 1);
        vm.expectCall(address(spUSDCVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), Ethereum.MORPHO_VAULT_USDC_BC, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDCVault,
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
        uint256 assets          = spUSDCVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        _mintSharesAndApprove(spUSDCVault, USDC, shares);

        // Simulate the SLL moving funds out of the vault.
        deal(address(USDC), address(spUSDCVault), 0);

        // Proxy holds no idle, so the full amount must be sourced from the PSM venue.
        deal(address(USDC), proxy, 0);

        _assertBalances({
            vault                  : spUSDCVault,
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
            address(spUSDCVault),
            user,
            recipient,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // The full amount is sourced via the PSM (mint USDS, swap to USDC) and transferred to the vault.
        _expectMintUSDSCall(assets * 1e12, 1);
        _expectSwapUSDSToUSDCCall(assets, 1);
        _expectTransferAssetCall(address(USDC), address(spUSDCVault), assets, 1);
        vm.expectCall(address(spUSDCVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), Ethereum.PSM, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDCVault,
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
        uint256 assets          = spETHVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPETH_PENALTY_AMOUNT;

        // The vault keeps a quarter, the proxy covers a quarter, the Aave venue draws the rest.
        uint256 vaultAmount      = assets / 4;
        uint256 proxyAmount      = assets / 4;
        uint256 assetsToTransfer = assets - vaultAmount;           // Moved into the vault
        uint256 assetsToWithdraw = assetsToTransfer - proxyAmount; // Drawn from the venue

        _mintSharesAndApprove(spETHVault, WETH, shares);

        // Simulate the SLL having moved most, but not all, of the vault's idle into the venue.
        deal(address(WETH), address(spETHVault), vaultAmount);

        // The proxy holds part of the shortfall, so the venue must cover the remainder.
        deal(address(WETH), proxy, proxyAmount);

        _assertBalances({
            vault                  : spETHVault,
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
            address(spETHVault),
            user,
            recipient,
            SPETH_PENALTY_AMOUNT,
            recipientAmount
        );

        // The venue covers only the remaining shortfall, then the full shortfall is transferred to the vault.
        _expectWithdrawAaveCall(SparkLend.WETH_SPTOKEN, assetsToWithdraw, 1);
        _expectTransferAssetCall(address(WETH), address(spETHVault), assetsToTransfer, 1);
        vm.expectCall(address(spETHVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spETHVault), SparkLend.WETH_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spETHVault,
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
        uint256 assets          = spUSDTVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDT_PENALTY_AMOUNT;

        // The vault keeps a quarter, the proxy covers a quarter, the Aave venue draws the rest.
        uint256 vaultAmount      = assets / 4;
        uint256 proxyAmount      = assets / 4;
        uint256 assetsToTransfer = assets - vaultAmount;           // Moved into the vault
        uint256 assetsToWithdraw = assetsToTransfer - proxyAmount; // Drawn from the venue

        _mintSharesAndApprove(spUSDTVault, USDT, shares);

        // Simulate the SLL having moved most, but not all, of the vault's idle into the venue.
        deal(address(USDT), address(spUSDTVault), vaultAmount);

        // The proxy holds part of the shortfall, so the venue must cover the remainder.
        deal(address(USDT), proxy, proxyAmount);

        _assertBalances({
            vault                  : spUSDTVault,
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
            address(spUSDTVault),
            user,
            recipient,
            SPUSDT_PENALTY_AMOUNT,
            recipientAmount
        );

        // The venue covers only the remaining shortfall, then the full shortfall is transferred to the vault.
        _expectWithdrawAaveCall(SparkLend.USDT_SPTOKEN, assetsToWithdraw, 1);
        _expectTransferAssetCall(address(USDT), address(spUSDTVault), assetsToTransfer, 1);
        vm.expectCall(address(spUSDTVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDTVault), SparkLend.USDT_SPTOKEN, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDTVault,
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
        uint256 assets          = spUSDCVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        // The vault keeps a quarter, the proxy covers a quarter, the ERC4626 venue draws the rest.
        uint256 vaultAmount      = assets / 4;
        uint256 proxyAmount      = assets / 4;
        uint256 assetsToTransfer = assets - vaultAmount;           // Moved into the vault
        uint256 assetsToWithdraw = assetsToTransfer - proxyAmount; // Drawn from the venue

        // Whitelist the USDC ERC4626 venue (setUp uses the PSM venue for USDC).
        vm.prank(admin);
        withdrawals.updateVenueConfig(address(spUSDCVault), Ethereum.MORPHO_VAULT_USDC_BC, IPermissionlessWithdrawals.VenueType.ERC4626, true);

        _mintSharesAndApprove(spUSDCVault, USDC, shares);

        // Simulate the SLL having moved most, but not all, of the vault's idle into the venue.
        deal(address(USDC), address(spUSDCVault), vaultAmount);

        // The proxy holds part of the shortfall, so the venue must cover the remainder.
        deal(address(USDC), proxy, proxyAmount);

        _assertBalances({
            vault                  : spUSDCVault,
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
            address(spUSDCVault),
            user,
            recipient,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // The venue covers only the remaining shortfall, then the full shortfall is transferred to the vault.
        _expectWithdrawERC4626Call(Ethereum.MORPHO_VAULT_USDC_BC, assetsToWithdraw, 1);
        _expectTransferAssetCall(address(USDC), address(spUSDCVault), assetsToTransfer, 1);
        vm.expectCall(address(spUSDCVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), Ethereum.MORPHO_VAULT_USDC_BC, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDCVault,
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
        uint256 assets          = spUSDCVault.convertToAssets(shares);
        uint256 recipientAmount = assets - SPUSDC_PENALTY_AMOUNT;

        // The vault keeps a quarter, the proxy covers a quarter, the PSM venue draws the rest.
        uint256 vaultAmount      = assets / 4;
        uint256 proxyAmount      = assets / 4;
        uint256 assetsToTransfer = assets - vaultAmount;           // Moved into the vault
        uint256 assetsToWithdraw = assetsToTransfer - proxyAmount; // Drawn from the venue

        _mintSharesAndApprove(spUSDCVault, USDC, shares);

        // Simulate the SLL having moved most, but not all, of the vault's idle into the venue.
        deal(address(USDC), address(spUSDCVault), vaultAmount);

        // The proxy holds part of the shortfall, so the venue must cover the remainder.
        deal(address(USDC), proxy, proxyAmount);

        _assertBalances({
            vault                  : spUSDCVault,
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
            address(spUSDCVault),
            user,
            recipient,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmount
        );

        // The venue covers only the remaining shortfall, then the full shortfall is transferred to the vault.
        _expectMintUSDSCall(assetsToWithdraw * 1e12, 1);
        _expectSwapUSDSToUSDCCall(assetsToWithdraw, 1);
        _expectTransferAssetCall(address(USDC), address(spUSDCVault), assetsToTransfer, 1);
        vm.expectCall(address(spUSDCVault), abi.encodeCall(ISparkVaultLike.redeem, (shares, address(withdrawals), user)), 1);

        vm.record();

        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), Ethereum.PSM, recipient, shares);

        _assertReentrancyGuardWrittenToTwice();

        _assertBalances({
            vault                  : spUSDCVault,
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
        uint256 assetsEach          = spUSDCVault.convertToAssets(sharesEach);
        uint256 recipientAmountEach = assetsEach - SPUSDC_PENALTY_AMOUNT;

        // Whitelist the ERC4626 and Aave (spToken) USDC venues. The PSM venue is whitelisted in setUp.
        vm.startPrank(admin);
        withdrawals.updateVenueConfig(address(spUSDCVault), Ethereum.MORPHO_VAULT_USDC_BC, IPermissionlessWithdrawals.VenueType.ERC4626, true);
        withdrawals.updateVenueConfig(address(spUSDCVault), SparkLend.USDC_SPTOKEN,         IPermissionlessWithdrawals.VenueType.AAVE,    true);
        vm.stopPrank();

        _mintSharesAndApprove(spUSDCVault, USDC, totalShares);

        // Simulate the SLL having moved all of the vault's idle into the venues.
        deal(address(USDC), address(spUSDCVault), 0);
        deal(address(USDC), proxy,                0);

        _assertBalances({
            vault                  : spUSDCVault,
            asset                  : USDC,
            userShares             : totalShares,
            userAllowance          : totalShares,
            recipientAssets        : 0,
            penaltyRecipientAssets : 0,
            vaultAssets            : 0,
            proxyAssets            : 0
        });

        // Each venue supplies exactly one withdrawal in full.
        _expectWithdrawERC4626Call(Ethereum.MORPHO_VAULT_USDC_BC, assetsEach, 1);
        _expectWithdrawAaveCall(SparkLend.USDC_SPTOKEN, assetsEach, 1);
        _expectMintUSDSCall(assetsEach * 1e12, 1);
        _expectSwapUSDSToUSDCCall(assetsEach, 1);
        _expectTransferAssetCall(address(USDC), address(spUSDCVault), assetsEach, 3);
        vm.expectCall(address(spUSDCVault), abi.encodeCall(ISparkVaultLike.redeem, (sharesEach, address(withdrawals), user)), 3);

        // Withdrawal 1: ERC4626 venue.
        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            address(spUSDCVault),
            user,
            recipient,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmountEach
        );
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), Ethereum.MORPHO_VAULT_USDC_BC, recipient, sharesEach);

        // Withdrawal 2: Aave venue (spUSDC token).
        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            address(spUSDCVault),
            user,
            recipient,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmountEach
        );
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), SparkLend.USDC_SPTOKEN, recipient, sharesEach);

        // Withdrawal 3: PSM venue.
        vm.expectEmit(address(withdrawals));
        emit IPermissionlessWithdrawals.PermissionlessWithdraw(
            address(spUSDCVault),
            user,
            recipient,
            SPUSDC_PENALTY_AMOUNT,
            recipientAmountEach
        );
        vm.prank(user);
        withdrawals.permissionlessWithdraw(address(spUSDCVault), Ethereum.PSM, recipient, sharesEach);

        _assertBalances({
            vault                  : spUSDCVault,
            asset                  : USDC,
            userShares             : 0,
            userAllowance          : 0,
            recipientAssets        : recipientAmountEach * 3,
            penaltyRecipientAssets : SPUSDC_PENALTY_AMOUNT * 3,
            vaultAssets            : 0,
            proxyAssets            : 0
        });
    }

}
