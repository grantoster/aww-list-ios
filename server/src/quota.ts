// Monthly photo quota per subscription (originalTransactionId), counted per calendar month in UTC.
//
// Workers KV is eventually consistent and has no atomic increment, so two requests landing at the same
// moment (or in different data centers) can both read n and both write n+1. That can let a subscriber go
// slightly over the limit; it never blocks anyone wrongly. Acceptable for a soft cost cap like this one.

const TTL_SECONDS = 40 * 24 * 60 * 60; // keys outlive their month, then KV deletes them

export interface Period {
  key: string;
  resets: Date; // first instant of next month, UTC
}

export function period(originalTransactionId: string, now: Date): Period {
  const y = now.getUTCFullYear();
  const m = now.getUTCMonth();
  const month = `${y}-${String(m + 1).padStart(2, "0")}`;
  return { key: `q:${originalTransactionId}:${month}`, resets: new Date(Date.UTC(y, m + 1, 1)) };
}

export async function getUsed(kv: KVNamespace, key: string): Promise<number> {
  const raw = await kv.get(key);
  const n = raw == null ? 0 : parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** Read-modify-write; see the note at the top about KV not being atomic. */
export async function increment(kv: KVNamespace, key: string): Promise<number> {
  const next = (await getUsed(kv, key)) + 1;
  await kv.put(key, String(next), { expirationTtl: TTL_SECONDS });
  return next;
}
