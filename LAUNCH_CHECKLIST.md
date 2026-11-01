# Assets Rack — Launch Checklist

v1.0 · `com.blackforestapps.assetsRack` · iOS 18.2+ · iPhone + iPad

Format: `- [ ] [P0] [You] Title` · detail on an indented line · done = `- [x] … (done YYYY-MM-DD)`.
Tags: **[P0]** blocks launch · **[P1]** should fix · **[You]** needs you (portal, account, device).

## Followups

- [ ] [P0] [You] Revoke the hardcoded Finnhub fallback key on finnhub.io
  - It's in git history at commit `63c787e` (`ISINLookupService.swift:25`); removing it from code isn't enough.
- [ ] [P0] Remove the Finnhub fallback key from code
  - Require a user-supplied key, or route search through a proxy you control.
- [ ] [P1] Fix Settings footer copy
  - `SettingsView.swift:116` says the key is for Tradegate; it's actually used for Yahoo search, and the copy implies it's required.
- [ ] [P1] Verify "No Finnhub API key configured" messaging
  - `ISINLookupService.swift:229` becomes reachable once the fallback is gone; the user should see a helpful prompt, not a dead end.
- [ ] [You] Delete local branch `backup/main-pre-rebase`
  - Only once rebased main is confirmed good.
- [ ] [P0] [You] Xcode build + run of current main
  - Rebased, not yet built.
- [ ] [You] Create an App Store Connect API key
  - For scripting Xcode Cloud workflow edits via the `ciWorkflows` API.
- [ ] [You] Set up Firebase
  - Create project → Blaze plan + budget alert → register iOS app → enable App Attest in App Check → set `FINNHUB_API_KEY` secret → deploy `functions/` → add `GoogleService-Info.plist` to `AssetRack/` and commit it (BUNDLE_ID `com.blackforestapps.assetsRack`; restrict its API key to that bundle ID).
- [ ] Enable `statement_scan_enabled` in Remote Config
  - Once bank statement scanning is ready (default is off).

## Data safety & persistence

- [ ] [P0] Replace the "wipe store on schema mismatch" fallback
  - `AssetRackApp.swift:15–27` deletes the SwiftData store if it fails to open: silent total data loss after an update. Add a `VersionedSchema` + `SchemaMigrationPlan`; on failure, show an error rather than delete.
- [ ] [P0] Decide on iCloud sync for v1
  - CLAUDE.md says CloudKit via `cloudKitDatabase: .automatic`, but the production `ModelConfiguration` doesn't set it and `AssetRack.entitlements` has no iCloud container. Enable it (container, entitlement, deploy schema to Production) or ship local-only and update the docs.
- [ ] [P0] [You] Upgrade test: install previous TestFlight build, add data, upgrade to new build
- [ ] [P1] [You] Backup export → delete app → reinstall → import round-trip
  - Check v1 and v2 `AppBackup` files both restore, including cost basis and history.
- [ ] [P1] CSV import with malformed rows, odd number formats and unknown currencies
  - Use `samples/assetrack-import-sample.csv` plus edge cases (comma decimal, blank cells, huge file).

## Privacy & security

- [ ] [P0] Add `PrivacyInfo.xcprivacy` to the app and widget targets
  - Required-reason APIs in use: `UserDefaults` (incl. App Group suite), likely file timestamp/disk APIs. Declare no tracking.
- [ ] [P0] Strip or `#if DEBUG` the logging of financial data
  - `StatementScanner` prints full OCR text of bank screenshots; `TickerService` logs holdings and prices. Use `Logger` with `.private` or debug-only.
- [ ] [P0] [You] Write and host a privacy policy; link it from Settings
  - Name the third parties contacted: Yahoo Finance, Tradegate, Finnhub (via Firebase proxy), Firebase (App Check, Remote Config), frankfurter.app.
- [ ] [P0] [You] Fill in the App Privacy "nutrition label" in App Store Connect
  - Likely "Data Not Collected" if nothing leaves the device except market lookups; confirm, including Firebase.
- [ ] [P1] [You] Biometric lock: test Face ID off, passcode only, failed attempts, backgrounding during an open sheet
- [ ] [P1] Hide balances in the app switcher snapshot when lock is enabled
- [ ] [P1] Widget shows net worth on the lock screen; consider a privacy/redaction option

## Third-party data sources

