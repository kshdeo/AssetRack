import assert from "node:assert/strict";
import {test} from "node:test";
import {
  fetchFinnhubSearch,
  handleSearch,
  MAX_RESULTS,
  normalizeQuery,
  SearchDeps,
  SearchRequest,
  SearchSymbol,
  TtlCache,
  UpstreamError,
  UpstreamRateLimitError,
  WindowRateLimiter,
} from "./searchCore";

function stubFetch(status: number, body: unknown, seen?: {url?: string; init?: RequestInit}): typeof fetch {
  return (async (url: string, init?: RequestInit) => {
    if (seen) {
      seen.url = url;
      seen.init = init;
    }
    return new Response(JSON.stringify(body), {status});
  }) as unknown as typeof fetch;
}

test("normalizeQuery collapses equivalent searches and rejects bad input", () => {
  assert.equal(normalizeQuery("  Apple   INC "), "apple inc");
  assert.equal(normalizeQuery("   "), null);
  assert.equal(normalizeQuery(42), null);
  assert.equal(normalizeQuery(undefined), null);
  assert.equal(normalizeQuery("a".repeat(65)), null);
  assert.equal(normalizeQuery("a".repeat(64))?.length, 64);
});

test("TtlCache expires entries", () => {
  let now = 0;
  const cache = new TtlCache<number>(10, 100, () => now);
  cache.set("a", 1);
  now = 99;
  assert.equal(cache.get("a"), 1);
  now = 100;
  assert.equal(cache.get("a"), undefined);
});

test("TtlCache evicts the least recently used entry", () => {
  const cache = new TtlCache<number>(2, 1000, () => 0);
  cache.set("a", 1);
  cache.set("b", 2);
  cache.get("a");
  cache.set("c", 3);
  assert.equal(cache.get("a"), 1);
  assert.equal(cache.get("b"), undefined);
  assert.equal(cache.get("c"), 3);
});

test("WindowRateLimiter blocks until the window resets", () => {
  let now = 1000;
  const limiter = new WindowRateLimiter(2, 100, () => now);
  assert.equal(limiter.tryAcquire(), true);
  assert.equal(limiter.tryAcquire(), true);
  assert.equal(limiter.tryAcquire(), false);
  now = 1100;
  assert.equal(limiter.tryAcquire(), true);
});

test("fetchFinnhubSearch keeps the key out of the URL and encodes the query", async () => {
  const seen: {url?: string; init?: RequestInit} = {};
  await fetchFinnhubSearch("a&b c", "secret", stubFetch(200, {result: []}, seen));
  assert.equal(seen.url, "https://finnhub.io/api/v1/search?q=a%26b%20c");
  assert.ok(!seen.url?.includes("secret"));
  assert.deepEqual(seen.init?.headers, {"X-Finnhub-Token": "secret"});
});

test("fetchFinnhubSearch caps results and returns only the expected fields", async () => {
  const item = {symbol: "A", description: "B", displaySymbol: "C", type: "D", extra: "x"};
  const result = await fetchFinnhubSearch("q", "k", stubFetch(200, {result: Array(50).fill(item)}));
  assert.equal(result.length, MAX_RESULTS);
  assert.deepEqual(result[0], {symbol: "A", description: "B", displaySymbol: "C", type: "D"});
});

test("fetchFinnhubSearch maps upstream failures", async () => {
  await assert.rejects(fetchFinnhubSearch("q", "k", stubFetch(429, {})), UpstreamRateLimitError);
  await assert.rejects(fetchFinnhubSearch("q", "k", stubFetch(500, {})), UpstreamError);
  await assert.rejects(fetchFinnhubSearch("q", "k", stubFetch(200, {nope: 1})), UpstreamError);
});

function makeDeps(overrides: Partial<SearchDeps> = {}) {
  const calls = {fetch: 0};
  const deps: SearchDeps = {
    verifyAppCheck: async () => ({}),
    cache: new TtlCache<SearchSymbol[]>(10, 1000),
    limiter: new WindowRateLimiter(10, 1000),
    fetchSearch: async () => {
      calls.fetch += 1;
      return [];
    },
    onUpstreamError: () => {},
    ...overrides,
  };
  return {deps, calls};
}

const validRequest: SearchRequest = {method: "POST", appCheckToken: "token", body: {q: "apple"}};

test("handleSearch rejects a missing App Check token without calling Finnhub", async () => {
  const {deps, calls} = makeDeps();
  const response = await handleSearch({...validRequest, appCheckToken: undefined}, deps);
  assert.equal(response.status, 401);
  assert.equal(calls.fetch, 0);
});

test("handleSearch rejects an invalid App Check token without calling Finnhub", async () => {
  const {deps, calls} = makeDeps({verifyAppCheck: async () => { throw new Error("bad"); }});
  const response = await handleSearch(validRequest, deps);
  assert.equal(response.status, 401);
  assert.equal(calls.fetch, 0);
});

test("handleSearch checks App Check before the query", async () => {
  const {deps} = makeDeps({verifyAppCheck: async () => { throw new Error("bad"); }});
  const response = await handleSearch({...validRequest, body: {}}, deps);
  assert.equal(response.status, 401);
});

test("handleSearch only accepts POST with a usable query", async () => {
  const {deps, calls} = makeDeps();
  assert.equal((await handleSearch({...validRequest, method: "GET"}, deps)).status, 405);
  assert.equal((await handleSearch({...validRequest, body: {}}, deps)).status, 400);
  assert.equal((await handleSearch({...validRequest, body: undefined}, deps)).status, 400);
  assert.equal(calls.fetch, 0);
});

test("handleSearch serves repeat searches from the cache", async () => {
  const {deps, calls} = makeDeps();
  await handleSearch(validRequest, deps);
  const response = await handleSearch({...validRequest, body: {q: "  APPLE "}}, deps);
  assert.equal(response.status, 200);
  assert.equal(calls.fetch, 1);
});

test("handleSearch returns 429 at the limit, but cache hits still work", async () => {
  const {deps, calls} = makeDeps({limiter: new WindowRateLimiter(1, 60_000)});
  await handleSearch(validRequest, deps);
  assert.equal((await handleSearch({...validRequest, body: {q: "other"}}, deps)).status, 429);
  assert.equal((await handleSearch(validRequest, deps)).status, 200);
  assert.equal(calls.fetch, 1);
});

test("handleSearch maps upstream failures and doesn't cache them", async () => {
  const errors: unknown[] = [];
  const limited = makeDeps({fetchSearch: async () => { throw new UpstreamRateLimitError(); }});
  assert.equal((await handleSearch(validRequest, limited.deps)).status, 429);

  const broken = makeDeps({
    fetchSearch: async () => { throw new UpstreamError("boom"); },
    onUpstreamError: (error) => errors.push(error),
  });
  assert.equal((await handleSearch(validRequest, broken.deps)).status, 503);
  assert.equal(errors.length, 1);
  assert.equal(broken.deps.cache.get("apple"), undefined);
});
