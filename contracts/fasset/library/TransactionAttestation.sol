// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../../generated/interface/IAttestationClient.sol";
import "../interface/IAssetManager.sol";
import "../library/AssetManagerSettings.sol";


library TransactionAttestation {
    
    // must be strictly smaller than PaymentConfirmations.VERIFICATION_CLEANUP_DAYS
    uint256 internal constant MAX_VALID_PROOF_AGE_SECONDS = 2 days;

    // payment status constants
    uint8 internal constant PAYMENT_SUCCESS = 0;
    uint8 internal constant PAYMENT_FAILED = 1;
    uint8 internal constant PAYMENT_BLOCKED = 2;

    function verifyPaymentSuccess(
        AssetManagerSettings.Settings storage _settings,
        IAttestationClient.Payment calldata _attestationData
    ) 
        internal view
    {
        require(_attestationData.status == PAYMENT_SUCCESS, "payment failed");
        verifyPayment(_settings, _attestationData);
    }
    
    function verifyPayment(
        AssetManagerSettings.Settings storage _settings,
        IAttestationClient.Payment calldata _attestationData
    ) 
        internal view
    {
        require(_settings.attestationClient.verifyPayment(_settings.chainId, _attestationData), 
            "legal payment not proved");
        require(_attestationData.blockTimestamp >= block.timestamp - MAX_VALID_PROOF_AGE_SECONDS,
            "verified transaction too old");
    }
    
    function verifyBalanceDecreasingTransaction(
        AssetManagerSettings.Settings storage _settings,
        IAttestationClient.BalanceDecreasingTransaction calldata _attestationData
    ) 
        internal view
    {
        require(_settings.attestationClient.verifyBalanceDecreasingTransaction(_settings.chainId, _attestationData), 
            "transaction not proved");
        require(_attestationData.blockTimestamp >= block.timestamp - MAX_VALID_PROOF_AGE_SECONDS,
            "verified transaction too old");
    }
    
    function verifyConfirmedBlockHeightExists(
        AssetManagerSettings.Settings storage _settings,
        IAttestationClient.ConfirmedBlockHeightExists calldata _attestationData
    ) 
        internal view
    {
        require(_settings.attestationClient.verifyConfirmedBlockHeightExists(_settings.chainId, _attestationData), 
            "block height not proved");
    }
    
    function verifyReferencedPaymentNonexistence(
        AssetManagerSettings.Settings storage _settings,
        IAttestationClient.ReferencedPaymentNonexistence calldata _attestationData
    ) 
        internal view
    {
        require(_settings.attestationClient.verifyReferencedPaymentNonexistence(_settings.chainId, _attestationData), 
            "non-payment not proved");
    }
}
