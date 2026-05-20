import Foundation

enum Currency: String, CaseIterable, Codable {
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case cad = "CAD"
    case aud = "AUD"
    case chf = "CHF"
    case jpy = "JPY"
    case cny = "CNY"
    case inr = "INR"
    case sgd = "SGD"
    case hkd = "HKD"
    case nzd = "NZD"
    case mxn = "MXN"
    case brl = "BRL"
    case krw = "KRW"
    case sek = "SEK"
    case nok = "NOK"
    case dkk = "DKK"
    case aed = "AED"
    case zar = "ZAR"

    var code: String { rawValue }

    var label: String {
        switch self {
        case .usd: return "USD — US Dollar"
        case .eur: return "EUR — Euro"
        case .gbp: return "GBP — British Pound"
        case .cad: return "CAD — Canadian Dollar"
        case .aud: return "AUD — Australian Dollar"
        case .chf: return "CHF — Swiss Franc"
        case .jpy: return "JPY — Japanese Yen"
        case .cny: return "CNY — Chinese Yuan"
        case .inr: return "INR — Indian Rupee"
        case .sgd: return "SGD — Singapore Dollar"
        case .hkd: return "HKD — Hong Kong Dollar"
        case .nzd: return "NZD — New Zealand Dollar"
        case .mxn: return "MXN — Mexican Peso"
        case .brl: return "BRL — Brazilian Real"
        case .krw: return "KRW — South Korean Won"
        case .sek: return "SEK — Swedish Krona"
        case .nok: return "NOK — Norwegian Krone"
        case .dkk: return "DKK — Danish Krone"
        case .aed: return "AED — UAE Dirham"
        case .zar: return "ZAR — South African Rand"
        }
    }

    var symbol: String {
        Locale.availableIdentifiers
            .map { Locale(identifier: $0) }
            .first { $0.currency?.identifier == rawValue }?
            .currencySymbol ?? rawValue
    }
}
