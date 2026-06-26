// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import {
    IAccessControlEnumerable
} from "../../lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";

/**
 *  @title  PermissionlessWithdrawals
 *  @notice Interface for the permissionless backup withdrawal path for Spark savings vaults.
 *  @dev    Sources a vault's missing liquidity from a whitelisted venue (SparkLend, ERC4626, or
 *          PSM) and hands it to the user in a single transaction, with no operator in the loop.
 */
interface IPermissionlessWithdrawals is IAccessControlEnumerable {

    /**********************************************************************************************/
    /*** Types                                                                                  ***/
    /**********************************************************************************************/

    /**
     *  @notice Identifies how a venue's liquidity is sourced during a withdrawal.
     *  @dev    NONE is the default for an unset (vault, venue) pair. A withdrawal reverts when the
     *          venue type is NONE.
     */
    enum VenueType { NONE, AAVE, ERC4626, PSM }

    /**
     *  @notice Configuration for a specific vault.
     *  @param  whitelisted   Whether the vault is enabled for permissionless withdrawals.
     *  @param  penaltyAmount The number of assets to be sent to the penalty recipient.
     *  @param  venueTypes    Mapping of venues to their type.
     */
    struct VaultConfig {
        bool    whitelisted;
        uint256 penaltyAmount;
        mapping (address venue => VenueType venueType) venueTypes;
    }

    /**********************************************************************************************/
    /*** Errors                                                                                 ***/
    /**********************************************************************************************/

    /// @notice Thrown when the controller does not have the CONTROLLER role on the ALM proxy.
    error ControllerProxyMismatch();

    /// @notice Thrown when a venue's underlying asset does not match the vault's asset.
    error IncorrectVenue();

    /**
     *  @notice Thrown when the redeemed assets are insufficient to cover the vault's penalty.
     *  @param  required  The penalty amount that must be covered.
     *  @param  available The redeemed assets available to cover it.
     */
    error InsufficientAssetsToCoverPenalty(uint256 required, uint256 available);

    /**
     *  @notice Thrown when a venue returns less liquidity than was requested.
     *  @param  required  The amount of assets requested from the venue.
     *  @param  available The amount of assets actually received.
     */
    error InsufficientVenueLiquidity(uint256 required, uint256 available);

    /// @notice Thrown when the ETH transfer to the recipient fails.
    error TransferETHFailed();

    /// @notice Thrown when the vault is not whitelisted for permissionless withdrawals.
    error VaultNotWhitelisted();

    /// @notice Thrown when the (vault, venue) pair has no venue type set.
    error VenueTypeNotSet();

    /// @notice Thrown when the admin address is zero during initialization.
    error ZeroAdminAddress();

    /// @notice Thrown when the controller address is zero during initialization.
    error ZeroControllerAddress();

    /// @notice Thrown when the penalty amount is zero during vault configuration.
    error ZeroPenaltyAmount();

    /// @notice Thrown when the penalty recipient address is zero.
    error ZeroPenaltyRecipientAddress();

    /// @notice Thrown when the recipient address is zero.
    error ZeroRecipientAddress();

    /// @notice Thrown when the shares amount is zero.
    error ZeroShares();

    /// @notice Thrown when the token address is zero.
    error ZeroTokenAddress();

    /// @notice Thrown when the vault address is zero.
    error ZeroVaultAddress();

    /// @notice Thrown when the venue address is zero.
    error ZeroVenueAddress();

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    /**
     *  @notice Emitted on a successful permissionless withdrawal.
     *  @param  vault           Address of the vault that was withdrawn from.
     *  @param  sender          Address that initiated the withdrawal and owned the shares.
     *  @param  recipient       Address that received the assets net of the penalty.
     *  @param  shares          The number of shares that were withdrawn.
     *  @param  penaltyAmount   The number of assets sent to the penalty recipient.
     *  @param  recipientAmount The number of assets sent to the recipient.
     */
    event PermissionlessWithdraw(
        address indexed vault,
        address indexed sender,
        address indexed recipient,
        uint256         shares,
        uint256         penaltyAmount,
        uint256         recipientAmount
    );

    /**
     *  @notice Emitted when the admin sets a vault's configuration.
     *  @param  vault         Address of the vault being configured.
     *  @param  penaltyAmount The number of assets to be sent to the penalty recipient.
     *  @param  whitelisted   Whether the vault is now whitelisted.
     */
    event VaultConfigSet(address indexed vault, uint256 penaltyAmount, bool whitelisted);

    /**
     *  @notice Emitted when the admin sets the type of a venue for a vault.
     *  @param  vault     Address of the vault being configured.
     *  @param  venue     Address of the venue being configured.
     *  @param  venueType The type of venue being configured.
     */
    event VenueTypeSet(address indexed vault, address indexed venue, VenueType indexed venueType);

    /**
     *  @notice Emitted when the admin sets the penalty recipient.
     *  @param  penaltyRecipient The address of the penalty recipient.
     */
    event PenaltyRecipientSet(address indexed penaltyRecipient);

