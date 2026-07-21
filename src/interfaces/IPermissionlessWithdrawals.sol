// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import {
    IAccessControlEnumerable
} from "../../lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";

/**
 * @title  PermissionlessWithdrawals
 * @notice Interface for the permissionless backup withdrawal path for Spark savings vaults.
 * @dev    Sources a vault's missing liquidity from a whitelisted venue (SparkLend, ERC4626, or PSM)
 *         and hands it to the user in a single transaction, with no operator in the loop.
 */
interface IPermissionlessWithdrawals is IAccessControlEnumerable {

    /**********************************************************************************************/
    /*** Types                                                                                  ***/
    /**********************************************************************************************/

    /**
     * @notice Identifies how a venue's liquidity is sourced during a withdrawal.
     * @dev    UNSET is the default for an unset (vault, venue) pair. A withdrawal reverts when the
     *         venue type is UNSET.
     */
    enum VenueType { UNSET, AAVE, ERC4626, PSM }

    /**
     * @notice Configuration for a specific vault.
     * @param  whitelisted   Whether the vault is enabled for permissionless withdrawals.
     * @param  penaltyAmount The number of assets to be sent to the penalty recipient.
     * @param  venueTypes    Mapping of venues to their type.
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
     * @notice Thrown when the assets to be sent to the recipient are insufficient.
     * @param  amount   The amount of assets to be sent to the recipient. net of the penalty.
     * @param  required The min assets required, as specified by the user.
     */
    error InsufficientAssetsForRecipient(uint256 amount, uint256 required);

    /**
     * @notice Thrown when the redeemed assets are insufficient to cover the vault's penalty.
     * @param  required  The penalty amount that must be covered.
     * @param  available The redeemed assets available to cover it.
     */
    error InsufficientAssetsToCoverPenalty(uint256 required, uint256 available);

    /**
     * @notice Thrown when the ALM Proxy has insufficient assets to send to the vault.
     * @param  required  The amount of assets requested.
     * @param  available The amount of assets actually held by the ALM proxy.
     */
    error InsufficientAssetsInALMProxy(uint256 required, uint256 available);

    /// @notice Thrown when the contract is not a relayer/allocator.
    error NotRelayerOnController();

    /// @notice Thrown when the controller address is passed in as a token in recovery functions.
    error TokenIsController();

    /// @notice Thrown when the ETH transfer to the recipient fails.
    error TransferETHFailed();

    /// @notice Thrown when the vault is not whitelisted for permissionless withdrawals.
    error VaultNotWhitelisted();

    /// @notice Thrown when the (vault, venue) pair has no venue type set.
    error VenueTypeNotSet();

    /// @notice Thrown when the admin address is zero during construction.
    error ZeroAdminAddress();

    /// @notice Thrown when the controller address is zero during construction.
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
     * @notice Emitted when the admin sets the ratio for the maximum number of shares that can be
     *         withdrawn from an ERC4626 venue given an amount of assets.
     * @param  venue            Address of the venue that was configured.
     * @param  maxSharesInRatio The ratio between the maximum number of shares and the amount of
     *                          assets.
     */
    event MaxSharesInRatioSet(address indexed venue, uint256 maxSharesInRatio);

    /**
     * @notice Emitted on a successful permissionless withdrawal.
     * @param  vault           Address of the vault that was withdrawn from.
     * @param  venue           Address of the venue, if any, that was withdrawn from.
     * @param  sender          Address that initiated the withdrawal and owned the shares.
     * @param  recipient       Address that received the assets net of the penalty.
     * @param  shares          The number of shares that were withdrawn.
     * @param  penaltyAmount   The number of assets sent to the penalty recipient.
     * @param  recipientAmount The number of assets sent to the recipient.
     */
    event PermissionlessWithdraw(
        address indexed vault,
        address indexed venue,
        address indexed sender,
        address         recipient,
        uint256         shares,
        uint256         penaltyAmount,
        uint256         recipientAmount
    );

    /**
     * @notice Emitted when the admin sets a vault's configuration.
     * @param  vault         Address of the vault being configured.
     * @param  penaltyAmount The number of assets to be sent to the penalty recipient.
     * @param  whitelisted   Whether the vault is now whitelisted.
     */
    event VaultConfigSet(address indexed vault, uint256 penaltyAmount, bool whitelisted);

    /**
     * @notice Emitted when the admin sets the type of a venue for a vault.
     * @param  vault     Address of the vault being configured.
     * @param  venue     Address of the venue being configured.
     * @param  venueType The type of venue being configured.
     */
    event VenueTypeSet(address indexed vault, address indexed venue, VenueType indexed venueType);

    /**
     * @notice Emitted when the admin sets the penalty recipient.
     * @param  penaltyRecipient The address of the penalty recipient.
     */
    event PenaltyRecipientSet(address indexed penaltyRecipient);

    /**********************************************************************************************/
    /*** Interactive Admin Functions                                                            ***/
    /**********************************************************************************************/

    /**
     * @notice Updates the ratio (taking the asset-to-share decimal ratio into account) for the
     *         maximum number of shares that can be withdrawn from an ERC4626 venue given an amount
     *         of assets.
     *         Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     * @dev    A `maxSharesInRatio` of 1e18 is 100% (i.e. 1:1) if both the asset and shares have the
     *         same decimal places, however if, for example, the asset has 6 decimals and the shares
     *         have 18 decimals, then 1e30 is 100% (`1e18 * (1e18 / 1e6)`).
     * @param  venue            Address of the venue to configure.
     * @param  maxSharesInRatio The ratio between the maximum number of shares and the amount of
     *                           assets.
     */
    function setMaxSharesInRatio(address venue, uint256 maxSharesInRatio) external;

