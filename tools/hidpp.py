#!/usr/bin/env python3
"""Minimal HID++ 2.0 request/response over a Unifying receiver hidraw node.

Read-only by design: this sends getFeature/get* requests only. It never writes
a setter. Responses are matched on (report_id, dev_idx, feat_idx, func|swid) so
concurrent kernel traffic on the same node is ignored.
"""
import os, select, sys, time

SWID = 0x0e  # ours; kernel hidpp uses 0x01, Solaar 0x0f — keeps replies distinct

class HIDPP:
    def __init__(self, path="/dev/hidraw4", dev=0x01):
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.dev = dev

    def close(self):
        os.close(self.fd)

    def _drain(self):
        while select.select([self.fd], [], [], 0)[0]:
            try: os.read(self.fd, 64)
            except OSError: break

    def request(self, feat_idx, func, params=b"", long=True, timeout=1.0, tries=4, echo=0):
        """Retries because the T650 wireless-sleeps: the first request after an
        idle period wakes the radio and is dropped, with no error reply."""
        for n in range(tries):
            try:
                return self._request1(feat_idx, func, params, long, timeout, echo)
            except TimeoutError:
                if n == tries - 1: raise
                time.sleep(0.05)

    def _request1(self, feat_idx, func, params, long, timeout, echo):
        rid, size = (0x11, 20) if long else (0x10, 7)
        head = bytes([rid, self.dev, feat_idx, (func << 4) | SWID])
        pkt = head + params.ljust(size - 4, b"\x00")
        self._drain()
        os.write(self.fd, pkt)
        end = time.time() + timeout
        while time.time() < end:
            r = select.select([self.fd], [], [], max(0, end - time.time()))[0]
            if not r: break
            data = os.read(self.fd, 64)
            if len(data) < 4 or data[1] != self.dev: continue
            # HID++ 2.0 error: 0xff sub-id, echoes feat_idx+func in payload
            if data[0] == 0x10 and data[2] == 0xff and data[3:5] == head[2:4]:
                raise OSError(f"HID++ error 0x{data[5]:02x} on feat 0x{feat_idx:02x} fn {func}")
            if data[2:4] != head[2:4]:
                continue
            # Indexed getters echo their leading param bytes. Without this the
            # reply to a *previous* request for a different index matches too.
            if echo and data[4:4 + echo] != params[:echo]:
                continue
            return data[4:]
        raise TimeoutError(f"no reply: feat 0x{feat_idx:02x} fn {func}")

    def get_feature(self, fid):
        r = self.request(0x00, 0x00, bytes([fid >> 8, fid & 0xff]))
        return r[0], r[1], r[2]   # index, type, version

if __name__ == "__main__":
    h = HIDPP()
    idx, typ, ver = h.get_feature(0x0003)
    print(f"FEATURE 0x0003 (DEVICE_FW_VERSION): index={idx} type=0x{typ:02x} ver={ver}")
