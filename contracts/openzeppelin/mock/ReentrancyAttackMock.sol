// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

contract ReentrancyAttackMock {
    function callSender(bytes4 data) public {
        (bool success, ) = msg.sender.call(abi.encodeWithSelector(data));
        require(success, "ReentrancyAttack: failed call");
    }
}
