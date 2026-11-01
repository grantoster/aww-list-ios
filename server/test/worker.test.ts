import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { SYSTEM_PROMPT } from "../src/anthropic";
import { type Env, MAX_IMAGE_CHARS, createHandler, isBase64Jpeg } from "../src/worker";
import { type Chain, NOW, fakeJpeg, makeChain, signTransaction, transaction } from "./helpers";

class MemoryKV {
  store = new Map<string, string>();
  puts: { key: string; value: string; options?: { expirationTtl?: number } }[] = [];
  async get(key: string) {
    return this.store.get(key) ?? null;
  }
  async put(key: string, value: string, options?: { expirationTtl?: number }) {
    this.puts.push({ key, value, options });
    this.store.set(key, value);
  }
}

const CLAUDE_REPLY = JSON.stringify({
  id: "msg_1",
  type: "message",
  role: "assistant",
  model: "claude-haiku-5-5",
  content: [{ type: "text", text: '{"score": 8.5, "caption": "toddler giggling at bubbles", "exclude": null}' }],
  stop_reason: "end_turn",
  usage: { input_tokens: 1200, output_tokens: 30 },
});
const KEY = "q:2000000123456789:2026-11";

let chain: Chain;
let jws: string;
let kv: MemoryKV;
let env: Env;
let fetchMock: ReturnType<typeof vi.fn>;
let logs: string[];
const handler = () => createHandler({ rootPems: [chain.root.toString("pem")], now: () => NOW });

beforeAll(async () => {
  chain = await makeChain();
  jws = await signTransaction(chain);
});

