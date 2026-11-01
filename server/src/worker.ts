// Awwbum scoring server: lets paying subscribers have photos scored by Claude without their own API key.
//
// Privacy (these are children's photos): image data and Claude's reply text are never logged, stored or
// cached. Logs carry only the route, status code, timing, and a truncated hash of originalTransactionId.

import type { X509Certificate } from "./x509";
import { DEFAULT_MODEL, MODELS, callClaude } from "./anthropic";
import { APPLE_ROOT_CA_G3_PEM } from "./appleRoot";
import { getUsed, increment, period } from "./quota";
import { type Subscription, parseRoots, verifyTransaction } from "./verify";

export interface Env {
  QUOTA: KVNamespace;
  ANTHROPIC_API_KEY: string;
  BUNDLE_ID: string;
  PRODUCT_IDS: string;
  MONTHLY_LIMIT?: string;
  ALLOWED_ENVIRONMENTS?: string;
}

export const MAX_IMAGE_CHARS = 1_500_000; // base64 characters (~1.1 MB of JPEG)
const MAX_BODY_BYTES = MAX_IMAGE_CHARS + 1_024; // room for the JSON wrapper and model name
const DEFAULT_MONTHLY_LIMIT = 5000;
const TRANSACTION_HEADER = "X-Awwbum-Transaction";

interface Options {
  rootPems?: string[]; // tests inject their own CA; production trusts only Apple Root CA - G3
  now?: () => Date;
}

export function createHandler(options: Options = {}): ExportedHandler<Env> {
  let roots: X509Certificate[] | undefined;
  const now = options.now ?? (() => new Date());

  return {
    async fetch(request, env): Promise<Response> {
      const started = Date.now();
      const route = new URL(request.url).pathname;
      let sub: string | undefined;
      let response: Response;
      try {
        roots ??= parseRoots(options.rootPems ?? [APPLE_ROOT_CA_G3_PEM]);
        response = await route_(request, env, roots, now(), (id) => (sub = id));
      } catch {
        response = error(500, "overloaded_error", "Something went wrong on the server; try again shortly.");
      }
      const hash = sub ? await shortHash(sub) : undefined;
      console.log(JSON.stringify({ route, status: response.status, ms: Date.now() - started, sub: hash }));
      return response;
    },
  };
}

async function route_(
  request: Request,
  env: Env,
  roots: X509Certificate[],
  now: Date,
  identify: (originalTransactionId: string) => void,
): Promise<Response> {
  const path = new URL(request.url).pathname;
  const isScore = path === "/v1/score" && request.method === "POST";
  const isQuota = path === "/v1/quota" && request.method === "GET";
  if (!isScore && !isQuota) return error(404, "not_found_error", "Not found.");

  // Cheap size check before anything else, when the client declares a length.
  if (isScore && Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) {
    return error(413, "request_too_large", "The photo is too large.");
  }

  let subscription: Subscription;
  try {
    subscription = await verifyTransaction(request.headers.get(TRANSACTION_HEADER) ?? "", {
      roots,
      bundleId: env.BUNDLE_ID,
      productIds: list(env.PRODUCT_IDS),
      environments: list(env.ALLOWED_ENVIRONMENTS ?? "Production,Sandbox"),
      now,
    });
  } catch {
    return error(401, "not_subscribed", "An active Awwbum Plus subscription is required.");
  }
  identify(subscription.originalTransactionId);

  const limit = monthlyLimit(env);
  const { key, resets } = period(subscription.originalTransactionId, now);
  const used = await getUsed(env.QUOTA, key);
  if (isQuota) return json(200, { used, limit, resets: resets.toISOString() });

  if (used >= limit) {
    const retryAfter = Math.max(1, Math.ceil((resets.getTime() - now.getTime()) / 1000));
    return error(429, "quota_exceeded", `Monthly limit of ${limit} photos reached; it resets ${resets.toISOString()}.`, {
      "retry-after": String(retryAfter),
    });
  }

  const raw = await readLimited(request, MAX_BODY_BYTES);
  if (raw === null) return error(413, "request_too_large", "The photo is too large.");
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return error(400, "invalid_request_error", "Body must be JSON.");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return error(400, "invalid_request_error", "Body must be a JSON object.");
  }
  const { image, model = DEFAULT_MODEL } = body as { image?: unknown; model?: unknown };
  if (typeof model !== "string" || !(MODELS as readonly string[]).includes(model)) {
    return error(400, "invalid_request_error", `model must be one of ${MODELS.join(", ")}.`);
  }
  if (typeof image !== "string" || image.length === 0) {
    return error(400, "invalid_request_error", "image must be a base64 JPEG string.");
  }
  if (image.length > MAX_IMAGE_CHARS) return error(413, "request_too_large", "The photo is too large.");
  if (!isBase64Jpeg(image)) return error(400, "invalid_request_error", "image must be a base64 JPEG string.");

  if (!env.ANTHROPIC_API_KEY) return error(500, "overloaded_error", "The server is not configured yet.");
  let upstream: Response;
  try {
    upstream = await callClaude(env.ANTHROPIC_API_KEY, model, image);
  } catch {
    return error(502, "overloaded_error", "Couldn't reach Claude; try again shortly.");
  }

  if (upstream.status === 200) {
    await increment(env.QUOTA, key); // only successful scores count toward the quota
    return new Response(upstream.body, { status: 200, headers: baseHeaders() });
  }
  return upstreamError(upstream);
}

