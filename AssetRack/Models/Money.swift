import Foundation

/// A currency-aware monetary value.
/// Never add or subtract Money values directly — use CurrencyService.sum().
struct Money: Equatable {
    let amount: Double
    let currency: String

    init(_ amount: Double, _ currency: String) {
        self.amount = amount
        self.currency = currency
    }

    init(_ amount: Double, _ currency: Currency) {
        self.amount = amount
        self.currency = currency.code
    }

    static let zero = Money(0, "USD")

    func formatted() -> String {
        amount.currencyFormatted(code: currency)
    }
}
