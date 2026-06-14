# AssetRack – Claude Context

## Project Overview
AssetRack is an iOS Net Worth Tracker — a personal finance app for tracking **net worth across multiple accounts in one place**, with insights and projections. The core value is a single unified view of assets and liabilities rather than logging into multiple apps.

**GitHub:** `git@github.com:kshdeo/AssetRack.git`
**Home-screen name:** Assets Rack
**Phase 1 status:** ✅ Complete and uncommitted (biometric lock was the final item)

## Architecture
- **Models** – `Account`, `Holding`, `BalanceSnapshot`, `NetWorthSnapshot`, `ProjectionSettings` (`@Model`)
- **Services** – `CurrencyService` (FX rates, currency arithmetic, formatting), `TickerService` (Yahoo Finance + Tradegate prices), `ISINLookupService` (Finnhub + Tradegate search, live price preview), `ProjectionService` (pure-growth net worth projection), `StatementScanner` (OCR + Apple Intelligence structured extraction from bank screenshots, iOS 26+), `BiometricLockService` (LocalAuthentication-based app lock)
- **ViewModels** – `DashboardViewModel` (`@Observable`) computes chart/history data
- **Views** – `DashboardView`, `AccountsListView`, `AccountRow`, `AddEditAccountView`, `AccountBalanceHistoryView`, `AddHistoricalEntryView`, `SettingsView`, `ProjectionView`, `OnboardingView`, `LockView`
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
- **SwiftData (iOS 18.2+)** — cleaner API than Core Data, native CloudKit sync with minimal boilerplate
- **CloudKit** — free, private, native; via `ModelConfiguration(cloudKitDatabase: .automatic)`
- **`@Observable` + MVVM** — simpler than TCA for this scope, avoids ceremony
- **Swift Charts** — built-in from iOS 16, handles area charts, interactive scrubbing
- **LocalAuthentication** — biometric lock (Face ID / Touch ID / passcode fallback) in `BiometricLockService`
- **Vision + FoundationModels** — `StatementScanner` uses `VNRecognizeTextRequest` for OCR then Apple Intelligence (`FoundationModels`, iOS 26+) for structured extraction. Guarded by `#if canImport(FoundationModels)` + `@available(iOS 26.0, *)` so the rest of the app builds on 18.2.
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
Tracks individual account history. Used for the history chart, per-account detail views, and the carry-forward logic. Always written through `account.setBalanceSnapshot(balance:at:)` — one row per calendar day, upserted in place when the same day is re-saved.

### `NetWorthSnapshot` as a separate model
Don't recompute net worth from all accounts on every render. Records point-in-time history that survives account deletions.

### Default values on all `@Model` properties
Required by CloudKit — forgetting this causes silent sync failures.

### Backup format versioning
`AppBackup` carries a `version: Int` field:
- **v1** — accounts + holdings + currentBalance only
- **v2** — adds `balanceHistory`, `netWorthSnapshots`, `projectionSettings`, plus previously-missing holding fields (`previousClose`, `priceSourceRaw`, `isin`, `name`, `lastPriceFetchedAt`)

New fields are added as `Optional` so older backups decode cleanly without migration.

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
// ❌ wrong — formatting inline, bypassing CurrencyService
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
- **Shared `@Observable` ViewModel** so each call site reads from the same computed state instead of recomputing it themselves.
- **`ViewModifier`** when more than one view applies the same chain of lifecycle modifiers.
- **Subview composition** — split a view into named subviews and reuse those.

Heuristic: if you find yourself copying ten lines from another file, **stop and factor**.

### 9. Do not run the build — the user runs it
**Never invoke `xcodebuild` or any iOS build/run/test command.** The user builds and runs the app themselves in Xcode and reports back. Don't try to "verify" a change by compiling it yourself; trust the diff and let the user catch issues at runtime.

This avoids redundant DerivedData churn, slow round-trips, and scheme/signing prompts that don't apply when the user is driving Xcode directly.

### 10. Always write balance snapshots through `setBalanceSnapshot`
All callsites that write a manual account's balance (save, historical entry, import) must use:
```swift
account.setBalanceSnapshot(balance: balance, at: date)
```
This enforces one snapshot per calendar day (upsert semantics) and is the single source of truth for history deduplication. Never append a `BalanceSnapshot` directly to `account.balanceHistory`.

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

### BiometricLockService
`@Observable @MainActor` singleton injected at the App level:
```swift
// AssetRackApp
let lockService = BiometricLockService()
// ...
ContentView().environment(lockService)
```
`ContentView` calls `lockService.lockIfEnabled()` in `.onChange(of: scenePhase)` when the app moves to `.background`, and applies `.lockOverlay(lockService)`. The lock screen is presented in a **separate top-level `UIWindow`** (`LockOverlay.swift`, `LockWindowManager`) at `.alert` level — NOT by swapping ContentView's root. This is deliberate: a root swap tears down any open `.sheet` (e.g. the Add Account form) and all its in-progress state; the overlay window floats above the main window and any sheets, so unlocking reveals the app exactly where the user left it. `LockView` fills the window with an opaque background and auto-triggers `authenticate()` via `.task` on appear. Settings reads the service from environment to toggle `isEnabled`.

### StatementScanner
Two-stage pipeline, iOS 26+ only:
1. `VNRecognizeTextRequest` runs OCR on a `UIImage` (background thread via `withCheckedThrowingContinuation`)
2. `FoundationModels.LanguageModelSession` extracts structured fields (`@Generable ExtractedAccountSchema`) from the raw text

`AddEditAccountView` shows the scanner entry point via `PhotosPicker` in the "add" flow only. The picker writes to `pendingScanItem`; a `.task(id: pendingScanItem)` reacts and calls `performScan(_:)`, which merges results into the form without overwriting already-filled fields. The entry point is always visible but disabled with an explanatory subtitle when Apple Intelligence isn't available.

### TickerService threading
`fetch(context:currency:)` and `fetchIfNeeded(context:currency:)` are both `@MainActor` to satisfy Swift 6 Sendability requirements for `ModelContext`.

### ModelContext helpers
```swift
// Record a net worth snapshot (call after any balance change)
modelContext.recordNetWorthSnapshot(currency: currencyService, at: date)

// Repair accounts whose currentBalance drifted from their latest snapshot
// (call after snapshot mutations and on dashboard load)
modelContext.reconcileAccountBalances()

// Collapse any multi-snapshot days to one row per day (idempotent)
modelContext.consolidateAllDailyHistory()
```

### Balance snapshot upsert
```swift
// One row per calendar day — re-saves the same day update in place
account.setBalanceSnapshot(balance: balance, at: date)
```

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
`ModelContainer.appContainer` — production CloudKit-backed container, used only in `AssetRackApp.swift`.

## Roadmap

### Phase 1 — ✅ Complete (not yet pushed to origin)
All items shipped. The two unpushed commits on `main` plus the current working-tree changes (biometric lock, StatementScanner, scan-statement in AddEditAccountView) constitute the complete MVP.

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