    /**********************************************************************************************/
    /*** Interactive Admin Functions                                                            ***/
    /**********************************************************************************************/

    /**
     *  @notice Updates the configuration for a given vault.
     *          Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *  @dev    Reverts if penaltyAmount is zero. Overwrites the vault's entire VaultConfig.
     *  @param  vault         Address of the vault to configure.
     *  @param  penaltyAmount The number of assets to be sent to the penalty recipient.
     *  @param  whitelisted   Whether the vault should be whitelisted.
     */
    function setVaultConfig(address vault, uint256 penaltyAmount, bool whitelisted) external;

    /**
     *  @notice Sets the type of a given venue.
     *          Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *  @dev    Setting venueType to NONE unsets the (vault, venue) pairing.
     *  @param  vault     Address of the vault being configured.
     *  @param  venue     Address of the venue to set the type of.
     *  @param  venueType The type of venue to set.
     */
    function setVenueType(address vault, address venue, VenueType venueType) external;

    /**
     *  @notice Sets the penalty recipient.
     *          Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *  @dev    Reverts if penaltyRecipient is zero.
     *  @param  penaltyRecipient The address of the penalty recipient.
     */
    function setPenaltyRecipient(address penaltyRecipient) external;

    /**********************************************************************************************/
    /*** Asset Recovery Functions                                                               ***/
    /**********************************************************************************************/

    /**
     *  @notice Recovers ETH stuck in this contract.
     *          Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *  @dev    Reverts if recipient is zero. Transfers all ETH in this contract to the recipient.
     *  @param  recipient Address that receives the ETH.
     */
    function recoverETH(address recipient) external;

    /**
     *  @notice Recovers ERC20 tokens stuck in this contract.
     *          Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *  @dev    Reverts if token or recipient is zero. Transfers all of the token in this contract
     *          to the recipient.
     *  @param  token     Address of the token to recover.
     *  @param  recipient Address that receives the tokens.
     */
    function recoverERC20(address token, address recipient) external;

    /**
     *  @notice Recovers ERC721 tokens stuck in this contract.
     *          Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *  @dev    Reverts if token or recipient is zero. Transfers the specified token to the recipient.
     *  @param  token     Address of the token to recover.
     *  @param  recipient Address that receives the token.
     *  @param  tokenId   The ID of the token to recover.
     */
    function recoverERC721(address token, address recipient, uint256 tokenId) external payable;

    /**********************************************************************************************/
    /*** Interactive Functions                                                                  ***/
    /**********************************************************************************************/

    /**
     *  @notice Redeems the caller's vault shares, sourcing any shortfall from a venue.
     *          Anyone holding shares can call this and always pays the vault's fixed penalty.
     *  @dev    Runs under nonReentrant. The caller must approve `shares` to this contract first.
     *          The shortfall is pulled from the venue through the controller using this contract's
     *          relayer role. Reverts if the redeemed assets cannot cover the penalty.
     *  @param  vault     Address of the vault to withdraw from.
     *  @param  venue     Address of the venue to source the shortfall from.
     *  @param  recipient Address that receives the assets net of the penalty.
     *  @param  shares    The number of vault shares to redeem.
     */
    function permissionlessWithdraw(address vault, address venue, address recipient, uint256 shares)
        external;


    /**********************************************************************************************/
    /*** Variables                                                                              ***/
    /**********************************************************************************************/

    /**
     *  @notice The fixed precision factor for converting a 6 decimal gem amount to 18 decimal USDS.
     *  @dev    Hardcoded to 1e12, which assumes the PSM gem is USDC.
     */
    function USDS_CONVERSION_PRECISION() external pure returns (uint256);

    /**
     *  @notice Returns the configured MainnetController address.
     */
    function controller() external view returns (address);

    /**
     *  @notice Returns the address that receives withdrawal penalties.
     */
    function penaltyRecipient() external view returns (address);

    /**
     *  @notice Returns the address of the ALM proxy contract.
     */
    function proxy() external view returns (address);

    /**********************************************************************************************/
    /*** View/Pure Functions                                                                    ***/
    /**********************************************************************************************/

    /**
     *  @notice Returns whether a vault is whitelisted for permissionless withdrawals.
     *  @param  vault         Address of the vault to query.
     *  @return isWhitelisted Whether the vault is whitelisted.
     */
    function getVaultIsWhitelisted(address vault) external view returns (bool isWhitelisted);

    /**
     *  @notice Returns the penalty amount for a given vault.
     *  @param  vault         Address of the vault to query.
     *  @return penaltyAmount The number of assets to be sent to the penalty recipient.
     */
    function getVaultPenaltyAmount(address vault) external view returns (uint256 penaltyAmount);

    /**
     *  @notice Returns the venue type set for a (vault, venue) pair.
     *  @param  vault     Address of the vault to query.
     *  @param  venue     Address of the venue to query.
     *  @return venueType The venue type, or NONE if unset.
     */
    function getVenueType(address vault, address venue) external view returns (VenueType venueType);

}
