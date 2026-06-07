import Foundation
import SwiftUI
import Vision
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Statement scanner
//
// Pull an account screenshot apart into structured fields the Add Account form
// can pre-fill. Two-stage pipeline:
//   1. `VNRecognizeTextRequest` runs OCR on the image and returns a flat block
//      of text. Works on every iOS 18+ device.
//   2. The OCR text is handed to Apple's on-device language model
//      (`FoundationModels`, iOS 26+) with a `@Generable` schema that pins down
//      the fields we care about — institution, account name, balance,
//      currency, type, and (for brokerage) a holdings list.
//
// Everything runs on-device. Nothing leaves the phone — same privacy promise
// as the rest of the app.
//
// On iOS 18.2–25.x the scanner reports `.unsupportedDevice` and the caller
// hides the entry point. We deliberately don't ship a heuristic fallback —
// half-working OCR parsing across hundreds of bank layouts is worse than not
// having the feature at all.

@MainActor
@Observable
final class StatementScanner {

    // MARK: - Availability

    enum Availability: Equatable {
        case available
        /// iOS is too old (< 26) or device hardware can't run Apple Intelligence.
        case unsupportedDevice
        /// OS / hardware are fine but Apple Intelligence is toggled off in Settings.
        case appleIntelligenceDisabled
        /// Model is downloading or otherwise temporarily unready.
        case preparing(reason: String)
        /// Catch-all when the framework reports an unfamiliar reason.
        case otherUnavailable(reason: String)

        var isReady: Bool {
            if case .available = self { return true }
            return false
        }
    }

    enum ScanError: LocalizedError {
        case ocrFailed
        case modelUnavailable
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .ocrFailed:
                return "Couldn't read text from this image. Try a clearer screenshot."
            case .modelUnavailable:
                return "On-device scanning isn't available on this device."
            case .extractionFailed(let detail):
                return "Couldn't pull account details from the screenshot. \(detail)"
            }
        }
    }

    /// Parsed result, normalised to types that drop straight into the form.
    /// Every field is optional because real screenshots vary wildly — let the
    /// view decide which blanks to leave for the user to fill in.
    struct Extracted {
        var institution: String?
        var accountName: String?
        var currency: String?       // ISO 4217
        var accountType: AccountType?
        var totalBalance: Double?   // headline balance on the page
        var cashBalance: Double?    // brokerage cash / settlement
        var holdings: [Holding]

        struct Holding {
            var tickerSymbol: String
            var quantity: Double
            var lastPrice: Double?
            var priceCurrency: String?
        }
    }

    private(set) var availability: Availability = .unsupportedDevice

    init() {
        availability = Self.computeAvailability()
    }

    // MARK: - Public entry point

    /// Run OCR + structured extraction on a single image. Throws if either
    /// stage fails; partial results aren't surfaced — callers either get a
    /// full `Extracted` (with optionals where the model couldn't decide) or
    /// an error they can show in the UI.
    func scan(image: UIImage) async throws -> Extracted {
        let text = try await runOCR(on: image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScanError.ocrFailed
        }
        return try await runExtraction(on: text)
    }

    // MARK: - Stage 1: OCR via Vision

    private func runOCR(on image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { throw ScanError.ocrFailed }

        // `VNImageRequestHandler.perform` is synchronous and CPU-bound. Run
        // it on a background queue so the main actor stays responsive (the
        // spinner keeps animating, etc.).
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { req, err in
                    if let err {
                        cont.resume(throwing: err)
                        return
                    }
                    let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                    // One line per observation, top candidate only. Keep the
                    // original order so the model can reason about layout.
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    cont.resume(returning: lines.joined(separator: "\n"))
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Stage 2: structured extraction

    private func runExtraction(on ocrText: String) async throws -> Extracted {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await runFoundationModelsExtraction(on: ocrText)
        }
        #endif
        throw ScanError.modelUnavailable
    }

    // MARK: - Availability check

    private static func computeAvailability() -> Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let raw = SystemLanguageModel.default.availability
            // Logged so we can see in the Xcode console why the scanner is
            // greyed out — much faster to debug than guessing.
            print("[StatementScanner] FoundationModels availability: \(raw)")
            switch raw {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unsupportedDevice
                case .appleIntelligenceNotEnabled:
                    return .appleIntelligenceDisabled
                case .modelNotReady:
                    return .preparing(reason: "Apple Intelligence model is downloading")
                @unknown default:
                    return .otherUnavailable(reason: "\(reason)")
                }
            @unknown default:
                return .otherUnavailable(reason: "\(raw)")
            }
        }
        #endif
        return .unsupportedDevice
    }
}

