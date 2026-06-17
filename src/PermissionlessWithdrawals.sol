// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { AccessControlEnumerable } from "../lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";
import { IERC20 }                  from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }               from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPermissionlessWithdrawals } from "./interfaces/IPermissionlessWithdrawals.sol";

interface IATokenLike {

    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

}

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

contract PermissionlessWithdrawals is IPermissionlessWithdrawals, AccessControlEnumerable {

    using SafeERC20 for IERC20;

    /**********************************************************************************************/
    /*** Declarations and constructor                                                           ***/
    /**********************************************************************************************/

    IMainnetControllerLike public immutable mainnetController;

    address public immutable penaltyRecipient;

    mapping(address vault => VaultConfig config) public vaultConfig;

    constructor(address admin, address mainnetController_, address penaltyRecipient_) {
        require(admin              != address(0), InvalidAdminAddress());
        require(mainnetController_ != address(0), InvalidMainnetControllerAddress());
        require(penaltyRecipient_  != address(0), InvalidPenaltyRecipientAddress());

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        mainnetController = IMainnetControllerLike(mainnetController_);
        penaltyRecipient  = penaltyRecipient_;
    }

    /**********************************************************************************************/
    /*** Admin functions                                                                        ***/
    /**********************************************************************************************/

    function updateVaultConfig(
        address   vault,
        address   venue,
        VenueType venueType,
        uint256   penaltyAmount,
        bool      whitelisted
    )
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault  != address(0), InvalidVaultAddress());
        require(venue  != address(0), InvalidVenueAddress());

        // TODO: Validate the venue type is compatible with the vault

        vaultConfig[vault] = VaultConfig({
            venue         : venue,
            venueType     : venueType,
            penaltyAmount : penaltyAmount,
            whitelisted   : whitelisted
        });

        emit VaultConfigUpdated(vault, venue, venueType, penaltyAmount, whitelisted);
    }

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    function permissionlessWithdraw(address vault, address recipient, uint256 shares) external {
        // Step 1: Validate the vault and recipient

        VaultConfig memory config = vaultConfig[vault];

        require(config.whitelisted, VaultNotWhitelisted());
        require(recipient != address(0),  InvalidRecipientAddress());

        // Step 2: Withdraw the assets from the venue

        address asset           = IERC4626Like(vault).asset();
        uint256 assetsRequested = IERC4626Like(vault).convertToAssets(shares);

        _validateAndWithdrawFromVenue(vault, asset, assetsRequested);

        // Step 3: Transfer assets to the vault

        mainnetController.transferAsset(asset, vault, assetsRequested);

        // Step 4: Redeem full shares amount
        uint256 fullAmount = IERC4626Like(vault).redeem(shares, address(this), msg.sender);

        // Step 5: Pay penalty amount and transfer remaining assets to the recipient

        uint256 recipientAmount = fullAmount - config.penaltyAmount;

        IERC20(asset).safeTransfer(penaltyRecipient, config.penaltyAmount);
        IERC20(asset).safeTransfer(recipient,        recipientAmount);

        emit PermissionlessWithdraw(
            vault,
            msg.sender,
            recipient,
            config.penaltyAmount,
            recipientAmount
        );
    }

    function _validateAndWithdrawFromVenue(
        address vault,
        address asset,
        uint256 assetsRequested
    ) internal {
        VaultConfig memory config = vaultConfig[vault];

        address proxy = mainnetController.proxy();

        uint256 startingBalance = IERC20(asset).balanceOf(proxy);

        // Proxy already holds enough idle liquidity, nothing to withdraw from the venue.
        if (startingBalance >= assetsRequested) return;

        uint256 shortfall = assetsRequested - startingBalance;

        if (config.venueType == VenueType.AAVE) {
            mainnetController.withdrawAave({
                aToken : config.venue,
                amount : shortfall
            });
        } else if (config.venueType == VenueType.ERC4626) {
            mainnetController.withdrawERC4626({
                token       : config.venue,
                amount      : shortfall,
                maxSharesIn : type(uint256).max // Relying on controller for slippage protection
            });
        } else if (config.venueType == VenueType.PSM) {
            mainnetController.mintUSDS(shortfall * 1e12); // @TODO : hard code is fine?
            mainnetController.swapUSDSToUSDC(shortfall);
        }

        uint256 endingBalance = IERC20(asset).balanceOf(proxy);

        require(
            endingBalance >= assetsRequested,
            InsufficientVenueLiquidity(assetsRequested, endingBalance)
        );
    }

}
