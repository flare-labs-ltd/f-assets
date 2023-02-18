// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../../utils/lib/SafePct.sol";
import "../../utils/lib/SafeBips.sol";
import "../interface/IWNat.sol";
import "../interface/IAssetManager.sol";
import "../interface/IAgentVault.sol";
import "./CollateralPoolToken.sol";

contract CollateralPool is ReentrancyGuard {

    using SafeMath for uint256;
    using SafePct for uint256;

    uint256 public constant CLAIM_FTSO_REWARDS_INTEREST_BIPS = 3;
    uint256 internal constant MAX_NAT_TO_POOL_TOKEN_RATIO = 1000;

    IAssetManager public immutable assetManager;
    IERC20 public immutable fAsset;
    address public immutable agentVault;
    CollateralPoolToken public poolToken;
    uint16 public enterBuyAssetRateBIPS; // = 1 + premium
    uint64 public enterWithoutFAssetMintDelaySeconds;
    uint256 public exitCRBIPS;
    uint256 public topupCRBIPS;
    uint256 public topupTokenDiscountBIPS;

    mapping(address => uint256) public addressFassetDebt;
    uint256 public totalFassetDebt;

    modifier onlyAssetManager {
        require(msg.sender == address(assetManager), "only asset manager");
        _;
    }

    // IMPLEMENT TOPUP DISCOUNT!
    function enter(uint256 _fassets, bool _enterWithAllFassets) external {
        IWNat wnat = assetManager.getWNat();
        uint256 poolBalanceNat = wnat.balanceOf(address(this));
        // fassetBalance are liquid fassets + debt fassets
        uint256 fassetBalance = fAsset.balanceOf(address(this));
        uint256 poolTokenSupply = poolToken.totalSupply();
        require(poolTokenSupply <= poolBalanceNat * MAX_NAT_TO_POOL_TOKEN_RATIO, "nat balance too low");
        // if user immediately withdraws the below liquid tokens he provably
        // gets back his liquidFassets and <= collateral than msg.value
        uint256 fassets = poolBalanceNat == 0 ?
            0 : fassetBalance.mulDiv(msg.value, poolBalanceNat);
        uint256 liquidFassets = _enterWithAllFassets ?
            fassets : min(_fassets, fassets);
        uint256 debtFassets = _enterWithAllFassets ?
            0 : fassets - liquidFassets;
        uint256 liquidTokens = fassetBalance == 0 ?
            msg.value : poolTokenSupply.mulDiv(liquidFassets, fassetBalance);
        require(liquidTokens > 0, "paid collaterall too low");
        uint256 debtTokens = fassetBalance == 0 ?
            0 : poolTokenSupply.mulDiv(debtFassets, fassetBalance);
        // transfer calculated assets
        if (liquidFassets > 0) {
            require(fAsset.allowance(msg.sender, address(this)) >= liquidFassets,
                "f-asset allowance too small");
            fAsset.transferFrom(msg.sender, address(this), liquidFassets);
        }
        wnat.deposit{value: msg.value}();
        poolToken.transfer(msg.sender, debtTokens + liquidTokens);
        poolToken.lock(msg.sender, debtTokens);
    }

    function exit(uint256 _tokenShare) external {
        require(_tokenShare > 0, "token share is zero");
        IWNat wnat = assetManager.getWNat();
        uint256 poolBalanceNat = wnat.balanceOf(address(this));
        uint256 poolTokenSupply = poolToken.totalSupply();
        uint256 fassetSupply = fAsset.totalSupply();
        // poolTokenSupply >= _tokenShare > 0
        uint256 natShare = SafePct.mulDiv(_tokenShare, poolBalanceNat, poolTokenSupply);
        require(natShare > 0, "amount of supplied tokens is too low");
        // checking whether the new collateral ratio is above exitCR
        uint256 updatedPoolBalanceNat = poolBalanceNat.sub(natShare);
        (uint256 assetPriceMul, uint256 assetPriceDiv) = assetManager.assetPriceNatWei();
        uint256 lhs = updatedPoolBalanceNat.mul(assetPriceDiv);
        uint256 rhs = fassetSupply.mul(assetPriceMul);
        require(lhs >= SafeBips.mulBips(rhs, exitCRBIPS), "collateral ratio falls below exitCR");
        // execute wnat and fasset transfer
        wnat.transfer(msg.sender, natShare);
        uint256 fassetBalance = fAsset.balanceOf(address(this));
        uint256 fassetShare = SafePct.mulDiv(_tokenShare, fassetBalance, poolTokenSupply);
        if (fassetShare > 0) {
            fAsset.transfer(msg.sender, fassetShare);
        }
        poolToken.burn(msg.sender, _tokenShare); // checks that msg.sender has sufficient liquid tokenShare
    }

    // requires the amount of fassets that doesn't lower pool CR
    function selfCloseExit(
        bool _getAgentCollateral, uint256 _tokenShare,
        string memory _redeemerUnderlyingAddressString
    ) public {
        require(_tokenShare > 0, "token share is zero");
        IWNat wnat = assetManager.getWNat();
        uint256 poolBalanceNat = wnat.balanceOf(address(this));
        uint256 poolTokenSupply = poolToken.totalSupply();
        uint256 fassetSupply = fAsset.totalSupply();
        uint256 fassetBalance = fAsset.balanceOf(address(this));
        // poolTokenSupply >= _tokenShare > 0
        uint256 natShare = SafePct.mulDiv(_tokenShare, poolBalanceNat, poolTokenSupply);
        require(natShare > 0, "amount of supplied tokens is too low");
        uint256 fassetShare = SafePct.mulDiv(_tokenShare, fassetBalance, poolTokenSupply);
        // calculate msg.sender's additionally required fassets
        uint256 updatedPoolBalanceNat = poolBalanceNat.sub(natShare);
        uint256 updatedFassetSupply = fassetSupply.sub(fassetShare);
        uint256 exemptionFassets = SafePct.mulDiv(fassetBalance, updatedPoolBalanceNat, poolBalanceNat);
        uint256 additionallyRequiredFassets = (exemptionFassets <= updatedFassetSupply) ?
            updatedFassetSupply - exemptionFassets : 0;
        if (additionallyRequiredFassets > 0) {
            require(fAsset.allowance(msg.sender, address(this)) >= additionallyRequiredFassets,
                "f-asset allowance too small");
            fAsset.transferFrom(msg.sender, address(this), additionallyRequiredFassets);
        }
        wnat.transfer(msg.sender, natShare);
        poolToken.burn(msg.sender, _tokenShare);
        uint256 redeemedFassets = fassetShare + additionallyRequiredFassets;
        if (redeemedFassets > 0) {
            uint256 lotSizeAMG = assetManager.getLotSizeAMG();
            uint256 lotsToRedeem = redeemedFassets / lotSizeAMG;
            if (lotsToRedeem == 0 || _getAgentCollateral) {
                assetManager.redeemChosenAgentCollateral(
                    agentVault, redeemedFassets, msg.sender);
            } else {
                assetManager.redeemChosenAgentUnderlying(
                    agentVault, redeemedFassets, _redeemerUnderlyingAddressString);
            }
        }
    }

    // helper function for self-close exits paid with agent's collateral
    function selfCloseExitPaidWithCollateral(uint256 _tokenShare) external {
        selfCloseExit(true, _tokenShare, "");
    }

    function _enterWithFassets() private {
        IWNat wnat = assetManager.getWNat();
        uint256 poolBalanceNat = wnat.balanceOf(address(this));
        uint256 poolTokenSupply = poolToken.totalSupply();
        uint256 fassetBalance = fAsset.balanceOf(address(this));
        require(poolTokenSupply <= poolBalanceNat * MAX_NAT_TO_POOL_TOKEN_RATIO, "nat balance too low");
        // If poolBalanceNat=0 then poolTokenSupply=0 due to require above.
        // So the entering staker is the only one and he can take all fassets, if there are any
        // (anyway, while such situation could theoretically happen due to agent slashing, it is very unlikely).
        // TODO: check if it is possible (can agent slashing ever go to 0?)
        uint256 fassetShare = poolBalanceNat > 0 ?
            SafePct.mulDiv(fassetBalance, msg.value, poolBalanceNat) : 0;
        if (fassetShare > 0) {
            require(fAsset.allowance(msg.sender, address(this)) >= fassetShare,
                "f-asset allowance too small");
            fAsset.transferFrom(msg.sender, address(this), fassetShare);
        }
        // if poolBalanceNat=0 then also poolTokenSupply=0 due to require above and we use ratio 1
        uint256 tokenShare = _collateralToTokenShare(msg.value);
        poolToken.mint(msg.sender, tokenShare);
    }

    function _enterWithoutFassets() private {
        IWNat wnat = assetManager.getWNat();
        uint256 poolBalanceNat = wnat.balanceOf(address(this));
        uint256 poolTokenSupply = poolToken.totalSupply();
        uint256 fassetBalance = fAsset.balanceOf(address(this));
        require(poolTokenSupply <= poolBalanceNat * MAX_NAT_TO_POOL_TOKEN_RATIO, "nat balance too low");
        (uint256 assetPriceMul, uint256 assetPriceDiv) = assetManager.assetPriceNatWei();
        uint256 pricePremiumMul = SafeBips.mulBips(assetPriceMul, enterBuyAssetRateBIPS);
        uint256 poolBalanceNatWithAssets = poolBalanceNat +
            SafePct.mulDiv(fassetBalance, pricePremiumMul, assetPriceDiv);
        // This condition prevents division by 0, since poolBalanceNatWithAssets >= poolBalanceNat.
        // Conversely, if poolBalanceNat=0 then poolTokenSupply=0 due to require above and we mint tokens at ratio 1.
        // In this case the entering staker is the only one and he can take all fassets, if there are any
        // (anyway, while such situation could theoretically happen due to agent slashing, it is very unlikely).
        uint256 tokenShare = poolBalanceNat > 0 ?
            SafePct.mulDiv(poolTokenSupply, msg.value, poolBalanceNatWithAssets) : msg.value;
        uint256 mintAt = block.timestamp + enterWithoutFAssetMintDelaySeconds;
        poolToken.mintDelayed(msg.sender, tokenShare, mintAt);
    }

    // alternative to _enterWithoutFassets
    function _enterWithoutFassets2() private {
        IWNat wnat = assetManager.getWNat();
        uint256 poolBalanceNat = wnat.balanceOf(address(this));
        uint256 poolTokenSupply = poolToken.totalSupply();
        uint256 fassetBalance = fAsset.balanceOf(address(this));
        require(poolTokenSupply <= poolBalanceNat * MAX_NAT_TO_POOL_TOKEN_RATIO, "nat balance too low");
        (uint256 assetPriceMul, uint256 assetPriceDiv) = assetManager.assetPriceNatWei();
        uint256 assetPriceMulPremium = SafeBips.mulBips(assetPriceMul, enterBuyAssetRateBIPS);
        uint256 requiredFassets = msg.value.mul(fassetBalance).mul(assetPriceDiv).div(
            assetPriceMulPremium.mul(fassetBalance).add(assetPriceDiv));
        uint256 requiredCollateral = msg.value.sub(
            SafePct.mulDiv(requiredFassets, assetPriceMulPremium, assetPriceDiv));
        uint256 tokenShare = _collateralToTokenShare(requiredCollateral);
        poolToken.mint(msg.sender, tokenShare);
    }

    function _collateralToTokenShare(uint256 _collateral) private view returns (uint256) {
        IWNat wnat = assetManager.getWNat();
        uint256 poolBalanceNat = wnat.balanceOf(address(this));
        if (poolBalanceNat == 0) return _collateral;
        uint256 poolTokenSupply = poolToken.totalSupply();
        uint256 fassetSupply = fAsset.totalSupply();
        (uint256 assetPriceMul, uint256 assetPriceDiv) = assetManager.assetPriceNatWei();
        // calculate amount of nat at topup price and nat at normal price
        uint256 lhs = assetPriceDiv * poolBalanceNat;
        uint256 rhs = assetPriceMul * fassetSupply;
        uint256 topupAssetPriceMul = SafeBips.mulBips(assetPriceMul, topupCRBIPS);
        uint256 natRequiredToTopup = (lhs < SafeBips.mulBips(rhs, topupCRBIPS)) ?
            SafePct.mulDiv(fassetSupply, topupAssetPriceMul, assetPriceDiv) - poolBalanceNat : 0;
        uint256 collateralAtTopupPrice = (_collateral < natRequiredToTopup) ?
            _collateral : natRequiredToTopup;
        uint256 collateralAtNormalPrice = (collateralAtTopupPrice < _collateral) ?
            _collateral - collateralAtTopupPrice : 0;
        uint256 tokenShareAtTopupPrice = SafePct.mulDiv(poolTokenSupply, collateralAtTopupPrice,
            SafeBips.mulBips(poolBalanceNat, topupTokenDiscountBIPS));
        uint256 tokenShareAtNormalPrice = SafePct.mulDiv(poolTokenSupply, collateralAtNormalPrice,
            poolBalanceNat);
        return tokenShareAtTopupPrice + tokenShareAtNormalPrice;
    }

    // used by AssetManager to handle liquidation
    function payout(address _recipient, uint256 _amount)
        external
        onlyAssetManager
        nonReentrant
    {
        IWNat wnat = assetManager.getWNat();
        wnat.transfer(_recipient, _amount);
    }

    ////////////////////////////////////////////////////////////////////////////////////
    // Delegation of the pool's collateral

    // implement onlyAdmin modifier
    function delegateCollateral(
        address[] memory _to, uint256[] memory _bips
    ) external {
        IVPToken wnat = IVPToken(assetManager.getWNat());
        wnat.batchDelegate(_to, _bips);
    }

    function claimFtsoRewards(
        IFtsoRewardManager _ftsoRewardManager, uint256 _lastRewardEpoch
    ) external nonReentrant {
        uint256 ftsoRewards = _ftsoRewardManager.claim(
            address(this), payable(address(this)), _lastRewardEpoch, false
        );
        uint256 callerReward = SafeBips.mulBips(
            ftsoRewards, CLAIM_FTSO_REWARDS_INTEREST_BIPS);
        if (callerReward > 0) {
            /* solhint-disable avoid-low-level-calls */
            //slither-disable-next-line arbitrary-send-eth
            (bool success, ) = msg.sender.call{value: callerReward}("");
            /* solhint-enable avoid-low-level-calls */
            require(success, "transfer failed");
        }
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a <= b ? a : b;
    }

}
