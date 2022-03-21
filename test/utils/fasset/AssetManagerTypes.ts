import { AssetManagerContract, AttestationClientMockInstance } from "../../../typechain-truffle";

export type AssetManagerSettings = Parameters<AssetManagerContract['new']>[0];

// attestation client types
export type Payment = Parameters<AttestationClientMockInstance['provePayment']>[1];
export type BalanceDecreasingTransaction = Parameters<AttestationClientMockInstance['proveBalanceDecreasingTransaction']>[1];
export type ReferencedPaymentNonexistence = Parameters<AttestationClientMockInstance['proveReferencedPaymentNonexistence']>[1];
export type ConfirmedBlockHeightExists = Parameters<AttestationClientMockInstance['proveConfirmedBlockHeightExists']>[1];
