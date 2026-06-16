import Foundation
import SwiftData

// MARK: - CSV account/holdings importer
//
// Parses a single CSV where each data row is EITHER an account or a holding —
// inferred from which columns carry values:
//   * a row with a `symbol`/`ticker` value is a HOLDING
//   * any other row with a name/type/balance is an ACCOUNT
//
// Holdings attach to a parent account by the `account`/`name` column when
// present; otherwise to the most recent account row above them (hierarchical
// layout). A holding that references an account not otherwise defined creates
// an implicit brokerage account, so a positions-only export still works.
//
// Recognised headers (case-insensitive, flexible aliases):
//   name | account | account name      → account name / holding's parent
//   type | account type | kind         → checking, savings, brokerage, …
//   institution | bank | broker        → institution
//   currency | ccy                     → ISO 4217 currency
//   balance | amount | value           → cash account balance
//   symbol | ticker                    → holding ticker
//   quantity | qty | shares | units    → holding quantity
//   price | last price                 → holding price per share
//   price currency                     → holding price currency (falls back to currency)
//   isin                               → holding ISIN (implies Tradegate source)
//   source | price source              → yahoo | tradegate
//
// The import is ADDITIVE — it appends accounts and holdings, it never deletes
// existing data (unlike the JSON backup restore).

enum CSVImportError: LocalizedError {
    case empty
    case noDataRows
    case noRecognisedColumns

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The file is empty."
        case .noDataRows:
            return "The file has a header but no data rows."
        case .noRecognisedColumns:
            return "No recognised columns found. Expected headers like name, type, balance, or symbol, quantity."
        }
    }
}

struct CSVImportResult {
    struct ParsedHolding {
        var tickerSymbol: String
        var quantity: Double
        var lastPrice: Double
        var priceCurrency: String
        var isin: String
        var priceSource: PriceSource
    }

    struct ParsedAccount {
        var name: String
        var type: AccountType
        var institution: String
        var currency: String
        var balance: Double
        var holdings: [ParsedHolding]
    }

    var accounts: [ParsedAccount]
    var warnings: [String]

    var accountCount: Int { accounts.count }
    var holdingCount: Int { accounts.reduce(0) { $0 + $1.holdings.count } }
}

enum CSVAccountImporter {

    // MARK: - Public API

