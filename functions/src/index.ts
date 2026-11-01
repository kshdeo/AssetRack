import {initializeApp} from "firebase-admin/app";
import {getAppCheck} from "firebase-admin/app-check";
import {defineSecret} from "firebase-functions/params";
import {onRequest} from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import {
  fetchFinnhubSearch,
  handleSearch,
  SearchSymbol,
  TtlCache,
  WindowRateLimiter,
} from "./searchCore";

initializeApp();

const finnhubApiKey = defineSecret("FINNHUB_API_KEY");

// Both are per instance. `maxInstances: 1` below makes them effectively global.
const cache = new TtlCache<SearchSymbol[]>(500, 60 * 60 * 1000);
// Stays under Finnhub's free-tier limit of 60 calls a minute.
const limiter = new WindowRateLimiter(50, 60 * 1000);

/**
 * Security search for the app's Add Holding screen. `POST {q}` with an App Check
 * token in `X-Firebase-AppCheck`; responds `{result}` (same shape as Finnhub's).
 * Public at the network level because App Check is the gate (see `handleSearch`).
 * Queries aren't logged: what someone looks up hints at what they hold.
 */
export const search = onRequest(
  {
    region: "europe-west1", // Keep in sync with ISINLookupService.functionsRegion.
    invoker: "public",
    secrets: [finnhubApiKey],
    maxInstances: 1,
    concurrency: 80,
    cpu: 1,
    memory: "256MiB",
    timeoutSeconds: 10,
  },
  async (req, res) => {
    const {status, body} = await handleSearch(
      {method: req.method, appCheckToken: req.header("X-Firebase-AppCheck"), body: req.body},
      {
        verifyAppCheck: (token) => getAppCheck().verifyToken(token),
        cache,
        limiter,
        fetchSearch: (query) => fetchFinnhubSearch(query, finnhubApiKey.value()),
        onUpstreamError: (error) => logger.error("Finnhub search failed", {
          error: error instanceof Error ? error.message : "unknown",
        }),
      },
    );
    res.status(status).json(body);
  },
);
