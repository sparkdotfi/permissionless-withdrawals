// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 }          from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {
    SafeERC20
} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    AccessControlEnumerable
} from "../lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

import { IPermissionlessWithdrawals } from "./interfaces/IPermissionlessWithdrawals.sol";

interface IALMProxyLike {

    function CONTROLLER() external view returns (bytes32);

    function hasRole(bytes32 role, address account) external view returns (bool);

}

interface IATokenLike {

    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

}

interface IControllerLike {

    function proxy() external view returns (address);

}

interface IERC20Like {

    function balanceOf(address account) external view returns (uint256);

}

interface IERC721Like {

    function safeTransferFrom(address from, address to, uint256 tokenId) external payable;

}

interface IERC4626Like {

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);

    function asset() external view returns (address);

    function convertToAssets(uint256 shares) external view returns (uint256);

}

interface IPSMLike {

    function gem() external view returns (address);

}

abstract contract PermissionlessWithdrawals is
    IPermissionlessWithdrawals,
    AccessControlEnumerable,
    ReentrancyGuard
{

    using SafeERC20 for IERC20;

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    /// @inheritdoc IPermissionlessWithdrawals
    uint256 public constant override USDS_CONVERSION_PRECISION = 1e12;

    /**********************************************************************************************/
    /*** Declarations                                                                           ***/
    /**********************************************************************************************/

    /// @inheritdoc IPermissionlessWithdrawals
    address public immutable controller;

    /// @inheritdoc IPermissionlessWithdrawals
    address public immutable proxy;

    mapping(address vault => VaultConfig config) _vaultConfigs;

    /// @inheritdoc IPermissionlessWithdrawals
    address public penaltyRecipient;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(address admin_, address controller_, address penaltyRecipient_) {
        require(admin_            != address(0), ZeroAdminAddress());
        require(controller_       != address(0), ZeroControllerAddress());
        require(penaltyRecipient_ != address(0), ZeroPenaltyRecipientAddress());

        proxy = IControllerLike(controller = controller_).proxy();

        _revertIfControllerProxyMismatch();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        penaltyRecipient = penaltyRecipient_;
    }

    /**********************************************************************************************/
    /*** External Admin Functions                                                               ***/
    /**********************************************************************************************/

    /// @inheritdoc IPermissionlessWithdrawals
    function setVaultConfig(address vault, uint256 penaltyAmount, bool whitelisted)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault != address(0), ZeroVaultAddress());
        require(penaltyAmount > 0,   ZeroPenaltyAmount());

        VaultConfig storage vaultConfig = _vaultConfigs[vault];

        vaultConfig.penaltyAmount = penaltyAmount;
        vaultConfig.whitelisted   = whitelisted;

        emit VaultConfigSet(vault, penaltyAmount, whitelisted);
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function setVenueType(address vault, address venue, VenueType venueType)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault != address(0), ZeroVaultAddress());
        require(venue != address(0), ZeroVenueAddress());

        address asset = IERC4626Like(vault).asset();

        require(
            venueType == VenueType.NONE ||
            (
                venueType == VenueType.AAVE &&
                IATokenLike(venue).UNDERLYING_ASSET_ADDRESS() == asset
            ) ||
            (
                venueType == VenueType.ERC4626 &&
                IERC4626Like(venue).asset() == asset
            ) ||
            (
                venueType == VenueType.PSM &&
                IPSMLike(venue).gem() == asset
            ),
            IncorrectVenue()
        );

        _vaultConfigs[vault].venueTypes[venue] = venueType;

        emit VenueTypeSet(vault, venue, venueType);
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function setPenaltyRecipient(address recipient)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(recipient != address(0), ZeroPenaltyRecipientAddress());

        penaltyRecipient = recipient;

        emit PenaltyRecipientSet(recipient);
    }

    /**********************************************************************************************/
    /*** External Asset Recovery Functions                                                      ***/
    /**********************************************************************************************/

    /// @inheritdoc IPermissionlessWithdrawals
    function recoverETH(address recipient)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(recipient != address(0), ZeroRecipientAddress());

        ( bool success, ) = recipient.call{value : address(this).balance}("");

        require(success, TransferETHFailed());
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function recoverERC20(address token, address recipient)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(token     != address(0), ZeroTokenAddress());
        require(recipient != address(0), ZeroRecipientAddress());

        IERC20(token).safeTransfer(recipient, IERC20Like(token).balanceOf(address(this)));
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function recoverERC721(address token, address recipient, uint256 tokenId)
        external
        payable
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(token     != address(0), ZeroTokenAddress());
        require(recipient != address(0), ZeroRecipientAddress());

        IERC721Like(token).safeTransferFrom{value: msg.value}(address(this), recipient, tokenId);
    }

    /**********************************************************************************************/
    /*** External Interactive Functions                                                         ***/
    /**********************************************************************************************/

    /// @inheritdoc IPermissionlessWithdrawals
    function permissionlessWithdraw(address vault, address venue, address recipient, uint256 shares)
        external
        override
        nonReentrant
    {
        // Step 1: Validation.

        require(vault     != address(0), ZeroVaultAddress());
        require(recipient != address(0), ZeroRecipientAddress());
        require(shares    != 0,          ZeroShares());

        _revertIfControllerProxyMismatch();

        VaultConfig storage vaultConfig = _vaultConfigs[vault];

        require(vaultConfig.whitelisted, VaultNotWhitelisted());

        // Step 2: Calculate additional amount needed for user withdrawal.

        address asset = IERC4626Like(vault).asset();

        uint256 assetsRequested      = IERC4626Like(vault).convertToAssets(shares);
        uint256 proxyStartingBalance = IERC20Like(asset).balanceOf(proxy);
        uint256 vaultStartingBalance = IERC20Like(asset).balanceOf(vault);

        // Total amount to transfer to the vault for the withdrawal.
        uint256 assetsToTransfer = assetsRequested > vaultStartingBalance
            ? assetsRequested - vaultStartingBalance
            : 0;

        // Additional amount needed to be sent to the ALMProxy to send to the vault.
        uint256 assetsToWithdraw = assetsToTransfer > proxyStartingBalance
            ? assetsToTransfer - proxyStartingBalance
            : 0;

        // Step 3: Withdraw the assets from the venue if necessary.

        if (assetsToWithdraw > 0) {
            _withdrawFromVenue(vault, venue, assetsToWithdraw);
        }

        // Step 4: Transfer withdrawn assets to the vault if necessary.

        if (assetsToTransfer > 0) {
            uint256 balance = IERC20Like(asset).balanceOf(proxy);

            require(balance >= assetsToTransfer, InsufficientBalance(assetsToTransfer, balance));

            _transferAsset(asset, vault, assetsToTransfer);
        }

        // Step 5: Redeem full shares amount into this contract.

        uint256 fullAmount = IERC4626Like(vault).redeem(shares, address(this), msg.sender);

        // Step 6: Pay penalty amount and transfer remaining assets to the recipient.

        uint256 penaltyAmount_ = vaultConfig.penaltyAmount;

        require(
            fullAmount >= penaltyAmount_,
            InsufficientAssetsToCoverPenalty(penaltyAmount_, fullAmount)
        );

        uint256 recipientAmount = fullAmount - penaltyAmount_;

        IERC20(asset).safeTransfer(penaltyRecipient, penaltyAmount_);
        IERC20(asset).safeTransfer(recipient,        recipientAmount);

        emit PermissionlessWithdraw(
            vault,
            msg.sender,
            recipient,
            shares,
            penaltyAmount_,
            recipientAmount
        );
    }

    /**********************************************************************************************/
    /*** External View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    /// @inheritdoc IPermissionlessWithdrawals
    function getVaultIsWhitelisted(address vault) external view returns (bool isWhitelisted) {
        return _vaultConfigs[vault].whitelisted;
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function getVaultPenaltyAmount(address vault) external view returns (uint256 penaltyAmount) {
        return _vaultConfigs[vault].penaltyAmount;
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function getVenueType(address vault, address venue)
        external
        view
        returns (VenueType venueType)
    {
        return _vaultConfigs[vault].venueTypes[venue];
    }

    /**********************************************************************************************/
    /*** Internal Interactive Functions                                                         ***/
    /**********************************************************************************************/

    function _withdrawFromVenue(address vault, address venue, uint256 amount) internal {
        VenueType venueType = _vaultConfigs[vault].venueTypes[venue];

        if (venueType == VenueType.AAVE) {
            return _withdrawAave(venue, amount);
        }

        if (venueType == VenueType.ERC4626) {
            return _withdrawERC4626(venue, amount, type(uint256).max);
        }

        if (venueType == VenueType.PSM) {
            _mintUSDS(amount * USDS_CONVERSION_PRECISION);
            _swapUSDSToUSDC(amount);
            return;
        }

        revert VenueTypeNotSet();
    }

    /**********************************************************************************************/
    /*** Internal View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    function _revertIfControllerProxyMismatch() internal view {
        require(
            IALMProxyLike(proxy).hasRole(IALMProxyLike(proxy).CONTROLLER(), controller),
            ControllerProxyMismatch()
        );
    }

    /**********************************************************************************************/
    /*** Controller Interaction Hooks                                                           ***/
    /**********************************************************************************************/

    function _transferAsset(address asset, address destination, uint256 amount) internal virtual;

    function _withdrawAave(address aToken, uint256 amount) internal virtual;

    function _withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn) internal virtual;

    function _mintUSDS(uint256 usdsAmount) internal virtual;

    function _swapUSDSToUSDC(uint256 usdcAmount) internal virtual;

}
