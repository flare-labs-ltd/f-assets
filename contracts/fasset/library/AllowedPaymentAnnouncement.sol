// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "@openzeppelin/contracts/utils/SafeCast.sol";
import "../../utils/lib/SafeMath64.sol";
import "./PaymentVerification.sol";
import "./Agents.sol";
import "./IllegalPaymentChallenge.sol";
import "./UnderlyingFreeBalance.sol";
import "./AssetManagerState.sol";


library AllowedPaymentAnnouncement {
    struct PaymentAnnouncement {
        uint128 valueUBA;
        uint64 createdAtBlock;
    }
    
    event AllowedPaymentAnnounced(
        address agentVault,
        uint256 valueUBA,
        uint64 announcementId);
        
    event AllowedPaymentReported(
        address agentVault,
        uint256 valueUBA,
        uint256 gasUBA,
        uint64 underlyingBlock,
        uint64 announcementId);
        
    function announceAllowedPayment(
        AssetManagerState.State storage _state,
        address _agentVault,
        uint256 _valueUBA
    )
        internal
    {
        Agents.requireOwnerAgent(_agentVault);
        require(_valueUBA > 0, "invalid value");
        UnderlyingFreeBalance.withdrawFreeFunds(_state, _agentVault, _valueUBA);
        uint64 announcementId = ++_state.newPaymentAnnouncementId;
        bytes32 key = _announcementKey(_agentVault, announcementId);
        _state.paymentAnnouncements[key] = PaymentAnnouncement({
            valueUBA: SafeCast.toUint128(_valueUBA),
            createdAtBlock: SafeCast.toUint64(block.number)
        });
        emit AllowedPaymentAnnounced(_agentVault, _valueUBA, announcementId);
    }
    
    function reportAllowedPayment(
        AssetManagerState.State storage _state,
        PaymentVerification.UnderlyingPaymentInfo memory _paymentInfo,
        address _agentVault,
        uint64 _announcementId
    )
        internal
    {
        Agents.requireOwnerAgent(_agentVault);
        Agents.Agent storage agent = Agents.getAgent(_state, _agentVault);
        bytes32 key = _announcementKey(_agentVault, _announcementId);
        PaymentAnnouncement storage announcement = _state.paymentAnnouncements[key];
        require(announcement.createdAtBlock != 0, "invalid announcement id");
        // if payment is challenged, make sure announcement was made strictly before challenge
        IllegalPaymentChallenge.Challenge storage challenge = 
            IllegalPaymentChallenge.getChallenge(_state, _paymentInfo.sourceAddress, _paymentInfo.transactionHash);
        require(challenge.agentVault == address(0) || challenge.createdAtBlock > announcement.createdAtBlock,
            "challenged before announcement");
        // verify that details match announcement
        PaymentVerification.validatePaymentDetails(_paymentInfo, 
            agent.underlyingAddress, 0 /* target not needed for allowed payments */, announcement.valueUBA);
        // once the transaction has been proved, reporting it is pointless
        require(!PaymentVerification.paymentConfirmed(_state.paymentVerifications, _paymentInfo),
            "payment report after confirm");
        // create the report
        PaymentReport.createReport(_state.paymentReports, _paymentInfo);
        // deduct gas from free balance (don't report multiple times or gas will be deducted every time)
        UnderlyingFreeBalance.updateFreeBalance(_state, _agentVault, 0, _paymentInfo.gasUBA, 
            _paymentInfo.underlyingBlock);
        emit AllowedPaymentReported(_agentVault, _paymentInfo.valueUBA, _paymentInfo.gasUBA, 
            _paymentInfo.underlyingBlock, _announcementId);
        delete _state.paymentAnnouncements[key];
    }
    
    function _announcementKey(address _agentVault, uint64 _id) private pure returns (bytes32) {
        return bytes32(uint256(_agentVault) | (uint256(_id) << 160));
    }
}
