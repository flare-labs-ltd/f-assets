// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../../stateConnector/interfaces/ISCProofVerifier.sol";
import "./data/AssetManagerState.sol";
import "./AMEvents.sol";
import "./Redemptions.sol";
import "./RedemptionFailures.sol";
import "./Liquidation.sol";
import "./UnderlyingBalance.sol";


library RedemptionConfirmations {
    using PaymentConfirmations for PaymentConfirmations.State;

    function confirmRedemptionPayment(
        Payment.Proof calldata _payment,
        uint64 _redemptionRequestId
    )
        internal
    {
        Redemption.Request storage request = Redemptions.getRedemptionRequest(_redemptionRequestId);
        Agent.State storage agent = Agent.get(request.agentVault);
        // Usually, we require the agent to trigger confirmation.
        // But if the agent doesn't respond for long enough,
        // we allow anybody and that user gets rewarded from agent's vault.
        bool isAgent = Agents.isOwner(agent, msg.sender);
        require(isAgent || _othersCanConfirmPayment(agent, request, _payment),
            "only agent vault owner");
        // verify transaction
        TransactionAttestation.verifyPayment(_payment);
        // payment reference must match
        require(_payment.data.responseBody.standardPaymentReference ==
                PaymentReference.redemption(_redemptionRequestId),
            "invalid redemption reference");
        // we do not allow payments before the underlying block at requests, because the payer should have guessed
        // the payment reference, which is good for nothing except attack attempts
        require(_payment.data.responseBody.blockNumber >= request.firstUnderlyingBlock,
            "redemption payment too old");
        // Valid payments are to correct destination, in time, and must have value at least the request payment value.
        (bool paymentValid, string memory failureReason) = _validatePayment(request, _payment);
        if (paymentValid) {
            // release agent collateral
            Agents.endRedeemingAssets(agent, request.valueAMG, request.poolSelfClose);
            // notify
            if (_payment.data.responseBody.status == TransactionAttestation.PAYMENT_SUCCESS) {
                emit AMEvents.RedemptionPerformed(request.agentVault, request.redeemer,  _redemptionRequestId,
                    _payment.data.requestBody.transactionId, request.underlyingValueUBA,
                    _payment.data.responseBody.spentAmount);
            } else {    // _payment.status == TransactionAttestation.PAYMENT_BLOCKED
                emit AMEvents.RedemptionPaymentBlocked(request.agentVault, request.redeemer, _redemptionRequestId,
                    _payment.data.requestBody.transactionId, request.underlyingValueUBA,
                    _payment.data.responseBody.spentAmount);
            }
        } else {
            // We only need failure reports from agent's underlying address, so disallow others to
            // lower the attack surface in case of report from other address.
            require(_payment.data.responseBody.sourceAddressHash == agent.underlyingAddressHash,
                "confirm failed payment only from agent's address");
            // We do not allow retrying failed payments, so just default here if not defaulted already.
            // This will also release the remaining agent's collateral.
            if (request.status == Redemption.Status.ACTIVE) {
                RedemptionFailures.executeDefaultPayment(agent, request, _redemptionRequestId);
            }
            // notify
            emit AMEvents.RedemptionPaymentFailed(request.agentVault, request.redeemer, _redemptionRequestId,
                _payment.data.requestBody.transactionId, _payment.data.responseBody.spentAmount, failureReason);
        }
        // agent has finished with redemption - account for used underlying balance and free the remainder
        UnderlyingBalance.updateBalance(agent, -_payment.data.responseBody.spentAmount);
        // record source decreasing transaction so that it cannot be challenged
        AssetManagerState.State storage state = AssetManagerState.get();
        state.paymentConfirmations.confirmSourceDecreasingTransaction(_payment);
        // if the confirmation was done by someone else than agent, pay some reward from agent's vault
        if (!isAgent) {
            Agents.payoutFromVault(agent, msg.sender,
                Agents.convertUSD5ToVaultCollateralWei(agent, Globals.getSettings().confirmationByOthersRewardUSD5));
        }
        // burn executor fee (or pay executor if the "other" that provided proof is the executor)
        Redemptions.payOrBurnExecutorFee(request);
        // redemption can make agent healthy, so check and pull out of liquidation
        Liquidation.endLiquidationIfHealthy(agent);
        // delete redemption request at end
        Redemptions.deleteRedemptionRequest(_redemptionRequestId);
    }

    function _othersCanConfirmPayment(
        Agent.State storage _agent,
        Redemption.Request storage _request,
        Payment.Proof calldata _payment
    )
        private view
        returns (bool)
    {
        AssetManagerSettings.Data storage settings = Globals.getSettings();
        // others can confirm payments only after several hours
        if (block.timestamp <= _request.timestamp + settings.confirmationByOthersAfterSeconds) return false;
        // others can confirm only payments arriving from agent's underlying address
        // - on utxo chains for multi-source payment, 3rd party might lie about payment not coming from agent's
        //   source, which would delete redemption request but not mark source decreasing transaction as used;
        //   so afterwards there can be an illegal payment challenge for this transaction
        // - we really only need 3rd party confirmations for payments from agent's underlying address,
        //   to properly account for underlying free balance (unless payment is failed, the collateral also gets
        //   unlocked, but that only benefits the agent, so the agent should take care of that)
        return _payment.data.responseBody.sourceAddressHash == _agent.underlyingAddressHash;
    }

    function _validatePayment(
        Redemption.Request storage request,
        Payment.Proof calldata _payment
    )
        private view
        returns (bool _paymentValid, string memory _failureReason)
    {
        uint256 paymentValueUBA = uint256(request.underlyingValueUBA) - request.underlyingFeeUBA;
        if (_payment.data.responseBody.status == TransactionAttestation.PAYMENT_FAILED) {
            return (false, "transaction failed");
        } else if (_payment.data.responseBody.receivingAddressHash != request.redeemerUnderlyingAddressHash) {
            return (false, "not redeemer's address");
        } else if (_payment.data.responseBody.receivedAmount < int256(paymentValueUBA)) { // paymentValueUBA < 2**128
            // for blocked payments, receivedAmount == 0, but it's still receiver's fault
            if (_payment.data.responseBody.status != TransactionAttestation.PAYMENT_BLOCKED) {
                return (false, "redemption payment too small");
            }
        } else if (_payment.data.responseBody.blockNumber > request.lastUnderlyingBlock &&
            _payment.data.responseBody.blockTimestamp > request.lastUnderlyingTimestamp) {
            return (false, "redemption payment too late");
        } else if (request.status == Redemption.Status.DEFAULTED) {
            // Redemption is already defaulted, although the payment was not too late.
            // This indicates a problem in state connector, which gives proofs of both valid payment and nonpayment,
            // but we cannot solve it here. So we just return as failed and the off-chain code should alert.
            return (false, "redemption payment too late");
        }
        return (true, "");
    }
}
