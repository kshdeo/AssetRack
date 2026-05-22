# Net Worth Tracker — Project Context

> This document captures all reasoning, decisions, and architecture discussions that led to the current codebase. Intended as context for Claude Code or any new session picking up this project.

---

## Who is building this

- 15 years of iOS development experience
- Previously worked on WhatsApp's media sharing flow and Share extension
- Has Mac + Xcode
- Goal: Build an MVP to eventually launch on the App Store

---

## What the app does

A personal finance app to track **net worth across multiple accounts in one place**, with insights and projections. The core value proposition is a single unified view of your financial picture — assets and liabilities — rather than logging into multiple apps.

---

## Account types in scope

| Type | Category | Asset or Liability |
|---|---|---|
| Checking | Cash & Bank | Asset |
| Savings | Cash & Bank | Asset |
| Brokerage | Investments | Asset |
| Real Estate | Real Estate | Asset |
| Mortgage | Liabilities | Liability |
| Credit Card | Liabilities | Liability |
| Loan | Liabilities | Liability |

---

## Data input strategy

**Both manual entry and automatic sync (Plaid).** The decision was to:
- Build manual entry first (Phase 1 MVP)
- Add Plaid sync in Phase 2 once the core flow is solid

The reasoning: Plaid introduces significant backend complexity and should not block getting a working, shippable app out.

---

## Tech stack decisions and why

### SwiftUI
Greenfield app, no reason to use UIKit. Move faster, cleaner code.

### SwiftData (iOS 17+)
Chosen over Core Data because:
- Much cleaner API
- Native CloudKit sync with minimal boilerplate
- The app targets iOS 17+ which makes this viable

### CloudKit sync
Users expect their data on all their devices. CloudKit is free, private, and native. Added via `ModelConfiguration(cloudKitDatabase: .automatic)`.

### `@Observable` + MVVM
Chosen over The Composable Architecture (TCA). TCA was considered but MVVM + `@Observable` is simpler for this scope and avoids ceremony. Can always migrate later if state complexity grows.

### Swift Charts
Built-in from iOS 16, first-class API, handles everything needed: line charts, area fills, interactive scrubbing via `chartOverlay`.

### No third-party dependencies in Phase 1
Deliberately kept dependency-free for Phase 1. The only planned third-party integration is Plaid (Phase 2), which requires a backend.

---

## Critical architecture decision: Plaid requires a backend

This is the most important thing to understand before starting Phase 2.

**Plaid access tokens must never live on-device.** The required flow is:

1. Your backend creates a Plaid `link_token` and sends it to the app
2. App opens Plaid Link UI using that token
3. User authenticates with their bank
4. App receives a `public_token`
5. App sends `public_token` to your backend
6. Backend exchanges it for an `access_token` (server-side only, never sent to app)
7. Backend fetches account/balance data using `access_token` and serves it to your app via your own API

**Recommended backend: Supabase** (Postgres + Auth + Edge Functions in TypeScript/Deno)
- Hosted, scales to zero, generous free tier
- Edge Functions handle Plaid token exchange cleanly
- Alternative: Vapor (Swift) if you prefer staying in the same language

This is Phase 2 work — don't design Phase 1 around it, but don't paint yourself into a corner either.

---

## Data model design decisions

### `typeRaw: String` instead of storing `AccountType` enum directly

```swift
var typeRaw: String = AccountType.checking.rawValue

var type: AccountType {
    get { AccountType(rawValue: typeRaw) ?? .checking }
    set { typeRaw = newValue.rawValue }
}
```

**Why:** SwiftData can store `Codable` enums but has had edge-case migration bugs in practice. Storing the rawValue as a `String` and using a computed `type` property is rock-solid and fully typesafe. Never surprises you mid-migration.

### `signedBalance` computed property

```swift
var signedBalance: Double { isLiability ? -currentBalance : currentBalance }
```

**Why:** Liabilities are stored as positive numbers (a $310K mortgage is stored as `310000`, not `-310000`) — this matches how users think about their balances. The `signedBalance` computed property handles the sign flip at the point of calculation. Net worth is then simply:

```swift
accounts.reduce(0) { $0 + $1.signedBalance }
```

### `NetWorthSnapshot` as a separate model (not recomputed from accounts)

**Why:** Don't recompute net worth from all accounts on every chart render. Record a `NetWorthSnapshot` whenever balances change and query those for the history chart. This is both faster and gives you true point-in-time history (account deletions won't distort historical data).

A `SnapshotService` should record a snapshot whenever:
- An account balance is updated manually
- Plaid sync returns new balances (Phase 2)
- (Optionally) on a daily schedule even if nothing changed, to fill gaps

### `BalanceSnapshot` on each `Account`

Separate from `NetWorthSnapshot` — this tracks an individual account's history. Useful for account detail views and identifying "biggest movers" in insights.

### Default values on all `@Model` properties

```swift
@Model final class Account {
    var id: UUID = UUID()
    var name: String = ""
    ...
}
```

**Why:** CloudKit sync requires all properties to have default values. This is a CloudKit constraint, not a SwiftData one. Forgetting this causes silent sync failures.

---

## Dashboard design decisions

### `DashboardViewModel` uses pure functions, not stored state

