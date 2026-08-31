// t650d — user-space daemon: Unifying receiver -> native macOS input events.
// Transport per T650_PROTOCOL_SPEC.md §2; decode/recognition lives in T650Kit.
//
// NOT yet run on hardware: written on Linux, compiled only by macOS CI.
// Expect first-run fixes on a real Mac.

#if os(macOS)
import Foundation
import IOKit.hid
import T650Kit

let vendorID = 0x046d, productID = 0xc52b       // Unifying receiver (spec §1.1)
let hidppDeviceIndex: UInt8 = 0x01
let swid: UInt8 = 0x0a                          // ours; kernel=0x1, solaar=0xf (spec §2.1)

final class Daemon {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var device: IOHIDDevice?
    var featureIndex: UInt8?
    var assembler = FrameAssembler()
    var recognizer = GestureRecognizer()
    let output = Output()
    var reportBuffer = [UInt8](repeating: 0, count: 64)

    func run() {
        // Match only the vendor-defined HID++ interface of the receiver, not the
        // keyboard/mouse interfaces (spec §1.1: report IDs 0x10/0x11 live there).
        let match: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: 0xFF00,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let this = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, this)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            fatalError("IOHIDManagerOpen: \(r) — is Input Monitoring granted?")
        }
        CFRunLoopRun()
    }

    func attach(_ dev: IOHIDDevice) {
        device = dev
        let this = Unmanaged.passUnretained(self).toOpaque()
        reportBuffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceRegisterInputReportCallback(dev, buf.baseAddress!, buf.count, { ctx, _, _, _, _, report, len in
                let bytes = Array(UnsafeBufferPointer(start: report, count: len))
                Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue().handleReport(bytes)
            }, this)
        }
        // Resolve 0x6100's feature index, then unlock. Replies arrive via
        // handleReport; requests are fire-and-retry (spec §2.4: first send after
        // idle is dropped silently).
        sendRootGetFeature()
        NSLog("t650d: receiver attached, resolving TOUCHPAD_RAW_XY")
    }

    // -- HID++ requests (all long reports; short ones are never answered, spec §5.1)

    func send(_ payload: [UInt8]) {
        guard let dev = device else { return }
        var pkt = payload + [UInt8](repeating: 0, count: 20 - payload.count)
        // No interrupt OUT on this interface: SetReport goes over the control
        // endpoint, exactly what the protocol needs (spec §1.1).
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(pkt[0]), &pkt, pkt.count)
    }

    func sendRootGetFeature() {
        send([0x11, hidppDeviceIndex, 0x00, 0x00 << 4 | swid, 0x61, 0x00])
    }

    func sendUnlock(_ featureIndex: UInt8) {
        // The unlock (spec §2.3): raw + enhanced sensitivity. Idempotent; resent
        // on every attach because persistence over power-cycle is unproven (§2.5).
        send([0x11, hidppDeviceIndex, featureIndex, 0x02 << 4 | swid, 0x05])
    }

    // -- inbound

    func handleReport(_ bytes: [UInt8]) {
        guard bytes.count == 20, bytes[0] == 0x11, bytes[1] == hidppDeviceIndex else { return }
        if featureIndex == nil, bytes[2] == 0x00, bytes[3] == 0x00 << 4 | swid {
            featureIndex = bytes[4]
            NSLog("t650d: TOUCHPAD_RAW_XY at feature index %d, unlocking", bytes[4])
            sendUnlock(bytes[4])
            return
        }
        guard let feat = featureIndex,
              let report = RawReport(report: bytes, featureIndex: feat),
              let frame = assembler.add(report) else { return }
        for event in recognizer.handle(frame) { output.post(event) }
    }
}

// Re-resolve + unlock on wake/reconnect is handled by IOHIDManager re-firing the
// matching callback when the device re-enumerates.
// ponytail: no retry timer for the dropped-first-request case yet; a second
// touch re-triggers traffic and the resolve retries on next attach. Add a
// 500 ms retry timer if unlock proves flaky on hardware.

Daemon().run()
#else
fatalError("t650d only runs on macOS; `make test` exercises the portable core")
#endif
