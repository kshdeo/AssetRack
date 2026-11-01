import Testing
@testable import AssetRack

@Suite("ConfigService")
struct ConfigServiceTests {
    @Test func comparesVersionsNumerically() {
        #expect(ConfigService.isVersion("1.9", olderThan: "1.10"))
        #expect(ConfigService.isVersion("1.0", olderThan: "1.0.1"))
        #expect(!ConfigService.isVersion("1.10", olderThan: "1.9"))
    }

    @Test func missingPartsCountAsZero() {
        #expect(!ConfigService.isVersion("1.0", olderThan: "1.0.0"))
        #expect(!ConfigService.isVersion("1.0.0", olderThan: "1.0"))
    }

    @Test func unparseableVersionsNeverPrompt() {
        #expect(!ConfigService.isVersion("1.0", olderThan: "latest"))
        #expect(!ConfigService.isVersion("1.0", olderThan: ""))
        #expect(!ConfigService.isVersion("", olderThan: "2.0"))
    }

    @Test func defaultMinimumDoesNotPrompt() {
        #expect(!ConfigService().isUpdateRequired)
    }
}
