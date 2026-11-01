// Test PKI that mirrors Apple's StoreKit chain shape: P-384 root -> P-384 intermediate (CA) -> P-256 leaf,
// plus a signer for ES256 compact JWS transactions.
import { BasicConstraintsExtension, X509Certificate, X509CertificateGenerator } from "../src/x509";

export const NOW = new Date("2026-11-15T12:00:00Z");
const DAY = 86_400_000;

type Keys = CryptoKeyPair;
const ecdsa = (namedCurve: string) =>
  crypto.subtle.generateKey({ name: "ECDSA", namedCurve }, true, ["sign", "verify"]) as Promise<Keys>;

export interface Chain {
  root: X509Certificate;
  rootKeys: Keys;
  intermediate: X509Certificate;
  intermediateKeys: Keys;
  leaf: X509Certificate;
  leafKeys: Keys;
}

export async function makeChain(opts: { leafNotAfter?: Date; intermediateIsCA?: boolean; rootName?: string } = {}): Promise<Chain> {
  const rootKeys = await ecdsa("P-384");
  const root = await X509CertificateGenerator.createSelfSigned({
    name: `CN=${opts.rootName ?? "Test Root CA"}, O=Test`,
    keys: rootKeys,
    notBefore: new Date("2026-01-01T00:00:00Z"),
    notAfter: new Date("2036-01-01T00:00:00Z"),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    extensions: [new BasicConstraintsExtension(true, undefined, true)],
  });
  const intermediateKeys = await ecdsa("P-384");
  const intermediate = await X509CertificateGenerator.create({
    subject: "CN=Test Intermediate, O=Test",
    issuer: root.subject,
    publicKey: intermediateKeys.publicKey,
    signingKey: rootKeys.privateKey,
    notBefore: new Date("2026-01-01T00:00:00Z"),
    notAfter: new Date("2031-01-01T00:00:00Z"),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
    extensions: opts.intermediateIsCA === false ? [] : [new BasicConstraintsExtension(true, 0, true)],
  });
  const leafKeys = await ecdsa("P-256");
  const leaf = await X509CertificateGenerator.create({
    subject: "CN=Test StoreKit Signing, O=Test",
    issuer: intermediate.subject,
    publicKey: leafKeys.publicKey,
    signingKey: intermediateKeys.privateKey,
    notBefore: new Date("2026-06-01T00:00:00Z"),
    notAfter: opts.leafNotAfter ?? new Date("2027-06-01T00:00:00Z"),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-384" },
  });
  return { root, rootKeys, intermediate, intermediateKeys, leaf, leafKeys };
}

export function transaction(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    transactionId: "2000000999999999",
    originalTransactionId: "2000000123456789",
    bundleId: "com.grantoster.awwlist",
    productId: "com.grantoster.awwlist.plus.monthly",
    purchaseDate: NOW.getTime() - 5 * DAY,
    expiresDate: NOW.getTime() + 25 * DAY,
    type: "Auto-Renewable Subscription",
    environment: "Sandbox",
    signedDate: NOW.getTime() - 5 * DAY,
    ...overrides,
  };
}

export async function signTransaction(
  chain: Chain,
  payload: Record<string, unknown> = transaction(),
  header: Record<string, unknown> = {},
  signingKey: CryptoKey = chain.leafKeys.privateKey,
): Promise<string> {
  const h = {
    alg: "ES256",
    x5c: [chain.leaf, chain.intermediate, chain.root].map((c) => b64(new Uint8Array(c.rawData))),
    ...header,
  };
  const input = `${b64url(utf8(JSON.stringify(h)))}.${b64url(utf8(JSON.stringify(payload)))}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signingKey, utf8(input));
  return `${input}.${b64url(new Uint8Array(sig))}`;
}

export function utf8(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

export function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export function b64url(bytes: Uint8Array): string {
  return b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A tiny fake "JPEG": correct magic bytes, then filler. */
export function fakeJpeg(size = 600): string {
  const bytes = new Uint8Array(size);
  bytes.set([0xff, 0xd8, 0xff, 0xe0]);
  for (let i = 4; i < size; i++) bytes[i] = i % 251;
  return b64(bytes);
}
