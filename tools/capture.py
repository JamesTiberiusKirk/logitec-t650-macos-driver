#!/usr/bin/env python3
"""Capture + decode T650 raw touch reports from the Unifying receiver.

Reads /dev/hidraw4 (the receiver's HID++ interface, 046d:c52b) passively. Every
report is logged with a monotonic timestamp so report intervals are measurable.
Decoding follows hid-logitech-hidpp.c: hidpp_touchpad_raw_xy_event() and
hidpp_touchpad_touch_event().

Usage: capture.py <outfile> [seconds]
"""
import os, select, sys, time

MT_FEATURE_INDEX = 15      # 0x6100 TOUCHPAD_RAW_XY on this unit
EVENT_RAW_XY     = 0x00
Y_SIZE           = 2364    # origin==1 (LOWER_LEFT) => kernel flips Y

def decode_finger(d):
    """d = 7 bytes. x/y are 14-bit, split: low 6 bits of byte0 are the HIGH bits."""
    return {
        "contact_type":   d[0] >> 6,
        "contact_status": d[2] >> 6,
        "x":  ((d[0] & 0x3f) << 8) | d[1],
        "y":  ((d[2] & 0x3f) << 8) | d[3],
        "z":  d[4],
        "area": d[5],
        "finger_id": d[6] >> 4,
    }

def decode(payload):
    """payload = the 16 bytes after [0x11, dev, feat, func]."""
    return {
        "timestamp":    (payload[0] << 8) | payload[1],
        "end_of_frame": payload[8] & 0x01,
        "spurious":     (payload[8] >> 1) & 0x01,
        "button":       (payload[8] >> 2) & 0x01,
        "finger_count": payload[15] & 0x0f,
        "fingers":      [decode_finger(payload[2:9]), decode_finger(payload[9:16])],
    }

def main():
    out, dur = sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
    fd = os.open("/dev/hidraw4", os.O_RDONLY | os.O_NONBLOCK)
    end, prev, n = time.time() + dur, None, 0
    with open(out, "w") as f:
        f.write("# T650 raw capture: /dev/hidraw4 (receiver 046d:c52b), device index 1\n")
        f.write("# cols: t_ms dt_ms  raw_hex  | decoded\n")
        t0 = time.monotonic()
        while time.time() < end:
            if not select.select([fd], [], [], 0.25)[0]:
                continue
            data = os.read(fd, 64)
            t = (time.monotonic() - t0) * 1000
            dt = 0.0 if prev is None else t - prev
            prev, n = t, n + 1
            line = f"{t:9.2f} {dt:7.2f}  {data.hex(' ')}"
            if data[0] == 0x11 and data[2] == MT_FEATURE_INDEX and data[3] == EVENT_RAW_XY:
                r = decode(data[4:])
                fs = " ".join(
                    f"[id={g['finger_id']} st={g['contact_status']} ty={g['contact_type']} "
                    f"x={g['x']:4d} y={g['y']:4d} yf={Y_SIZE-g['y']:4d} z={g['z']:3d} a={g['area']:3d}]"
                    for g in r["fingers"] if g["finger_id"])
                line += (f"  | ts={r['timestamp']:5d} eof={r['end_of_frame']} "
                         f"sp={r['spurious']} btn={r['button']} n={r['finger_count']} {fs}")
            f.write(line + "\n")
    os.close(fd)
    print(f"{n} reports -> {out}")

if __name__ == "__main__":
    main()
