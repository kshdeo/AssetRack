# AssetRack – Claude Context

## Project Overview
AssetRack is an iOS Net Worth Tracker built with SwiftUI + SwiftData (iOS 17+).

## Architecture
- **Models** – `Account`, `Holding`, `BalanceSnapshot`, `NetWorthSnapshot` (`@Model`)
- **Services** – `CurrencyService` (FX rates, currency arithmetic), `TickerService` (Yahoo Finance prices)
- **ViewModels** – `DashboardViewModel` (`@Observable`) computes chart/history data
- **Views** – `DashboardView`, `AccountsListView`, `AddEditAccountView`, `SettingsView`

## Strict Rules

### 1. All currency arithmetic MUST go through `CurrencyService`
Never add, subtract, or compare monetary amounts from different currencies inline.
Always use:
```swift
// Sum a collection of mixed-currency amounts
currencyService.sum([Money(100, "GBP"), Money(200, "USD")], in: "GBP")

// Convert a single amount
currencyService.convert(Money(amount, currency), to: baseCurrency)
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

## Key Patterns

### History / chart data
- `stackedHistoryData(from:currency:)` — per-category stacked area chart data derived from `BalanceSnapshot`; always includes today using live `currentBalance`
- `accountHistoryEntries(from:currency:)` — per-date list of all accounts with carry-forward values; always includes today
- Both methods use "most recent snapshot on or before the date" (carry-forward) so every account appears on every date

### Pull-to-refresh
Wrapped in `Task { @MainActor in }` to avoid `-999 NSURLErrorDomain cancelled` from SwiftUI's cooperative cancellation propagating into URLSession.
