import {defineSecret} from "firebase-functions/params";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {
  fetchFinnhubSearch,
  normalizeQuery,
  SearchSymbol,
  TtlCache,
  UpstreamRateLimitError,
  WindowRateLimiter,
} from "./searchCore";

const finnhubApiKey = defineSecret("FINNHUB_API_KEY");

// Both are per instance. `maxInstances: 1` below makes them effectively global.
const cache = new TtlCache<SearchSymbol[]>(500, 60 * 60 * 1000);
// Stays under Finnhub's free-tier limit of 60 calls a minute.
const upstreamLimiter = new WindowRateLimiter(50, 60 * 1000);

/**
 * Security search for the app's Add Holding screen. Request `{q}`, response
 * `{result}` (same shape as Finnhub's). Queries aren't logged: what someone
 * looks up hints at what they hold.
 */
export const search = onCall(
  {
    region: "europe-west1", // Keep in sync with ISINLookupService.functionsRegion.
    enforceAppCheck: true,
    secrets: [finnhubApiKey],
    maxInstances: 1,
    concurrency: 80,
    cpu: 1,
    memory: "256MiB",
    timeoutSeconds: 10,
  },
  async (request) => {
    const query = normalizeQuery((request.data as {q?: unknown} | null)?.q);
    if (query === null) {
      throw new HttpsError("invalid-argument", "Enter a search of 1 to 64 characters.");
    }

    const cached = cache.get(query);
    if (cached) return {result: cached};

    if (!upstreamLimiter.tryAcquire()) {
      throw new HttpsError("resource-exhausted", "Too many searches. Try again shortly.");
    }

    try {
      const result = await fetchFinnhubSearch(query, finnhubApiKey.value());
      cache.set(query, result);
      return {result};
    } catch (error) {
      if (error instanceof UpstreamRateLimitError) {
        throw new HttpsError("resource-exhausted", "Too many searches. Try again shortly.");
      }
      logger.error("Finnhub search failed", {
        error: error instanceof Error ? error.message : "unknown",
      });
      throw new HttpsError("unavailable", "Search is unavailable right now.");
    }
  },
);
