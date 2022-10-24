import { expectRevert, time } from "@openzeppelin/test-helpers";
import { AssetManagerInstance, AttestationClientSCInstance, FAssetInstance, FtsoMockInstance, FtsoRegistryMockInstance, StateConnectorMockInstance, WNatInstance } from "../../../../typechain-truffle";
import { TestChainInfo, testChainInfo } from "../../../integration/utils/TestChainInfo";
import { findRequiredEvent } from "../../../../lib/utils/events/truffle";
import { AssetManagerSettings } from "../../../../lib/fasset/AssetManagerTypes";
import { AttestationHelper } from "../../../../lib/underlying-chain/AttestationHelper";
import { newAssetManager } from "../../../utils/fasset/DeployAssetManager";
import { MockChain, MockChainWallet } from "../../../utils/fasset/MockChain";
import { MockStateConnectorClient } from "../../../utils/fasset/MockStateConnectorClient";
import { PaymentReference } from "../../../../lib/fasset/PaymentReference";
import { randomAddress, toBNExp } from "../../../../lib/utils/helpers";
import { getTestFile } from "../../../utils/test-helpers";
import { setDefaultVPContract } from "../../../utils/token-test-helpers";
import { SourceId } from "../../../../lib/verification/sources/sources";
import { createTestSettings } from "../test-settings";

const AgentVault = artifacts.require('AgentVault');
const AttestationClient = artifacts.require('AttestationClientSC');
const WNat = artifacts.require('WNat');
const FtsoMock = artifacts.require('FtsoMock');
const FtsoRegistryMock = artifacts.require('FtsoRegistryMock');
const StateConnector = artifacts.require('StateConnectorMock');
const AgentVaultFactory = artifacts.require('AgentVaultFactory');

contract(`TransactionAttestation.sol; ${getTestFile(__filename)}; Transaction attestation basic tests`, async accounts => {
    const governance = accounts[10];
    let assetManagerController = accounts[11];
    let attestationClient: AttestationClientSCInstance;
    let assetManager: AssetManagerInstance;
    let fAsset: FAssetInstance;
    let wnat: WNatInstance;
    let ftsoRegistry: FtsoRegistryMockInstance;
    let natFtso: FtsoMockInstance;
    let assetFtso: FtsoMockInstance;
    let settings: AssetManagerSettings;
    let chain: MockChain;
    let chainInfo: TestChainInfo;
    let wallet: MockChainWallet;
    let stateConnectorClient: MockStateConnectorClient;
    let attestationProvider: AttestationHelper;
    let stateConnector: StateConnectorMockInstance;

    // addresses
    const agentOwner1 = accounts[20];
    const underlyingAgent1 = "Agent1";  // addresses on mock underlying chain can be any string, as long as it is unique
  
    async function createAgent(chain: MockChain, owner: string, underlyingAddress: string) {
        // mint some funds on underlying address (just enough to make EOA proof)
        chain.mint(underlyingAddress, 10001);
        // create and prove transaction from underlyingAddress
        const txHash = await wallet.addTransaction(underlyingAddress, underlyingAddress, 1, PaymentReference.addressOwnership(owner), { maxFee: 100 });
        const proof = await attestationProvider.provePayment(txHash, underlyingAddress, underlyingAddress);
        await assetManager.proveUnderlyingAddressEOA(proof, { from: owner });
        // create agent
        const response = await assetManager.createAgent(underlyingAddress, { from: owner });
        // extract agent vault address from AgentCreated event
        const event = findRequiredEvent(response, 'AgentCreated');
        const agentVaultAddress = event.args.agentVault;
        // get vault contract at this address
        return await AgentVault.at(agentVaultAddress);
    }

    beforeEach(async () => {
        // create state connector
        stateConnector = await StateConnector.new();
        // create agent vault factory
        const agentVaultFactory = await AgentVaultFactory.new();
        // create atetstation client
        attestationClient = await AttestationClient.new(stateConnector.address);
        // create mock chain attestation provider
        chain = new MockChain(await time.latest());
        chainInfo = testChainInfo.eth;
        chain.secondsPerBlock = chainInfo.blockTime;
        wallet = new MockChainWallet(chain);
        const chainId: SourceId = 1;
        stateConnectorClient = new MockStateConnectorClient(stateConnector, { [chainId]: chain }, 'auto');
        attestationProvider = new AttestationHelper(stateConnectorClient, chain, chainId);
        // create WNat token
        wnat = await WNat.new(governance, "NetworkNative", "NAT");
        await setDefaultVPContract(wnat, governance);
        // create FTSOs for nat and asset and set some price
        natFtso = await FtsoMock.new("NAT");
        await natFtso.setCurrentPrice(toBNExp(1.12, 5), 0);
        assetFtso = await FtsoMock.new("ETH");
        await assetFtso.setCurrentPrice(toBNExp(3521, 5), 0);
        // create ftso registry
        ftsoRegistry = await FtsoRegistryMock.new();
        await ftsoRegistry.addFtso(natFtso.address);
        await ftsoRegistry.addFtso(assetFtso.address);
        // create asset manager
        settings = createTestSettings(agentVaultFactory, attestationClient, wnat, ftsoRegistry);
        [assetManager, fAsset] = await newAssetManager(governance, assetManagerController, "Ethereum", "ETH", 18, settings);
    });

    it("should not verify payment - legal payment not proved", async () => {
        const chainId: SourceId = 2;
        stateConnectorClient = new MockStateConnectorClient(stateConnector, { [chainId]: chain }, 'auto');
        attestationProvider = new AttestationHelper(stateConnectorClient, chain, chainId);
        chain.mint(underlyingAgent1, 10001);
        const txHash = await wallet.addTransaction(underlyingAgent1, underlyingAgent1, 1, PaymentReference.addressOwnership(agentOwner1), { maxFee: 100 });
        const proof = await attestationProvider.provePayment(txHash, underlyingAgent1, underlyingAgent1);
        await expectRevert(assetManager.proveUnderlyingAddressEOA(proof, { from: agentOwner1 }), "legal payment not proved")
    });

    it("should not succeed challenging illegal payment - transaction not proved", async() => {
        const agentVault = await createAgent(chain, agentOwner1, underlyingAgent1);
        let txHash = await wallet.addTransaction(underlyingAgent1, randomAddress(), 1, PaymentReference.redemption(0));
        const chainId: SourceId = 2;
        stateConnectorClient = new MockStateConnectorClient(stateConnector, { [chainId]: chain }, 'auto');
        attestationProvider = new AttestationHelper(stateConnectorClient, chain, chainId);
        let proof = await attestationProvider.proveBalanceDecreasingTransaction(txHash, underlyingAgent1);
        let res = assetManager.illegalPaymentChallenge(proof, agentVault.address);
        await expectRevert(res, 'transaction not proved');
    });

    it("should not update current block - block height not proved", async() => {
        await createAgent(chain, agentOwner1, underlyingAgent1);
        const chainId: SourceId = 2;
        stateConnectorClient = new MockStateConnectorClient(stateConnector, { [chainId]: chain }, 'auto');
        attestationProvider = new AttestationHelper(stateConnectorClient, chain, chainId);
        const proof = await attestationProvider.proveConfirmedBlockHeightExists();
        let res = assetManager.updateCurrentBlock(proof);
        await expectRevert(res, "block height not proved")
    });

});
