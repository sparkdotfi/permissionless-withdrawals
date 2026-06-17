// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

interface IPermissionlessWithdrawals {

    /**********************************************************************************************/
    /*** Types                                                                                  ***/
    /**********************************************************************************************/

    enum VenueType { AAVE, ERC4626, PSM }

    /**
     *  @dev   Configuration for a specific vault.
     *  @param whitelisted   Whether the vault is allowed to be used with this contract.
     *  @param venueType     The type of venue used for the withdrawals.
     *  @param venue         Address of the venue used for the withdrawals.
     *                       For Aave, this is the address of the aToken.
     *                       For ERC4626, this is the address of the vault.
     *                       For PSM, this is the address of the PSM.
     *  @param penaltyAmount The number of assets to be sent to the penalty recipient.
     */
    struct VaultConfig {
        bool      whitelisted;
        VenueType venueType;
        address   venue;
        uint256   penaltyAmount;
    }

    /**********************************************************************************************/
    /*** Errors                                                                                 ***/
    /**********************************************************************************************/

    error InsufficientVenueLiquidity(uint256 required, uint256 available);
    error InvalidAdminAddress();
    error InvalidVenueAddress();
    error InvalidMainnetControllerAddress();
    error InvalidPenaltyRecipientAddress();
    error InvalidRecipientAddress();
    error InvalidVaultAddress();
    error VaultNotWhitelisted();

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    event PermissionlessWithdraw(
        address indexed vault,
        address indexed sender,
        address         recipient,
        uint256         penaltyAmount,
        uint256         recipientAmount
    );

    /**
     *  @dev   Emitted when the admin updates a vault's configuration.
     *  @param vault         Address of the vault being configured.
     *  @param venue         Address of the venue being configured.
     *  @param venueType     The type of venue being configured.
     *  @param penaltyAmount The number of assets to be sent to the penalty recipient.
     *  @param whitelisted   Whether the vault is now whitelisted.
     */
    event VaultConfigUpdated(
        address indexed vault,
        address indexed venue,
        VenueType       venueType,
        uint256         penaltyAmount,
        bool            whitelisted
    );

    /**********************************************************************************************/
    /*** Admin functions                                                                        ***/
    /**********************************************************************************************/

    /**
     *  @dev   Updates the configuration for a given vault.
     *         This function can only called by accounts with DEFAULT_ADMIN_ROLE.
     *  @param vault         Address of the vault to configure.
     *  @param venue         Address of the venue to configure.
     *  @param venueType     The type of venue to configure.
     *  @param penaltyAmount The number of assets to be sent to the penalty recipient.
     *  @param whitelisted   Whether the vault should be whitelisted.
     */
    function updateVaultConfig(
        address   vault,
        address   venue,
        VenueType venueType,
        uint256   penaltyAmount,
        bool      whitelisted
    ) external;

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    function permissionlessWithdraw(address vault, address recipient, uint256 shares) external;

}
