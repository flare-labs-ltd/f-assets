// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./PaymentVerification.sol";

library PaymentReport {
    using SafeMath for uint256;

    enum ReportMatch { DOES_NOT_EXIST, MATCH, MISMATCH }
    
    struct Report {
        // hash of (sourceAddress, targetAddress, deliveredUBA, spentUBA)
        // matched if challenger provides LegalPayment proof (includes target data)
        bytes16 fullDetailsHash;
        
        // hash of (sourceAddress, spentUBA)
        // matched if challenger provides SourceUsingTransaction proof (no target data)
        bytes16 sourceDetailsHash;
    }
    
    struct Reports {
        // mapping(PaymentVerification.transactionKey(paymentInfo) => Report)
        mapping(bytes32 => Report) reports;
    }
    
    uint256 internal constant REPORT_CLEANUP_SECONDS = 5 * 86400;   // 5 days, as for verification
        
    function createReport(
        Reports storage _state,
        PaymentVerification.UnderlyingPaymentInfo memory _paymentInfo
    )
        internal
    {
        bytes32 txKey = PaymentVerification.transactionKey(_paymentInfo);
        _state.reports[txKey] = Report({
            fullDetailsHash: _fullDetailsHash(_paymentInfo),
            sourceDetailsHash: _sourceDetailsHash(_paymentInfo)
        });
    }

    function deleteReport(
        Reports storage _state,
        PaymentVerification.UnderlyingPaymentInfo memory _paymentInfo
    )
        internal
    {
        bytes32 txKey = PaymentVerification.transactionKey(_paymentInfo);
        delete _state.reports[txKey];
    }

    function reportMatch(
        Reports storage _state,
        PaymentVerification.UnderlyingPaymentInfo memory _paymentInfo
    )
        internal view
        returns (ReportMatch)
    {
        bytes32 txKey = PaymentVerification.transactionKey(_paymentInfo);
        Report storage report = _state.reports[txKey];
        if (report.fullDetailsHash == 0) {
            return ReportMatch.DOES_NOT_EXIST;
        }
        bool matches = _paymentInfo.targetAddress != 0
            ? report.fullDetailsHash == _fullDetailsHash(_paymentInfo) 
            : report.sourceDetailsHash == _sourceDetailsHash(_paymentInfo);
        if (matches) {
            return ReportMatch.MATCH;
        }
        return ReportMatch.MISMATCH;
    }
    
    function _fullDetailsHash(
        PaymentVerification.UnderlyingPaymentInfo memory _pi
    )
        private pure
        returns (bytes16)
    {
        bytes32 detailsHash = keccak256(
            abi.encode(_pi.sourceAddress, _pi.targetAddress, _pi.deliveredUBA, _pi.spentUBA));
        return bytes16(detailsHash);
    }

    function _sourceDetailsHash(
        PaymentVerification.UnderlyingPaymentInfo memory _pi
    )
        private pure
        returns (bytes16)
    {
        bytes32 detailsHash = keccak256(
            abi.encode(_pi.sourceAddress, _pi.deliveredUBA, _pi.spentUBA));
        return bytes16(detailsHash);
    }
}
