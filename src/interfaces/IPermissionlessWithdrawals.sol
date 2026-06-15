// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

interface IPermissionlessWithdrawals {

    /**********************************************************************************************/
    /*** Types                                                                                  ***/
    /**********************************************************************************************/

    /**
     *  @dev   Configuration for a specific vault.
     *  @param whitelisted   Whether the vault is allowed to be used with this contract.
     *  @param aToken        Address of the Aave aToken corresponding to the vault.
     *  @param penaltyShares The number of shares to be sent to the penalty recipient.
     */
    struct VaultConfig {
        bool    whitelisted;
        address aToken;
        uint256 penaltyShares;
    }

    /**********************************************************************************************/
    /*** Errors                                                                                 ***/
    /**********************************************************************************************/

    error InsufficientAllowance(uint256 requiredAllowance, uint256 currentAllowance);
    error InsufficientATokenLiquidity(uint256 required, uint256 available);
    error InsufficientShares(uint256 sharesRequested, uint256 sharesPresent);
    error InsufficientSharesToCoverPenalty(uint256 sharesRequested, uint256 penaltyShares);
    error InvalidAdminAddress();
    error InvalidATokenAddress();
    error InvalidATokenUnderlying();
    error InvalidMainnetControllerAddress();
    error InvalidPenaltyRecipientAddress();
    error InvalidRecipientAddress();
    error InvalidVaultAddress();
    error VaultNotWhitelisted();

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    event PermissionlessWithdraw(
        address indexed sender,
        address indexed vault,
        uint256         assetsWithdrawn,
        address         recipient,
        uint256         penaltyShares,
        uint256         sharesToRecipient
    );

    /**
     *  @dev   Emitted when the admin updates a vault's configuration.
     *  @param vault         Address of the vault being configured.
     *  @param aToken        Address of the Aave aToken corresponding to the vault.
     *  @param penaltyShares The number of shares to be sent to the penalty recipient.
     *  @param whitelisted   Whether the vault is now whitelisted.
     */
    event VaultConfigUpdated(
        address indexed vault,
        address indexed aToken,
        uint256         penaltyShares,
        bool            whitelisted
    );

    /**********************************************************************************************/
    /*** Admin functions                                                                        ***/
    /**********************************************************************************************/

    /**
     *  @dev   Updates the configuration for a given vault.
     *         This function can only called by accounts with DEFAULT_ADMIN_ROLE.
     *  @param vault         Address of the vault to configure.
     *  @param aToken        Address of the Aave aToken corresponding to the vault.
     *  @param penaltyShares The number of shares to be sent to the penalty recipient.
     *  @param whitelisted   Whether the vault should be whitelisted.
     */
    function updateVaultConfig(
        address vault,
        address aToken,
        uint256 penaltyShares,
        bool    whitelisted
    ) external;

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    function permissionlessWithdraw(address vault, address recipient, uint256 shares) external;

}
