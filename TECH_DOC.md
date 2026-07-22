# Permissionless Withdrawals: Technical Design

## Objective

The ALM Planner is the normal path for moving liquidity in and out of Spark savings vaults. If it is unavailable, users could be unable to withdraw even when the underlying liquidity exists in SparkLend or other venues. This contract is a backup, a permissionless, single transaction path that sources a vault's missing liquidity straight from a set of admin-configured venues and hands it to the user, with no operator in the loop.

Anyone holding shares above the 24/7 liquidity level can call it. Supported venues are SparkLend (Aave style aTokens), generic ERC4626 vaults, and the PSM, covering USDC, USDT, and WETH.

## Withdrawal Flow

`permissionlessWithdraw(vault, venue, recipient, shares)` runs entirely inside a `nonReentrant` guard:

1. Validate that `vault` and `recipient` are non-zero, `shares` is non-zero, the controller/proxy consistency check passes, the contract is an authorized allocator/relayer of the controller, and that the vault is enabled (i.e. has a non-zero `maxExchangeRate`).
2. Compute the shortfall. `assetsRequested = vault.convertToAssets(shares)`. Verify that the exchange rate (`assetsRequested * 1e18 / shares`) does not exceed the vault's configured `maxExchangeRate` (reverting with `ExchangeRateTooHigh` otherwise). Work out how much the vault is short, and from that how much the ALMProxy is short.
3. If the proxy is short, withdraw the difference from the venue into the proxy through the controller (Aave withdraw, ERC4626 withdraw, or PSM mint plus swap).
4. If a transfer to the vault is needed, check that the proxy's absolute balance of the asset is at least the required transfer amount (`assetsToTransfer`), then transfer the shortfall from the proxy to the vault.
5. Redeem the caller's full `shares` from the vault to this contract.
6. Deduct the fixed per vault penalty, send it to the penalty recipient, and send the remainder to `recipient`.

The contract never holds funds between calls, assets only pass through during a single transaction.

The diagram below traces this flow for both the Diamond and Legacy implementations, including the venue withdrawal, the top up to the vault, and the recipient and penalty split.

![Permissionless Withdrawals withdrawal flow](./architecture_flow.png)

## Design Choices

### Two controller implementations behind one base

Spark runs two Controller versions (a legacy one called `MainnetController` and a newer diamond PAU `Controller`) whose function names differ. All of the logic above lives once in the abstract `PermissionlessWithdrawals`. The four controller interactions (`_transferAsset`, `_withdrawAave`, `_withdrawERC4626`, `_withdrawPSM`) are `virtual` hooks. The PSM path is a single `_withdrawPSM` hook that mints USDS and swaps it to the gem internally. `PermissionlessWithdrawalsLegacyPAU` and `PermissionlessWithdrawalsDiamondPAU` each implement only those hooks against their controller's ABI. The same test suite runs against both, so behaviour stays identical across versions.

The controller is set once in the constructor as an `immutable` and has no setter. The `proxy` is derived from it there too, so neither can change after deployment. Switching implementations is therefore a separate deployment, not an in-place upgrade. Initially the `PermissionlessWithdrawalsLegacyPAU` will be deployed, then `PermissionlessWithdrawalsDiamondPAU` separately once the diamond controller is live.

### ERC4626 venue slippage bounded by a per venue ratio

When withdrawing from an ERC4626 venue, the contract caps the shares burned at `maxSharesIn = amount * maxSharesInRatio / 1e18`, with `maxSharesInRatio` set per venue by the admin through `setVenueMaxSharesInRatio`. This bounds slippage on the withdraw path, which the controller does not guard itself (unlike its deposit and redeem paths, it applies no `maxExchangeRate` check).

