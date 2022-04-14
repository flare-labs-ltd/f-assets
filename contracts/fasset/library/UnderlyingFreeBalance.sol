// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@openzeppelin/contracts/utils/math/SignedSafeMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../../generated/interface/IAttestationClient.sol";
import "./AMEvents.sol";
import "./Agents.sol";
import "./PaymentConfirmations.sol";
import "./AssetManagerState.sol";
import "./Liquidation.sol";
import "./PaymentReference.sol";
import "./TransactionAttestation.sol";


library UnderlyingFreeBalance {
    using SignedSafeMath for int256;
    using PaymentConfirmations for PaymentConfirmations.State;

    function updateFreeBalance(
        AssetManagerState.State storage _state, 
        address _agentVault,
        int256 _balanceChange
    ) 
        internal
    {
        Agents.Agent storage agent = Agents.getAgent(_state, _agentVault);
        int256 newBalance = agent.freeUnderlyingBalanceUBA + _balanceChange;
        if (newBalance < 0) {
            emit AMEvents.UnderlyingFreeBalanceNegative(_agentVault, newBalance);
            Liquidation.startFullLiquidation(_state, _agentVault);
        }
        agent.freeUnderlyingBalanceUBA = SafeCast.toInt128(newBalance);
    }

    // Like updateFreeBalance, but it can never make balance negative and trigger liquidation.
    // Separate implementation to avoid circular dependency in liquidation releasing underlying funds.
    function increaseFreeBalance(
        AssetManagerState.State storage _state, 
        address _agentVault,
        uint256 _balanceIncrease
    ) 
        internal
    {
        Agents.Agent storage agent = Agents.getAgent(_state, _agentVault);
        int256 newBalance = agent.freeUnderlyingBalanceUBA + SafeCast.toInt256(_balanceIncrease);
        agent.freeUnderlyingBalanceUBA = SafeCast.toInt128(newBalance);
    }

    function confirmTopupPayment(
        AssetManagerState.State storage _state,
        IAttestationClient.Payment calldata _payment,
        address _agentVault
    )
        external
    {
        Agents.Agent storage agent = Agents.getAgent(_state, _agentVault);
        TransactionAttestation.verifyPaymentSuccess(_state.settings, _payment);
        require(_payment.receivingAddress == agent.underlyingAddressHash, 
            "not underlying address");
        require(_payment.paymentReference == PaymentReference.topup(_agentVault),
            "not a topup payment");
        require(_payment.blockNumber >= agent.underlyingBlockAtCreation,
            "topup before agent created");
        _state.paymentConfirmations.confirmIncomingPayment(_payment);
        increaseFreeBalance(_state, _agentVault, _payment.receivedAmount);
    }
}
