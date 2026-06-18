// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

// Minimal ALMProxy that custodies all funds and executes calls on behalf of the controller,
// so venue interactions and asset transfers run with the proxy as `msg.sender`, mirroring the
// production ALMProxy's `doCall`.
contract MockALMProxy {

    address public controller;

    function setController(address controller_) external {
        controller = controller_;
    }

    function doCall(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == controller, "MockALMProxy/not-controller");

        bool success;
        ( success, result ) = target.call(data);

        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

}