```swift
func netWorth(from accounts: [Account]) -> Double {
    accounts.reduce(0) { $0 + $1.signedBalance }
}
```

**Why:** SwiftData `@Query` already handles reactivity. The ViewModel doesn't need to store derived values — it just computes them. This makes the VM trivially unit-testable and avoids the double-state problem (query state + VM state getting out of sync).

### `NetWorthHeroCard` uses `.contentTransition(.numericText())`

The balance number animates when it changes. Small detail, high polish.

### Chart scrubbing via `chartOverlay`

```swift
.chartOverlay { proxy in
    GeometryReader { geo in
        Rectangle().fill(.clear).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let x = drag.location.x - geo[proxy.plotAreaFrame].origin.x
                    if let date: Date = proxy.value(atX: x) {
                        selectedSnapshot = snapshots.min { ... }
                    }
                }
            )
    }
}
```

**Why this approach:** `chartOverlay` gives you a coordinate-space-aware proxy to convert drag position → data value. The `selectedSnapshot` state drives both the `PointMark` highlight and the callout label below the chart.

### Allocation bar uses proportional widths via `GeometryReader`

The stacked allocation bar is built from `GeometryReader` + `HStack` with fractional widths, not a custom drawing. Simpler to maintain and naturally adapts to screen size.

### Accounts card shows top 5 with "See All" navigation

Avoids an infinitely long dashboard. The "See All" link navigates to a full accounts list. The 5 shown are sorted by `abs(currentBalance)` — biggest positions first.

---

## Preview / testing strategy

### `ModelContainer.previewContainer` — in-memory, pre-seeded

```swift
static var previewContainer: ModelContainer {
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    // insert mock accounts + 12-month snapshots
}
```

**Why:** Xcode Previews need a `ModelContainer` but can't use the real CloudKit one. The in-memory container with realistic mock data means every view has a rich, realistic preview without any simulator overhead.

### `ModelContainer.appContainer` — production, CloudKit-backed

Used only in `NetWorthApp.swift`. Kept separate so it's impossible to accidentally use the production container in previews.

---

## Phase 1 build sequence (recommended order)

1. ✅ **SwiftData models** (`Account`, `BalanceSnapshot`, `NetWorthSnapshot`) — foundation
2. ✅ **Dashboard view** — core value, make it beautiful early
3. 🔜 **Add/Edit Account sheet** — makes the dashboard come alive with real data
4. 🔜 **SnapshotService** — records `NetWorthSnapshot` on every balance change
5. 🔜 **Biometric lock** — `LocalAuthentication`, quick to add
6. 🔜 **Basic insights** — month-over-month delta, biggest movers

---

## Phase 2 (after MVP ships)

- Plaid Link integration (requires Supabase backend)
- Background refresh via `BGAppRefreshTask`
- Push notifications for large balance changes
- Real estate value estimates (Redfin/Attom API — Zillow is gated)

## Phase 3

- Net worth projection model (configurable growth rates per asset class)
- Debt payoff simulator (avalanche vs snowball)
- Asset allocation targets + drift alerts
- CSV / PDF export
- "On track for $X by year Y" milestone cards

---

## FX rate source

**Current:** `FXRateService` fetches from [frankfurter.app](https://frankfurter.app) — free, no API key, backed by European Central Bank data, cached in `UserDefaults` and refreshed daily.

**Investigated:** iOS has no system API for live exchange rates. `Locale` and `NumberFormatter` provide currency formatting and symbols only — no conversion rates. There is no `CoreFX` or equivalent framework.

**Future options if frankfurter.app becomes unsuitable:**
- [Open Exchange Rates](https://openexchangerates.org) — free tier available, API key required
- [CurrencyAPI](https://currencyapi.com) — free tier, API key required
- [Wise](https://wise.com/gb/currency-converter/) — no public API but real-time rates

---

## Known gaps / TODO before App Store

| Item | Notes |
|---|---|
| `SnapshotService` | Records `NetWorthSnapshot` on balance change. Not yet built. |
| `AddAccountView` | Sheet for manual account entry. Not yet built. |
| Multi-currency | Store in base currency (USD); fetch FX from frankfurter.app |
| Privacy policy | Required by App Store + Plaid terms |
| Data deletion flow | Required by App Store review |
| Real estate valuation | Manual only in Phase 1; API integration in Phase 2 |
| Plaid rate limits | Cache balance data locally, max 2× refresh/day |

---

## File structure (current)

```
NetWorthApp/
├── NetWorthApp.swift          # App entry point, wires .appContainer
├── Models.swift               # SwiftData @Model classes + formatting helpers
├── DashboardViewModel.swift   # Business logic — pure functions, @Observable
├── DashboardView.swift        # Full dashboard UI
└── PreviewData.swift          # Mock data + ModelContainer variants
```

---

## Xcode project setup checklist

- [ ] iOS 17.0 minimum deployment target
- [ ] iCloud capability enabled (Signing & Capabilities → + → iCloud)
- [ ] CloudKit container created: `iCloud.com.yourname.networth`
- [ ] Background Modes capability → Remote notifications checked
- [ ] Swift Charts — built-in, just `import Charts`
- [ ] No third-party packages yet (Phase 1)