/** Maps a non-200 Anthropic response to our error contract. Error bodies never contain reply text. */
async function upstreamError(upstream: Response): Promise<Response> {
  const retry = upstream.headers.get("retry-after");
  const extra: Record<string, string> = retry ? { "retry-after": retry } : {};
  const status = upstream.status;
  if (status === 429) {
    return new Response(await upstream.text(), { status, headers: { ...baseHeaders(), ...extra } });
  }
  if (status >= 500) return error(status, "overloaded_error", "Claude is busy; try again shortly.", extra);
  if (status === 413) return error(413, "request_too_large", "The photo is too large.");
  if (status === 400) {
    let message = "Claude couldn't read this photo.";
    try {
      const m = ((await upstream.json()) as { error?: { message?: unknown } }).error?.message;
      if (typeof m === "string" && m) message = m.slice(0, 300);
    } catch {
      /* keep default */
    }
    return error(400, "invalid_request_error", message);
  }
  // 401/403/404 etc. mean the server's own key or setup is wrong, not the app's request.
  await upstream.body?.cancel();
  return error(502, "overloaded_error", "Scoring is temporarily unavailable.");
}

/** Strict base64 (standard alphabet, padded) whose first bytes are the JPEG magic FF D8 FF. */
export function isBase64Jpeg(s: string): boolean {
  if (s.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(s)) return false;
  const head = atob(s.slice(0, 4)); // 4 base64 chars = first 3 bytes
  return head.charCodeAt(0) === 0xff && head.charCodeAt(1) === 0xd8 && head.charCodeAt(2) === 0xff;
}

/** Reads the body as text, giving up (null) as soon as it exceeds max bytes. */
async function readLimited(request: Request, max: number): Promise<string | null> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    all.set(c, offset);
    offset += c.byteLength;
  }
  return new TextDecoder().decode(all);
}

function monthlyLimit(env: Env): number {
  const n = parseInt(env.MONTHLY_LIMIT ?? "", 10);
  return Number.isFinite(n) && n >= 0 ? n : DEFAULT_MONTHLY_LIMIT;
}

function list(s: string | undefined): string[] {
  return (s ?? "").split(",").map((x) => x.trim()).filter(Boolean);
}

async function shortHash(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest).slice(0, 6)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function baseHeaders(): Record<string, string> {
  return { "content-type": "application/json", "cache-control": "no-store" };
}

function json(status: number, data: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...baseHeaders(), ...extra } });
}

function error(status: number, type: string, message: string, extra: Record<string, string> = {}): Response {
  return json(status, { error: { type, message } }, extra);
}
