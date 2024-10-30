// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "flare-smart-contracts-v2/contracts/userInterfaces/IFdcHub.sol";


contract FdcHubMock is IFdcHub {
     /**
     * Method to request an attestation.
     * @param _data ABI encoded attestation request
     */
    function requestAttestation(bytes calldata _data) external payable {
        emit AttestationRequest(_data, msg.value);
    }

    /**
     * The offset (in seconds) for the requests to be processed during the current voting round.
     */
    function requestsOffsetSeconds() external pure returns (uint8) {
        return 0;
    }
}