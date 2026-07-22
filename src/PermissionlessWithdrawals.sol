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

abstract contract PermissionlessWithdrawals is
    IPermissionlessWithdrawals,
    AccessControlEnumerable,
    ReentrancyGuard
{

    using SafeERC20 for IERC20;

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant _USDS_CONVERSION_PRECISION = 1e12;

    /**********************************************************************************************/
    /*** Declarations                                                                           ***/
    /**********************************************************************************************/

    /// @inheritdoc IPermissionlessWithdrawals
    address public immutable override controller;

    /// @inheritdoc IPermissionlessWithdrawals
    address public immutable override proxy;

    mapping(address vault => VaultConfig config) _vaultConfigs;

    mapping(address venue => uint256 maxSharesInRatio) _venueMaxSharesInRatios;

    /// @inheritdoc IPermissionlessWithdrawals
    address public override penaltyRecipient;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(address admin_, address controller_, address penaltyRecipient_) {
        require(admin_      != address(0), ZeroAdminAddress());
        require(controller_ != address(0), ZeroControllerAddress());

        _setPenaltyRecipient(penaltyRecipient_);

        proxy = IControllerLike(controller = controller_).proxy();

        // NOTE: Not calling `_revertIfNotRelayer` here to simplify deployment as this contract's
        //       address will be needed before granting it the relayer/allocator role.
        _revertIfControllerProxyMismatch();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /**********************************************************************************************/
    /*** External Admin Functions                                                               ***/
    /**********************************************************************************************/

    /// @inheritdoc IPermissionlessWithdrawals
    function setVaultConfig(address vault, uint256 maxExchangeRate, uint256 penaltyAmount)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault != address(0), ZeroVaultAddress());

        VaultConfig storage vaultConfig = _vaultConfigs[vault];

        emit VaultConfigSet(
            vault,
            vaultConfig.maxExchangeRate = maxExchangeRate,
            vaultConfig.penaltyAmount = penaltyAmount
        );
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function setVaultVenueType(address vault, address venue, VenueType venueType)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault != address(0), ZeroVaultAddress());
        require(venue != address(0), ZeroVenueAddress());

        // NOTE: The asset of the venue is not checked against the asset of the vault after being
        //       set here, since transfers will fail anyway in `permissionlessWithdraw` if the
        //       assets are not equal.

        require(
            venueType == VenueType.UNSET ||
            (
                venueType == VenueType.AAVE &&
                IATokenLike(venue).UNDERLYING_ASSET_ADDRESS() == IERC4626Like(vault).asset()
            ) ||
            (
                venueType == VenueType.ERC4626 &&
                IERC4626Like(venue).asset() == IERC4626Like(vault).asset()
            ) ||
            (
                venueType == VenueType.PSM &&
                venue == _getPSM() &&
                _getPSMUSDC() == IERC4626Like(vault).asset()
            ),
            IncorrectVenue()
        );

        emit VaultVenueTypeSet(vault, venue, _vaultConfigs[vault].venueTypes[venue] = venueType);
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function setPenaltyRecipient(address recipient)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setPenaltyRecipient(recipient);
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function setVenueMaxSharesInRatio(address venue, uint256 maxSharesInRatio)
        external
        override
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        emit VenueMaxSharesInRatioSet(venue, _venueMaxSharesInRatios[venue] = maxSharesInRatio);
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
        require(token     != controller, TokenIsController());

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
        require(token     != controller, TokenIsController());

        IERC721Like(token).safeTransferFrom{value: msg.value}(address(this), recipient, tokenId);
    }

    /**********************************************************************************************/
    /*** External Interactive Functions                                                         ***/
    /**********************************************************************************************/

    /// @inheritdoc IPermissionlessWithdrawals
    function permissionlessWithdraw(
        address vault,
        address venue,
        address recipient,
        uint256 shares,
        uint256 minAssetsToRecipient
    )
        external
        override
        nonReentrant
    {
        // Step 1: Validation.
        // NOTE: Venue can be zero address if a withdrawal from a venue is not expected or desired.

        require(vault     != address(0), ZeroVaultAddress());
        require(recipient != address(0), ZeroRecipientAddress());
        require(shares    != 0,          ZeroShares());

        _revertIfControllerProxyMismatch();
        _revertIfNotRelayer();

        require(_vaultConfigs[vault].maxExchangeRate != 0, VaultNotWhitelisted());

        // Step 2: Calculate additional amount needed for user withdrawal.

        address asset = IERC4626Like(vault).asset();

        uint256 assetsRequested = IERC4626Like(vault).convertToAssets(shares);

        require(
            assetsRequested * 1e18 <= shares * _vaultConfigs[vault].maxExchangeRate,
            ExchangeRateTooHigh()
        );

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

            require(
                balance >= assetsToTransfer,
                InsufficientAssetsInALMProxy(assetsToTransfer, balance)
            );

            _transferAsset(asset, vault, assetsToTransfer);
        }

        // Step 5: Redeem full shares amount into this contract.

        // NOTE: Since the assumption is that the vault is a SparkVault implementation, the return
        //       of the `redeem` function can be trusted and used as the final payout amount.
        uint256 fullAmount = IERC4626Like(vault).redeem(shares, address(this), msg.sender);

        // Step 6: Pay penalty amount and transfer remaining assets to the recipient.

        uint256 penaltyAmount_ = _vaultConfigs[vault].penaltyAmount;

        require(
            fullAmount >= penaltyAmount_,
            InsufficientAssetsToCoverPenalty(penaltyAmount_, fullAmount)
        );

        uint256 recipientAmount = fullAmount - penaltyAmount_;

        require(
            recipientAmount >= minAssetsToRecipient,
            InsufficientAssetsForRecipient(recipientAmount, minAssetsToRecipient)
        );

        IERC20(asset).safeTransfer(penaltyRecipient, penaltyAmount_);
        IERC20(asset).safeTransfer(recipient,        recipientAmount);

        emit PermissionlessWithdraw(
            vault,
            venue,
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
    function getVaultIsWhitelisted(address vault)
        external
        view
        override
        returns (bool isWhitelisted)
    {
        return _vaultConfigs[vault].maxExchangeRate != 0;
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function getVaultMaxExchangeRate(address vault)
        external
        view
        override
        returns (uint256 maxExchangeRate)
    {
        return _vaultConfigs[vault].maxExchangeRate;
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function getVaultPenaltyAmount(address vault)
        external
        view
        override
        returns (uint256 penaltyAmount)
    {
        return _vaultConfigs[vault].penaltyAmount;
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function getVaultVenueType(address vault, address venue)
        external
        view
        override
        returns (VenueType venueType)
    {
        return _vaultConfigs[vault].venueTypes[venue];
    }

    /// @inheritdoc IPermissionlessWithdrawals
    function getVenueMaxSharesInRatio(address venue)
        external
        view
        override
        returns (uint256 maxSharesInRatio)
    {
        return _venueMaxSharesInRatios[venue];
    }

    /**********************************************************************************************/
    /*** Internal Interactive Functions                                                         ***/
    /**********************************************************************************************/

    function _setPenaltyRecipient(address recipient) internal {
        require(recipient != address(0), ZeroPenaltyRecipientAddress());

        emit PenaltyRecipientSet(penaltyRecipient = recipient);
    }

    function _withdrawFromVenue(address vault, address venue, uint256 amount) internal {
        VenueType venueType = _vaultConfigs[vault].venueTypes[venue];

        if (venueType == VenueType.AAVE) {
            return _withdrawAave(venue, amount);
        }

        if (venueType == VenueType.ERC4626) {
            return _withdrawERC4626(venue, amount, (amount * _venueMaxSharesInRatios[venue]) / 1e18);
        }

        if (venueType == VenueType.PSM) {
            return _withdrawPSM(amount);
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

    function _revertIfNotRelayer() internal view {
        require(_isRelayer(), NotRelayerOnController());
    }

    /**********************************************************************************************/
    /*** Controller Interaction Hooks                                                           ***/
    /**********************************************************************************************/

    /**
     * @dev   Transfers assets from the ALMProxy to the specified destination address.
     * @param asset       The address of the asset to transfer.
     * @param destination The address receiving the assets (usually the vault).
     * @param amount      The amount of assets to transfer.
     */
    function _transferAsset(address asset, address destination, uint256 amount) internal virtual;

    /**
     * @dev   Withdraws assets from Aave to the ALMProxy via the controller.
     * @param aToken The address of the Aave aToken to withdraw from.
     * @param amount The amount of underlying assets to withdraw.
     */
    function _withdrawAave(address aToken, uint256 amount) internal virtual;

    /**
     * @dev   Withdraws assets from a generic ERC4626 venue to the ALMProxy via the controller.
     * @param token       The address of the ERC4626 venue.
     * @param amount      The amount of underlying assets to withdraw.
     * @param maxSharesIn The maximum number of shares that can be burned for the withdrawal.
     */
    function _withdrawERC4626(address token, uint256 amount, uint256 maxSharesIn) internal virtual;

    /**
     * @dev   Withdraws assets from the PSM venue to the ALMProxy via the controller.
     * @param amount The amount of underlying assets (i.e. USDC) to withdraw.
     */
    function _withdrawPSM(uint256 amount) internal virtual;

    /// @dev Returns the address of the PSM.
    function _getPSM() internal view virtual returns (address);

    /// @dev Returns the address of the PSM USDC token.
    function _getPSMUSDC() internal view virtual returns (address);

    /// @dev Returns true if this contract is a relayer/allocator.
    function _isRelayer() internal view virtual returns (bool);

}
