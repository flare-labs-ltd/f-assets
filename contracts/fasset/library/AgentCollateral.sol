// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../../utils/lib/SafePct.sol";
import "./data/AssetManagerState.sol";
import "./data/Collateral.sol";
import "./Conversion.sol";
import "./Agents.sol";


library AgentCollateral {
    using SafeMath for uint256;
    using SafePct for uint256;
    using Agent for Agent.State;

    function combinedData(
        Agent.State storage _agent
    )
        internal view
        returns (Collateral.CombinedData memory)
    {
        Collateral.Data memory poolCollateral = poolCollateralData(_agent);
        return Collateral.CombinedData({
            agentCollateral: agentClass1CollateralData(_agent),
            poolCollateral: poolCollateral,
            agentPoolTokens: agentsPoolTokensCollateralData(_agent, poolCollateral)
        });
    }

    function singleCollateralData(
        Agent.State storage _agent,
        Collateral.Kind _kind
    )
        internal view
        returns (Collateral.Data memory)
    {
        if (_kind == Collateral.Kind.AGENT_CLASS1) {
            return agentClass1CollateralData(_agent);
        } else if (_kind == Collateral.Kind.AGENT_CLASS1) {
            return poolCollateralData(_agent);
        } else {
            return agentsPoolTokensCollateralData(_agent, poolCollateralData(_agent));
        }
    }

    function agentClass1CollateralData(
        Agent.State storage _agent
    )
        internal view
        returns (Collateral.Data memory)
    {
        AssetManagerState.State storage state = AssetManagerState.get();
        CollateralToken.Data storage collateral = state.collateralTokens[_agent.class1CollateralIndex];
        return Collateral.Data({
            kind: Collateral.Kind.AGENT_CLASS1,
            fullCollateral: collateral.token.balanceOf(_agent.vaultAddress()),
            amgToTokenWeiPrice: Conversion.currentAmgPriceInTokenWei(collateral)
        });
    }

    function poolCollateralData(
        Agent.State storage _agent
    )
        internal view
        returns (Collateral.Data memory)
    {
        AssetManagerState.State storage state = AssetManagerState.get();
        CollateralToken.Data storage collateral = state.collateralTokens[_agent.poolCollateralIndex];
        return Collateral.Data({
            kind: Collateral.Kind.POOL,
            fullCollateral: collateral.token.balanceOf(address(_agent.collateralPool)),
            amgToTokenWeiPrice: Conversion.currentAmgPriceInTokenWei(collateral)
        });
    }

    function agentsPoolTokensCollateralData(
        Agent.State storage _agent,
        Collateral.Data memory _poolCollateral
    )
        internal view
        returns (Collateral.Data memory)
    {
        IERC20 poolToken = _agent.collateralPool.poolToken();
        uint256 agentPoolTokens = poolToken.balanceOf(_agent.vaultAddress());
        uint256 totalPoolTokens = poolToken.totalSupply();
        uint256 amgToPoolTokenWeiPrice = _poolCollateral.fullCollateral != 0 ?
            _poolCollateral.amgToTokenWeiPrice.mulDiv(totalPoolTokens, _poolCollateral.fullCollateral) : 0;
        return Collateral.Data({
            kind: Collateral.Kind.AGENT_POOL,
            fullCollateral: agentPoolTokens,
            amgToTokenWeiPrice: amgToPoolTokenWeiPrice
        });
    }

    // The max number of lots the agent can mint
    function freeCollateralLots(
        Collateral.CombinedData memory _data,
        Agent.State storage _agent
    )
        internal view
        returns (uint256 _lots)
    {
        uint256 agentLots = freeSingleCollateralLots(_data.agentCollateral, _agent);
        uint256 poolLots = freeSingleCollateralLots(_data.poolCollateral, _agent);
        uint256 agentPoolTokenLots = freeSingleCollateralLots(_data.agentPoolTokens, _agent);
        return Math.min(agentLots, Math.min(poolLots, agentPoolTokenLots));
    }

    function freeSingleCollateralLots(
        Collateral.Data memory _data,
        Agent.State storage _agent
    )
        internal view
        returns (uint256)
    {
        uint256 collateralWei = freeCollateralWei(_data, _agent);
        uint256 lotWei = mintingLotCollateralWei(_data, _agent);
        // lotWei=0 is possible only for agent's pool token collateral if pool balance in NAT is 0
        // so then we can safely return 0 here, since minting is impossible
        return lotWei != 0 ? collateralWei / lotWei : 0;
    }

    function freeCollateralWei(
        Collateral.Data memory _data,
        Agent.State storage _agent
    )
        internal view
        returns (uint256)
    {
        uint256 lockedCollateral = lockedCollateralWei(_data, _agent);
        (, uint256 freeCollateral) = _data.fullCollateral.trySub(lockedCollateral);
        return freeCollateral;
    }

    // Amount of collateral NOT available for new minting or withdrawal.
    function lockedCollateralWei(
        Collateral.Data memory _data,
        Agent.State storage _agent
    )
        internal view
        returns (uint256)
    {
        (uint256 mintingMinCollateralRatioBIPS, uint256 systemMinCollateralRatioBIPS) =
            mintingMinCollateralRatio(_agent, _data.kind);
        uint256 backedAMG = uint256(_agent.reservedAMG) + uint256(_agent.mintedAMG);
        uint256 mintingCollateral = Conversion.convertAmgToTokenWei(backedAMG, _data.amgToTokenWeiPrice)
            .mulBips(mintingMinCollateralRatioBIPS);
        uint64 redeemingAMG = _data.kind == Collateral.Kind.POOL ? _agent.poolRedeemingAMG : _agent.redeemingAMG;
        uint256 redeemingCollateral = Conversion.convertAmgToTokenWei(redeemingAMG, _data.amgToTokenWeiPrice)
            .mulBips(systemMinCollateralRatioBIPS);
        uint256 announcedWithdrawal =
            _data.kind != Collateral.Kind.POOL ? Agents.withdrawalAnnouncement(_agent, _data.kind).amountWei : 0;
        return mintingCollateral + redeemingCollateral + announcedWithdrawal;
    }

    function mintingLotCollateralWei(
        Collateral.Data memory _data,
        Agent.State storage _agent
    )
        internal view
        returns (uint256)
    {
        AssetManagerState.State storage state = AssetManagerState.get();
        (uint256 minCollateralRatio,) = mintingMinCollateralRatio(_agent, _data.kind);
        return Conversion.convertAmgToTokenWei(state.settings.lotSizeAMG, _data.amgToTokenWeiPrice)
            .mulBips(minCollateralRatio);
    }

    function mintingMinCollateralRatio(
        Agent.State storage _agent,
        Collateral.Kind _kind
    )
        internal view
        returns (uint256 _mintingMinCollateralRatioBIPS, uint256 _systemMinCollateralRatioBIPS)
    {
        AssetManagerState.State storage state = AssetManagerState.get();
        if (_kind == Collateral.Kind.AGENT_POOL) {
            _systemMinCollateralRatioBIPS = state.settings.mintingPoolHoldingsRequiredBIPS;
            _mintingMinCollateralRatioBIPS = _systemMinCollateralRatioBIPS;
        } else if (_kind == Collateral.Kind.POOL) {
            _systemMinCollateralRatioBIPS =
                state.collateralTokens[_agent.poolCollateralIndex].minCollateralRatioBIPS;
            _mintingMinCollateralRatioBIPS =
                Math.max(_agent.minPoolCollateralRatioBIPS, _systemMinCollateralRatioBIPS);
        } else {
            _systemMinCollateralRatioBIPS =
                state.collateralTokens[_agent.class1CollateralIndex].minCollateralRatioBIPS;
            // agent's minCollateralRatioBIPS must be greater than minCollateralRatioBIPS when set, but
            // minCollateralRatioBIPS can change later so we always use the max of both
            _mintingMinCollateralRatioBIPS =
                Math.max(_agent.minClass1CollateralRatioBIPS, _systemMinCollateralRatioBIPS);
        }
    }

    // Used for redemption default payment - calculate all types of collateral at the same rate, so that
    // future redemptions don't get less than this one (unless the price changes).
    // Ignores collateral announced for withdrawal (redemption has priority over withdrawal).
    function maxRedemptionCollateral(
        Collateral.Data memory _data,
        Agent.State storage _agent,
        uint256 _valueAMG
    )
        internal view
        returns (uint256)
    {
        if (_valueAMG == 0) return 0;
        // Assumption is that redemption is NOT a pool self close redemption,
        // otherwise the below formula would not be correct.
        uint64 redeemingAMG = _data.kind == Collateral.Kind.POOL ? _agent.poolRedeemingAMG : _agent.redeemingAMG;
        assert(_valueAMG <= redeemingAMG);
        uint256 totalAMG = uint256(_agent.mintedAMG) + uint256(_agent.reservedAMG) + uint256(redeemingAMG);
        return _data.fullCollateral.mulDiv(_valueAMG, totalAMG); // totalAMG > 0 (guarded by assert)
    }

    // Agent's collateral ratio for single collateral type (BIPS) - used in liquidation.
    // Ignores collateral announced for withdrawal (withdrawals are forbidden during liquidation).
    function collateralRatioBIPS(
        Collateral.Data memory _data,
        Agent.State storage _agent
    )
        internal view
        returns (uint256)
    {
        uint256 totalAMG = uint256(_agent.mintedAMG) + uint256(_agent.reservedAMG) + uint256(_agent.redeemingAMG);
        if (totalAMG == 0) return 1e10;    // nothing minted - ~infinite collateral ratio (but avoid overflows)
        uint256 backingTokenWei = Conversion.convertAmgToTokenWei(totalAMG, _data.amgToTokenWeiPrice);
        return _data.fullCollateral.mulDiv(SafePct.MAX_BIPS, backingTokenWei);
    }
}
