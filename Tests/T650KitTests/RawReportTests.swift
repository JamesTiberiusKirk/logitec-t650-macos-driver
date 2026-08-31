import XCTest
@testable import T650Kit

/// Decodes the full live gesture-session capture and asserts the properties
/// the protocol spec claims (T650_PROTOCOL_SPEC.md §3-§4).
final class RawReportTests: XCTestCase {
    static let feat: UInt8 = 0x0f

    func loadCapture(_ name: String) throws -> [[UInt8]] {
        let url = Bundle.module.url(forResource: "fixtures/\(name)", withExtension: "txt")!
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 3 else { return nil }
            let bytes = cols[2...].prefix(20).compactMap { UInt8($0, radix: 16) }
            return bytes.count == 20 ? bytes : nil
        }
    }

    func testKnownReportDecodesExactly() {
        // First report of 11-validate-drag: worked example from spec §3.3.
        let raw: [UInt8] = [0x11, 0x01, 0x0f, 0x00, 0x00, 0x07, 0x06, 0x96, 0x44, 0x11,
                            0x00, 0x0c, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]
        let r = RawReport(report: raw, featureIndex: Self.feat)!
        XCTAssertEqual(r.timestamp, 7)
        XCTAssertTrue(r.endOfFrame)
        XCTAssertFalse(r.button)
        XCTAssertEqual(r.fingerCount, 1)
        XCTAssertEqual(r.contacts, [Contact(fingerID: 1, x: 1686, y: 1041, area: 12)])
    }

    func testGestureSessionInvariants() throws {
        let reports = try loadCapture("20-gesture-session").compactMap {
            RawReport(report: $0, featureIndex: Self.feat)
        }
        XCTAssertEqual(reports.count, 2642)  // every wire report was raw-XY
        for r in reports {
            XCTAssertLessThanOrEqual(r.fingerCount, 5)          // spec §5.2
            for c in r.contacts {
                XCTAssertTrue((1...5).contains(c.fingerID))
                XCTAssertTrue((0...2832).contains(c.x))          // spec §3.4
                XCTAssertTrue((0...2364).contains(c.y))
            }
        }
        XCTAssertTrue(reports.contains { $0.button })            // physical click captured
        XCTAssertTrue(reports.contains { $0.fingerCount == 0 })  // lift terminator §3.5
    }
}
