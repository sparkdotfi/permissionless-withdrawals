// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { MockALMProxy } from "./MockALMProxy.sol";
import { MockAToken }   from "./MockAToken.sol";
import { MockERC20 }    from "./MockERC20.sol";
import { MockERC4626 }  from "./MockERC4626.sol";
import { MockPSM }      from "./MockPSM.sol";

// Shared MainnetController behaviour for both the legacy and diamond (PAU) controller versions.
abstract contract MockMainnetControllerBase {

    MockALMProxy public almProxy;
    MockERC20    public usds;

    address public psm;

    bool    internal deliveryOverridden;
    uint256 internal deliveryAmount;

    constructor(address psm_) {
        almProxy = new MockALMProxy();
        usds     = new MockERC20("Sky USD", "USDS", 18);
        psm      = psm_;
        almProxy.setController(address(this));
    }

    function proxy() external view returns (address) {
        return address(almProxy);
    }

    function setVenueDelivery(uint256 amount) external {
        deliveryOverridden = true;
        deliveryAmount     = amount;
    }

    /**********************************************************************************************/
    /*** Shared controller interaction logic                                                    ***/
    /**********************************************************************************************/

    function _transferAsset(address asset, address destination, uint256 amount) internal {
        almProxy.doCall(asset, abi.encodeCall(IERC20.transfer, (destination, amount)));
    }

    function _withdrawAave(address aToken, uint256 amount) internal returns (uint256 delivered) {
        delivered = _delivered(amount);
        almProxy.doCall(aToken, abi.encodeCall(MockAToken.release, (address(almProxy), delivered)));
    }

    function _withdrawERC4626(address token, uint256 amount) internal returns (uint256 delivered) {
        delivered = _delivered(amount);
        almProxy.doCall(
            token,
            abi.encodeCall(MockERC4626.withdraw, (delivered, address(almProxy), address(almProxy)))
        );
    }

    function _mintUSDS(uint256 usdsAmount) internal {
        almProxy.doCall(address(usds), abi.encodeCall(MockERC20.mint, (address(almProxy), usdsAmount)));
    }

    function _swapUSDSToUSDC(uint256 usdcAmount) internal {
        // Send the minted USDS to the PSM and receive the gem (USDC), executed by the proxy.
        almProxy.doCall(address(usds), abi.encodeCall(IERC20.transfer, (psm, usdcAmount * 1e12)));
        almProxy.doCall(psm,           abi.encodeCall(MockPSM.release, (address(almProxy), _delivered(usdcAmount))));
    }

    function _delivered(uint256 requested) internal view returns (uint256) {
        return deliveryOverridden ? deliveryAmount : requested;
    }

}
