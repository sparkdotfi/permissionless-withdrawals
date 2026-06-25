# Permissionless Withdrawals: Technical Design

## Objective

The ALM Planner is the normal path for moving liquidity in and out of Spark savings vaults. If it
is unavailable, users could be unable to withdraw even when the underlying liquidity exists in
SparkLend or other venues. This contract is a backup, a permissionless, single transaction path
that sources a vault's missing liquidity straight from a hardcoded set of venues and hands it to the
user, with no operator in the loop.

Anyone holding shares above the 24/7 liquidity level can call it. Supported venues are SparkLend
(Aave style aTokens), generic ERC4626 vaults, and the PSM, covering USDC, USDT, and ETH.

## Withdrawal Flow

`permissionlessWithdraw(vault, venue, recipient, shares)` runs entirely inside a `nonReentrant`
guard:

1. Validate that the vault and the `(vault, venue)` pair are whitelisted and that `recipient` is non
   zero.
2. Compute the shortfall. `assetsRequested = vault.convertToAssets(shares)`. Work out how much the
   vault is short, and from that how much the ALMProxy is short.
3. If the proxy is short, withdraw the difference from the venue into the proxy through the
   controller (Aave withdraw, ERC4626 withdraw, or PSM mint plus swap). A balance delta check
   enforces that the proxy actually received at least the requested amount.
4. Transfer the shortfall from the proxy to the vault.
5. Redeem the caller's full `shares` from the vault to this contract.
6. Deduct the fixed per vault penalty, send it to the penalty recipient, and send the remainder to
   `recipient`.

The contract never holds funds between calls, assets only pass through during a single transaction.

The diagram below traces this flow for both the Diamond and Legacy implementations, including the
venue withdrawal, the top up to the vault, and the recipient and penalty split.

![Permissionless Withdrawals withdrawal flow](./architecture_flow.png)

## Design Choices

### Two controller implementations behind one base

Spark runs two MainnetController versions (a legacy one and the diamond/PAU one) whose function names
differ. All of the logic above lives once in the abstract `PermissionlessWithdrawals`. The six
controller interactions (`_proxy`, `_transferAsset`, `_withdrawAave`, `_withdrawERC4626`,
`_mintUSDS`, `_swapUSDSToUSDC`) are `virtual` hooks. `PermissionlessWithdrawalsLegacyPAU` and
`PermissionlessWithdrawalsDiamondPAU` each implement only those hooks against their controller's ABI.
The same test suite runs against both, so behaviour stays identical across versions.

The controller is fixed at `initialize` and has no setter. Switching implementations is therefore a
separate deployment, not an in-place upgrade. Initially the `PermissionlessWithdrawalsLegacyPAU` will be deployed, then  `PermissionlessWithdrawalsDiamondPAU` separately once the diamond controller is live.

### Upgradeability (UUPS), admin is Spark governance

The contract is UUPS upgradeable. This is a deliberately defensive choice rather than a feature for
iteration. If funds ever become stuck or a bug is discovered, governance can ship an upgrade to
recover the situation instead of being forced to redeploy and migrate. UUPS exists for bug recovery
only, an upgrade does not change the controller, which stays fixed from `initialize`. Upgrade
authority is held by
`DEFAULT_ADMIN_ROLE`, set to `SPARK_PROXY` (Spark governance). Using the same governance address that
already controls the ALM system keeps the trust surface consistent and robust, with no separate
upgrade key to protect.

### ERC4626 venue slippage delegated to the controller

When withdrawing from an ERC4626 venue, the contract calls the controller with
`maxSharesIn = type(uint256).max`, placing no slippage bound of its own. This is intentional:

- The caller is permissionless and untrusted, so it cannot be allowed to pass a slippage value.
- Burdening the admin with a per call bound is impractical and still would not protect against a
  manipulated venue between blocks.
- Unlike the controller's deposit and redeem paths, the ERC4626 withdraw path applies no
  `maxExchangeRate` check. The only protection on this path is the per venue withdraw rate limit.
  Passing `maxSharesIn = max` is therefore a deliberate accepted risk choice, acceptable because
  venues are curated and whitelisted by the admin.

### PSM conversion assumes a USDC gem

The PSM path mints USDS and swaps it to the gem using a hardcoded `USDS_CONVERSION_PRECISION = 1e12`,
which assumes a 6 decimal gem against 18 decimal USDS. This is safe only because the PSM gem is
permanently USDC. The controller reads this factor from the PSM at call time, but this contract
relies on the invariant rather than reading it.

### Venue whitelisting and the incorrect venue guard

Vaults and venues are whitelisted by the admin per `(vault, venue)` pair, and the admin is trusted to
whitelist correct venues. As a safety net, before drawing from a venue the contract checks that the
venue's underlying asset matches the vault asset (`IncorrectVenue` otherwise). Two cases follow from
where the check sits in the flow:

- If the vault and proxy already hold enough liquidity, no venue withdrawal is needed, the venue is
  never touched, and the withdrawal succeeds regardless of any misconfiguration on that venue.
- If a venue withdrawal is actually required and the configured venue is wrong, the asset check
  fails and the call reverts rather than pulling from the wrong venue.

So a misconfigured venue can never cause funds to be drawn from the wrong place, at worst it makes
the backup path unavailable for vaults that genuinely need a top up from that venue.

### Fixed penalty

Each vault has a fixed penalty deducted from the redeemed assets and sent to the penalty recipient.
It compensates for the cost of force unwinding ALM liquidity and keeps the permissionless path a
backup rather than the default withdrawal route.

## Known Limitations

- Shared rate-limit budget. The backup path draws down the SLL's shared rate limits (the global
  `LIMIT_USDS_TO_USDC` and the per venue withdraw keys). It can therefore be exhausted by normal SLL
  activity or griefed through repeated calls. The fixed penalty per call and the limits regenerating
  over time are the mitigations.

## Trust Assumptions

- `DEFAULT_ADMIN_ROLE` (Spark governance, `SPARK_PROXY`): fully trusted. Whitelists vaults and
  venues, sets penalties, and authorizes upgrades.
- Supported assets must be standard, non-rebasing, non-fee-on-transfer ERC-20s. USDT is in scope and
  has a dormant fee switch that, if enabled, would break the exact penalty plus recipient amount
  split.
- MainnetController, ALMProxy, and RateLimits: trusted to custody funds and enforce rate limits and
  slippage. This contract must hold the controller's relayer role (legacy `RELAYER`, diamond
  `ALLOCATOR_ROLE`), granted by a governance spell, in order to drive the ALMProxy.
- Callers: untrusted and permissionless. A caller can only redeem their own shares (which they must
  have approved to this contract) and always pays the penalty.
