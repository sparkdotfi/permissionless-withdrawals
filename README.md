# Permissionless Withdrawals

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](./LICENSE)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

## Overview

Permissionless Withdrawals is a backup withdrawal path for Spark savings vaults. It lets anyone redeem their own vault shares in a single transaction, even when the vault holds no idle liquidity, by sourcing the shortfall directly from a whitelisted venue (SparkLend, an ERC4626 vault, or the PSM) through the Spark ALM Controller and ALMProxy.

The goal is resilience: withdrawals do not depend on the ALM Planner being online. Any user above the 24/7 liquidity level can trigger a withdrawal for the major supported assets (USDC, USDT, and WETH) without an operator in the loop. Note that the underlying asset for the spETH savings vault is WETH; since the contract performs no unwrap step, the recipient receives WETH rather than native ETH. A fixed penalty per withdrawal keeps this path a backup rather than the default route.

## Core Contracts

| Contract                              | Description                                                                    |
| ------------------------------------- | ------------------------------------------------------------------------------ |
| `PermissionlessWithdrawals`           | Abstract base holding all withdrawal logic, controller calls are virtual hooks |
| `PermissionlessWithdrawalsLegacyPAU`  | Concrete implementation for the legacy MainnetController                       |
| `PermissionlessWithdrawalsDiamondPAU` | Concrete implementation for the diamond (PAU) Controller                       |
| `IPermissionlessWithdrawals`          | External interface: types, errors, events, and function signatures             |

Two concrete contracts exist because Spark runs a legacy MainnetController and new DiamondPAU Controller (which is a migration from old controller). The shared logic lives once in the abstract base, each implementation only binds the controller interactions to its controller's ABI.

## Architecture

The diagram below shows the end to end withdrawal flow for both implementations: the contract sources any shortfall from the venue into the vault through the Controller and ALMProxy, the user redeems shares from the vault, and the proceeds are split between the recipient and the penalty recipient.

![Permissionless Withdrawals architecture and withdrawal flow](./architecture_flow.png)

## Documentation

| Document                          | Description                                                       |
| --------------------------------- | ----------------------------------------------------------------- |
| [Technical Design](./TECH_DOC.md) | Objective, withdrawal flow, design choices, and trust assumptions |

## Quick Start

Initialize submodules:

```bash
git submodule update --init --recursive
```

Build:

```bash
forge build
```

The test suite is fork only and requires a mainnet archive RPC:

```bash
forge test
```

## License

AGPL-3.0-or-later. See [LICENSE](./LICENSE).

---

<p align="center">
  <img src="https://github.com/user-attachments/assets/c83ef7e4-fae1-4c5c-8cff-99494ef75962" height="100"/>
</p>
