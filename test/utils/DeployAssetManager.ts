import { constants } from "@openzeppelin/test-helpers";
import { getTestFile } from "flare-smart-contracts/test/utils/constants";
import { WNatInstance, AssetManagerContract } from "../../typechain-truffle";

export type AssetManagerSettings = Parameters<AssetManagerContract['new']>[0];

// TODO: fix parameters
export async function deployAssetManager(assetManagerControllerAddress: string, settings: AssetManagerSettings) {
    // libraries without dependencies
    const AssetManager = await linkAssetManager();
    //return AssetManagerContract.new()
    const FAsset = artifacts.require('FAsset');
    const fAsset = await FAsset.new("", "", "", "");
    const assetManager = await AssetManager.new(settings, fAsset.address, "");
    await fAsset.setAssetManager(assetManager.address);
    return [assetManager, fAsset];
}

export async function linkAssetManager() {
    const Agents = await artifacts.require('Agents' as any).new();
    const AllowedPaymentAnnouncement = await artifacts.require('AllowedPaymentAnnouncement' as any).new();
    const AvailableAgents = await artifacts.require('AvailableAgents' as any).new();
    const CollateralReservations = await artifacts.require('CollateralReservations' as any).new();
    const Liquidation = await artifacts.require('Liquidation' as any).new();
    const Minting = await artifacts.require('Minting' as any).new();
    const Redemption = await artifacts.require('Redemption' as any).new();
    // IllegalPaymentChallenge
    const IllegalPaymentChallengeLibrary = artifacts.require('IllegalPaymentChallenge' as any);
    IllegalPaymentChallengeLibrary.link('Liquidation', Liquidation.address);
    const IllegalPaymentChallenge = await IllegalPaymentChallengeLibrary.new();
    // UnderlyingFreeBalance
    const UnderlyingFreeBalanceLibrary = artifacts.require('UnderlyingFreeBalance' as any);
    UnderlyingFreeBalanceLibrary.link('Liquidation', Liquidation.address);
    const UnderlyingFreeBalance = await UnderlyingFreeBalanceLibrary.new();
    // AssetManagerContract
    const AssetManager = artifacts.require('AssetManager');
    AssetManager.link('Agents', Agents.address);
    AssetManager.link('AllowedPaymentAnnouncement', AllowedPaymentAnnouncement.address);
    AssetManager.link('AvailableAgents', AvailableAgents.address);
    AssetManager.link('CollateralReservations', CollateralReservations.address);
    AssetManager.link('Liquidation', Liquidation.address);
    AssetManager.link('Minting', Minting.address);
    AssetManager.link('Redemption', Redemption.address);
    AssetManager.link('IllegalPaymentChallenge', IllegalPaymentChallenge.address);
    AssetManager.link('UnderlyingFreeBalance', UnderlyingFreeBalance.address);
    return AssetManager;
}
