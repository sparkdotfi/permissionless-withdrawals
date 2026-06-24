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

    function asset() external view returns (address);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

}

interface IPSMLike {

    function gem() external view returns (address);

}

abstract contract PermissionlessWithdrawals is
    IPermissionlessWithdrawals,
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{

    using SafeERC20 for IERC20;

    /**********************************************************************************************/
    /*** PermissionlessWithdrawals Storage Domain                                               ***/
    /**********************************************************************************************/

    /// @custom:storage-location erc7201:spark.withdrawals.storage.PermissionlessWithdrawals.v1
    struct PermissionlessWithdrawalsStorage {
        address controller;
        address penaltyRecipient;
        mapping(address vault => VaultConfig config) vaultConfig;
        mapping(address vault => mapping(address venue => VenueType venueType)) venueTypes;
    }
    // keccak256(abi.encode(uint256(keccak256("spark.withdrawals.storage.PermissionlessWithdrawals.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant _PERMISSIONLESS_WITHDRAWALS_STORAGE_LOCATION =
        0x55695ff96e8e70f27abe05ec6edfd21471d0cc570eaae83e862e9d6b6779da00;

    function _getPermissionlessWithdrawalsStorage() 
        internal
        pure
        returns (PermissionlessWithdrawalsStorage storage $) 
    {
        assembly {
            $.slot := _PERMISSIONLESS_WITHDRAWALS_STORAGE_LOCATION
        }
    }

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    string  public constant override VERSION = "1.0.0";

    uint256 public constant override USDS_CONVERSION_PRECISION = 1e12;

    /**********************************************************************************************/
    /*** Initialization and upgradeability                                                      ***/
    /**********************************************************************************************/

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address controller_, address penaltyRecipient_)
        external
        initializer
    {
        require(admin             != address(0), ZeroAdminAddress());
        require(controller_       != address(0), ZeroControllerAddress());
        require(penaltyRecipient_ != address(0), ZeroPenaltyRecipientAddress());

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        PermissionlessWithdrawalsStorage storage $ = _getPermissionlessWithdrawalsStorage();

        $.controller       = controller_;
        $.penaltyRecipient = penaltyRecipient_;
    }

    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

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

        _getPermissionlessWithdrawalsStorage().vaultConfig[vault] = VaultConfig({
            penaltyAmount : penaltyAmount,
            whitelisted   : whitelisted
        });

        emit VaultConfigUpdated(vault, penaltyAmount, whitelisted);
    }

    function setVenueType(
        address   vault,
        address   venue,
        VenueType venueType
    )
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault != address(0), ZeroVaultAddress());
        require(venue != address(0), ZeroVenueAddress());

        _getPermissionlessWithdrawalsStorage().venueTypes[vault][venue] = venueType;

        emit VenueTypeSet(vault, venue, venueType);
    }

    function setPenaltyRecipient(address penaltyRecipient_)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(penaltyRecipient_ != address(0), ZeroPenaltyRecipientAddress());

        _getPermissionlessWithdrawalsStorage().penaltyRecipient = penaltyRecipient_;

        emit PenaltyRecipientSet(penaltyRecipient_);
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

        PermissionlessWithdrawalsStorage storage $ = _getPermissionlessWithdrawalsStorage();

        VaultConfig memory vaultConfig_ = $.vaultConfig[vault];
        VenueType          venueType    = $.venueTypes[vault][venue];

        require(vaultConfig_.whitelisted,    VaultNotWhitelisted());
        require(venueType != VenueType.NONE, VenueTypeNotSet());
        require(recipient != address(0),     ZeroRecipientAddress());

        // Step 2: Calculate additional amount needed for user withdrawal

        address asset = IERC4626Like(vault).asset();

        uint256 assetsRequested      = IERC4626Like(vault).convertToAssets(shares);
        uint256 proxyStartingBalance = IERC20(asset).balanceOf(_proxy());
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
            _withdrawFromVenue(venueType, venue, asset, _proxy(), assetsToWithdraw, proxyStartingBalance);
        }

        // Step 4: Transfer withdrawn assets to the vault if necessary

        if (assetsToTransfer > 0) {
            _transferAsset(asset, vault, assetsToTransfer);
        }

        // Step 5: Redeem full shares amount into this contract

        uint256 fullAmount = IERC4626Like(vault).redeem(shares, address(this), msg.sender);

        // Step 6: Pay penalty amount and transfer remaining assets to the recipient

        require(
            fullAmount >= vaultConfig_.penaltyAmount,
            InsufficientAssetsToCoverPenalty(vaultConfig_.penaltyAmount, fullAmount)
        );

        uint256 recipientAmount = fullAmount - vaultConfig_.penaltyAmount;

        IERC20(asset).safeTransfer($.penaltyRecipient, vaultConfig_.penaltyAmount);
        IERC20(asset).safeTransfer(recipient,          recipientAmount);

        emit PermissionlessWithdraw(
            vault,
            msg.sender,
            recipient,
            vaultConfig_.penaltyAmount,
            recipientAmount
        );
    }

    /**********************************************************************************************/
    /*** View/Pure functions                                                                    ***/
    /**********************************************************************************************/

    function getController() public view override returns (address) {
        return _getPermissionlessWithdrawalsStorage().controller;
    }

    function getImplementation() public view override returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function getPenaltyRecipient() public view override returns (address) {
        return _getPermissionlessWithdrawalsStorage().penaltyRecipient;
    }

    function getVaultConfig(address vault) public view override returns (VaultConfig memory) {
        return _getPermissionlessWithdrawalsStorage().vaultConfig[vault];
    }

    function getVenueType(address vault, address venue) public view override returns (VenueType) {
        return _getPermissionlessWithdrawalsStorage().venueTypes[vault][venue];
    }

    /**********************************************************************************************/
    /*** Internal helper functions                                                              ***/
    /**********************************************************************************************/

    function _withdrawFromVenue(
        VenueType venueType,
        address   venue,
        address   asset,
        address   proxy,
        uint256   assetsToWithdraw,
        uint256   proxyStartingBalance
    ) internal {
        if (venueType == VenueType.AAVE) {
            require(IATokenLike(venue).UNDERLYING_ASSET_ADDRESS() == asset, IncorrectVenue());

            _withdrawAave(venue, assetsToWithdraw);
        }
        else if (venueType == VenueType.ERC4626) {
            require(IERC4626Like(venue).asset() == asset, IncorrectVenue());

            _withdrawERC4626(venue, assetsToWithdraw, type(uint256).max);
        }
        else if (venueType == VenueType.PSM) {
            require(IPSMLike(venue).gem() == asset, IncorrectVenue());

            _mintUSDS(assetsToWithdraw * USDS_CONVERSION_PRECISION);
            _swapUSDSToUSDC(assetsToWithdraw);
        }

        uint256 amountWithdrawn 
            = IERC20(asset).balanceOf(proxy) - proxyStartingBalance;

        require(
            amountWithdrawn >= assetsToWithdraw,
            InsufficientVenueLiquidity(assetsToWithdraw, amountWithdrawn)
        );
    }

    /**********************************************************************************************/
    /*** MainnetController interaction hooks                                                    ***/
    /**********************************************************************************************/

    function _proxy() internal view virtual returns (address proxy);

    function _transferAsset(address asset, address destination, uint256 amount) internal virtual;

    function _withdrawAave(address aToken, uint256 amount) internal virtual;

    function _withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn) internal virtual;

    function _mintUSDS(uint256 usdsAmount) internal virtual;

    function _swapUSDSToUSDC(uint256 usdcAmount) internal virtual;

}
