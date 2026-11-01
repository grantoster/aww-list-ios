import { beforeAll, describe, expect, it } from "vitest";
import { X509Certificate } from "../src/x509";
import { APPLE_ROOT_CA_G3_PEM } from "../src/appleRoot";
import { NotSubscribed, type VerifyOptions, verifyTransaction } from "../src/verify";
import { type Chain, NOW, b64url, makeChain, signTransaction, transaction, utf8 } from "./helpers";

let chain: Chain;
let opts: VerifyOptions;

beforeAll(async () => {
  chain = await makeChain();
  opts = {
    roots: [chain.root],
    bundleId: "com.grantoster.awwlist",
    productIds: ["com.grantoster.awwlist.plus.monthly", "com.grantoster.awwlist.plus.yearly"],
    environments: ["Production", "Sandbox"],
    now: NOW,
  };
});

const rejects = (jws: string, o: Partial<VerifyOptions> = {}) =>
  expect(verifyTransaction(jws, { ...opts, ...o })).rejects.toBeInstanceOf(NotSubscribed);

describe("verifyTransaction", () => {
  it("accepts a valid, current subscription", async () => {
    const sub = await verifyTransaction(await signTransaction(chain), opts);
    expect(sub).toEqual({
      originalTransactionId: "2000000123456789",
      productId: "com.grantoster.awwlist.plus.monthly",
      environment: "Sandbox",
      expiresDate: NOW.getTime() + 25 * 86_400_000,
    });
  });

  it("accepts the yearly product too", async () => {
    const jws = await signTransaction(chain, transaction({ productId: "com.grantoster.awwlist.plus.yearly" }));
    await expect(verifyTransaction(jws, opts)).resolves.toMatchObject({ productId: "com.grantoster.awwlist.plus.yearly" });
  });

  it("rejects an expired subscription", async () => {
    await rejects(await signTransaction(chain, transaction({ expiresDate: NOW.getTime() - 1 })));
  });

  it("rejects a missing expiresDate", async () => {
    await rejects(await signTransaction(chain, transaction({ expiresDate: undefined })));
  });

  it("rejects the wrong bundle id", async () => {
    await rejects(await signTransaction(chain, transaction({ bundleId: "com.example.other" })));
  });

  it("rejects the wrong product", async () => {
    await rejects(await signTransaction(chain, transaction({ productId: "com.grantoster.awwlist.tip" })));
  });

  it("rejects a revoked transaction", async () => {
    await rejects(await signTransaction(chain, transaction({ revocationDate: NOW.getTime() - 1000, revocationReason: 0 })));
  });

  it("rejects an environment that isn't allowed", async () => {
    await rejects(await signTransaction(chain, transaction({ environment: "Xcode" })));
    await rejects(await signTransaction(chain), { environments: ["Production"] });
  });

  it("rejects a tampered payload (bad signature)", async () => {
    const [h, , s] = (await signTransaction(chain)).split(".");
    const forged = b64url(utf8(JSON.stringify(transaction({ expiresDate: NOW.getTime() + 999 * 86_400_000 }))));
    await rejects(`${h}.${forged}.${s}`);
  });

  it("rejects a signature from a key other than the leaf's", async () => {
    const other = await makeChain();
    await rejects(await signTransaction(chain, transaction(), {}, other.leafKeys.privateKey));
  });

  it("rejects a chain from an untrusted root, even one with the same name", async () => {
    const impostor = await makeChain({ rootName: "Test Root CA" });
    await rejects(await signTransaction(impostor));
  });

  it("rejects a leaf from one chain presented with another chain's intermediate", async () => {
    const other = await makeChain();
    const mixed = { ...chain, leaf: other.leaf, leafKeys: other.leafKeys };
    await rejects(await signTransaction(mixed));
  });

  it("rejects an expired leaf certificate", async () => {
    const old = await makeChain({ leafNotAfter: new Date(NOW.getTime() - 86_400_000) });
    await rejects(await signTransaction(old), { roots: [old.root] });
  });

  it("rejects certificates that aren't valid yet", async () => {
    await rejects(await signTransaction(chain), { now: new Date("2026-03-01T00:00:00Z") });
  });

  it("rejects an intermediate that isn't a CA", async () => {
    const weak = await makeChain({ intermediateIsCA: false });
    await rejects(await signTransaction(weak), { roots: [weak.root] });
  });

  it("rejects other algorithms and missing or malformed x5c", async () => {
    await rejects(await signTransaction(chain, transaction(), { alg: "none" }));
    await rejects(await signTransaction(chain, transaction(), { alg: "HS256" }));
    await rejects(await signTransaction(chain, transaction(), { x5c: undefined }));
    await rejects(await signTransaction(chain, transaction(), { x5c: ["not-base64!"] }));
    await rejects(await signTransaction(chain, transaction(), { x5c: ["AAAA", "AAAA", "AAAA"] }));
  });

  it("rejects garbage", async () => {
    await rejects("");
    await rejects("abc");
    await rejects("a.b.c");
    await rejects("x".repeat(20_000));
  });
});

describe("embedded Apple root", () => {
  it("is Apple Root CA - G3 with the published fingerprint", async () => {
    const root = new X509Certificate(APPLE_ROOT_CA_G3_PEM);
    expect(root.subject).toBe("CN=Apple Root CA - G3, OU=Apple Certification Authority, O=Apple Inc., C=US");
    expect(root.notAfter.toISOString()).toBe("2039-04-30T18:19:06.000Z");
    const fp = new Uint8Array(await crypto.subtle.digest("SHA-256", root.rawData));
    const hex = [...fp].map((b) => b.toString(16).padStart(2, "0").toUpperCase()).join(":");
    expect(hex).toBe("63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79");
  });
});
