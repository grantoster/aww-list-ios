// Verifies a StoreKit 2 signed transaction (Transaction.jwsRepresentation) entirely offline:
// x5c chain leaf -> intermediate -> trusted Apple root, certificate dates, the ES256 signature,
// then the transaction fields that make it a live Awwbum subscription.
import { BasicConstraintsExtension, X509Certificate } from "./x509";

export interface VerifyOptions {
  roots: X509Certificate[];
  bundleId: string;
  productIds: string[];
  environments: string[];
  now?: Date;
}

export interface Subscription {
  originalTransactionId: string;
  productId: string;
  environment: string;
  expiresDate: number;
}

/** Any reason the transaction doesn't prove an active subscription. The message is for logs/tests only. */
export class NotSubscribed extends Error {}

const MAX_JWS_LENGTH = 16_384;

export async function verifyTransaction(jws: string, opts: VerifyOptions): Promise<Subscription> {
  const now = opts.now ?? new Date();
  if (!jws || jws.length > MAX_JWS_LENGTH) throw new NotSubscribed("missing or oversized transaction");
  const parts = jws.split(".");
  if (parts.length !== 3) throw new NotSubscribed("not a compact JWS");
  const [headerB64, payloadB64, signatureB64] = parts;

  const header = parseJson(base64UrlDecode(headerB64));
  if (header.alg !== "ES256") throw new NotSubscribed("alg must be ES256");
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2 || x5c.length > 3 || !x5c.every((c) => typeof c === "string")) {
    throw new NotSubscribed("bad x5c");
  }

  // Chain: leaf signed by intermediate, intermediate signed by one of our trusted roots.
  // A root sent in x5c[2] is ignored; trust comes only from opts.roots.
  let leaf: X509Certificate, intermediate: X509Certificate;
  try {
    leaf = new X509Certificate(base64Decode(x5c[0]));
    intermediate = new X509Certificate(base64Decode(x5c[1]));
  } catch {
    throw new NotSubscribed("unparseable certificate");
  }
  const root = await findIssuer(intermediate, opts.roots);
  if (!root) throw new NotSubscribed("chain does not end at a trusted root");
  const basic = intermediate.getExtension(BasicConstraintsExtension);
  if (!basic?.ca) throw new NotSubscribed("intermediate is not a CA");
  if (leaf.issuer !== intermediate.subject || !(await signedBy(leaf, intermediate))) {
    throw new NotSubscribed("leaf not signed by intermediate");
  }
  for (const cert of [leaf, intermediate, root]) {
    if (now < cert.notBefore || now > cert.notAfter) throw new NotSubscribed("certificate outside validity dates");
  }

  // JWS signature (raw r||s, 64 bytes for P-256) over "header.payload" with the leaf key.
  const signature = base64UrlDecode(signatureB64);
  if (signature.length !== 64) throw new NotSubscribed("bad signature length");
  let key: CryptoKey;
  try {
    key = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
  } catch {
    throw new NotSubscribed("leaf key is not P-256");
  }
  const signed = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature, signed);
  if (!ok) throw new NotSubscribed("bad signature");

  // Payload: right app, right product, right environment, not expired, not revoked.
  const p = parseJson(base64UrlDecode(payloadB64));
  if (p.bundleId !== opts.bundleId) throw new NotSubscribed("wrong bundleId");
  if (typeof p.productId !== "string" || !opts.productIds.includes(p.productId)) throw new NotSubscribed("wrong productId");
  if (typeof p.environment !== "string" || !opts.environments.includes(p.environment)) {
    throw new NotSubscribed("environment not allowed");
  }
  if (typeof p.expiresDate !== "number" || p.expiresDate <= now.getTime()) throw new NotSubscribed("expired");
  if (p.revocationDate != null) throw new NotSubscribed("revoked");
  const original = p.originalTransactionId;
  if (typeof original !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(original)) {
    throw new NotSubscribed("bad originalTransactionId");
  }
  return { originalTransactionId: original, productId: p.productId, environment: p.environment, expiresDate: p.expiresDate };
}

export function parseRoots(pems: string[]): X509Certificate[] {
  return pems.map((pem) => new X509Certificate(pem));
}

async function findIssuer(cert: X509Certificate, roots: X509Certificate[]): Promise<X509Certificate | undefined> {
  for (const root of roots) {
    if (cert.issuer === root.subject && (await signedBy(cert, root))) return root;
  }
  return undefined;
}

async function signedBy(cert: X509Certificate, issuer: X509Certificate): Promise<boolean> {
  try {
    return await cert.verify({ publicKey: issuer.publicKey, signatureOnly: true });
  } catch {
    return false;
  }
}

function parseJson(bytes: Uint8Array): Record<string, any> {
  try {
    const v = JSON.parse(new TextDecoder().decode(bytes));
    if (v && typeof v === "object" && !Array.isArray(v)) return v;
  } catch {
    /* fall through */
  }
  throw new NotSubscribed("bad JSON in JWS");
}

function base64UrlDecode(s: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new NotSubscribed("bad base64url");
  return base64Decode(s.replace(/-/g, "+").replace(/_/g, "/"));
}

function base64Decode(s: string): Uint8Array {
  try {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    throw new NotSubscribed("bad base64");
  }
}