    /// Parse CSV text into a structured, not-yet-persisted result. Pure — does
    /// no SwiftData work, so it's easy to unit-test and safe to call off the
    /// main actor. `defaultCurrency` fills in rows that omit a currency.
    static func parse(_ text: String, defaultCurrency: String) throws -> CSVImportResult {
        let rows = tokenize(text)
        guard let headerRow = rows.first(where: { !isBlank($0) }) else {
            throw CSVImportError.empty
        }
        let columns = ColumnMap(header: headerRow)
        guard columns.hasAnyRecognised else { throw CSVImportError.noRecognisedColumns }

        let headerIndex = rows.firstIndex(where: { !isBlank($0) })!
        let dataRows = rows[(headerIndex + 1)...].filter { !isBlank($0) }
        guard !dataRows.isEmpty else { throw CSVImportError.noDataRows }

        var accounts: [CSVImportResult.ParsedAccount] = []
        var indexByName: [String: Int] = [:]      // lowercased name → accounts index
        var lastAccountIndex: Int?
        var warnings: [String] = []

        func ensureImplicitAccount(named rawName: String) -> Int {
            let key = rawName.lowercased()
            if let existing = indexByName[key] { return existing }
            let acc = CSVImportResult.ParsedAccount(
                name: rawName, type: .brokerage, institution: "",
                currency: defaultCurrency, balance: 0, holdings: []
            )
            accounts.append(acc)
            let idx = accounts.count - 1
            indexByName[key] = idx
            lastAccountIndex = idx
            return idx
        }

        for (offset, row) in dataRows.enumerated() {
            let lineNo = offset + 1
            let symbol = columns.value(.symbol, in: row)?.trimmingCharacters(in: .whitespaces) ?? ""

            if !symbol.isEmpty {
                // ----- Holding row -----
                let qty = columns.number(.quantity, in: row) ?? 0
                let price = columns.number(.price, in: row) ?? 0
                let isin = columns.value(.isin, in: row)?.trimmingCharacters(in: .whitespaces) ?? ""
                let priceCcy = columns.value(.priceCurrency, in: row)?.uppercased()
                    ?? columns.value(.currency, in: row)?.uppercased()
                    ?? defaultCurrency
                let source = parseSource(columns.value(.source, in: row), isin: isin)

                let holding = CSVImportResult.ParsedHolding(
                    tickerSymbol: symbol.uppercased(),
                    quantity: qty,
                    lastPrice: price,
                    priceCurrency: priceCcy,
                    isin: isin,
                    priceSource: source
                )

                // Resolve parent: explicit name column → that account; else the
                // most recent account row; else a default container.
                let parentName = columns.value(.name, in: row)?.trimmingCharacters(in: .whitespaces)
                let idx: Int
                if let parentName, !parentName.isEmpty {
                    idx = ensureImplicitAccount(named: parentName)
                } else if let last = lastAccountIndex {
                    idx = last
                } else {
                    idx = ensureImplicitAccount(named: "Imported Holdings")
                }

                // A holding forces its parent to be holdings-capable.
                if !accounts[idx].type.supportsHoldings {
                    warnings.append("Line \(lineNo): '\(accounts[idx].name)' had holdings, so its type was set to Brokerage.")
                    accounts[idx].type = .brokerage
                }
                accounts[idx].holdings.append(holding)

            } else {
                // ----- Account row -----
                let name = columns.value(.name, in: row)?.trimmingCharacters(in: .whitespaces) ?? ""
                let typeRaw = columns.value(.type, in: row)
                guard !name.isEmpty || typeRaw != nil else {
                    warnings.append("Line \(lineNo): skipped — no symbol and no account name/type.")
                    continue
                }
                let type = parseType(typeRaw) ?? .checking
                let account = CSVImportResult.ParsedAccount(
                    name: name.isEmpty ? type.displayName : name,
                    type: type,
                    institution: columns.value(.institution, in: row)?.trimmingCharacters(in: .whitespaces) ?? "",
                    currency: columns.value(.currency, in: row)?.uppercased() ?? defaultCurrency,
                    balance: columns.number(.balance, in: row) ?? 0,
                    holdings: []
                )
                accounts.append(account)
                let idx = accounts.count - 1
                indexByName[account.name.lowercased()] = idx
                lastAccountIndex = idx
            }
        }

        return CSVImportResult(accounts: accounts, warnings: warnings)
    }

    /// Persist a parsed result. Additive: inserts new accounts and holdings,
    /// records a net-worth snapshot, saves once. Must run on the main actor
    /// (SwiftData mutation — Rule #4).
    @MainActor
    static func commit(_ result: CSVImportResult, into context: ModelContext, currency: CurrencyService) {
        for parsed in result.accounts {
            let account = Account(
                name: parsed.name,
                type: parsed.type,
                balance: parsed.type.supportsHoldings ? 0 : parsed.balance,
                institution: parsed.institution,
                currency: parsed.currency
            )
            context.insert(account)

            if parsed.type.supportsHoldings {
                for h in parsed.holdings {
                    // Appending to the tracked parent auto-inserts (Rule #5).
                    let holding = Holding(
                        tickerSymbol: h.tickerSymbol,
                        quantity: h.quantity,
                        priceSource: h.priceSource,
                        isin: h.isin
                    )
                    holding.lastPrice = h.lastPrice
                    holding.priceCurrency = h.priceCurrency
                    account.holdings.append(holding)
                }
                account.recomputeBalance(convert: currency.convert)
            } else {
                // One snapshot per day, through the canonical path (Rule #10).
                account.setBalanceSnapshot(balance: parsed.balance)
            }
        }

        context.recordNetWorthSnapshot(currency: currency)
        try? context.save()
    }

    // MARK: - Column mapping

    private enum Field: CaseIterable {
        case name, type, institution, currency, balance
        case symbol, quantity, price, priceCurrency, isin, source

