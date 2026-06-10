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

    uint256 public constant MAX_PENALTY_BPS = 200; // 2% penalty

    address public immutable penaltyRecipient;

    IMainnetControllerLike public immutable mainnetController;

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
            whitelisted : whitelisted,
            aToken      : aToken
        });

        emit VaultConfigUpdated(vault, aToken, whitelisted);
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

        uint256 userShares = IERC4626Like(vault).balanceOf(msg.sender);

        require(shares <= userShares, InsufficientShares(shares, userShares));

        uint256 allowance = IERC4626Like(vault).allowance(msg.sender, address(this));

        require(shares <= allowance, InsufficientAllowance(shares, allowance));

        // Step 3: Pay the penalty

        uint256 penaltyShares = (shares * MAX_PENALTY_BPS) / 1e4;

        if (penaltyShares > 0) {
            IERC4626Like(vault).redeem(penaltyShares, penaltyRecipient, msg.sender);
        }

        // Step 4: Withdraw underlying from Aave

        uint256 sharesToRedeem  = shares - penaltyShares;
        uint256 assetsToFund    = IERC4626Like(vault).convertToAssets(sharesToRedeem);
        uint256 assetsWithdrawn = mainnetController.withdrawAave(vaultConfig_.aToken, assetsToFund);

        require(
            assetsWithdrawn >= assetsToFund,
            InsufficientATokenLiquidity(assetsToFund, assetsWithdrawn)
        );

        // Step 5: Transfer assets to the vault and redeem shares from the vault

        address underlying = IERC4626Like(vault).asset();

        mainnetController.transferAsset(underlying, vault, assetsWithdrawn);

        IERC4626Like(vault).redeem(sharesToRedeem, recipient, msg.sender);

        emit PermissionlessWithdraw(
            msg.sender,
            vault,
            recipient,
            penaltyShares,
            sharesToRedeem,
            assetsWithdrawn
        );
    }

}