- The caller is permissionless and untrusted, so the bound cannot come from the caller. Anchoring it to a per venue admin ratio keeps the caller out of the slippage decision.
- The ratio must encode both the slippage headroom and the asset to share decimal gap, `10**(shareDecimals - assetDecimals)`. `1e18` is `1:1` only when the decimals match, a 6 decimal asset against an 18 decimal share vault needs `1.1e18 * 1e12` for 10% headroom.
- The ratio defaults to zero, so an unconfigured venue yields `maxSharesIn = 0` and every withdrawal through it reverts. The path is fail closed, a venue is unusable until its ratio is set.
- **Admin Guidance for Mitigating Attacks**: The admin should keep `maxSharesInRatio` close to the ERC4626 venue's fair shares-per-asset ratio and treat any headroom as a venue-specific loss limit. In addition, the admin should configure a high-enough penalty via `setVaultConfig` to discourage various attacks that may take advantage of temporary share-price manipulation, deposit/withdraw fees, per-withdrawal rounding, or other edge cases.

### PSM conversion assumes a USDC gem

The PSM path mints USDS and swaps it to the gem using a hardcoded `_USDS_CONVERSION_PRECISION = 1e12` defined in each concrete implementation, which assumes a 6 decimal gem against 18 decimal USDS. This is safe only because the PSM gem is permanently USDC. The controller reads this factor from the PSM at call time, but this contract relies on the invariant rather than reading it.

Additionally, when calling `setVaultVenueType` for a PSM venue, the `venue` address must exactly match the PSM contract address that the controller is aware of, and the vault's underlying asset must exactly match the USDC contract address that the controller is aware of. This is because the controller's PSM route is hardcoded and does not accept a venue address dynamically. Therefore, even though there is no flexibility in the PSM contract address used by the controller, the correct address must still be provided by the admin during `setVaultVenueType` configuration and by the caller during `permissionlessWithdraw` in order to pass the whitelisting and asset-matching checks.

### Venue whitelisting and the incorrect venue guard

Vaults and venues are whitelisted by the admin per `(vault, venue)` pair. As a safety net, when configuring a venue type using `setVaultVenueType`, the contract checks that the venue's underlying asset matches the vault's asset, reverting with `IncorrectVenue` otherwise. This prevents storing an asset-mismatched venue in the contract's whitelist mapping at configuration time.

At withdrawal time:

- The type of the venue is validated lazily. If the vault already holds enough liquidity, no venue withdrawal is needed, the venue is never touched, and the withdrawal succeeds without querying or validating the venue.
- If a venue withdrawal is actually required, the contract loads the venue type. If the venue has not been configured (or was unconfigured to `UNSET`), the call reverts with `VenueTypeNotSet`.

Consequently, while a misconfigured venue type will prevent withdrawals that genuinely need a top-up from that venue, the lazy validation preserves functional withdrawals when the vault already has sufficient funds.

### Vault Whitelisting and Configuration Persistence

Vault configurations are updated via `setVaultConfig(vault, maxExchangeRate, penaltyAmount)`. Instead of a simple whitelisting boolean, the contract uses a `maxExchangeRate` value (representing the maximum units of asset allowed per 1e18 units of shares requested).

- If `maxExchangeRate` is set to `0`, the vault is disabled (unwhitelisted) and any withdrawal through it reverts.
- If `maxExchangeRate` is non-zero, the vault is enabled (whitelisted), and every withdrawal enforces that the requested asset-to-share ratio does not exceed this limit. This protects the contract (which holds an authorized allocator/relayer role on the controller) from drawing excessive assets if the vault's exchange rate is somehow manipulated.

Disabling a vault by setting its `maxExchangeRate` to `0` does not clear or delete its other parameters, such as the `penaltyAmount` or the venue type mappings configured via `setVaultVenueType`. Because these parameters remain in storage, re-enabling the vault in the future (by setting a non-zero `maxExchangeRate`) will automatically use the existing configuration, unless they are explicitly cleared or updated by the admin.

### Pausing or Disabling Permissionless Withdrawals

