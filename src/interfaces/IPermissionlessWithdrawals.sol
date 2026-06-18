// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

interface IPermissionlessWithdrawals {

    /**********************************************************************************************/
    /*** Types                                                                                  ***/
    /**********************************************************************************************/

    enum VenueType { AAVE, ERC4626, PSM }

    /**
     *  @dev   Configuration for a specific venue.
     *  @param whitelisted Whether the venue is allowed to be used for permissionless withdrawals.
     *  @param venueType   The type of venue used for the withdrawals.
     */
    struct VenueConfig {
        bool      whitelisted;
        VenueType venueType;
    }

    /**
     *  @dev   Configuration for a specific vault.
     *  @param whitelisted   Whether the vault is allowed to be used for permissionless withdrawals.
     *  @param penaltyAmount The number of assets to be sent to the penalty recipient.
     */
    struct VaultConfig {
        bool    whitelisted;
        uint256 penaltyAmount;
    }

    /**********************************************************************************************/
    /*** Errors                                                                                 ***/
    /**********************************************************************************************/

    error InsufficientAssetsToCoverPenalty(uint256 required, uint256 available);
    error InsufficientVenueLiquidity(uint256 required, uint256 available);
    error VaultNotWhitelisted();
    error VenueNotWhitelisted();
    error ZeroAdminAddress();
    error ZeroMainnetControllerAddress();
    error ZeroPenaltyAmount();
    error ZeroPenaltyRecipientAddress();
    error ZeroRecipientAddress();
    error ZeroVaultAddress();
    error ZeroVenueAddress();

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
     *  @param penaltyAmount The number of assets to be sent to the penalty recipient.
     *  @param whitelisted   Whether the vault is now whitelisted.
     */
    event VaultConfigUpdated(
        address indexed vault,
        uint256         penaltyAmount,
        bool            whitelisted
    );

    /**
     *  @dev   Emitted when the admin updates a venue's configuration.
     *  @param venue         Address of the venue being configured.
     *  @param venueType     The type of venue being configured.
     *  @param whitelisted   Whether the venue is now whitelisted.
     */
    event VenueConfigUpdated(
        address indexed venue,
        VenueType       venueType,
        bool            whitelisted
    );

    /**********************************************************************************************/
    /*** Admin functions                                                                        ***/
    /**********************************************************************************************/

    /**
     *  @dev   Updates the configuration for a given vault.
     *         This function can only called by accounts with DEFAULT_ADMIN_ROLE.
     *  @param vault         Address of the vault to configure.
     *  @param penaltyAmount The number of assets to be sent to the penalty recipient.
     *  @param whitelisted   Whether the vault should be whitelisted.
     */
    function updateVaultConfig(
        address   vault,
        uint256   penaltyAmount,
        bool      whitelisted
    ) external;

    /**
     *  @dev   Updates the configuration for a given venue.
     *         This function can only called by accounts with DEFAULT_ADMIN_ROLE.
     *  @param venue       Address of the venue to configure.
     *  @param venueType   The type of venue being configured.
     *  @param whitelisted Whether the venue should be whitelisted.
     */
    function updateVenueConfig(
        address   venue,
        VenueType venueType,
        bool      whitelisted
    ) external;

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    function permissionlessWithdraw(
        address vault,
        address venue,
        address recipient,
        uint256 shares
    ) external;

}