- [ ] [P1] Review the Yahoo Finance dependency
  - Unofficial endpoints (cookie + crumb) can break at any time and may conflict with their terms. Have a graceful fallback.
- [ ] [P1] Same review for Tradegate scraping (`refresh.php`, `kurssuche.php`)
- [ ] [P0] [You] Offline / airplane-mode pass
  - Dashboard, add account, pull-to-refresh, FX with a cold cache: no hangs, no crashes, clear messaging.
- [ ] [P1] Remove force-unwrapped `URL(string:)!` where the string is interpolated
  - e.g. `TickerService.swift:136`, `ISINLookupService.swift:40,191,203`, `CurrencyService.swift:51`.
- [ ] [P1] Rate-limit/backoff behaviour on 401/429

## Stability & edge cases

- [ ] [P1] Replace `task as! BGAppRefreshTask` with a safe cast
  - `BackgroundRefreshService.swift:10`.
- [ ] [P1] [You] Verify background refresh runs
  - Debugger: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.blackforestapps.assetsRack.widgetRefresh"]`
- [ ] [P0] [You] Empty state: fresh install, no accounts — every screen
  - Dashboard, history, projection, widget.
- [ ] [P1] [You] Large data: 50+ accounts, 3+ years of daily history
  - Watch for "Hang detected" warnings.
- [ ] [P1] [You] Multi-currency: base currency change mid-use, unsupported currency codes
- [ ] [P1] [You] Statement scanner on a non-Apple-Intelligence device shows disabled state
- [ ] [P1] [You] Dark mode, Dynamic Type (largest sizes), VoiceOver pass on key screens
- [ ] [P1] [You] Run the unit + UI test suites in Xcode
- [ ] Fix any Xcode warnings / consider Swift 6 language mode
  - Currently `SWIFT_VERSION = 5.0`.

## Build & project settings

- [ ] [P0] Decide on iPad
  - `TARGETED_DEVICE_FAMILY = 1,2` means iPad screenshots and iPad layout review. Drop to iPhone-only if not ready.
- [ ] [P1] Align build numbers
  - `CURRENT_PROJECT_VERSION` is 1 in some configs and 2 in others; app and widget must match.
- [ ] Set `NSHumanReadableCopyright`
  - Currently empty.
- [ ] [P1] Fix widget display name
  - Shows as "AssetsRackWidget".
- [ ] [P1] [You] App icon and widget icon checked at all sizes, light/dark/tinted
- [ ] Remove `.DS_Store` files from the repo and gitignore them
- [ ] [P0] [You] Archive a Release build and validate in Organizer

## App Store Connect

- [ ] [P0] [You] Create the app record (name, bundle ID, SKU, primary language)
  - Confirm "Assets Rack" is available as the store name.
- [ ] [P0] [You] Register App Group `group.blackforestapps.assetsRack` and widget bundle ID in the developer portal
- [ ] [P0] [You] Screenshots: 6.9" iPhone (and 13" iPad if keeping iPad)
- [ ] [P0] [You] Description, subtitle, keywords, promotional text
- [ ] [P0] [You] Support URL and marketing URL
- [ ] [P0] [You] Age rating questionnaire
- [ ] [P0] [You] Category: Finance; pricing and availability
- [ ] Export compliance
  - `ITSAppUsesNonExemptEncryption = NO` is already set.
- [ ] [P0] Implement a Demo mode for App Review
  - One-tap "Try with sample data" (onboarding and Settings) with sample accounts, holdings, history and projections; no real credentials, API key or live APIs (stub prices/FX). Isolated from real data; no widget or backup writes.
- [ ] [P1] [You] Review notes: no login, no account linking, data stays on-device; how to enter Demo mode; how to test the scanner
  - Spell out the exact taps to reach Demo mode.
- [ ] [P1] Add a disclaimer: not financial advice; projections are estimates

## TestFlight

- [ ] [P0] [You] Upload first build to TestFlight
- [ ] [P0] [You] Internal testing on at least two physical devices
- [ ] [You] External beta (requires Beta App Review)
- [ ] [P1] [You] Collect feedback, triage crashes from Xcode Organizer

## Launch day & after

- [ ] [P0] [You] Submit for review
- [ ] [You] Tag the release in git (`v1.0`) and push
- [ ] [You] Monitor crashes and reviews for the first week
- [ ] Update CLAUDE.md to match reality (CloudKit, test counts, Phase 1 status)
