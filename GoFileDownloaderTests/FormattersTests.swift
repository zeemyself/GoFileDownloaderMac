import Foundation
import Testing
@testable import GoFileDownloader

@Suite("Formatters Tests")
struct FormattersTests {
    @Test("Formats byte counts including negative and zero inputs")
    func byteFormatting() {
        #expect(Formatters.bytes(-50) == Formatters.bytes(0))
        #expect(!Formatters.bytes(0).isEmpty)
        #expect(Formatters.bytes(1_000_000).contains("MB") || Formatters.bytes(1_000_000).contains("KB"))
    }

    @Test("Formats transfer speeds and guards low or NaN values")
    func speedFormatting() {
        #expect(Formatters.speed(0) == "—")
        #expect(Formatters.speed(0.5) == "—")
        #expect(Formatters.speed(.nan) == "—")
        #expect(Formatters.speed(2_000_000).hasSuffix("/s"))
    }

    @Test("Formats ETA across seconds, minutes, hours, and rejects invalid or huge durations")
    func etaFormatting() {
        #expect(Formatters.eta(remainingBytes: 0, bytesPerSecond: 1000) == "—")
        #expect(Formatters.eta(remainingBytes: 1000, bytesPerSecond: 0) == "—")
        #expect(Formatters.eta(remainingBytes: 1000, bytesPerSecond: .nan) == "—")
        #expect(Formatters.eta(remainingBytes: 45_000, bytesPerSecond: 1_000) == "45s")
        #expect(Formatters.eta(remainingBytes: 125_000, bytesPerSecond: 1_000) == "2m 05s")
        #expect(Formatters.eta(remainingBytes: 7_380_000, bytesPerSecond: 1_000) == "2h 03m")
        #expect(Formatters.eta(remainingBytes: 10_000_000_000, bytesPerSecond: 10) == "—")
    }

    @Test("Formats log timestamps in HH:mm:ss format")
    func timeStringFormatting() {
        let str = Formatters.timeString(Date(timeIntervalSince1970: 0))
        #expect(str.count == 8)
        #expect(str.filter { $0 == ":" }.count == 2)
    }
}
