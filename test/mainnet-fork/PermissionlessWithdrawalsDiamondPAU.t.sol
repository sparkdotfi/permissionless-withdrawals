// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum }  from "../../lib/spark-address-registry/src/Ethereum.sol";
import { SparkLend } from "../../lib/spark-address-registry/src/SparkLend.sol";

import { Ethereum as SkyPAU } from "../../lib/sky-pau-registry/src/Ethereum.sol";

import { PermissionlessWithdrawals }          from "../../src/PermissionlessWithdrawals.sol";
import { PermissionlessWithdrawalsDiamondPAU } from "../../src/PermissionlessWithdrawalsDiamondPAU.sol";

import { PermissionlessWithdrawalsTestBase } from "./PermissionlessWithdrawalsTestBase.t.sol";

interface IPAUFactoryLike {

    function deployAccessControls(address admin) external returns (address);

    function deployController(address accessControls, address proxy, address rateLimits)
        external
        returns (address);

}

interface IControllerLike {

    function updateIntegrations(bytes32[] calldata ids) external;

    function proxy() external view returns (address);

    // Rate-limit key getters.
    function aave_getWithdrawRateLimitKey(address aToken, address pool) external pure returns (bytes32);

    function erc4626_getWithdrawRateLimitKey(address token) external pure returns (bytes32);

    function usds_mintRateLimitKey() external pure returns (bytes32);

    function psm_usdsToUSDCSwapRateLimitKey() external pure returns (bytes32);

    function transferAsset_getTransferRateLimitKey(address asset, address destination)
        external
        pure
        returns (bytes32);

    // Config.
    function usds_setVault(address vault) external;

    // Facet actions.
    function aave_withdraw(address aToken, uint256 amount) external returns (uint256);

    function erc4626_withdraw(address token, uint256 amount, uint256 maxSharesIn) external returns (uint256);

    function usds_mint(uint256 usdsAmount) external;

    function psm_swapUSDSToUSDC(uint256 usdcAmount) external;

    function transferAsset_transfer(address asset, address destination, uint256 amount) external;

}

interface IAccessControlsLike {

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

}

interface IControllerRoleLike {

    function CONTROLLER() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

}

interface IRateLimitsLike {

    function CONTROLLER() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function setUnlimitedRateLimitData(bytes32 key) external;

    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external;

}

interface IAaveTokenLike {

    function POOL() external view returns (address);

}

