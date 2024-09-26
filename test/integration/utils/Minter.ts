import { IBlockChainWallet } from "../../../lib/underlying-chain/interfaces/IBlockChainWallet";
import { EventArgs } from "../../../lib/utils/events/common";
import { filterEvents, requiredEventArgs } from "../../../lib/utils/events/truffle";
import { BN_ZERO, BNish, ZERO_ADDRESS, requireNotNull, sorted, toBN } from "../../../lib/utils/helpers";
import { CollateralReserved } from "../../../typechain-truffle/IIAssetManager";
import { MockChain, MockChainWallet } from "../../utils/fasset/MockChain";
import { AssetContext, AssetContextClient } from "./AssetContext";

export class Minter extends AssetContextClient {
    static deepCopyWithObjectCreate = true;

    constructor(
        context: AssetContext,
        public address: string,
        public underlyingAddress: string,
        public wallet: IBlockChainWallet,
    ) {
        super(context);
    }

    static async createTest(ctx: AssetContext, address: string, underlyingAddress: string, underlyingBalance: BN) {
        if (!(ctx.chain instanceof MockChain)) assert.fail("only for mock chains");
        ctx.chain.mint(underlyingAddress, underlyingBalance);
        const wallet = new MockChainWallet(ctx.chain);
        return Minter.create(ctx, address, underlyingAddress, wallet);
    }

    static async create(ctx: AssetContext, address: string, underlyingAddress: string, wallet: IBlockChainWallet) {
        return new Minter(ctx, address, underlyingAddress, wallet);
    }

    async reserveCollateral(agent: string, lots: BNish, executorAdddress?: string, executorFeeNatWei?: BNish) {
        const agentInfo = await this.assetManager.getAgentInfo(agent);
        const crFee = await this.getCollateralReservationFee(lots);
        const totalNatFee = executorAdddress ? crFee.add(toBN(requireNotNull(executorFeeNatWei, "executor fee required if executor used"))) : crFee;
        const res = await this.assetManager.reserveCollateral(agent, lots, agentInfo.feeBIPS, executorAdddress ?? ZERO_ADDRESS,
            { from: this.address, value: totalNatFee });
        return requiredEventArgs(res, 'CollateralReserved');
    }

    async performMintingPayment(crt: EventArgs<CollateralReserved>) {
        const paymentAmount = crt.valueUBA.add(crt.feeUBA);
        return this.performPayment(crt.paymentAddress, paymentAmount, crt.paymentReference);
    }

    async executeMinting(crt: EventArgs<CollateralReserved>, transactionHash: string) {
        const proof = await this.attestationProvider.provePayment(transactionHash, this.underlyingAddress, crt.paymentAddress);
        const executorAddress = crt.executor !== ZERO_ADDRESS ? crt.executor : this.address;
        const res = await this.assetManager.executeMinting(proof, crt.collateralReservationId, { from: executorAddress });
        return requiredEventArgs(res, 'MintingExecuted');
    }

    async performMinting(agent: string, lots: BNish) {
        const crt = await this.reserveCollateral(agent, lots);
        const txHash = await this.performMintingPayment(crt);
        const minted = await this.executeMinting(crt, txHash);
        return [minted, crt, txHash] as const;
    }

    async getCollateralReservationFee(lots: BNish) {
        return await this.assetManager.collateralReservationFee(lots);
    }

    async performPayment(paymentAddress: string, paymentAmount: BNish, paymentReference: string | null = null) {
        return this.wallet.addTransaction(this.underlyingAddress, paymentAddress, paymentAmount, paymentReference);
    }

    async transferFAsset(target: string, amount: BNish) {
        const res = await this.context.fAsset.transfer(target, amount, { from: this.address });
        const transferEvents = sorted(filterEvents(res, "Transfer"), ev => toBN(ev.args.value), (x, y) => -x.cmp(y));
        assert.isAtLeast(transferEvents.length, 1, "Missing event Transfer");
        return { ...transferEvents[0].args, fee: transferEvents[1]?.args.value };
    }
}