beforeEach(() => {
  kv = new MemoryKV();
  env = {
    QUOTA: kv as unknown as KVNamespace,
    ANTHROPIC_API_KEY: "sk-test",
    BUNDLE_ID: "com.grantoster.awwlist",
    PRODUCT_IDS: "com.grantoster.awwlist.plus.monthly,com.grantoster.awwlist.plus.yearly",
    MONTHLY_LIMIT: "5000",
    ALLOWED_ENVIRONMENTS: "Production,Sandbox",
  };
  fetchMock = vi.fn(async () => new Response(CLAUDE_REPLY, { status: 200, headers: { "content-type": "application/json" } }));
  vi.stubGlobal("fetch", fetchMock);
  logs = [];
  vi.spyOn(console, "log").mockImplementation((...args: unknown[]) => void logs.push(args.join(" ")));
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function call(method: string, path: string, init: { body?: string; headers?: Record<string, string> } = {}) {
  const req = new Request(`https://awwbum.example.workers.dev${path}`, {
    method,
    body: init.body,
    headers: { "content-type": "application/json", ...init.headers },
  });
  return handler().fetch!(req as any, env, {} as ExecutionContext);
}

const score = (body: unknown, headers: Record<string, string> = { "X-Awwbum-Transaction": jws }) =>
  call("POST", "/v1/score", { body: typeof body === "string" ? body : JSON.stringify(body), headers });

async function expectError(res: Response, status: number, type: string) {
  expect(res.status).toBe(status);
  const body = (await res.json()) as { error: { type: string; message: string } };
  expect(body.error.type).toBe(type);
  expect(typeof body.error.message).toBe("string");
}

describe("routing", () => {
  it("404s anything but POST /v1/score and GET /v1/quota", async () => {
    await expectError(await call("GET", "/"), 404, "not_found_error");
    await expectError(await call("GET", "/v1/score", { headers: { "X-Awwbum-Transaction": jws } }), 404, "not_found_error");
    await expectError(await call("POST", "/v1/quota", { body: "{}" }), 404, "not_found_error");
    await expectError(await call("PUT", "/v1/score", { body: "{}" }), 404, "not_found_error");
    await expectError(await call("OPTIONS", "/v1/score"), 404, "not_found_error");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("POST /v1/score", () => {
  it("calls Claude with the exact request and passes the reply through unchanged", async () => {
    const image = fakeJpeg();
    const res = await score({ image });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");
    expect(await res.text()).toBe(CLAUDE_REPLY);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.anthropic.com/v1/messages");
    expect(init.method).toBe("POST");
    expect(init.headers).toEqual({ "x-api-key": "sk-test", "anthropic-version": "2023-06-01", "content-type": "application/json" });
    expect(JSON.parse(init.body as string)).toEqual({
      model: "claude-haiku-5-5",
      max_tokens: 2000,
      system: SYSTEM_PROMPT,
      output_config: { effort: "low" },
      messages: [
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: "image/jpeg", data: image } },
            { type: "text", text: "Rate this photo." },
          ],
        },
      ],
    });
  });

  it("uses the requested model", async () => {
    for (const model of ["claude-sonnet-5-5", "claude-opus-5-5"]) {
      expect((await score({ image: fakeJpeg(), model })).status).toBe(200);
      expect(JSON.parse((fetchMock.mock.calls.at(-1) as [string, RequestInit])[1].body as string).model).toBe(model);
    }
  });

  it("counts a successful score in KV with a ~40 day TTL", async () => {
    await score({ image: fakeJpeg() });
    await score({ image: fakeJpeg() });
    expect(kv.store.get(KEY)).toBe("2");
    expect(kv.puts.every((p) => p.key === KEY && p.options?.expirationTtl === 40 * 86_400)).toBe(true);
  });

  it("401s without a valid subscription and never calls Claude", async () => {
    await expectError(await score({ image: fakeJpeg() }, {}), 401, "not_subscribed");
    await expectError(await score({ image: fakeJpeg() }, { "X-Awwbum-Transaction": "junk" }), 401, "not_subscribed");
    const expired = await signTransaction(chain, transaction({ expiresDate: NOW.getTime() - 1 }));
    await expectError(await score({ image: fakeJpeg() }, { "X-Awwbum-Transaction": expired }), 401, "not_subscribed");
    const wrongBundle = await signTransaction(chain, transaction({ bundleId: "com.other.app" }));
    await expectError(await score({ image: fakeJpeg() }, { "X-Awwbum-Transaction": wrongBundle }), 401, "not_subscribed");
    const untrusted = await signTransaction(await makeChain());
    await expectError(await score({ image: fakeJpeg() }, { "X-Awwbum-Transaction": untrusted }), 401, "not_subscribed");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("413s an image over the size limit", async () => {
    await expectError(await score({ image: "/9j/" + "A".repeat(MAX_IMAGE_CHARS) }), 413, "request_too_large");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("413s on a declared Content-Length over the limit, before checking anything else", async () => {
    const res = await score({ image: fakeJpeg() }, { "content-length": String(MAX_IMAGE_CHARS + 10_000) });
    await expectError(res, 413, "request_too_large");
  });

  it("400s invalid requests", async () => {
    await expectError(await score("not json"), 400, "invalid_request_error");
    await expectError(await score([1, 2]), 400, "invalid_request_error");
    await expectError(await score({}), 400, "invalid_request_error");
    await expectError(await score({ image: 42 }), 400, "invalid_request_error");
    await expectError(await score({ image: fakeJpeg(), model: "claude-3-opus" }), 400, "invalid_request_error");
    await expectError(await score({ image: "@@@@not base64" }), 400, "invalid_request_error");
    await expectError(await score({ image: "iVBORw0KGgoAAAANSUhEUg==" }), 400, "invalid_request_error"); // PNG
    await expectError(await score({ image: "data:image/jpeg;base64," + fakeJpeg() }), 400, "invalid_request_error");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("429s with Retry-After once the monthly quota is used, without calling Claude", async () => {
    env.MONTHLY_LIMIT = "3";
    kv.store.set(KEY, "3");
    const res = await score({ image: fakeJpeg() });
    expect(res.headers.get("retry-after")).toBe(String((Date.parse("2026-12-01T00:00:00Z") - NOW.getTime()) / 1000));
    await expectError(res, 429, "quota_exceeded");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("passes an Anthropic 429 through and doesn't count it", async () => {
    const body = JSON.stringify({ type: "error", error: { type: "rate_limit_error", message: "slow down" } });
    fetchMock.mockResolvedValueOnce(new Response(body, { status: 429, headers: { "retry-after": "12" } }));
    const res = await score({ image: fakeJpeg() });
    expect(res.status).toBe(429);
    expect(res.headers.get("retry-after")).toBe("12");
    expect(await res.text()).toBe(body);
    expect(kv.store.has(KEY)).toBe(false);
  });

  it("maps Anthropic 5xx to overloaded_error with the same status", async () => {
    fetchMock.mockResolvedValueOnce(new Response('{"type":"error","error":{"type":"overloaded_error","message":"x"}}', { status: 529 }));
    await expectError(await score({ image: fakeJpeg() }), 529, "overloaded_error");
    fetchMock.mockResolvedValueOnce(new Response("upstream html", { status: 500 }));
    await expectError(await score({ image: fakeJpeg() }), 500, "overloaded_error");
    fetchMock.mockRejectedValueOnce(new Error("network down"));
    await expectError(await score({ image: fakeJpeg() }), 502, "overloaded_error");
    expect(kv.store.has(KEY)).toBe(false);
  });

  it("maps Anthropic 400 to invalid_request_error and server-key problems to 502", async () => {
    fetchMock.mockResolvedValueOnce(
      new Response('{"type":"error","error":{"type":"invalid_request_error","message":"Could not process image"}}', { status: 400 }),
    );
    const res = await score({ image: fakeJpeg() });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: { type: "invalid_request_error", message: "Could not process image" } });
    fetchMock.mockResolvedValueOnce(new Response('{"type":"error","error":{"type":"authentication_error"}}', { status: 401 }));
    await expectError(await score({ image: fakeJpeg() }), 502, "overloaded_error");
  });

  it("never logs image data, reply text or the raw transaction id", async () => {
    const image = fakeJpeg();
    await score({ image });
    await call("GET", "/v1/quota", { headers: { "X-Awwbum-Transaction": jws } });
    expect(logs.length).toBe(2);
    for (const line of logs) {
      expect(Object.keys(JSON.parse(line)).sort()).toEqual(["ms", "route", "status", "sub"]);
      expect(line).not.toContain(image.slice(0, 40));
      expect(line).not.toContain("giggling");
      expect(line).not.toContain("2000000123456789");
    }
    expect(JSON.parse(logs[0]).sub).toMatch(/^[0-9a-f]{12}$/);
  });
});

describe("GET /v1/quota", () => {
  it("reports used, limit and the next reset", async () => {
    kv.store.set(KEY, "17");
    const res = await call("GET", "/v1/quota", { headers: { "X-Awwbum-Transaction": jws } });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ used: 17, limit: 5000, resets: "2026-12-01T00:00:00.000Z" });
  });

  it("starts at zero and honors MONTHLY_LIMIT", async () => {
    env.MONTHLY_LIMIT = "250";
    const res = await call("GET", "/v1/quota", { headers: { "X-Awwbum-Transaction": jws } });
    expect(await res.json()).toEqual({ used: 0, limit: 250, resets: "2026-12-01T00:00:00.000Z" });
  });

  it("401s without a subscription", async () => {
    await expectError(await call("GET", "/v1/quota"), 401, "not_subscribed");
  });
});

describe("helpers", () => {
  it("isBase64Jpeg checks alphabet, padding and FF D8 FF", () => {
    expect(isBase64Jpeg(fakeJpeg())).toBe(true);
    expect(isBase64Jpeg("/9j/4A==")).toBe(true);
    expect(isBase64Jpeg("/9j/4A")).toBe(false); // unpadded
    expect(isBase64Jpeg("/9j/4A==\n")).toBe(false);
    expect(isBase64Jpeg("AAAAAA==")).toBe(false);
  });

  it("system prompt is the app's prompt, four lines", () => {
    const lines = SYSTEM_PROMPT.split("\n");
    expect(lines).toHaveLength(4);
    expect(lines[0]).toBe(`You rate family photos for "The Aww List", which ranks how cute the children in a family's photo library look.`);
    expect(lines[3]).toBe(
      `Reply with JSON only: {"score": number, "caption": "specific description of the moment, at most 8 words, no names", "exclude": null or one of the reasons above}`,
    );
  });
});
