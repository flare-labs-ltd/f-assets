import { IFtsoContract, IFtsoInstance, IFtsoRegistryInstance } from "../../typechain-truffle";
import { AssetManagerSettings } from "../fasset/AssetManagerTypes";
import { amgToTokenWeiPrice } from "../fasset/Conversions";
import { BN_ZERO, BNish, minBN, toBN } from "../utils/helpers";

const IFtso = artifacts.require("flare-smart-contracts/contracts/userInterfaces/IFtso.sol:IFtso" as any) as any as IFtsoContract;

export class TokenPrice {
    constructor(
        public readonly price: BN,
        public readonly timestamp: BN,
        public readonly decimals: BN
    ) {
    }

    fresh(relativeTo: TokenPrice, maxAge: BN) {
        return this.timestamp.add(maxAge).gte(relativeTo.timestamp);
    }

    toNumber() {
        return Number(this.price) * (10 ** -Number(this.decimals));
    }

    toFixed(displayDecimals: number = 3) {
        return this.toNumber().toFixed(displayDecimals);
    }

    toString() {
        return this.toNumber().toFixed(3);
    }

    amgToTokenWei(settings: AssetManagerSettings, tokenDecimals: BNish, assetUSD: TokenPrice) {
        return amgToTokenWeiPrice(settings, tokenDecimals, this.price, this.decimals, assetUSD.price, assetUSD.decimals);
    }

    static fromFraction(multiplier: BN, divisor: BN, timestamp: BN, decimals: BNish) {
        decimals = toBN(decimals);
        const price = multiplier.isZero() ? BN_ZERO : multiplier.mul(toBN(10).pow(decimals)).div(divisor);
        return new TokenPrice(price, timestamp, decimals);
    }

    priceInToken(tokenPrice: TokenPrice, decimals: BNish) {
        decimals = toBN(decimals);
        const multiplier = toBN(10).pow(decimals.add(tokenPrice.decimals).sub(this.decimals));
        const price = this.price.mul(multiplier).div(tokenPrice.price);
        const timestamp = minBN(this.timestamp, tokenPrice.timestamp);
        return new TokenPrice(price, timestamp, decimals);
    }

    static async bySymbol(ftsoRegistry: IFtsoRegistryInstance, tokenSymbol: string): Promise<TokenPrice> {
        const ftsoAddress = await ftsoRegistry.getFtsoBySymbol(tokenSymbol);
        const ftso = await IFtso.at(ftsoAddress);
        return await TokenPrice.forFtso(ftso);
    }

    static async forFtso(ftso: IFtsoInstance): Promise<TokenPrice> {
        const { 0: price, 1: timestamp, 2: decimals } = await ftso.getCurrentPriceWithDecimals();
        return new TokenPrice(toBN(price), toBN(timestamp), toBN(decimals));
    }

    static async forFtsoTrusted(ftso: IFtsoInstance, maxAge: BN, fallbackPrice: TokenPrice): Promise<TokenPrice> {
        const { 0: price, 1: timestamp, 2: decimals } = await ftso.getCurrentPriceWithDecimalsFromTrustedProviders();
        const trustedPrice = new TokenPrice(toBN(price), toBN(timestamp), toBN(decimals));
        return trustedPrice.fresh(fallbackPrice, maxAge) ? trustedPrice : fallbackPrice;
    }
}