// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../utils/lib/SafePct.sol";
import "./data/AssetManagerState.sol";
import "./data/RedemptionTimeExtension.sol";
import "./AMEvents.sol";
import "./Conversion.sol";
import "./Redemptions.sol";
import "./Liquidation.sol";
import "./TransactionAttestation.sol";


library RedemptionRequests {
    using SafePct for *;
    using SafeCast for uint256;
    using RedemptionQueue for RedemptionQueue.State;

    struct AgentRedemptionData {
        address agentVault;
        uint64 valueAMG;
    }

    struct AgentRedemptionList {
        AgentRedemptionData[] items;
        uint256 length;
    }

    function redeem(
        address _redeemer,
        uint64 _lots,
        string memory _redeemerUnderlyingAddress,
        address payable _executor
    )
        internal
        returns (uint256)
    {
        uint256 maxRedeemedTickets = Globals.getSettings().maxRedeemedTickets;
        AgentRedemptionList memory redemptionList = AgentRedemptionList({
            length: 0,
            items: new AgentRedemptionData[](maxRedeemedTickets)
        });
        uint64 redeemedLots = 0;
        for (uint256 i = 0; i < maxRedeemedTickets && redeemedLots < _lots; i++) {
            // each loop, firstTicketId will change since we delete the first ticket
            uint64 redeemedForTicket = _redeemFirstTicket(_lots - redeemedLots, redemptionList);
            if (redeemedForTicket == 0) {
                break;   // queue empty
            }
            redeemedLots += redeemedForTicket;
        }
        require(redeemedLots != 0, "redeem 0 lots");
        uint256 executorFeeNatGWei = msg.value / Conversion.GWEI;
        for (uint256 i = 0; i < redemptionList.length; i++) {
            // distribute executor fee over redemption request with at most 1 gwei leftover
            uint256 currentExecutorFeeNatGWei = executorFeeNatGWei / (redemptionList.length - i);
            executorFeeNatGWei -= currentExecutorFeeNatGWei;
            _createRedemptionRequest(redemptionList.items[i], _redeemer, _redeemerUnderlyingAddress, false,
                _executor, currentExecutorFeeNatGWei.toUint64());
        }
        // notify redeemer of incomplete requests
        if (redeemedLots < _lots) {
            emit AMEvents.RedemptionRequestIncomplete(_redeemer, _lots - redeemedLots);
        }
        // burn the redeemed value of fassets
        uint256 redeemedUBA = Conversion.convertLotsToUBA(redeemedLots);
        Redemptions.burnFAssets(msg.sender, redeemedUBA);
        return redeemedUBA;
    }

    function redeemFromAgent(
        address _agentVault,
        address _redeemer,
        uint256 _amountUBA,
        string memory _receiverUnderlyingAddress,
        address payable _executor
    )
        internal
    {
        Agent.State storage agent = Agent.get(_agentVault);
        Agents.requireCollateralPool(agent);
        require(_amountUBA != 0, "redemption of 0");
        // close redemption tickets
        uint64 amountAMG = Conversion.convertUBAToAmg(_amountUBA);
        (uint64 closedAMG, uint256 closedUBA) = Redemptions.closeTickets(agent, amountAMG, false);
        // create redemption request
        AgentRedemptionData memory redemption = AgentRedemptionData(_agentVault, closedAMG);
        _createRedemptionRequest(redemption, _redeemer, _receiverUnderlyingAddress, true,
            _executor, (msg.value / Conversion.GWEI).toUint64());
        // burn the closed assets
        Redemptions.burnFAssets(msg.sender, closedUBA);
    }

    function redeemFromAgentInCollateral(
        address _agentVault,
        address _redeemer,
        uint256 _amountUBA
    )
        internal
    {
        Agent.State storage agent = Agent.get(_agentVault);
        Agents.requireCollateralPool(agent);
        require(_amountUBA != 0, "redemption of 0");
        // close redemption tickets
        uint64 amountAMG = Conversion.convertUBAToAmg(_amountUBA);
        (uint64 closedAMG, uint256 closedUBA) = Redemptions.closeTickets(agent, amountAMG, true);
        // pay in collateral
        uint256 priceAmgToWei = Conversion.currentAmgPriceInTokenWei(agent.vaultCollateralIndex);
        uint256 paymentWei = Conversion.convertAmgToTokenWei(closedAMG, priceAmgToWei)
            .mulBips(agent.buyFAssetByAgentFactorBIPS);
        Agents.payoutFromVault(agent, _redeemer, paymentWei);
        emit AMEvents.RedeemedInCollateral(_agentVault, _redeemer, closedUBA, paymentWei);
        // burn the closed assets
        Redemptions.burnFAssets(msg.sender, closedUBA);
    }

    function selfClose(
        address _agentVault,
        uint256 _amountUBA
    )
        internal
        returns (uint256)
    {
        Agent.State storage agent = Agent.get(_agentVault);
        Agents.requireAgentVaultOwner(_agentVault);
        require(_amountUBA != 0, "self close of 0");
        uint64 amountAMG = Conversion.convertUBAToAmg(_amountUBA);
        (, uint256 closedUBA) = Redemptions.closeTickets(agent, amountAMG, true);
        // burn the self-closed assets
        Redemptions.burnFAssets(msg.sender, closedUBA);
        // try to pull agent out of liquidation
        Liquidation.endLiquidationIfHealthy(agent);
        // send event
        emit AMEvents.SelfClose(_agentVault, closedUBA);
        return closedUBA;
    }

    function rejectInvalidRedemption(
        AddressValidity.Proof calldata _proof,
        uint64 _redemptionRequestId
    )
        internal
    {
        Redemption.Request storage request = Redemptions.getRedemptionRequest(_redemptionRequestId);
        Agent.State storage agent = Agent.get(request.agentVault);
        // only owner can call
        require(Agents.isOwner(agent, msg.sender), "only agent vault owner");
        // check proof
        TransactionAttestation.verifyAddressValidity(_proof);
        // the actual redeemer's address must be validated
        bytes32 addressHash = keccak256(bytes(_proof.data.requestBody.addressStr));
        require(addressHash == request.redeemerUnderlyingAddressHash, "wrong address");
        // and the address must be invalid or not normalized
        bool valid = _proof.data.responseBody.isValid &&
            _proof.data.responseBody.standardAddressHash == request.redeemerUnderlyingAddressHash;
        require(!valid, "address valid");
        // release agent collateral
        Agents.endRedeemingAssets(agent, request.valueAMG, request.poolSelfClose);
        // emit event
        uint256 valueUBA = Conversion.convertAmgToUBA(request.valueAMG);
        emit AMEvents.RedemptionRejected(request.agentVault, request.redeemer, _redemptionRequestId, valueUBA);
        // delete redemption request at end
        Redemptions.deleteRedemptionRequest(_redemptionRequestId);
    }

    function maxRedemptionFromAgent(
        address _agentVault
    )
        internal view
        returns (uint256)
    {
        Agent.State storage agent = Agent.get(_agentVault);
        return Redemptions.maxClosedFromAgentPerTransaction(agent);
    }

    function _redeemFirstTicket(
        uint64 _lots,
        AgentRedemptionList memory _list
    )
        private
        returns (uint64 _redeemedLots)
    {
        AssetManagerState.State storage state = AssetManagerState.get();
        AssetManagerSettings.Data storage settings = Globals.getSettings();
        uint64 ticketId = state.redemptionQueue.firstTicketId;
        if (ticketId == 0) {
            return 0;    // empty redemption queue
        }
        RedemptionQueue.Ticket storage ticket = state.redemptionQueue.getTicket(ticketId);
        uint64 maxRedeemLots = ticket.valueAMG / settings.lotSizeAMG;
        _redeemedLots = SafeMath64.min64(_lots, maxRedeemLots);
        uint64 redeemedAMG = _redeemedLots * settings.lotSizeAMG;
        address agentVault = ticket.agentVault;
        // find list index for ticket's agent
        uint256 index = 0;
        while (index < _list.length && _list.items[index].agentVault != agentVault) {
            ++index;
        }
        // add to list item or create new item
        if (index < _list.length) {
            _list.items[index].valueAMG = _list.items[index].valueAMG + redeemedAMG;
        } else {
            _list.items[_list.length++] = AgentRedemptionData({ agentVault: agentVault, valueAMG: redeemedAMG });
        }
        // _removeFromTicket may delete ticket data, so we call it at end
        Redemptions.removeFromTicket(ticketId, redeemedAMG);
    }

    function _createRedemptionRequest(
        AgentRedemptionData memory _data,
        address _redeemer,
        string memory _redeemerUnderlyingAddressString,
        bool _poolSelfClose,
        address payable _executor,
        uint64 _executorFeeNatGWei
    )
        private
    {
        AssetManagerState.State storage state = AssetManagerState.get();
        // validate redemption address
        bytes32 underlyingAddressHash = keccak256(bytes(_redeemerUnderlyingAddressString));
        // create request
        uint128 redeemedValueUBA = Conversion.convertAmgToUBA(_data.valueAMG).toUint128();
        uint64 requestId = _newRequestId(_poolSelfClose);
        // create in-memory request and then put it to storage to not go out-of-stack
        Redemption.Request memory request;
        request.redeemerUnderlyingAddressHash = underlyingAddressHash;
        request.underlyingValueUBA = redeemedValueUBA;
        request.firstUnderlyingBlock = state.currentUnderlyingBlock;
        (request.lastUnderlyingBlock, request.lastUnderlyingTimestamp) = _lastPaymentBlock(_data.agentVault);
        request.timestamp = block.timestamp.toUint64();
        request.underlyingFeeUBA = redeemedValueUBA.mulBips(Globals.getSettings().redemptionFeeBIPS).toUint128();
        request.redeemer = _redeemer;
        request.agentVault = _data.agentVault;
        request.valueAMG = _data.valueAMG;
        request.status = Redemption.Status.ACTIVE;
        request.poolSelfClose = _poolSelfClose;
        request.executor = _executor;
        request.executorFeeNatGWei = _executorFeeNatGWei;
        state.redemptionRequests[requestId] = request;
        // decrease mintedAMG and mark it to redeemingAMG
        // do not add it to freeBalance yet (only after failed redemption payment)
        Agents.startRedeemingAssets(Agent.get(_data.agentVault), _data.valueAMG, _poolSelfClose);
        // emit event to remind agent to pay
        _emitRedemptionRequestedEvent(request, requestId, _redeemerUnderlyingAddressString);
    }

    function _emitRedemptionRequestedEvent(
        Redemption.Request memory _request,
        uint64 _requestId,
        string memory _redeemerUnderlyingAddressString
    )
        private
    {
        emit AMEvents.RedemptionRequested(
            _request.agentVault,
            _request.redeemer,
            _requestId,
            _redeemerUnderlyingAddressString,
            _request.underlyingValueUBA,
            _request.underlyingFeeUBA,
            _request.firstUnderlyingBlock,
            _request.lastUnderlyingBlock,
            _request.lastUnderlyingTimestamp,
            PaymentReference.redemption(_requestId),
            _request.executor,
            _request.executorFeeNatGWei * Conversion.GWEI);
    }

    function _newRequestId(bool _poolSelfClose)
        private
        returns (uint64)
    {
        AssetManagerState.State storage state = AssetManagerState.get();
        uint64 nextRequestId = state.newRedemptionRequestId + PaymentReference.randomizedIdSkip();
        // the requestId will indicate in the lowest bit whether it is a pool self close redemption
        // (+1 is added so that the request id still increases after clearing lowest bit)
        uint64 requestId = ((nextRequestId + 1) & ~uint64(1)) | (_poolSelfClose ? 1 : 0);
        state.newRedemptionRequestId = requestId;
        return requestId;
    }

    function _lastPaymentBlock(address _agentVault)
        private
        returns (uint64 _lastUnderlyingBlock, uint64 _lastUnderlyingTimestamp)
    {
        AssetManagerState.State storage state = AssetManagerState.get();
        AssetManagerSettings.Data storage settings = Globals.getSettings();
        // timeshift amortizes for the time that passed from the last underlying block update;
        // it also adds redemption time extension when there are many redemption requests in short time
        uint64 timeshift = block.timestamp.toUint64() - state.currentUnderlyingBlockUpdatedAt
            + RedemptionTimeExtension.extendTimeForRedemption(_agentVault);
        uint64 blockshift = (uint256(timeshift) * 1000 / settings.averageBlockTimeMS).toUint64();
        _lastUnderlyingBlock =
            state.currentUnderlyingBlock + blockshift + settings.underlyingBlocksForPayment;
        _lastUnderlyingTimestamp =
            state.currentUnderlyingBlockTimestamp + timeshift + settings.underlyingSecondsForPayment;
    }
}
