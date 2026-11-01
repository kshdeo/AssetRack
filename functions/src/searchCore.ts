// Finnhub proxy logic, kept free of firebase-functions so it can be unit tested.

export const MAX_QUERY_LENGTH = 64;
export const MAX_RESULTS = 20;

export interface SearchSymbol {
  symbol: string;
  description: string;
  displaySymbol: string;
  type: string;
}

export class UpstreamRateLimitError extends Error {}
export class UpstreamError extends Error {}

/** Lowercased and whitespace-collapsed, so equivalent searches share a cache entry. */
export function normalizeQuery(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const query = raw.trim().replace(/\s+/g, " ").toLowerCase();
  return query.length >= 1 && query.length <= MAX_QUERY_LENGTH ? query : null;
}

/** TTL cache with least-recently-used eviction (a Map iterates in insertion order). */
export class TtlCache<V> {
  private readonly entries = new Map<string, {value: V; expiresAt: number}>();

  constructor(
    private readonly maxEntries: number,
    private readonly ttlMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  get(key: string): V | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    this.entries.delete(key);
    if (entry.expiresAt <= this.now()) return undefined;
    this.entries.set(key, entry);
    return entry.value;
  }

  set(key: string, value: V): void {
    this.entries.delete(key);
    this.entries.set(key, {value, expiresAt: this.now() + this.ttlMs});
    if (this.entries.size > this.maxEntries) {
      const oldest = this.entries.keys().next().value;
      if (oldest !== undefined) this.entries.delete(oldest);
    }
  }
}

/** Fixed-window limiter for calls to Finnhub. Cache hits don't count against it. */
export class WindowRateLimiter {
  private windowStart = 0;
  private used = 0;

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  tryAcquire(): boolean {
    const time = this.now();
    if (time - this.windowStart >= this.windowMs) {
      this.windowStart = time;
      this.used = 0;
    }
    if (this.used >= this.limit) return false;
    this.used += 1;
    return true;
  }
}

/** Calls Finnhub, sending the key as a header so it can't end up in a logged URL. */
export async function fetchFinnhubSearch(
  query: string,
  apiKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<SearchSymbol[]> {
  const url = `https://finnhub.io/api/v1/search?q=${encodeURIComponent(query)}`;
  const response = await fetchImpl(url, {
    headers: {"X-Finnhub-Token": apiKey},
    signal: AbortSignal.timeout(5_000),
  });
  if (response.status === 429) throw new UpstreamRateLimitError();
  if (!response.ok) throw new UpstreamError(`Finnhub returned ${response.status}`);

  const body = (await response.json()) as {result?: unknown};
  if (!Array.isArray(body.result)) throw new UpstreamError("Unexpected Finnhub response");
  return body.result.slice(0, MAX_RESULTS).map((item: Partial<SearchSymbol>) => ({
    symbol: String(item.symbol ?? ""),
    description: String(item.description ?? ""),
    displaySymbol: String(item.displaySymbol ?? ""),
    type: String(item.type ?? ""),
  }));
}

export interface SearchRequest {
  method: string;
  appCheckToken: string | undefined;
  body: unknown;
}

export interface SearchDeps {
  /** Rejects if the App Check token isn't valid. */
  verifyAppCheck: (token: string) => Promise<unknown>;
  cache: TtlCache<SearchSymbol[]>;
  limiter: WindowRateLimiter;
  fetchSearch: (query: string) => Promise<SearchSymbol[]>;
  onUpstreamError: (error: unknown) => void;
}

export interface SearchResponse {
  status: number;
  body: {result: SearchSymbol[]} | {error: string};
}

/**
 * The whole request flow, in cost order: nothing past the App Check step runs,
 * and no Finnhub quota is spent, for an unverified caller.
 */
export async function handleSearch(request: SearchRequest, deps: SearchDeps): Promise<SearchResponse> {
  if (request.method !== "POST") return {status: 405, body: {error: "Method not allowed"}};

  if (!request.appCheckToken) return {status: 401, body: {error: "Unauthorized"}};
  try {
    await deps.verifyAppCheck(request.appCheckToken);
  } catch {
    return {status: 401, body: {error: "Unauthorized"}};
  }

  const query = normalizeQuery((request.body as {q?: unknown} | null | undefined)?.q);
  if (query === null) return {status: 400, body: {error: "Enter a search of 1 to 64 characters."}};

  const cached = deps.cache.get(query);
  if (cached) return {status: 200, body: {result: cached}};

  const tooMany: SearchResponse = {status: 429, body: {error: "Too many searches. Try again shortly."}};
  if (!deps.limiter.tryAcquire()) return tooMany;

  try {
    const result = await deps.fetchSearch(query);
    deps.cache.set(query, result);
    return {status: 200, body: {result}};
  } catch (error) {
    if (error instanceof UpstreamRateLimitError) return tooMany;
    deps.onUpstreamError(error);
    return {status: 503, body: {error: "Search is unavailable right now."}};
  }
}
