// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC1967Utils }    from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { IERC20 }          from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 }       from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { AccessControlEnumerableUpgradeable }
    from "../lib/openzeppelin-contracts-upgradeable/contracts/access/extensions/AccessControlEnumerableUpgradeable.sol";

import { UUPSUpgradeable }
    from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

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

interface PSMLike {

    function gem() external view returns (address);

}

contract PermissionlessWithdrawals is
    IPermissionlessWithdrawals,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{

    using SafeERC20 for IERC20;

    /**********************************************************************************************/
    /*** Declarations                                                                           ***/
    /**********************************************************************************************/

    string  public constant version                   = "1";
    uint256 public constant USDS_CONVERSION_PRECISION = 1e12;

    IMainnetControllerLike public mainnetController;
    address                public penaltyRecipient;

    mapping(address vault => VaultConfig config)                           public vaultConfig;
    mapping(address vault => mapping(address venue => VenueConfig config)) public venueConfig;

    /**********************************************************************************************/
    /*** Initialization and upgradeability                                                      ***/
    /**********************************************************************************************/

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address mainnetController_, address penaltyRecipient_)
        external
        initializer
    {
        require(admin              != address(0), ZeroAdminAddress());
        require(mainnetController_ != address(0), ZeroMainnetControllerAddress());
        require(penaltyRecipient_  != address(0), ZeroPenaltyRecipientAddress());

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        mainnetController = IMainnetControllerLike(mainnetController_);
        penaltyRecipient  = penaltyRecipient_;
    }

    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
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
        address   vault,
        address   venue,
        VenueType venueType,
        bool      whitelisted
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault != address(0), ZeroVaultAddress());
        require(venue != address(0), ZeroVenueAddress());

        venueConfig[vault][venue] = VenueConfig({
            venueType   : venueType,
            whitelisted : whitelisted
        });

        emit VenueConfigUpdated(vault, venue, venueType, whitelisted);
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
        // Step 1: Validate the vault, venue and recipient

        VaultConfig memory vaultConfig_ = vaultConfig[vault];

        require(vaultConfig_.whitelisted,              VaultNotWhitelisted());
        require(venueConfig[vault][venue].whitelisted, VenueNotWhitelisted());
        require(recipient != address(0),               ZeroRecipientAddress());

        // Step 2: Calculate additional amount needed for user withdrawal

        address asset = IERC4626Like(vault).asset();
        address proxy = mainnetController.proxy();

        uint256 assetsRequested      = IERC4626Like(vault).convertToAssets(shares);
        uint256 proxyStartingBalance = IERC20(asset).balanceOf(proxy);
        uint256 vaultStartingBalance = IERC20(asset).balanceOf(vault);

        // Total amount to transfer to the vault for the withdrawal
        uint256 assetsToTransfer = assetsRequested > vaultStartingBalance
            ? assetsRequested - vaultStartingBalance
            : 0;

        // Additional amount needed to be sent to the ALMProxy to send to the vault
        uint256 assetsToWithdraw = assetsToTransfer > proxyStartingBalance
            ? assetsToTransfer - proxyStartingBalance
            : 0;

        // Step 3: Withdraw the assets from the venue if necessary

        if (assetsToWithdraw > 0) {
            _withdrawFromVenue(vault, venue, asset, proxy, assetsToWithdraw, proxyStartingBalance);
        }

        // Step 4: Transfer withdrawn assets to the vault if necessary

        if (assetsToTransfer > 0) {
            mainnetController.transferAsset(asset, vault, assetsToTransfer);
        }

        // Step 5: Redeem full shares amount

        uint256 fullAmount = IERC4626Like(vault).redeem(shares, address(this), msg.sender);

        // Step 6: Pay penalty amount and transfer remaining assets to the recipient

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

    function _withdrawFromVenue(
        address vault,
        address venue,
        address asset,
        address proxy,
        uint256 assetsToWithdraw,
        uint256 proxyStartingBalance
    ) internal {
        VenueConfig memory venueConfig_ = venueConfig[vault][venue];

        if (venueConfig_.venueType == VenueType.AAVE) {
            require(IATokenLike(venue).UNDERLYING_ASSET_ADDRESS() == asset, IncorrectVenue());

            mainnetController.withdrawAave({
                aToken : venue,
                amount : assetsToWithdraw
            });
        }
        else if (venueConfig_.venueType == VenueType.ERC4626) {
            require(IERC4626Like(venue).asset() == asset, IncorrectVenue());

            mainnetController.withdrawERC4626({
                token       : venue,
                amount      : assetsToWithdraw,
                maxSharesIn : type(uint256).max // Relying on controller for slippage protection
            });
        }
        else if (venueConfig_.venueType == VenueType.PSM) {
            require(PSMLike(venue).gem() == asset, IncorrectVenue());

            mainnetController.mintUSDS(assetsToWithdraw * USDS_CONVERSION_PRECISION);
            mainnetController.swapUSDSToUSDC(assetsToWithdraw);
        }

        uint256 amountWithdrawn 
            = IERC20(asset).balanceOf(proxy) - proxyStartingBalance;

        require(
            amountWithdrawn >= assetsToWithdraw,
            InsufficientVenueLiquidity(assetsToWithdraw, amountWithdrawn)
        );
    }

}
