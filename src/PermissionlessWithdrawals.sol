// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { AccessControlEnumerable } from "../lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";
import { IERC20 }                  from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard }         from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 }               from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPermissionlessWithdrawals } from "./interfaces/IPermissionlessWithdrawals.sol";

interface IERC4626Like {

    function allowance(address owner, address spender) external view returns (uint256);

    function asset() external view returns (address);

    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

}

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

contract PermissionlessWithdrawals is IPermissionlessWithdrawals, AccessControlEnumerable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    /**********************************************************************************************/
    /*** Declarations and constructor                                                           ***/
    /**********************************************************************************************/

    uint256 public constant USDS_CONVERSION_PRECISION = 1e12;

    IMainnetControllerLike public immutable mainnetController;

    address public immutable penaltyRecipient;

    mapping(address vault => VaultConfig config) public vaultConfig;
    mapping(address venue => VenueConfig config) public venueConfig;

    constructor(address admin, address mainnetController_, address penaltyRecipient_) {
        require(admin              != address(0), ZeroAdminAddress());
        require(mainnetController_ != address(0), ZeroMainnetControllerAddress());
        require(penaltyRecipient_  != address(0), ZeroPenaltyRecipientAddress());

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        mainnetController = IMainnetControllerLike(mainnetController_);
        penaltyRecipient  = penaltyRecipient_;
    }

    /**********************************************************************************************/
    /*** Admin functions                                                                        ***/
    /**********************************************************************************************/

    function updateVaultConfig(
        address   vault,
        uint256   penaltyAmount,
        bool      whitelisted
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault != address(0), ZeroVaultAddress());
        require(penaltyAmount > 0,   ZeroPenaltyAmount());

        vaultConfig[vault] = VaultConfig({
            penaltyAmount : penaltyAmount,
            whitelisted   : whitelisted
        });

        emit VaultConfigUpdated(vault, penaltyAmount, whitelisted);
    }

    function updateVenueConfig(
        address   venue,
        VenueType venueType,
        bool      whitelisted
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(venue != address(0), ZeroVenueAddress());

        venueConfig[venue] = VenueConfig({
            venueType   : venueType,
            whitelisted : whitelisted
        });

        emit VenueConfigUpdated(venue, venueType, whitelisted);
    }

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    function permissionlessWithdraw(
        address vault,
        address venue,
        address recipient,
        uint256 shares
    )
        external
        override
        nonReentrant
    {
        // Step 1: Validate the vault and recipient

        VaultConfig memory vaultConfig_ = vaultConfig[vault];

        require(vaultConfig_.whitelisted,       VaultNotWhitelisted());
        require(venueConfig[venue].whitelisted, VenueNotWhitelisted());
        require(recipient != address(0),        ZeroRecipientAddress());

        // Step 2: Withdraw the assets from the venue

        address asset           = IERC4626Like(vault).asset();
        uint256 assetsRequested = IERC4626Like(vault).convertToAssets(shares);
        uint256 assetsToTransfer = _validateAndWithdrawFromVenue(vault, venue, asset, assetsRequested);

        // Step 3: Transfer withdrawn assets to the vault

        if (assetsToTransfer > 0) {
            mainnetController.transferAsset(asset, vault, assetsToTransfer);
        }

        // Step 4: Redeem full shares amount
        uint256 fullAmount = IERC4626Like(vault).redeem(shares, address(this), msg.sender);

        // Step 5: Pay penalty amount and transfer remaining assets to the recipient

        require(
            fullAmount >= vaultConfig_.penaltyAmount,
            InsufficientAssetsToCoverPenalty(vaultConfig_.penaltyAmount, fullAmount)
        );

        uint256 recipientAmount = fullAmount - vaultConfig_.penaltyAmount;

        IERC20(asset).safeTransfer(penaltyRecipient, vaultConfig_.penaltyAmount);
        IERC20(asset).safeTransfer(recipient,        recipientAmount);

        emit PermissionlessWithdraw(
            vault,
            msg.sender,
            recipient,
            vaultConfig_.penaltyAmount,
            recipientAmount
        );
    }

    /**********************************************************************************************/
    /*** Internal helper functions                                                              ***/
    /**********************************************************************************************/

    function _validateAndWithdrawFromVenue(
        address vault,
        address venue,
        address asset,
        uint256 assetsRequested
    ) internal returns (uint256 assetsToTransfer) {
        address proxy                = mainnetController.proxy();
        uint256 proxyStartingBalance = IERC20(asset).balanceOf(proxy);
        uint256 vaultStartingBalance = IERC20(asset).balanceOf(vault);

        // Amount to move into the vault.
        assetsToTransfer = assetsRequested - _min(assetsRequested, vaultStartingBalance);

        // Amount proxy must pull from the venue.
        uint256 assetsToWithdraw = assetsToTransfer - _min(assetsToTransfer, proxyStartingBalance);

        // Proxy already holds enough assets to transfer, skip the venue withdrawal.
        if (assetsToWithdraw == 0) return assetsToTransfer;

        VenueConfig memory venueConfig_ = venueConfig[venue];

        if (venueConfig_.venueType == VenueType.AAVE) {
            mainnetController.withdrawAave({
                aToken : venue,
                amount : assetsToWithdraw
            });
        }
        else if (venueConfig_.venueType == VenueType.ERC4626) {
            mainnetController.withdrawERC4626({
                token       : venue,
                amount      : assetsToWithdraw,
                maxSharesIn : type(uint256).max // Relying on controller for slippage protection
            });
        }
        else if (venueConfig_.venueType == VenueType.PSM) {
            mainnetController.mintUSDS(assetsToWithdraw * USDS_CONVERSION_PRECISION);
            mainnetController.swapUSDSToUSDC(assetsToWithdraw);
        }

        uint256 proxyEndingBalance = IERC20(asset).balanceOf(proxy);

        require(
            proxyEndingBalance >= assetsToTransfer,
            InsufficientVenueLiquidity(assetsToTransfer, proxyEndingBalance)
        );
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

}
