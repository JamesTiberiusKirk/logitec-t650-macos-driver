/// Decoder for T650 HID++ raw touch reports.
/// Byte layout per T650_PROTOCOL_SPEC.md §3 — verified against live captures.

public struct Contact: Equatable {
    public let fingerID: Int   // 1-based tracking id, sparse (spec §3.5); 0 never appears here
    public let x: Int          // 0...2832
    public let y: Int          // 0...2364, RAW (lower-left origin; flip is the caller's job, spec §3.4)
    public let area: Int       // 0...255; the only pressure signal (z is dead, spec §5.3)
}

public struct RawReport: Equatable {
    public let timestamp: Int     // hardware clock, ~1 unit/ms, u16 wrap (spec §5.5)
    public let endOfFrame: Bool
    public let button: Bool
    public let fingerCount: Int
    public let contacts: [Contact]  // 0...2 present contacts

    /// Parse one 20-byte HID++ long report. Returns nil unless it is a raw-XY
    /// touch event for the given feature index (spec §3.2).
    public init?(report: [UInt8], featureIndex: UInt8) {
        guard report.count == 20, report[0] == 0x11, report[2] == featureIndex,
              report[3] == 0x00 else { return nil }
        let p = Array(report[4...])  // 16-byte payload, kernel-style indexing
        timestamp = Int(p[0]) << 8 | Int(p[1])
        endOfFrame = p[8] & 0x01 != 0
        button = p[8] & 0x04 != 0
        fingerCount = Int(p[15] & 0x0f)
        contacts = [Self.contact(p[2...8]), Self.contact(p[9...15])].compactMap { $0 }
    }

    private static func contact(_ s: ArraySlice<UInt8>) -> Contact? {
        let b = Array(s)
        let id = Int(b[6] >> 4)
        guard id != 0 else { return nil }  // empty slot; lift is by absence (spec §3.5)
        return Contact(
            fingerID: id,
            x: Int(b[0] & 0x3f) << 8 | Int(b[1]),
            y: Int(b[2] & 0x3f) << 8 | Int(b[3]),
            area: Int(b[5]))
    }
}
