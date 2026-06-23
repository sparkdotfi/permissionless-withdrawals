// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControlEnumerable } from "../../lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";

interface IPermissionlessWithdrawals is IAccessControlEnumerable {

    /**********************************************************************************************/
    /*** Types                                                                                  ***/
    /**********************************************************************************************/

    enum VenueType { NONE, AAVE, ERC4626, PSM }

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

    error IncorrectVenue();
    error InsufficientAssetsToCoverPenalty(uint256 required, uint256 available);
    error InsufficientVenueLiquidity(uint256 required, uint256 available);
    error VaultNotWhitelisted();
    error VenueTypeNotSet();
    error ZeroAdminAddress();
    error ZeroControllerAddress();
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
     *  @dev   Emitted when the admin sets the type of a venue.
     *  @param vault     Address of the vault being configured.
     *  @param venue     Address of the venue being configured.
     *  @param venueType The type of venue being configured.
     */
    event VenueTypeSet(
        address indexed vault,
        address indexed venue,
        VenueType       venueType
    );

    /**
     *  @dev   Emitted when the admin sets the penalty recipient.
     *  @param penaltyRecipient The address of the penalty recipient.
     */
    event PenaltyRecipientSet(
        address indexed penaltyRecipient
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
     *  @dev   Sets the type of a given venue.
     *         This function can only called by accounts with DEFAULT_ADMIN_ROLE.
     *  @param vault     Address of the vault being configured.
     *  @param venue     Address of the venue to set the type of.
     *  @param venueType The type of venue to set.
     */
    function setVenueType(
        address   vault,
        address   venue,
        VenueType venueType
    ) external;

    /**
     *  @dev   Sets the penalty recipient.
     *         This function can only called by accounts with DEFAULT_ADMIN_ROLE.
     *  @param penaltyRecipient The address of the penalty recipient.
     */
    function setPenaltyRecipient(address penaltyRecipient) external;

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    function permissionlessWithdraw(
        address vault,
        address venue,
        address recipient,
        uint256 shares
    ) external;

    /**********************************************************************************************/
    /*** View/Pure functions                                                                    ***/
    /**********************************************************************************************/

    function controller() external view returns (address);

    function getImplementation() external view returns (address);

    function penaltyRecipient() external view returns (address);

    function USDS_CONVERSION_PRECISION() external pure returns (uint256);

    function vaultConfig(address vault)
        external
        view
        returns (bool whitelisted, uint256 penaltyAmount);

    function venueTypes(address vault, address venue)
        external
        view
        returns (VenueType venueType);

    function VERSION() external pure returns (string memory);

}