        /// Lower-cased header aliases that map to this field.
        var aliases: [String] {
            switch self {
            case .name:         return ["name", "account", "account name", "accountname", "account_name"]
            case .type:         return ["type", "account type", "accounttype", "kind", "category"]
            case .institution:  return ["institution", "bank", "provider", "broker", "brokerage"]
            case .currency:     return ["currency", "ccy", "curr"]
            case .balance:      return ["balance", "amount", "value", "current balance", "market value"]
            case .symbol:       return ["symbol", "ticker", "ticker symbol", "tickersymbol"]
            case .quantity:     return ["quantity", "qty", "shares", "units", "no. of shares"]
            case .price:        return ["price", "last price", "unit price", "share price", "cost"]
            case .priceCurrency:return ["price currency", "pricecurrency", "holding currency"]
            case .isin:         return ["isin"]
            case .source:       return ["source", "price source", "exchange", "venue"]
            }
        }
    }

    private struct ColumnMap {
        private var indexByField: [Field: Int] = [:]

        init(header: [String]) {
            let normalised = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            for field in Field.allCases {
                if let idx = normalised.firstIndex(where: { field.aliases.contains($0) }) {
                    indexByField[field] = idx
                }
            }
        }

        /// True if at least one column we can act on was recognised.
        var hasAnyRecognised: Bool {
            indexByField[.name] != nil || indexByField[.type] != nil
                || indexByField[.balance] != nil || indexByField[.symbol] != nil
        }

        func value(_ field: Field, in row: [String]) -> String? {
            guard let idx = indexByField[field], idx < row.count else { return nil }
            let trimmed = row[idx].trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }

        func number(_ field: Field, in row: [String]) -> Double? {
            value(field, in: row).flatMap(parseNumber)
        }
    }

    // MARK: - Parsing helpers

    private static func parseType(_ raw: String?) -> AccountType? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "checking", "current", "chequing", "cheque":        return .checking
        case "savings", "saving", "saver":                       return .savings
        case "brokerage", "investment", "investments",
             "stocks", "shares", "trading", "isa", "gia":        return .brokerage
        case "pension", "retirement", "ira", "401k", "sipp":     return .pension
        case "real estate", "realestate", "property", "home":    return .realEstate
        case "mortgage":                                         return .mortgage
        case "credit card", "creditcard", "credit":              return .creditCard
        case "loan", "debt":                                     return .loan
        default:
            // Last resort: match by enum rawValue / displayName.
            return AccountType.allCases.first {
                $0.rawValue.lowercased() == raw || $0.displayName.lowercased() == raw
            }
        }
    }

    private static func parseSource(_ raw: String?, isin: String) -> PriceSource {
        if let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased() {
            if raw.contains("trade") || raw == "tg" { return .tradegate }
            if raw.contains("yahoo") || raw == "yf" { return .yahooFinance }
        }
        // No explicit source — an ISIN strongly implies the Tradegate path.
        return isin.isEmpty ? .yahooFinance : .tradegate
    }

    /// Lenient numeric parse for CSV cells. CSV comes from an unknown source
    /// locale, so we use the separator-agnostic heuristic rather than the
    /// device-locale parser.
    static func parseNumber(_ raw: String) -> Double? {
        NumberParsing.heuristicNumber(raw)
    }

    // MARK: - CSV tokeniser

    private static func isBlank(_ row: [String]) -> Bool {
        row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Split CSV text into rows of fields, honouring quoted fields, escaped
    /// double-quotes (`""`), and both LF and CRLF line endings.
    private static func tokenize(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let c = nextChar() {
            if inQuotes {
                if c == "\"" {
                    if let n = nextChar() {
                        if n == "\"" { field.append("\"") }      // escaped quote
                        else { inQuotes = false; pending = n }   // closing quote
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    record.append(field); field = ""
                case "\n":
                    record.append(field); rows.append(record)
                    record = []; field = ""
                case "\r":
                    break   // CRLF — the \n will close the record
                default:
                    field.append(c)
                }
            }
        }
        // Flush the trailing field/record (file without a final newline).
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            rows.append(record)
        }
        return rows
    }
}
