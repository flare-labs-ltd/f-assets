import { time } from "@nomicfoundation/hardhat-network-helpers";
import { expectRevert } from "@openzeppelin/test-helpers";
import { BNish, DAYS, MAX_BIPS, toBN, toWei, WEEKS, ZERO_ADDRESS } from "../../../lib/utils/helpers";
import { FAssetInstance, IIAssetManagerInstance } from "../../../typechain-truffle";
import { assertApproximatelyEqual } from "../../utils/approximation";
import { MockChain } from "../../utils/fasset/MockChain";
import { getTestFile, loadFixtureCopyVars } from "../../utils/test-helpers";
import { assertWeb3Equal } from "../../utils/web3assertions";
import { Web3EventDecoder } from "../../utils/Web3EventDecoder";
import { Agent } from "../utils/Agent";
import { AssetContext } from "../utils/AssetContext";
import { CommonContext } from "../utils/CommonContext";
import { Minter } from "../utils/Minter";
import { Redeemer } from "../utils/Redeemer";
import { testChainInfo } from "../utils/TestChainInfo";

contract(`AssetManagerSimulation.sol; ${getTestFile(__filename)}; Asset manager simulations - transfer fees`, async accounts => {
    const governance = accounts[10];
    const agentOwner1 = accounts[20];
    const agentOwner2 = accounts[21];
    const agentOwner3 = accounts[22];
    const userAddress1 = accounts[30];
    const userAddress2 = accounts[31];
    const userAddress3 = accounts[32];
    // addresses on mock underlying chain can be any string, as long as it is unique
    const underlyingAgent1 = "Agent1";
    const underlyingAgent2 = "Agent2";
    const underlyingAgent3 = "Agent3";
    const underlyingUser1 = "Minter1";
    const underlyingUser2 = "Minter2";

    const epochDuration = 1 * WEEKS;

    let commonContext: CommonContext;
    let context: AssetContext;
    let mockChain: MockChain;
    let assetManager: IIAssetManagerInstance;
    let fAsset: FAssetInstance;

    function epochAverage(cumulative: BNish) {
        return toBN(cumulative).divn(epochDuration);
    }

    const UNLIMITED = toBN(1).shln(255);

    async function setFAssetFeesPaidBy(origin: string, feePayer: string, maxFeeAmount: BNish, method: () => Promise<void>,) {
        await fAsset.approve(origin, maxFeeAmount, { from: feePayer });
        await fAsset.setTransferFeesPaidBy(feePayer, { from: origin });
        await method();
        await fAsset.setTransferFeesPaidBy(ZERO_ADDRESS, { from: origin });
        await fAsset.approve(origin, 0, { from: feePayer });
    }

    async function initialize() {
        commonContext = await CommonContext.createTest(governance);
        context = await AssetContext.createTest(commonContext, testChainInfo.btc, {
            testSettings: {
                transferFeeMillionths: 200, // 2 BIPS
                transferFeeClaimFirstEpochStartTs: (await time.latest()) - 20 * epochDuration,
                transferFeeClaimEpochDurationSeconds: epochDuration,
                transferFeeClaimMaxUnexpiredEpochs: 12,
            }
        });
        return { commonContext, context };
    }

    beforeEach(async () => {
        ({ commonContext, context } = await loadFixtureCopyVars(initialize));
        assetManager = context.assetManager;
        fAsset = context.fAsset;
        mockChain = context.chain as MockChain;
    });

    describe("transfer fees charging", () => {
        it("should charge transfer fee and agent can claim", async () => {
            const agent = await Agent.createTest(context, agentOwner1, underlyingAgent1);
            const minter = await Minter.createTest(context, userAddress1, underlyingUser1, context.lotSize().muln(100));
            const redeemer = await Redeemer.create(context, userAddress2, underlyingUser2);
            const agentInfo = await agent.getAgentInfo();
            await agent.depositCollateralsAndMakeAvailable(toWei(1e8), toWei(1e8));
            mockChain.mine(10);
            await context.updateUnderlyingBlock();
            const currentEpoch = await assetManager.currentTransferFeeEpoch();
            const trfSettings = await assetManager.transferFeeSettings();
            // perform minting
            const lots = 3;
            const [minted] = await minter.performMinting(agent.vaultAddress, lots);
            // cannot transfer everything - something must remain to pay the fee
            await expectRevert(minter.transferFAsset(redeemer.address, minted.mintedAmountUBA),
                "balance too low for transfer fee");
            // transfer and check that fee was subtracted
            const transferAmount = context.lotSize().muln(2);
            const transferFee = transferAmount.mul(toBN(trfSettings.transferFeeMillionths)).divn(1e6);
            assertWeb3Equal(transferFee, await context.fAsset.transferFeeAmount(transferAmount));
            const startBalance = await fAsset.balanceOf(minter.address);
            const transfer = await minter.transferFAsset(redeemer.address, transferAmount);
            const endBalance = await fAsset.balanceOf(minter.address);
            assertWeb3Equal(transfer.fee, transferFee);
            assert.isAbove(Number(transferFee), 100);
            assertWeb3Equal(startBalance.sub(endBalance), transferAmount.add(transferFee));
            // at this epoch, claimable amount should be 0, though fees are collected
            const epochData = await assetManager.transferFeeEpochData(currentEpoch);
            const claimableAmount0 = await agent.transferFeeShare(10);
            assertWeb3Equal(epochData.totalFees, transferFee);
            assertWeb3Equal(claimableAmount0, 0);
            // skip 1 epoch and claim
            await time.increase(epochDuration);
            const claimableAmount1 = await agent.transferFeeShare(10);
            assertWeb3Equal(claimableAmount1, transferFee);
            const claimed = await agent.claimTransferFees(agent.ownerWorkAddress, 10);
            const ownerFBalance = await fAsset.balanceOf(agent.ownerWorkAddress);
            const poolFeeShare = transferFee.mul(toBN(agentInfo.poolFeeShareBIPS)).divn(MAX_BIPS);
            const agentFeeShare = transferFee.sub(poolFeeShare);
            assertWeb3Equal(ownerFBalance, agentFeeShare);
            assertWeb3Equal(agentFeeShare, claimed.agentClaimedUBA);
            assertWeb3Equal(poolFeeShare, claimed.poolClaimedUBA);
            const poolFBalance = await fAsset.balanceOf(agentInfo.collateralPool);
            const poolExpected = toBN(minted.poolFeeUBA).add(poolFeeShare);
            assertWeb3Equal(poolFBalance, poolExpected);
        });

        it("transfer fees should not affect mint and redeem", async () => {
            const agent = await Agent.createTest(context, agentOwner1, underlyingAgent1);
            const minter = await Minter.createTest(context, userAddress1, underlyingUser1, context.lotSize().muln(100));
            const redeemer = await Redeemer.create(context, userAddress1, underlyingUser1);
            await agent.depositCollateralsAndMakeAvailable(toWei(1e8), toWei(1e8));
            mockChain.mine(10);
            await context.updateUnderlyingBlock();
            const currentEpoch = await assetManager.currentTransferFeeEpoch();
            // perform minting and redemption
            const lots = 2;
            const [minted] = await minter.performMinting(agent.vaultAddress, lots);
            const [requests] = await redeemer.requestRedemption(lots);
            await agent.performRedemptions(requests);
            // only pool minting fee is minted now
            const agentInfo = await agent.getAgentInfo();
            assertWeb3Equal(agentInfo.mintedUBA, minted.poolFeeUBA);
            // and no fee was charged
            const epochData = await assetManager.transferFeeEpochData(currentEpoch);
            assertWeb3Equal(epochData.totalFees, 0);
        });

        it("other account can pay transfer fee", async () => {
            const agent = await Agent.createTest(context, agentOwner1, underlyingAgent1);
            const minter1 = await Minter.createTest(context, userAddress1, underlyingUser1, context.lotSize().muln(100));
            const minter2 = await Minter.createTest(context, userAddress2, underlyingUser2, context.lotSize().muln(100));
            await agent.depositCollateralsAndMakeAvailable(toWei(1e8), toWei(1e8));
            mockChain.mine(10);
            await context.updateUnderlyingBlock();
            const currentEpoch = await assetManager.currentTransferFeeEpoch();
            // perform mintings
            const lots = 1;
            const [minted1] = await minter1.performMinting(agent.vaultAddress, lots);
            const [minted2] = await minter2.performMinting(agent.vaultAddress, lots);
            // change transfer payer
            await fAsset.setTransferFeesPaidBy(minter2.address, { from: minter1.address });
            // of course the other has to agree
            await expectRevert(minter1.transferFAsset(userAddress3, minted1.mintedAmountUBA),
                "allowance too low for transfer fee");
            // after approval, minter1 should be able to transfer whole amount
            const transferAmount = toBN(minted1.mintedAmountUBA);
            await fAsset.approve(minter1.address, transferAmount.divn(1000), { from: minter2.address });
            assertWeb3Equal(await fAsset.balanceOf(minter1.address), transferAmount);
            const transfer = await minter1.transferFAsset(userAddress3, transferAmount);
            assertWeb3Equal(await fAsset.balanceOf(minter1.address), 0);
            assertWeb3Equal(await fAsset.balanceOf(userAddress3), transferAmount);
            assertWeb3Equal(transfer.value, transferAmount);
            assert.isBelow(Number(transfer.fee), Number(transfer.value) / 100);
            assert.isAbove(Number(transfer.fee), 0);
            const epochData = await assetManager.transferFeeEpochData(currentEpoch);
            assertWeb3Equal(transfer.fee, epochData.totalFees);
            // minter2 has paid the fee
            assertWeb3Equal(await fAsset.balanceOf(minter2.address), toBN(minted2.mintedAmountUBA).sub(toBN(transfer.fee)));
        });

        it("various ways of paying transfer fee", async () => {
            const TokenHolderMock = artifacts.require("TokenHolderMock");
            //
            const agent = await Agent.createTest(context, agentOwner1, underlyingAgent1);
            const minter = await Minter.createTest(context, userAddress1, underlyingUser1, context.lotSize().muln(100));
            await agent.depositCollateralsAndMakeAvailable(toWei(1e8), toWei(1e8));
            mockChain.mine(10);
            await context.updateUnderlyingBlock();
            const trfSettings = await assetManager.transferFeeSettings();
            // settings
            const lotSize = context.lotSize();
            const transferFeeMillionths = await assetManager.transferFeeMillionths();
            const eventDecoder = new Web3EventDecoder({ fAsset: context.fAsset })
            // perform minting
            const lots = 5;
            const [minted] = await minter.performMinting(agent.vaultAddress, lots);
            // transfer enough to a contract
            const holder = await TokenHolderMock.new();
            await minter.transferFAsset(holder.address, lotSize.muln(4));
            // ordinary transfer - fee should be paid by tx.origin
            const res1 = await holder.transferTo(fAsset.address, accounts[50], lotSize, { from: minter.address });
            const transfers1 = eventDecoder.filterEventsFrom(res1, context.fAsset, "Transfer");
            assert.equal(transfers1.length, 2);
            assertWeb3Equal(transfers1[0].args.from, holder.address);
            assertWeb3Equal(transfers1[0].args.to, accounts[50]);
            assertWeb3Equal(transfers1[0].args.value, lotSize);
            assertWeb3Equal(transfers1[1].args.from, minter.address);
            assertWeb3Equal(transfers1[1].args.to, assetManager.address);
            assertWeb3Equal(transfers1[1].args.value, lotSize.mul(transferFeeMillionths).divn(1e6));
            // transferAndPayFee - fee should be paid by the payer (holder contract)
            const res2 = await holder.transferToAndPayFee(fAsset.address, accounts[50], lotSize, { from: minter.address });
            const transfers2 = eventDecoder.filterEventsFrom(res2, context.fAsset, "Transfer");
            assert.equal(transfers2.length, 2);
            assertWeb3Equal(transfers2[0].args.from, holder.address);
            assertWeb3Equal(transfers2[0].args.to, accounts[50]);
            assertWeb3Equal(transfers2[0].args.value, lotSize);
            assertWeb3Equal(transfers2[1].args.from, holder.address);
            assertWeb3Equal(transfers2[1].args.to, assetManager.address);
            assertWeb3Equal(transfers2[1].args.value, lotSize.mul(transferFeeMillionths).divn(1e6));
            // transferSubtractingFee - fee should be paid by the payer (holder contract)
            const res3 = await holder.transferToSubtractingFee(fAsset.address, accounts[50], lotSize, { from: minter.address });
            const transfers3 = eventDecoder.filterEventsFrom(res3, context.fAsset, "Transfer");
            assert.equal(transfers3.length, 2);
            assertWeb3Equal(transfers3[0].args.from, holder.address);
            assertWeb3Equal(transfers3[0].args.to, accounts[50]);
            assertWeb3Equal(transfers3[1].args.from, holder.address);
            assertWeb3Equal(transfers3[1].args.to, assetManager.address);
            assertApproximatelyEqual(transfers2[1].args.value, lotSize.mul(transferFeeMillionths).divn(1e6), "relative", 1e-5);
            assertWeb3Equal(toBN(transfers3[0].args.value).add(toBN(transfers3[1].args.value)), lotSize);
        });
    });

    describe("transfer fee claim epochs", () => {
        it("current epoch should be same as first claimable at start", async () => {
            const currentEpoch = await assetManager.currentTransferFeeEpoch();
            const firstClaimableEpoch = await assetManager.firstClaimableTransferFeeEpoch();
            assertWeb3Equal(currentEpoch, 20);
            assertWeb3Equal(firstClaimableEpoch, 20);
        });

        it("multiple agents split the fees according to average minted amount", async () => {
            const agent1 = await Agent.createTest(context, agentOwner1, underlyingAgent1);
            await agent1.depositCollateralsAndMakeAvailable(toWei(1e8), toWei(1e8));
            const agent2 = await Agent.createTest(context, agentOwner2, underlyingAgent2);
            await agent2.depositCollateralsAndMakeAvailable(toWei(1e8), toWei(1e8));
            const agent3 = await Agent.createTest(context, agentOwner3, underlyingAgent3);  // do-nothing agent, just to test init
            const minter = await Minter.createTest(context, userAddress1, underlyingUser1, context.lotSize().muln(100));
            const redeemer = await Redeemer.create(context, userAddress2, underlyingUser2);
            mockChain.mine(10);
            await context.updateUnderlyingBlock();
            //
            const firstEpoch = Number(await assetManager.currentTransferFeeEpoch());
            const start = await time.latest();
            const trfSettings = await assetManager.transferFeeSettings();
            const epochDuration = Number(trfSettings.epochDuration);
            const lotSize = context.lotSize();
            // do some minting, redeeming and transfers
            const [minted1] = await minter.performMinting(agent1.vaultAddress, 10);
            const [minted2] = await minter.performMinting(agent2.vaultAddress, 30);
            // check
            const poolFees1 = toBN(minted1.poolFeeUBA);
            const poolFees2 = toBN(minted2.poolFeeUBA);
            const poolFeesTotal = poolFees1.add(poolFees2);
            await agent1.checkAgentInfo({ mintedUBA: toBN(lotSize).muln(10).add(poolFees1) });
            await agent2.checkAgentInfo({ mintedUBA: toBN(lotSize).muln(30).add(poolFees2) });
            // console.log(await time.latest() - Number((await firstEpochData).startTs));
            // console.log((await time.latest() - Number((await firstEpochData).startTs)) / epochDuration);
            // give minter enough extra to cover transfer fees (mind that this charges some transfer fees too)
            await setFAssetFeesPaidBy(agent1.ownerWorkAddress, minter.address, UNLIMITED, async () => {
                await agent1.withdrawPoolFees(await agent1.poolFeeBalance(), minter.address);
            });
            //
            await time.increaseTo(start + 0.5 * epochDuration);
            await minter.transferFAsset(redeemer.address, lotSize.muln(30));
            const [rrqs1] = await redeemer.requestRedemption(20);
            await Agent.performRedemptions([agent1, agent2], rrqs1);
            await agent1.checkAgentInfo({ mintedUBA: toBN(lotSize).muln(0).add(poolFees1) });
            await agent2.checkAgentInfo({ mintedUBA: toBN(lotSize).muln(20).add(poolFees2) });
            //
            await time.increaseTo(start + 1.5 * epochDuration);
            await minter.transferFAsset(redeemer.address, lotSize.muln(10));
            const [rrqs2] = await redeemer.requestRedemption(20);
            await Agent.performRedemptions([agent1, agent2], rrqs2);
            await agent1.checkAgentInfo({ mintedUBA: toBN(lotSize).muln(0).add(poolFees1) });
            await agent2.checkAgentInfo({ mintedUBA: toBN(lotSize).muln(0).add(poolFees2) });
            //
            await time.increaseTo(start + 2.5 * epochDuration);
            // check unclaimed epochs
            const { 0: firstUnclaimed1, 1: totalUnclaimed1 } = await assetManager.agentUnclaimedTransferFeeEpochs(agent1.vaultAddress);
            assertWeb3Equal(firstUnclaimed1, 20);
            assertWeb3Equal(totalUnclaimed1, 2);
            const { 0: firstUnclaimed2, 1: totalUnclaimed2 } = await assetManager.agentUnclaimedTransferFeeEpochs(agent2.vaultAddress);
            assertWeb3Equal(firstUnclaimed2, 20);
            assertWeb3Equal(totalUnclaimed2, 2);
            const { 0: firstUnclaimed3, 1: totalUnclaimed3 } = await assetManager.agentUnclaimedTransferFeeEpochs(agent3.vaultAddress);
            assertWeb3Equal(firstUnclaimed3, 20);
            assertWeb3Equal(totalUnclaimed3, 2);
            const totalFeeAgent1 = await assetManager.agentTransferFeeShare(agent1.vaultAddress, 10);
            const totalFeeAgent2 = await assetManager.agentTransferFeeShare(agent2.vaultAddress, 10);
            const totalFeeAgent3 = await assetManager.agentTransferFeeShare(agent3.vaultAddress, 10);
            // we can also do init agents now, it should be a no-op
            await assetManager.initAgentsMintingHistory([agent1.vaultAddress, agent2.vaultAddress]);
            // check unclaimed epochs again - should be equal
            const { 0: firstUnclaimed1a, 1: totalUnclaimed1a } = await assetManager.agentUnclaimedTransferFeeEpochs(agent1.vaultAddress);
            assertWeb3Equal(firstUnclaimed1a, 20);
            assertWeb3Equal(totalUnclaimed1a, 2);
            assertWeb3Equal(totalFeeAgent1, await assetManager.agentTransferFeeShare(agent1.vaultAddress, 10));
            const { 0: firstUnclaimed2a, 1: totalUnclaimed2a } = await assetManager.agentUnclaimedTransferFeeEpochs(agent2.vaultAddress);
            assertWeb3Equal(firstUnclaimed2a, 20);
            assertWeb3Equal(totalUnclaimed2a, 2);
            assertWeb3Equal(totalFeeAgent2, await assetManager.agentTransferFeeShare(agent2.vaultAddress, 10));
            const { 0: firstUnclaimed3a, 1: totalUnclaimed3a } = await assetManager.agentUnclaimedTransferFeeEpochs(agent3.vaultAddress);
            assertWeb3Equal(firstUnclaimed3a, 20);
            assertWeb3Equal(totalUnclaimed3a, 2);
            assertWeb3Equal(totalFeeAgent3, await assetManager.agentTransferFeeShare(agent3.vaultAddress, 10));
            // backing for epoch1: total = 40 lots for 1/2 epoch, 20 lots for 1/2 epoch = 30 lots avg
            //   ag1: 10 lots for 1/2 epoch -> 10 * 1/2 / 30 = 1/6 share
            //   ag2: 30 lots for 1/2 epoch, 20 lots for 1/2 epoch -> (30 * 1/2 + 20 * 1/2) / 30 = 25/30 = 5/6 share
            // backing for epoch2: total = 20 lots for 1/2 epoch = 10 lots avg
            //   ag1: 0
            //   ag2: 20 lots for 1/2 epoch -> 10 / 10 = 25/30 = 1 share
            const ep1agent1 = await assetManager.transferFeeCalculationDataForAgent(agent1.vaultAddress, firstEpoch);
            const ep1agent2 = await assetManager.transferFeeCalculationDataForAgent(agent2.vaultAddress, firstEpoch);
            const ep2agent1 = await assetManager.transferFeeCalculationDataForAgent(agent1.vaultAddress, firstEpoch + 1);
            const ep2agent2 = await assetManager.transferFeeCalculationDataForAgent(agent2.vaultAddress, firstEpoch + 1);
            assertWeb3Equal(ep1agent1.totalCumulativeMinted, ep1agent2.totalCumulativeMinted);
            assertWeb3Equal(ep2agent1.totalCumulativeMinted, ep2agent2.totalCumulativeMinted);
            const ep1TotalAvgNoFee = epochAverage(ep1agent1.totalCumulativeMinted).sub(poolFeesTotal);
            const ep2TotalAvgNoFee = epochAverage(ep2agent1.totalCumulativeMinted).sub(poolFeesTotal);
            assertApproximatelyEqual(ep1TotalAvgNoFee, lotSize.muln(30), 'relative', 1e-3);
            assertApproximatelyEqual(ep2TotalAvgNoFee, lotSize.muln(10), 'relative', 1e-3);
            assertApproximatelyEqual(epochAverage(ep1agent1.cumulativeMinted), ep1TotalAvgNoFee.muln(1).divn(6).add(poolFees1), 'relative', 1e-3);
            assertApproximatelyEqual(epochAverage(ep1agent2.cumulativeMinted), ep1TotalAvgNoFee.muln(5).divn(6).add(poolFees2), 'relative', 1e-3);
            assertApproximatelyEqual(epochAverage(ep2agent1.cumulativeMinted), ep2TotalAvgNoFee.muln(0).add(poolFees1), 'relative', 1e-3);
            assertApproximatelyEqual(epochAverage(ep2agent2.cumulativeMinted), ep2TotalAvgNoFee.muln(1).add(poolFees2), 'relative', 1e-3);
            // fees should be split accordingly
            const fee1agent1 = await assetManager.agentTransferFeeShareForEpoch(agent1.vaultAddress, firstEpoch);
            const fee1agent2 = await assetManager.agentTransferFeeShareForEpoch(agent2.vaultAddress, firstEpoch);
            const fee2agent1 = await assetManager.agentTransferFeeShareForEpoch(agent1.vaultAddress, firstEpoch + 1);
            const fee2agent2 = await assetManager.agentTransferFeeShareForEpoch(agent2.vaultAddress, firstEpoch + 1);
            assertApproximatelyEqual(fee1agent1, toBN(ep1agent1.cumulativeMinted).mul(toBN(ep1agent1.totalFees)).div(toBN(ep1agent1.totalCumulativeMinted)), 'relative', 1e-3);
            assertApproximatelyEqual(fee1agent2, toBN(ep1agent2.cumulativeMinted).mul(toBN(ep1agent2.totalFees)).div(toBN(ep1agent2.totalCumulativeMinted)), 'relative', 1e-3);
            assertApproximatelyEqual(fee2agent1, toBN(ep2agent1.cumulativeMinted).mul(toBN(ep2agent1.totalFees)).div(toBN(ep2agent1.totalCumulativeMinted)), 'relative', 1e-3);
            assertApproximatelyEqual(fee2agent2, toBN(ep2agent2.cumulativeMinted).mul(toBN(ep2agent2.totalFees)).div(toBN(ep2agent2.totalCumulativeMinted)), 'relative', 1e-3);
            // total fees should match
            assertWeb3Equal(totalFeeAgent1, fee1agent1.add(fee2agent1));
            assertWeb3Equal(totalFeeAgent2, fee1agent2.add(fee2agent2));
            assertWeb3Equal(totalFeeAgent3, 0);
            // claimed amounts should match
            const agent1balPre = await fAsset.balanceOf(agent1.ownerWorkAddress);
            const agent1claim = await agent1.claimTransferFees(agent1.ownerWorkAddress, 10);
            const agent1balPost = await fAsset.balanceOf(agent1.ownerWorkAddress);
            assertWeb3Equal(toBN(agent1claim.agentClaimedUBA).add(toBN(agent1claim.poolClaimedUBA)), totalFeeAgent1);
            assertWeb3Equal(agent1balPost.sub(agent1balPre), agent1claim.agentClaimedUBA);
            //
            const agent2balPre = await fAsset.balanceOf(agent2.ownerWorkAddress);
            const agent2claim = await agent2.claimTransferFees(agent2.ownerWorkAddress, 10);
            const agent2balPost = await fAsset.balanceOf(agent2.ownerWorkAddress);
            assertWeb3Equal(toBN(agent2claim.agentClaimedUBA).add(toBN(agent2claim.poolClaimedUBA)), totalFeeAgent2);
            assertWeb3Equal(agent2balPost.sub(agent2balPre), agent2claim.agentClaimedUBA);
        });
    });

    describe("transfer fee settings", () => {
        it("transfer fee share can be updated with scheduled effect", async () => {
            const startTime = await time.latest();
            const startFee = await assetManager.transferFeeMillionths();
            assertWeb3Equal(startFee, 200);
            // update fee to 500 in 100 sec
            await context.assetManagerController.setTransferFeeMillionths([assetManager.address], 500, startTime + 100, { from: governance});
            assertWeb3Equal(await assetManager.transferFeeMillionths(), startFee);
            await time.increase(50);
            assertWeb3Equal(await assetManager.transferFeeMillionths(), startFee);
            await time.increase(50);
            assertWeb3Equal(await assetManager.transferFeeMillionths(), 500);
            // updating is rate-limited
            await expectRevert(context.assetManagerController.setTransferFeeMillionths([assetManager.address], 400, await time.latest() + 200, { from: governance }),
                "too close to previous update");
            // update fee again, to 400
            await time.increase(1 * DAYS);  // skip to avoid too close updates
            await context.assetManagerController.setTransferFeeMillionths([assetManager.address], 400, await time.latest() + 200, { from: governance });
            assertWeb3Equal(await assetManager.transferFeeMillionths(), 500);
            await time.increase(100);
            assertWeb3Equal(await assetManager.transferFeeMillionths(), 500);
            await time.increase(100);
            assertWeb3Equal(await assetManager.transferFeeMillionths(), 400);
            // update in past/now/0 updates immediately
            await time.increase(1 * DAYS);
            await context.assetManagerController.setTransferFeeMillionths([assetManager.address], 300, startTime, { from: governance });
            assertWeb3Equal(await assetManager.transferFeeMillionths(), 300);
            await time.increase(1 * DAYS);
            await context.assetManagerController.setTransferFeeMillionths([assetManager.address], 150, await time.latest() + 1, { from: governance });
            assertWeb3Equal(await assetManager.transferFeeMillionths(), 150);
            await time.increase(1 * DAYS);
            await context.assetManagerController.setTransferFeeMillionths([assetManager.address], 100, 0, { from: governance });
            assertWeb3Equal(await assetManager.transferFeeMillionths(), 100);
        });
    });
});
