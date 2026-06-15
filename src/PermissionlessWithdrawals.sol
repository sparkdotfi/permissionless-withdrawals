// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { AccessControlEnumerable } from "../lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

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

interface IATokenLike {

    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

}

interface IMainnetControllerLike {

    function transferAsset(address asset, address destination, uint256 amount) external;

    function withdrawAave(address aToken, uint256 amount) external returns (uint256);

}

contract PermissionlessWithdrawals is IPermissionlessWithdrawals, AccessControlEnumerable {

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
        address vault,
        address aToken,
        uint256 penaltyShares,
        bool    whitelisted
    )
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vault  != address(0), InvalidVaultAddress());
        require(aToken != address(0), InvalidATokenAddress());

        require(
            IATokenLike(aToken).UNDERLYING_ASSET_ADDRESS() == IERC4626Like(vault).asset(),
            InvalidATokenUnderlying()
        );

        vaultConfig[vault] = VaultConfig({
            aToken        : aToken,
            penaltyShares : penaltyShares,
            whitelisted   : whitelisted
        });

        emit VaultConfigUpdated(vault, aToken, penaltyShares, whitelisted);
    }

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    function permissionlessWithdraw(address vault, address recipient, uint256 shares) external {
        // Step 1: Validate the vault and recipient

        VaultConfig memory vaultConfig_ = vaultConfig[vault];

        require(vaultConfig_.whitelisted, VaultNotWhitelisted());
        require(recipient != address(0),  InvalidRecipientAddress());

        // Step 2: Validate the user has sufficient shares and allowance

        require(
            shares > vaultConfig_.penaltyShares,
            InsufficientSharesToCoverPenalty(shares, vaultConfig_.penaltyShares)
        );

        uint256 userShares = IERC4626Like(vault).balanceOf(msg.sender);

        require(shares <= userShares, InsufficientShares(shares, userShares));

        uint256 allowance = IERC4626Like(vault).allowance(msg.sender, address(this));

        require(shares <= allowance, InsufficientAllowance(shares, allowance));

        // Step 3: Withdraw underlying from Aave

        uint256 assetsRequested = IERC4626Like(vault).convertToAssets(shares);
        uint256 assetsWithdrawn = mainnetController.withdrawAave(vaultConfig_.aToken, assetsRequested);

        require(
            assetsWithdrawn >= assetsRequested,
            InsufficientATokenLiquidity(assetsRequested, assetsWithdrawn)
        );

        // Step 4: Transfer assets to the vault

        mainnetController.transferAsset(IERC4626Like(vault).asset(), vault, assetsWithdrawn);

        // Step 5: Pay the penalty

        if (vaultConfig_.penaltyShares > 0) {
            IERC4626Like(vault).redeem(vaultConfig_.penaltyShares, penaltyRecipient, msg.sender);
        }

        // Step 6: Redeem shares from the vault to the recipient

        uint256 sharesToRecipient = shares - vaultConfig_.penaltyShares;

        IERC4626Like(vault).redeem(sharesToRecipient, recipient, msg.sender);

        emit PermissionlessWithdraw(
            msg.sender,
            vault,
            assetsWithdrawn,
            recipient,
            vaultConfig_.penaltyShares,
            sharesToRecipient
        );
    }

}