Controller withdrawal and transfer hooks are only invoked when the vault lacks sufficient liquidity. Consequently, disabling or unconfiguring venue operations does not fully pause permissionless withdrawals: withdrawals can continue as long as the vault holds enough assets to satisfy them directly. To completely stop all permissionless withdrawals, one of the following actions must be taken:

- The admin must disable the vault by setting its `maxExchangeRate` to `0` via `setVaultConfig`.
- PAU/ALM governance must revoke the controller's role on the `ALMProxy`.
- PAU/ALM governance must revoke the `PermissionlessWithdrawals` contract's authorized role (legacy `RELAYER`, diamond `ALLOCATOR_ROLE`) on the controller.

### Fixed penalty

Each vault has a fixed penalty deducted from the redeemed assets and sent to the penalty recipient. It compensates for the cost of force unwinding ALM liquidity and keeps the permissionless path a backup rather than the default withdrawal route.

A penalty fee is charged on every successful `permissionlessWithdraw` call. This fee is deducted from the redeemed assets even if there are no assets the ALM/PAU needs to withdraw from venues, and even if no assets are needed from the ALMProxy/proxy (the vault already can perform the withdrawal from its own balance).

## Known Limitations

- Shared rate-limit budget. The backup path draws down the SLL's shared rate limits: the per venue withdraw keys consumed by the step 3 venue withdrawal, plus the per `(asset, vault)` `LIMIT_ASSET_TRANSFER` key consumed by the step 4 top up from the proxy to the vault. The PSM venue is special: a single PSM withdrawal mints then swaps, so it spends two global budgets in one call, the global `LIMIT_USDS_MINT` from the mint and the global `LIMIT_USDS_TO_USDC` from the swap. Any of these can be exhausted SLL activity or griefed through repeated calls, in particular repeated PSM withdrawals can stall unrelated SLL operations that share `LIMIT_USDS_MINT` or `LIMIT_USDS_TO_USDC`. The fixed penalty per call and the limits regenerating over time are the mitigations.

- Per vault transfer limit must be provisioned. The step 4 top up calls `_transferAsset(asset, vault, amount)`, which the controller meters under `makeAddressAddressKey(LIMIT_ASSET_TRANSFER, asset, vault)`. Whitelisting a vault does not by itself make the backup path usable: if that key is left at its default of zero, every call that needs a top up reverts and the path is dead for that vault. The governance spell that whitelists a vault must also raise this rate limit, alongside the relevant venue withdraw keys, high enough to cover the expected backup withdrawals.

- ERC4626 venue setup is two steps. Setting a venue type for a vault with `setVaultVenueType` does not make the venue usable on its own: `setVenueMaxSharesInRatio` must also be called for that venue. The two calls are uncoupled and unvalidated, so an unset ratio leaves `maxSharesIn` at zero and every withdrawal through that venue reverts. A governance spell adding an ERC4626 venue must set its ratio in the same spell.

## Trust Assumptions

- `DEFAULT_ADMIN_ROLE` (Spark governance, `SPARK_PROXY`): fully trusted. Sets vault configurations (max exchange rates and penalties), sets venue types for vaults, sets the penalty recipient, and sets per venue max shares in ratios.
- Supported assets must be standard, non-rebasing, non-fee-on-transfer ERC-20s. USDT is in scope and has a dormant fee switch that, if enabled, would cause withdrawals to revert (due to the transfer fee reducing the transferred/redeemed balances below expected values), making the `spUSDT` path unavailable until the fee is disabled.
- Controller, ALMProxy, and RateLimits: trusted to custody funds and enforce rate limits and slippage. This contract must hold the controller's relayer role (legacy `RELAYER`, diamond `ALLOCATOR_ROLE`), granted by a governance spell, in order to drive the ALMProxy.
- Callers: untrusted and permissionless. A caller can only redeem their own shares (which they must have approved to this contract) and always pays the penalty.