    /**
     * @notice Updates the configuration for a given vault.
     *         Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     * @dev    Reverts if penaltyAmount is zero.
     * @param  vault         Address of the vault to configure.
     * @param  penaltyAmount The number of assets to be sent to the penalty recipient.
     * @param  whitelisted   Whether the vault should be whitelisted.
     */
    function setVaultConfig(address vault, uint256 penaltyAmount, bool whitelisted) external;

    /**
     * @notice Sets the type of a given venue.
     *         Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     * @dev    Setting venueType to `UNSET` unsets the (vault, venue) pairing.
     *         Reverts if the venue type is incorrect.
     * @param  vault     Address of the vault being configured.
     * @param  venue     Address of the venue to set the type of.
     * @param  venueType The type of venue to set.
     */
    function setVenueType(address vault, address venue, VenueType venueType) external;

    /**
     * @notice Sets the penalty recipient.
     *         Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     * @dev    Reverts if penaltyRecipient is zero.
     * @param  recipient The address of the penalty recipient.
     */
    function setPenaltyRecipient(address recipient) external;

    /**********************************************************************************************/
    /*** Asset Recovery Functions                                                               ***/
    /**********************************************************************************************/

    /**
     * @notice Recovers ETH stuck in this contract.
     *          Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     * @dev    Reverts if recipient is zero. Transfers all ETH in this contract to the recipient.
     * @param  recipient Address that receives the ETH.
     */
    function recoverETH(address recipient) external;

    /**
     * @notice Recovers ERC20 tokens stuck in this contract.
     *         Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     * @dev    Reverts if token or recipient is zero, or if the token is the controller address.
     *         Transfers all of the token in this contract to the recipient.
     * @param  token     Address of the token to recover.
     * @param  recipient Address that receives the tokens.
     */
    function recoverERC20(address token, address recipient) external;

    /**
     * @notice Recovers ERC721 tokens stuck in this contract. Payable to cover any fee if needed.
     *         Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     * @dev    Reverts if token or recipient is zero, or if the token is the controller address.
     *         Transfers the specified token to the recipient.
     * @param  token     Address of the token to recover.
     * @param  recipient Address that receives the token.
     * @param  tokenId   The ID of the token to recover.
     */
    function recoverERC721(address token, address recipient, uint256 tokenId) external payable;

    /**********************************************************************************************/
    /*** Interactive Functions                                                                  ***/
    /**********************************************************************************************/

    /**
     * @notice Redeems the caller's vault shares, sourcing any shortfall from a venue.
     *         Anyone holding shares can call this and always pays the vault's fixed penalty.
     * @dev    Runs under nonReentrant. The caller must approve `shares` to this contract first.
     *         The shortfall is pulled from the venue through the controller using this contract's
     *         relayer role. Reverts if the redeemed assets cannot cover the penalty.
     * @param  vault                 Address of the vault to withdraw from.
     * @param  venue                 Address of the venue to source the shortfall from if necessary.
     * @param  recipient             Address that receives the assets net of the penalty.
     * @param  shares                The number of vault shares to redeem.
     * @param  minAssetsForRecipient Minimum assets for the recipient, net of penalty.
     */
    function permissionlessWithdraw(
        address vault,
        address venue,
        address recipient,
        uint256 shares,
        uint256 minAssetsForRecipient
    )
        external;

    /**********************************************************************************************/
    /*** Variables                                                                              ***/
    /**********************************************************************************************/

    /**
     * @notice Returns the configured Controller address.
     */
    function controller() external view returns (address);

    /**
     * @notice Returns the address that receives withdrawal penalties.
     */
    function penaltyRecipient() external view returns (address);

    /**
     * @notice Returns the address of the ALM proxy contract.
     */
    function proxy() external view returns (address);

    /**********************************************************************************************/
    /*** View/Pure Functions                                                                    ***/
    /**********************************************************************************************/

    /**
     * @notice Returns the ratio between the maximum number of shares that can be withdrawn from a
     *         given ERC4626 venue and the amount of assets.
     * @param  venue            Address of the venue to query.
     * @return maxSharesInRatio The ratio between the maximum number of shares and the amount of
     *                          assets.
     */
    function getMaxSharesInRatio(address venue) external view returns (uint256 maxSharesInRatio);

    /**
     * @notice Returns whether a vault is whitelisted for permissionless withdrawals.
     * @param  vault         Address of the vault to query.
     * @return isWhitelisted Whether the vault is whitelisted.
     */
    function getVaultIsWhitelisted(address vault) external view returns (bool isWhitelisted);

    /**
     * @notice Returns the penalty amount for a given vault.
     * @param  vault         Address of the vault to query.
     * @return penaltyAmount The number of assets to be sent to the penalty recipient.
     */
    function getVaultPenaltyAmount(address vault) external view returns (uint256 penaltyAmount);

    /**
     * @notice Returns the venue type set for a (vault, venue) pair.
     * @param  vault     Address of the vault to query.
     * @param  venue     Address of the venue to query.
     * @return venueType The venue type, or `UNSET` if unset.
     */
    function getVenueType(address vault, address venue) external view returns (VenueType venueType);

}
