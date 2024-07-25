// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IRedemptionTimeExtension {
    event RedemptionPaymentExtensionSecondsChanged(uint256 value);

    function setRedemptionPaymentExtensionSeconds(uint256 _value)
        external;

    function redemptionPaymentExtensionSeconds()
        external view
        returns (uint256);
}
