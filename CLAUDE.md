# AssetRack – Claude Context

## Project Overview
AssetRack is an iOS Net Worth Tracker — a personal finance app for tracking **net worth across multiple accounts in one place**, with insights and projections. The core value is a single unified view of assets and liabilities rather than logging into multiple apps.

**GitHub:** `git@github.com:kshdeo/AssetRack.git`

## Architecture
- **Models** – `Account`, `Holding`, `BalanceSnapshot`, `NetWorthSnapshot`, `ProjectionSettings` (`@Model`)
- **Services** – `CurrencyService` (FX rates, currency arithmetic, formatting), `TickerService` (Yahoo Finance + Tradegate prices), `ISINLookupService` (Finnhub + Tradegate search, live price preview), `ProjectionService` (pure-growth net worth projection)
- **ViewModels** – `DashboardViewModel` (`@Observable`) computes chart/history data
- **Views** – `DashboardView`, `AccountsListView`, `AccountRow`, `AddEditAccountView`, `AccountBalanceHistoryView`, `AddHistoricalEntryView`, `SettingsView`, `ProjectionView`
- **Tests** – `CurrencyServiceTests` (20 tests, Swift Testing framework)

## Account Types

| Type | Category | Asset or Liability |
|---|---|---|
| Checking | Cash & Bank | Asset |
| Savings | Cash & Bank | Asset |
| Brokerage | Investments | Asset |
| Real Estate | Real Estate | Asset |
| Pension | Retirement | Asset |
| Mortgage | Liabilities | Liability |
| Credit Card | Liabilities | Liability |
| Loan | Liabilities | Liability |

## Tech Stack Decisions

- **SwiftUI** — greenfield app, no reason to use UIKit
- **SwiftData (iOS 17+)** — cleaner API than Core Data, native CloudKit sync with minimal boilerplate
- **CloudKit** — free, private, native; via `ModelConfiguration(cloudKitDatabase: .automatic)`
- **`@Observable` + MVVM** — simpler than TCA for this scope, avoids ceremony
- **Swift Charts** — built-in from iOS 16, handles area charts, interactive scrubbing
- **No third-party dependencies in Phase 1** — only planned third-party integration is Plaid (Phase 2, requires backend)

## Data Model Design Decisions

### `typeRaw: String` instead of storing enum directly
```swift
var typeRaw: String = AccountType.checking.rawValue
var type: AccountType {
    get { AccountType(rawValue: typeRaw) ?? .checking }
    set { typeRaw = newValue.rawValue }
}
```
Storing rawValue as `String` avoids CloudKit migration edge cases. Never surprises you mid-migration.

### `signedBalance` computed property
Liabilities are stored as positive numbers (a £310K mortgage = `310000`). `signedBalance` flips the sign at calculation time. Net worth is then just `accounts.reduce(0) { $0 + $1.signedBalance }`.

### `BalanceSnapshot` on each `Account`
Tracks individual account history. Used for the history chart, per-account detail views, and the carry-forward logic.

### `NetWorthSnapshot` as a separate model
Don't recompute net worth from all accounts on every render. Records point-in-time history that survives account deletions.

### Default values on all `@Model` properties
Required by CloudKit — forgetting this causes silent sync failures.

