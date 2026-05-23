import Testing
@testable import AssetRack

// Base currency: GBP
// Rates stored as "how many X per 1 GBP":
//   USD = 1.27  →  1 GBP = 1.27 USD
//   EUR = 1.17  →  1 GBP = 1.17 EUR
//
// Conversions:
//   GBP → USD : amount * 1.27
//   USD → GBP : amount / 1.27
//   USD → EUR : (amount / 1.27) * 1.17

private let testRates: [String: Double] = ["USD": 1.27, "EUR": 1.17]

private func makeSUT() -> CurrencyService {
    CurrencyService(baseCurrency: "GBP", rates: testRates)
}

// MARK: - toBase

@Suite("toBase")
struct ToBaseTests {
    @Test func sameCurrencyReturnsUnchanged() {
        let sut = makeSUT()
        #expect(sut.toBase(100, currency: "GBP") == 100)
    }

    @Test func convertsKnownCurrencyToBase() {
        let sut = makeSUT()
        // 127 USD / 1.27 = 100 GBP
        #expect(sut.toBase(127, currency: "USD") == 100)
    }

    @Test func unknownCurrencyFallsBackToAmount() {
        let sut = makeSUT()
        // No rate for JPY — returns the amount unchanged
        #expect(sut.toBase(5000, currency: "JPY") == 5000)
    }
}

// MARK: - convert (Double)

@Suite("convert Double")
struct ConvertDoubleTests {
    @Test func sameCurrencyIsIdentity() {
        let sut = makeSUT()
        #expect(sut.convert(200, from: "GBP", to: "GBP") == 200)
    }

    @Test func baseToForeign() {
        let sut = makeSUT()
        // 100 GBP * 1.27 = 127 USD
        #expect(sut.convert(100, from: "GBP", to: "USD") == 127)
    }

    @Test func foreignToBase() {
        let sut = makeSUT()
        // 127 USD / 1.27 = 100 GBP
        #expect(sut.convert(127, from: "USD", to: "GBP") == 100)
    }

    @Test func foreignToForeign() {
        let sut = makeSUT()
        // 127 USD → 100 GBP → 117 EUR
        #expect(sut.convert(127, from: "USD", to: "EUR").isApproximately(117))
    }

    @Test func unknownFromCurrencyFallsBack() {
        let sut = makeSUT()
        // No rate for JPY: toBase returns amount as-is, then convert to USD
        // 1000 "GBP equivalent" * 1.27 = 1270 USD
        #expect(sut.convert(1000, from: "JPY", to: "USD") == 1270)
    }

    @Test func unknownToCurrencyReturnsBase() {
        let sut = makeSUT()
        // No rate for JPY: converts to base only (127 USD → 100 GBP)
        #expect(sut.convert(127, from: "USD", to: "JPY") == 100)
    }
}

// MARK: - convert (Money)

@Suite("convert Money")
struct ConvertMoneyTests {
    @Test func returnsMoneySameCurrency() {
        let sut = makeSUT()
        let result = sut.convert(Money(50, "GBP"), to: "GBP")
        #expect(result.amount == 50)
        #expect(result.currency == "GBP")
    }

    @Test func returnsMoneyInTargetCurrency() {
        let sut = makeSUT()
        let result = sut.convert(Money(100, "GBP"), to: "USD")
        #expect(result.amount == 127)
        #expect(result.currency == "USD")
    }
}

// MARK: - sum

@Suite("sum")
struct SumTests {
    @Test func emptyArrayReturnsZero() {
        let sut = makeSUT()
        let result = sut.sum([], in: "GBP")
        #expect(result.amount == 0)
        #expect(result.currency == "GBP")
    }

    @Test func singleSameCurrencyAmount() {
        let sut = makeSUT()
        let result = sut.sum([Money(300, "GBP")], in: "GBP")
        #expect(result.amount == 300)
    }

    @Test func mixedCurrenciesConvertToTarget() {
        let sut = makeSUT()
        // 100 GBP + 127 USD (= 100 GBP) = 200 GBP
        let result = sut.sum([Money(100, "GBP"), Money(127, "USD")], in: "GBP")
        #expect(result.amount.isApproximately(200))
        #expect(result.currency == "GBP")
    }

    @Test func sumsIntoForeignCurrency() {
        let sut = makeSUT()
        // 100 GBP (= 127 USD) + 127 USD = 254 USD
        let result = sut.sum([Money(100, "GBP"), Money(127, "USD")], in: "USD")
        #expect(result.amount.isApproximately(254))
        #expect(result.currency == "USD")
    }

    @Test func negativeAmountsSubtract() {
        let sut = makeSUT()
        // 200 GBP + (-127 USD = -100 GBP) = 100 GBP
        let result = sut.sum([Money(200, "GBP"), Money(-127, "USD")], in: "GBP")
        #expect(result.amount.isApproximately(100))
    }
}

// MARK: - formatting

@Suite("formatting")
struct FormattingTests {
    @Test func formattedMoneyIsNonEmpty() {
        let sut = makeSUT()
        #expect(!sut.formatted(Money(1234, "GBP")).isEmpty)
    }

    @Test func formattedBaseIsNonEmpty() {
        let sut = makeSUT()
        #expect(!sut.formattedBase(9999).isEmpty)
    }

    @Test func formattedMoneyContainsCurrencySymbol() {
        let sut = CurrencyService(baseCurrency: "USD", rates: [:])
        let result = sut.formatted(Money(100, "USD"))
        #expect(result.contains("$") || result.contains("USD"))
    }

    @Test func formattedBaseReflectsBaseCurrency() {
        let sut = CurrencyService(baseCurrency: "USD", rates: [:])
        let result = sut.formattedBase(500)
        #expect(result.contains("$") || result.contains("USD"))
    }
}

// MARK: - Helpers

private extension Double {
    /// Approximate equality for floating-point results (within 0.001).
    func isApproximately(_ other: Double, tolerance: Double = 0.001) -> Bool {
        abs(self - other) < tolerance
    }
}
