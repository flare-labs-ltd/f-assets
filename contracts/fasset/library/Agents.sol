// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "../interface/IAgentVault.sol";
import "../../utils/lib/SafeBips.sol";
import "./AMEvents.sol";
import "./Conversion.sol";
import "./RedemptionQueue.sol";
import "./UnderlyingAddressOwnership.sol";
import "./AssetManagerState.sol";


library Agents {
    using SafeMath for uint256;
    using SafeBips for uint256;
    using SafePct for uint256;
    using UnderlyingAddressOwnership for UnderlyingAddressOwnership.State;
    using RedemptionQueue for RedemptionQueue.State;
    
    enum AgentType {
        NONE,
        AGENT_100,
        AGENT_0,
        SELF_MINTING
    }
    
    enum AgentStatus {
        NORMAL,
        LIQUIDATION, // CCB, liquidation due to CR or topup
        FULL_LIQUIDATION // illegal payment liquidation
    }

    enum LiquidationPhase {
        CCB,
        PRICE_PREMIUM,
        COLLATERAL_PREMIUM
    }
    
    struct LiquidationState {
        uint64 liquidationStartedAt;
        LiquidationPhase initialLiquidationPhase; // at the time when liquidation started
        uint16 initialPremiumFactorBIPS; // at the time when liquidation started
    }

    struct Agent {
        // Current address for underlying agent's collateral.
        // Agent can change this address anytime and it affects future mintings.
        bytes32 underlyingAddress;
        
        // For agents to withdraw NAT collateral, they must first announce it and then wait 
        // withdrawalAnnouncementSeconds. 
        // The announced amount cannt be used as collateral for minting during that time.
        // This makes sure that agents cannot just remove all collateral if they are challenged.
        uint128 withdrawalAnnouncedNATWei;
        
        // The time when withdrawal was announced.
        uint64 withdrawalAnnouncedAt;
        
        // Amount of collateral locked by collateral reservation.
        uint64 reservedAMG;
        
        // Amount of collateral backing minted fassets.
        uint64 mintedAMG;
        
        // The amount of fassets being redeemed. In this case, the fassets were already burned,
        // but the collateral must still be locked to allow payment in case of redemption failure.
        // The distinction between 'minted' and 'redeemed' assets is important in case of challenge.
        uint64 redeemingAMG;
        
        // When lot size changes, there may be some leftover after redemtpion that doesn't fit
        // a whole lot size. It is added to dustAMG and can be recovered via self-close.
        // Unlike redeemingAMG, dustAMG is still counted in the mintedAMG.
        uint64 dustAMG;
        
        // Position of this agent in the list of agents available for minting.
        // Value is actually `list index + 1`, so that 0 means 'not in list'.
        uint64 availableAgentsPos;
        
        // Minting fee in BIPS (collected in underlying currency).
        uint16 feeBIPS;
        
        // Collateral ratio at which we calculate locked collateral and collateral available for minting.
        // Agent may set own value for minting collateral ratio when entering the available agent list,
        // but it must always be greater than minimum collateral ratio.
        uint32 agentMinCollateralRatioBIPS;
        
        // Current status of the agent (changes for liquidation).
        AgentType agentType;
        AgentStatus status;
        LiquidationState liquidationState;

        // The amount of underlying funds that may be withdrawn by the agent
        // (fees, self-close and, amount released by liquidation).
        // May become negative (due to high underlying gas costs), in which case topup is required.
        int128 freeUnderlyingBalanceUBA;
        
        // When freeUnderlyingBalanceUBA becomes negative, agent has until this block to perform topup,
        // otherwise liquidation can be triggered by a challenger.
        uint64 lastUnderlyingBlockForTopup;
    }
    
    function createAgent(
        AssetManagerState.State storage _state, 
        AgentType _agentType,
        address _agentVault,
        bytes32 _underlyingAddress
    ) 
        internal 
    {
        // TODO: create vault here instead of passing _agentVault?
        require(_agentVault != address(0), "zero vault address");
        require(_underlyingAddress != 0, "zero underlying address");
        Agent storage agent = _state.agents[_agentVault];
        require(agent.agentType == AgentType.NONE, "agent already exists");
        agent.agentType = _agentType;
        agent.status = AgentStatus.NORMAL;
        // claim the address to make sure no other agent is using it
        // for chains where this is required, also checks that address was proved to be EOA
        _state.underlyingAddressOwnership.claim(_agentVault, _underlyingAddress, 
            _state.settings.requireEOAAddressProof);
        agent.underlyingAddress = _underlyingAddress;
    }
    
    function allocateMintedAssets(
        AssetManagerState.State storage _state, 
        address _agentVault,
        uint64 _valueAMG
    )
        internal
    {
        Agent storage agent = getAgent(_state, _agentVault);
        agent.mintedAMG = SafeMath64.add64(agent.mintedAMG, _valueAMG);
    }

    function releaseMintedAssets(
        AssetManagerState.State storage _state, 
        address _agentVault,
        uint64 _valueAMG
    )
        internal
    {
        Agent storage agent = getAgent(_state, _agentVault);
        agent.mintedAMG = SafeMath64.sub64(agent.mintedAMG, _valueAMG, "not enough minted");
    }

    function startRedeemingAssets(
        AssetManagerState.State storage _state, 
        address _agentVault,
        uint64 _valueAMG
    )
        internal
    {
        Agent storage agent = getAgent(_state, _agentVault);
        agent.redeemingAMG = SafeMath64.add64(agent.redeemingAMG, _valueAMG);
        agent.mintedAMG = SafeMath64.sub64(agent.mintedAMG, _valueAMG, "not enough minted");
    }

    function endRedeemingAssets(
        AssetManagerState.State storage _state, 
        address _agentVault,
        uint64 _valueAMG
    )
        internal
    {
        Agent storage agent = getAgent(_state, _agentVault);
        agent.redeemingAMG = SafeMath64.sub64(agent.redeemingAMG, _valueAMG, "not enough redeeming");
    }
    
    function announceWithdrawal(
        AssetManagerState.State storage _state, 
        address _agentVault,
        uint256 _valueNATWei,
        uint256 _fullCollateral, 
        uint256 _amgToNATWeiPrice
    )
        internal
    {
        Agent storage agent = getAgent(_state, _agentVault);
        if (_valueNATWei > agent.withdrawalAnnouncedNATWei) {
            // announcement increased - must check there is enough free collateral and then lock it
            // in this case the wait to withdrawal restarts from this moment
            uint256 increase = _valueNATWei - agent.withdrawalAnnouncedNATWei;
            require(increase <= freeCollateralWei(agent, _state.settings, _fullCollateral, _amgToNATWeiPrice),
                "withdrawal: value too high");
            agent.withdrawalAnnouncedAt = SafeCast.toUint64(block.timestamp);
        } else {
            // announcement decreased or canceled - might be needed to get agent out of CCB
            // if value is 0, we cancel announcement completely (i.e. set announcement time to 0)
            // otherwise, for decreasing announcement, we can safely leave announcement time unchanged
            if (_valueNATWei == 0) {
                agent.withdrawalAnnouncedAt = 0;
            }
        }
        agent.withdrawalAnnouncedNATWei = SafeCast.toUint128(_valueNATWei);
    }

    function increaseDust(
        AssetManagerState.State storage _state,
        address _agentVault,
        uint64 _dustIncreaseAMG
    )
        internal
    {
        Agent storage agent = getAgent(_state, _agentVault);
        uint64 newDustAMG = SafeMath64.add64(agent.dustAMG, _dustIncreaseAMG);
        agent.dustAMG = newDustAMG;
        uint256 dustUBA = Conversion.convertAmgToUBA(_state.settings, newDustAMG);
        emit AMEvents.DustChanged(_agentVault, dustUBA);
    }

    function decreaseDust(
        AssetManagerState.State storage _state,
        address _agentVault,
        uint64 _dustDecreaseAMG
    )
        internal
    {
        Agent storage agent = getAgent(_state, _agentVault);
        uint64 newDustAMG = SafeMath64.sub64(agent.dustAMG, _dustDecreaseAMG, "not enough dust");
        agent.dustAMG = newDustAMG;
        uint256 dustUBA = Conversion.convertAmgToUBA(_state.settings, newDustAMG);
        emit AMEvents.DustChanged(_agentVault, dustUBA);
    }
    
    function convertDustToTickets(
        AssetManagerState.State storage _state,
        address _agentVault
    )
        internal
    {
        // we do NOT check that the caller is the agent owner, since we want to
        // allow anyone to convert dust to tickets to increase asset fungibility
        Agent storage agent = getAgent(_state, _agentVault);
        // if dust is more than 1 lot, create a new redemption ticket
        if (agent.dustAMG >= _state.settings.lotSizeAMG) {
            uint64 remainingDustAMG = agent.dustAMG % _state.settings.lotSizeAMG;
            _state.redemptionQueue.createRedemptionTicket(_agentVault, agent.dustAMG - remainingDustAMG);
            agent.dustAMG = remainingDustAMG;
        }
    }
    
    function withdrawalExecuted(
        AssetManagerState.State storage _state, 
        address _agentVault,
        uint256 _valueNATWei
    )
        internal
    {
        Agent storage agent = getAgent(_state, _agentVault);
        require(agent.withdrawalAnnouncedAt != 0 &&
            block.timestamp <= agent.withdrawalAnnouncedAt + _state.settings.withdrawalWaitMinSeconds,
            "withdrawal: not announced");
        require(_valueNATWei <= agent.withdrawalAnnouncedNATWei,
            "withdrawal: more than announced");
        agent.withdrawalAnnouncedAt = 0;
        agent.withdrawalAnnouncedNATWei = 0;
    }
    
    function getAgent(
        AssetManagerState.State storage _state, 
        address _agentVault
    ) 
        internal view 
        returns (Agent storage _agent) 
    {
        _agent = _state.agents[_agentVault];
        require(_agent.agentType != AgentType.NONE, "agent does not exist");
    }

    function getAgentNoCheck(
        AssetManagerState.State storage _state, 
        address _agentVault
    ) 
        internal view 
        returns (Agent storage _agent) 
    {
        _agent = _state.agents[_agentVault];
    }
    
    function isAgentInLiquidation(
        AssetManagerState.State storage _state, 
        address _agentVault
    )
        internal view
        returns (bool)
    {
        Agents.Agent storage agent = _state.agents[_agentVault];
        return agent.liquidationState.liquidationStartedAt > 0;
    }

    function freeCollateralLots(
        Agents.Agent storage _agent, 
        AssetManagerSettings.Settings storage _settings,
        uint256 _fullCollateral, 
        uint256 _amgToNATWeiPrice
    )
        internal view 
        returns (uint256) 
    {
        uint256 freeCollateral = freeCollateralWei(_agent, _settings, _fullCollateral, _amgToNATWeiPrice);
        uint256 lotCollateral = mintingLotCollateralWei(_agent, _settings, _amgToNATWeiPrice);
        return freeCollateral.div(lotCollateral);
    }

    function freeCollateralWei(
        Agents.Agent storage _agent, 
        AssetManagerSettings.Settings storage _settings, 
        uint256 _fullCollateral, 
        uint256 _amgToNATWeiPrice
    )
        internal view 
        returns (uint256) 
    {
        uint256 lockedCollateral = lockedCollateralWei(_agent, _settings, _amgToNATWeiPrice);
        (, uint256 freeCollateral) = _fullCollateral.trySub(lockedCollateral);
        return freeCollateral;
    }
    
    function lockedCollateralWei(
        Agents.Agent storage _agent, 
        AssetManagerSettings.Settings storage _settings, 
        uint256 _amgToNATWeiPrice
    )
        internal view 
        returns (uint256) 
    {
        uint256 mintingAMG = uint256(_agent.reservedAMG).add(_agent.mintedAMG);
        uint256 mintingCollateral = Conversion.convertAmgToNATWei(mintingAMG, _amgToNATWeiPrice)
            .mulBips(_agent.agentMinCollateralRatioBIPS);
        uint256 redeemingCollateral = lockedRedeemingCollateralWei(_agent, _settings, _amgToNATWeiPrice);
        return mintingCollateral.add(redeemingCollateral).add(_agent.withdrawalAnnouncedNATWei);
    }

    function lockedRedeemingCollateralWei(
        Agents.Agent storage _agent, 
        AssetManagerSettings.Settings storage _settings, 
        uint256 _amgToNATWeiPrice
    )
        internal view 
        returns (uint256) 
    {
        return Conversion.convertAmgToNATWei(_agent.redeemingAMG, _amgToNATWeiPrice)
            .mulBips(_settings.initialMinCollateralRatioBIPS);
    }
    
    function mintingLotCollateralWei(
        Agents.Agent storage _agent, 
        AssetManagerSettings.Settings storage _settings,
        uint256 _amgToNATWeiPrice
    ) 
        internal view 
        returns (uint256) 
    {
        return Conversion.convertAmgToNATWei(_settings.lotSizeAMG, _amgToNATWeiPrice)
            .mulBips(_agent.agentMinCollateralRatioBIPS);
    }
    
    function collateralShare(
        Agents.Agent storage _agent, 
        uint256 _fullCollateral, 
        uint256 _valueAMG
    )
        internal view 
        returns (uint256) 
    {
        // safe - all are uint64
        uint256 totalAMG = uint256(_agent.mintedAMG) + uint256(_agent.reservedAMG) + uint256(_agent.redeemingAMG);
        require(totalAMG < _valueAMG, "value larger than total");
        return _fullCollateral.mulDiv(_valueAMG, totalAMG);
    }
    
    function requireOwnerAgent(address _agentVault) internal view {
        require(msg.sender == IAgentVault(_agentVault).owner(), "only agent");
    }
}