## FX Rate Source
**Current:** [frankfurter.app](https://frankfurter.app) — free, no API key, ECB data, cached in `UserDefaults`, refreshed daily.
iOS has no system API for live exchange rates. `Locale`/`NumberFormatter` provide formatting only — no conversion rates. There is no `CoreFX` or equivalent framework.

**Alternatives if frankfurter.app becomes unsuitable:**
- [Open Exchange Rates](https://openexchangerates.org) — free tier, API key required
- [CurrencyAPI](https://currencyapi.com) — free tier, API key required
- [Wise](https://wise.com/gb/currency-converter/) — no public API but real-time rates

## Strict Rules

### 1. All currency arithmetic MUST go through `CurrencyService`
Never add, subtract, or compare monetary amounts from different currencies inline.
Always use:
```swift
// Sum a collection of mixed-currency amounts
currencyService.sum([Money(100, "GBP"), Money(200, "USD")], in: "GBP")

// Convert a single amount
currencyService.convert(Money(amount, currency), to: targetCurrency)
```
**Never** do this:
```swift
// ❌ wrong – mixes currencies without conversion
let total = accounts.reduce(0) { $0 + $1.currentBalance }
// ❌ wrong – manually accumulating converted doubles
return sum + currencyService.convert(...).amount  // inside a reduce
```

### 2. `Money` type for all monetary values
Use `Money(amount: Double, currency: String)` for any value that has a currency.
The `Double`-based `convert(_:from:to:)` overload is for internal `CurrencyService` use and `recomputeBalance` closures only.

### 3. All currency formatting MUST go through `CurrencyService`
Never call `Double.currencyFormatted(code:)` directly at a call site.
Always use:
```swift
currencyService.formatted(money)          // formats Money in its own currency
currencyService.formattedBase(amount)     // formats a Double in the base currency
```
**Never** do this:
```swift
// ❌ wrong – formatting inline, bypassing CurrencyService
amount.currencyFormatted(code: currencyService.baseCurrency)
someDouble.currencyFormatted(code: "USD")
```

### 4. SwiftData threading
All `modelContext.save()` calls and SwiftData model mutations must happen on the `@MainActor`.
Unstructured Tasks that perform `await` before touching SwiftData **must** be declared `Task { @MainActor in ... }` so continuations don't hop to a background thread.

### 5. SwiftData relationship children – no explicit `insert`
SwiftData auto-inserts relationship children when appended to a tracked parent.
Never call `modelContext.insert(child)` before `parent.relationship.append(child)` — it causes "Duplicate registration" crashes.

### 6. Net worth recording
Always record net-worth snapshots via the `ModelContext` extension:
```swift
modelContext.recordNetWorthSnapshot(currency: currencyService, at: date)
```
Never compute assets/liabilities manually outside this method.

### 7. No heavy work in View `body`
A View's `body` re-runs every time SwiftUI invalidates the view — frequently, and often without any real data change. Do **not** do any of the following inside `body`:

- Build arrays or call services that compute them
  ```swift
  // ❌ wrong — runs every render
  var body: some View {
      let points = ProjectionService.project(...)
      ...
  }
  ```
- Trigger SwiftData side-effects (`modelContext.projectionSettings()`, `insert`, `save`)
- Loop / reduce over `@Query` results to produce derived data
- Instantiate models or service objects

**Instead**, cache derived data in `@State` (or an `@Observable` ViewModel) and refresh it from lifecycle modifiers. Build a `dataKey` from the observed inputs and pass it to `.task(id:)` so the work runs only when an input actually changes:

```swift
@State private var vm = SomeViewModel()

private var dataKey: Int {
    var hasher = Hasher()
    hasher.combine(horizonYears)
    for account in accounts { hasher.combine(account.currentBalance) }
    return hasher.finalize()
}

var body: some View {
    SummaryCard(points: vm.points)
        .task(id: dataKey) { vm.recalculate(...) }
}
```

`body` reads already-computed state; it never produces it. SwiftData and Observation will trigger re-renders when any tracked field changes, and `.task(id:)` will refire the recalculation.

### 8. Compose; don't duplicate
When two views or services share logic — same hash, same pipeline, same lifecycle — extract it. Prefer, in roughly this order:

- **Static helpers on a ViewModel / service** for pure functions
  ```swift
  // ✅ one source of truth
  ProjectionViewModel.dataKey(accounts:settings:horizonYears:baseCurrency:)
  ```
  not the same `var dataKey: Int { var hasher = Hasher(); ... }` block copy-pasted into every view.
- **Shared `@Observable` ViewModel** so each call site reads from the same computed state instead of recomputing it themselves.
- **`ViewModifier`** when more than one view applies the same chain of lifecycle modifiers (`.onAppear { ... }.task(id: ...) { ... }`). Give it a name that states intent: `.projectionData(...)`, not `.commonStuff(...)`.
- **Subview composition** — split a view into named subviews (`ProjectionSummaryCard`, `ProjectionChartCard`) and reuse those, instead of inlining the same `VStack { ... }.padding().background(...)` structure.

Heuristic: if you find yourself copying ten lines from another file, **stop and factor**.

## Performance

### Cache heavy `Foundation` objects
`NumberFormatter`, `DateFormatter`, `ISO8601DateFormatter`, `JSONEncoder/Decoder` are all expensive to instantiate (~1–2ms each on modern devices) and are typically called many times per render across `ForEach` rows. Always cache them keyed by their configuration — see `CurrencyFormatterCache` in `Models.swift` for the pattern.

Symptom of a missing cache: "Hang detected: 0.2s+" in the console when tapping a text field, scrolling a list, or first-rendering a screen with many formatted values. Always cache before adding a new formatter.

## UI conventions

### Card backgrounds
Screens use `Color(.systemGroupedBackground)`. Cards on top of those screens **must** use `Color(.secondarySystemGroupedBackground)`, not `.background` (which resolves to `systemBackground` = pure black in dark mode and disappears against the dark-gray screen).

```swift
// ✅ correct
.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

// ❌ wrong — invisible card in dark mode
.background(.background, in: RoundedRectangle(cornerRadius: 16))
```

For a nested card (a card inside a card), step further to `tertiarySystemGroupedBackground`.

## Key Patterns

### CurrencyService API
```swift
// Initializers
init()                                              // production: loads UserDefaults cache, fetches on demand
init(baseCurrency: String, rates: [String: Double]) // tests: inject rates, no network/UserDefaults

// Arithmetic
func toBase(_ amount: Double, currency: String) -> Double
func convert(_ amount: Double, from: String, to: String) -> Double
func convert(_ money: Money, to currency: String) -> Money
func sum(_ amounts: [Money], in target: String) -> Money

// Formatting (always use these — never format inline)
func formatted(_ money: Money) -> String
func formattedBase(_ amount: Double) -> String
```

### TickerService threading
`fetch(context:currency:)` and `fetchIfNeeded(context:currency:)` are both `@MainActor` to satisfy Swift 6 Sendability requirements for `ModelContext`.

### History / chart data flow
- `DashboardViewModel.stackedHistoryData(from:currency:)` — per-category stacked area chart data from `BalanceSnapshot`; always appends today using live `account.currentBalance`
- `DashboardViewModel.accountHistoryEntries(from:currency:)` — per-date list of all accounts with carry-forward values; always includes today as a read-only live entry
- Both use "most recent snapshot on or before the date" (carry-forward) so every account appears on every date
- Today's entry is always synthetic (no `BalanceSnapshot`), uses live `currentBalance`, and is read-only

### History navigation flow
1. `NetWorthHistoryView` — list of dates with total net worth; "+" opens `AddHistoricalEntryView`
2. Tap a date → `HistoryDayDetailView` — per-account rows; today's entry is read-only
3. `AccountBalanceHistoryView` — per-account snapshot list; tap to edit via `EditBalanceSnapshotView`
4. `AddHistoricalEntryView` — bulk entry for all accounts on a selected past date; pre-fills with carry-forward balances

### Net worth projection
- `ProjectionSettings` (`@Model`, singleton) — per-category annual growth rates, liability paydown years, monthly income & expenses, persisted horizon choice. Fetch/create via `modelContext.projectionSettings()`.
- `ProjectionService.project(over:accounts:settings:currency:)` — pure function, returns `[ProjectionPoint]` at monthly granularity. Standard annuity formula per asset category: `FV = PV * (1+r)^t + PMT * ((1+r)^t − 1)/r`. V2 routes net monthly savings (income − expenses) into Investments as the PMT stream; negative net drains investments. Other categories pure-grow. Liabilities amortise linearly to zero. Values floor at 0.
- `ProjectionView` — horizon picker (1/5/10/20/30y), summary card with cash-flow subtitle, stacked-area chart with net worth line, per-category breakdown, "Assumptions" sheet for editing rates and monthly cash flow.
- Dashboard `ProjectionTeaserCard` shows the projected value at the saved horizon and navigates to the full view.

### Pull-to-refresh
Wrapped in `Task { @MainActor in }` to avoid `-999 NSURLErrorDomain cancelled` from SwiftUI's cooperative cancellation propagating into URLSession.

### Previews
`ModelContainer.previewContainer` — in-memory, pre-seeded with mock accounts and snapshots. Used in all `#Preview` blocks.
`ModelContainer.appContainer` — production CloudKit-backed container, used only in `NetWorthApp.swift`.

## Roadmap

### Remaining Phase 1
- 🔜 **Biometric lock** — `LocalAuthentication`, quick to add

### Phase 2 (after MVP ships)
- Plaid Link integration — **requires a Supabase backend** (access tokens must never live on-device; backend handles token exchange)
- Background refresh via `BGAppRefreshTask`
- Push notifications for large balance changes
- Real estate value estimates (Redfin/Attom API)
- **"In case of…" estate vault** — per-account important info (account number, portal URL, customer service phone, login username, joint owner, beneficiary, document location, free-form notes) plus an aggregate "Estate Vault" screen that can be exported to PDF and handed to a trusted contact. New `@Model AccountInfo` with 1:1 relationship to `Account`. V1 = per-account form + aggregate view; V2 = PDF export; V3 = optional CryptoKit field-level encryption gated behind biometric.

### Phase 3
- Debt payoff simulator (avalanche vs snowball)
- Asset allocation targets + drift alerts
- CSV / PDF export
