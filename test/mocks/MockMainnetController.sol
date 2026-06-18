// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { MockALMProxy } from "./MockALMProxy.sol";
import { MockAToken }   from "./MockAToken.sol";
import { MockERC20 }    from "./MockERC20.sol";
import { MockERC4626 }  from "./MockERC4626.sol";
import { MockPSM }      from "./MockPSM.sol";

// Minimal MainnetController that custodies nothing: all funds live in the ALMProxy and every
// venue interaction and transfer is executed by the proxy via `doCall`, mirroring production.
// `setVenueDelivery` overrides how much the next venue withdrawal delivers to the proxy, to
// simulate a venue returning more or less than requested.
contract MockMainnetController {

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

    function transferAsset(address asset, address destination, uint256 amount) external {
        almProxy.doCall(asset, abi.encodeCall(IERC20.transfer, (destination, amount)));
    }

    function withdrawAave(address aToken, uint256 amount) external returns (uint256 delivered) {
        delivered = _delivered(amount);
        almProxy.doCall(aToken, abi.encodeCall(MockAToken.release, (address(almProxy), delivered)));
    }

    function withdrawERC4626(address token, uint256 amount, uint256) external returns (uint256 delivered) {
        delivered = _delivered(amount);
        almProxy.doCall(
            token,
            abi.encodeCall(MockERC4626.withdraw, (delivered, address(almProxy), address(almProxy)))
        );
    }

    function mintUSDS(uint256 usdsAmount) external {
        almProxy.doCall(address(usds), abi.encodeCall(MockERC20.mint, (address(almProxy), usdsAmount)));
    }

    function swapUSDSToUSDC(uint256 usdcAmount) external {
        // Send the minted USDS to the PSM and receive the gem (USDC), executed by the proxy.
        almProxy.doCall(address(usds), abi.encodeCall(IERC20.transfer, (psm, usdcAmount * 1e12)));
        almProxy.doCall(psm,           abi.encodeCall(MockPSM.release, (address(almProxy), _delivered(usdcAmount))));
    }

    function _delivered(uint256 requested) internal view returns (uint256) {
        return deliveryOverridden ? deliveryAmount : requested;
    }

}