// MARK: - FoundationModels-only code path
//
// Kept in its own `@available` extension so the rest of the file builds on
// iOS 18.2 without conditional compilation everywhere.

#if canImport(FoundationModels)
@available(iOS 26.0, *)
extension StatementScanner {

    @Generable
    struct ExtractedAccountSchema {
        @Guide(description: "Bank or brokerage name shown on the page. Leave null if not clearly visible.")
        let institution: String?

        @Guide(description: "Specific account name or label, e.g. 'Premier Saver', 'Everyday Checking', 'Roth IRA'. Leave null if only the bank name is shown.")
        let accountName: String?

        @Guide(description: "ISO 4217 currency code (USD, GBP, EUR, JPY, etc). Map symbols when context is clear: $→USD, £→GBP, €→EUR, ¥→JPY. Null if uncertain.")
        let currency: String?

        @Guide(description: "Account category. Must be one of exactly: checking, savings, brokerage, pension, realEstate, mortgage, creditCard, loan. Pick from page cues — 'savings' on the page → savings; credit limit + statement balance → creditCard; 'IRA'/'401k'/'pension' → pension. Null if uncertain.")
        let accountType: String?

        @Guide(description: "Headline balance on the page. For cash accounts this is the current balance; for brokerage this is the portfolio value. Numeric only — no symbols, no thousands separators.")
        let totalBalance: Double?

        @Guide(description: "Cash / settlement balance shown on a brokerage page, if any. Numeric only.")
        let cashBalance: Double?

        @Guide(description: "Holdings list. Populate only for brokerage / pension pages that show individual positions. Leave empty array for cash accounts.")
        let holdings: [ExtractedHoldingSchema]
    }

    @Generable
    struct ExtractedHoldingSchema {
        @Guide(description: "Ticker symbol exactly as shown (e.g. AAPL, VWRP.L, BRK.B).")
        let tickerSymbol: String

        @Guide(description: "Number of shares or units held. Numeric only.")
        let quantity: Double

        @Guide(description: "Last price per share if visible. Numeric only, no currency symbols.")
        let lastPrice: Double?

        @Guide(description: "ISO 4217 currency for the price (USD, GBP, EUR…). Null if uncertain.")
        let priceCurrency: String?
    }

    func runFoundationModelsExtraction(on ocrText: String) async throws -> Extracted {
        let instructions = """
        You extract account details from OCR text of a single bank or brokerage \
        screenshot. The text is noisy — layout artefacts from columns, mixed \
        units, currency symbols glued to numbers.

        Rules:
        - When a field is unclear or absent, return null. Never invent values.
        - Strip currency symbols, commas, and units from numbers.
        - `accountType` must be one of: checking, savings, brokerage, pension, \
          realEstate, mortgage, creditCard, loan. Pick from visual / textual cues.
        - For brokerage pages, populate `holdings` with each visible position. \
          For cash pages, return an empty array.
        - `totalBalance` is the headline balance (current balance for cash, \
          portfolio value for brokerage).
        """

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: "Extract account details from this screenshot text:\n\n\(ocrText)",
                generating: ExtractedAccountSchema.self
            )
            return normalise(response.content)
        } catch {
            throw ScanError.extractionFailed(error.localizedDescription)
        }
    }

    private func normalise(_ raw: ExtractedAccountSchema) -> Extracted {
        Extracted(
            institution: raw.institution?.trimmedNonEmpty,
            accountName: raw.accountName?.trimmedNonEmpty,
            currency: raw.currency.flatMap(normaliseCurrencyCode),
            accountType: raw.accountType.flatMap { AccountType(rawValue: $0.trimmingCharacters(in: .whitespaces)) },
            totalBalance: raw.totalBalance,
            cashBalance: raw.cashBalance,
            holdings: raw.holdings.map { h in
                Extracted.Holding(
                    tickerSymbol: h.tickerSymbol.trimmingCharacters(in: .whitespaces).uppercased(),
                    quantity: h.quantity,
                    lastPrice: h.lastPrice,
                    priceCurrency: h.priceCurrency.flatMap(normaliseCurrencyCode)
                )
            }
        )
    }

    /// Force-uppercase and only accept codes we actually support. Anything
    /// else falls through to `nil` so the form falls back to whatever the
    /// user had selected.
    private func normaliseCurrencyCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        return Currency.allCases.contains(where: { $0.rawValue == code }) ? code : nil
    }
}
#endif

// MARK: - Helpers

private extension String {
    /// Trim whitespace and return nil if empty. Saves writing the same
    /// `trim`-and-test pattern at every assignment site.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