contract PermissionlessWithdrawalsDiamondPAUForkTest is PermissionlessWithdrawalsTestBase {

    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    address internal accessControls;

    /**********************************************************************************************/
    /*** Deploy and role hooks                                                                  ***/
    /**********************************************************************************************/

    function _deployImplementation() internal override returns (PermissionlessWithdrawals) {
        return new PermissionlessWithdrawalsDiamondPAU();
    }

    function _controllerAddress() internal override returns (address) {
        IPAUFactoryLike factory = IPAUFactoryLike(SkyPAU.PAU_FACTORY);

        // Deploy a fresh AccessControls and Controller pointed at the live ALMProxy and RateLimits.
        accessControls = factory.deployAccessControls(Ethereum.SPARK_PROXY);

        address controller_ = factory.deployController(
            accessControls,
            Ethereum.ALM_PROXY,
            Ethereum.ALM_RATE_LIMITS
        );

        // Sync the facets used by the withdrawals flow from the pre-wired registry Beacon.
        bytes32[] memory ids = new bytes32[](5);

        ids[0] = "AAVE_FACET";
        ids[1] = "ERC4626_FACET";
        ids[2] = "PSM_FACET";
        ids[3] = "USDS_FACET";
        ids[4] = "TRANSFER_ASSET_FACET";

        vm.startPrank(Ethereum.SPARK_PROXY);

        IControllerLike(controller_).updateIntegrations(ids);

        IControllerLike(controller_).usds_setVault(Ethereum.ALLOCATOR_VAULT);

        IControllerRoleLike(Ethereum.ALM_PROXY).grantRole(
            IControllerRoleLike(Ethereum.ALM_PROXY).CONTROLLER(),
            controller_
        );
        IRateLimitsLike(Ethereum.ALM_RATE_LIMITS).grantRole(
            IRateLimitsLike(Ethereum.ALM_RATE_LIMITS).CONTROLLER(),
            controller_
        );

        _configureRateLimits(IControllerLike(controller_), IRateLimitsLike(Ethereum.ALM_RATE_LIMITS));

        vm.stopPrank();

        return controller_;
    }

    function _proxy() internal override returns (address) {
        return Ethereum.ALM_PROXY;
    }

    function _grantRelayerRole(address account) internal override {
        vm.prank(Ethereum.SPARK_PROXY);
        IAccessControlsLike(accessControls).grantRole(ALLOCATOR_ROLE, account);
    }

    function _revokeRelayerRole(address account) internal override {
        vm.prank(Ethereum.SPARK_PROXY);
        IAccessControlsLike(accessControls).revokeRole(ALLOCATOR_ROLE, account);
    }

    function _relayerRole() internal view override returns (bytes32) {
        return ALLOCATOR_ROLE;
    }

    // Sets every rate-limit key the stories consume. Everything is unlimited except the PSM.
    function _configureRateLimits(IControllerLike c, IRateLimitsLike rl) internal {
        rl.setUnlimitedRateLimitData(c.aave_getWithdrawRateLimitKey(SparkLend.WETH_SPTOKEN, IAaveTokenLike(SparkLend.WETH_SPTOKEN).POOL()));
        rl.setUnlimitedRateLimitData(c.aave_getWithdrawRateLimitKey(SparkLend.USDT_SPTOKEN, IAaveTokenLike(SparkLend.USDT_SPTOKEN).POOL()));
        rl.setUnlimitedRateLimitData(c.aave_getWithdrawRateLimitKey(SparkLend.USDC_SPTOKEN, IAaveTokenLike(SparkLend.USDC_SPTOKEN).POOL()));

        rl.setUnlimitedRateLimitData(c.erc4626_getWithdrawRateLimitKey(Ethereum.MORPHO_VAULT_USDC_BC));

        rl.setUnlimitedRateLimitData(c.transferAsset_getTransferRateLimitKey(address(WETH), address(spETHVault)));
        rl.setUnlimitedRateLimitData(c.transferAsset_getTransferRateLimitKey(address(USDC), address(spUSDCVault)));
        rl.setUnlimitedRateLimitData(c.transferAsset_getTransferRateLimitKey(address(USDT), address(spUSDTVault)));

        rl.setUnlimitedRateLimitData(c.usds_mintRateLimitKey());
        rl.setRateLimitData(c.psm_usdsToUSDCSwapRateLimitKey(), 5_000_000e6, uint256(1_000_000e6) / 4 hours);
    }

    /**********************************************************************************************/
    /*** Controller call expectation hooks                                                      ***/
    /**********************************************************************************************/

    function _mockWithdrawAaveReturnsZero(address aToken, uint256 amount) internal override {
        vm.mockCall(
            controller,
            abi.encodeCall(IControllerLike.aave_withdraw, (aToken, amount)),
            abi.encode(uint256(0))
        );
    }

    function _expectRateLimitExceededRevert() internal override {
        vm.expectRevert("RateLimits/rate-limit-exceeded");
    }

    function _expectWithdrawAaveCall(address aToken, uint256 amount, uint64 count) internal override {
        vm.expectCall(
            controller,
            abi.encodeCall(IControllerLike.aave_withdraw, (aToken, amount)),
            count
        );
    }

    function _expectWithdrawERC4626Call(address token, uint256 amount, uint64 count) internal override {
        vm.expectCall(
            controller,
            abi.encodeCall(IControllerLike.erc4626_withdraw, (token, amount, type(uint256).max)),
            count
        );
    }

    function _expectMintUSDSCall(uint256 usdsAmount, uint64 count) internal override {
        vm.expectCall(
            controller,
            abi.encodeCall(IControllerLike.usds_mint, (usdsAmount)),
            count
        );
    }

    function _expectSwapUSDSToUSDCCall(uint256 usdcAmount, uint64 count) internal override {
        vm.expectCall(
            controller,
            abi.encodeCall(IControllerLike.psm_swapUSDSToUSDC, (usdcAmount)),
            count
        );
    }

    function _expectTransferAssetCall(address asset_, address destination, uint256 amount, uint64 count)
        internal
        override
    {
        vm.expectCall(
            controller,
            abi.encodeCall(IControllerLike.transferAsset_transfer, (asset_, destination, amount)),
            count
        );
    }

}
