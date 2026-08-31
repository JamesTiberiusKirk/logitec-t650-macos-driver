# Logitech Wireless Rechargeable Touchpad T650 — HID++ 2.0 Raw Touch Protocol

Empirical protocol specification, produced as the input to a macOS DriverKit /
IOHIDManager port.

Every numeric claim below is traceable to a capture in `captures/`. Where the
Linux kernel driver and the live device disagree, **the live device wins** and the
discrepancy is called out explicitly. Anything not verified on hardware is in
§6, not stated as fact.

- **Host used:** Artix Linux, kernel `7.1.8-artix1-3`, x86-64
- **Capture date:** 2026-08-31
- **Tools:** `tools/hidpp.py` (HID++ request/response), `tools/capture.py`
  (raw logger + decoder), `tools/segment.py` (gesture segmenter)

---

## 1. Device identification

### 1.1 USB / transport

| Property | Value | Source |
|---|---|---|
| Receiver | Logitech Unifying Receiver | `lsusb` |
| Receiver VID:PID | **`046d:c52b`** | `lsusb` |
| Receiver firmware | `24.10.B0036` | `solaar show` |
| Touchpad HID++ device index | **`0x01`** | `captures/01-feature-enumeration.txt` |
| DJ virtual child (Linux only) | `046d:4101` | `/proc/bus/input/devices` |
| Device serial / uniq | `c8-50-c6-db` | `captures/04-evdev-capabilities.txt` |
| HID++ protocol version | **2.0** | `captures/06-protocol-and-battery.txt` |
| Device name (feature `0x0005`) | `Rechargeable Touchpad T650` | `captures/02-raw-xy-info.txt` |

The receiver exposes three USB interfaces. **Interface 2** is the HID++ interface
and the only one that matters here.

```
bInterfaceNumber 2
  bEndpointAddress 0x83  EP 3 IN   Interrupt   bInterval 2
```

**Interface 2 has an interrupt IN endpoint and no interrupt OUT endpoint.**
Consequently every host→device HID++ report — including the unlock in §2 — must
be sent as a **control transfer `SET_REPORT`**, not an interrupt OUT write. This
is the direct answer to "control endpoint vs interrupt endpoint".

Report IDs declared by interface 2's report descriptor:

| Report ID | Total size | Direction | Purpose |
|---|---|---|---|
| `0x10` | 7 bytes | In + Out | HID++ short |
| `0x11` | **20 bytes** | In + Out | HID++ long — **all touch data** |
| `0x20` / `0x21` | 15 / 32 bytes | In + Out | DJ receiver management |

> **Verified quirk:** this device **does not answer short (`0x10`) requests at
> all** — they time out silently, with no error reply. Every request in this
> document uses the long (`0x11`) form. See §5.1.

### 1.2 Firmware version tested

`captures/03-fw-entities.txt`, feature `0x0003` (DEVICE_FW_VERSION):

| Entity | Type | Prefix | Version | Build |
|---|---|---|---|---|
| 0 | Main firmware | `RQM` | **41.00** | **0033** |
| 1 | Bootloader | `BL ` | 03.00 | 0000 |
| 2 | Hardware | `HW ` | 05.00 | 0000 |
| 3 | Touchpad sensor | `SYN` | 05.00 | 0000 |

So this unit is **`RQM41.00_B0033`** — in the community's dotted notation,
`041.000.00033`.

> **Discrepancy vs. the task brief.** The brief states firmware `041.001.00038`
> is *required* for raw mode. This unit runs an **older** build and raw mode is
> nonetheless fully functional — `getRawReportState` returns `0x05` and 5-contact
> raw reporting works (§3, §4). **The stated firmware requirement is not
> reproduced here and appears to be wrong**, or applies to some other capability.

The `SYN` prefix on the sensor entity indicates a **Synaptics** touch sensor
inside a Logitech shell.

### 1.3 Feature table

Full dump in `captures/01-feature-enumeration.txt`; machine-readable in
`captures/features.json`. 23 features. The one that matters:

| Feature index | Feature ID | Name |
|---|---|---|
| **15 (`0x0f`)** | **`0x6100`** | **`TOUCHPAD_RAW_XY`** |

Feature indices are **per-unit and must be resolved at runtime** via the root
feature — never hardcode 15. See §2.2.

### 1.4 Default (mouse-emulation) behaviour — **verified**

Captured directly by disabling raw mode (`0x6100` fn2, params `0x00`), recording
25 s of use, then restoring `0x05`. Raw log in
`captures/30-mouse-emulation-baseline.txt`, analysis in
`captures/31-mouse-emulation-analysis.txt`.

> **The kernel source describes the post-demux child report, not the wire — and
> this is the most important correction in this document.** `wtp_raw_event()`
> handles a `case 0x02:`, which makes it tempting to expect report ID `0x02`
> from the receiver. **No `0x02` report was ever observed on the wire** — 1313
> of 1313 captured reports were **DJ short reports, ID `0x20`**. The driver is
> not wrong; it simply operates one layer up. `hid-logitech-dj` demultiplexes
> the DJ report and re-emits it as report `0x02` on its virtual child device.
> That child is a **Linux-internal construct with no macOS equivalent** — a
> macOS driver reads the receiver directly and must therefore parse `0x20`
> itself.

On the wire, factory mode delivers a standard **Unifying DJ mouse report**:

```
20 01 02 | 00 00 36 d0 00 00 00 38 00 00 00 00
▲  ▲  ▲    └──────────── 12 data bytes ────────────┘
│  │  └─ REPORT_TYPE_MOUSE (0x02)
│  └──── device index
└─────── REPORT_ID_DJ_SHORT (0x20), 15 bytes total
```

Data-byte layout, matching the `mse_descriptor` that `hid-logitech-dj` embeds in
the child device (confirmed against the live descriptor at
`/sys/class/hidraw/hidraw6/device/report_descriptor`):

| Offset (into the 12 data bytes) | Size | Field |
|---|---|---|
| `0..1` | 16 bits | Buttons, LE bitmask (16 buttons declared) |
| `2..4` | 12 + 12 bits | **dx**, then **dy** — signed, −2047..2047 |
| `5` | 8 bits | Wheel, signed −127..127 |
| `6` | 8 bits | AC Pan (horizontal scroll), signed |
| `7` | 8 bits | **Undocumented, varies smoothly — see §6.12** |
| `8..11` | — | Always zero in every captured report |

`dx`/`dy` unpack as:

```c
dx = sign12( p[2] | ((p[3] & 0x0f) << 8) );
dy = sign12( (p[3] >> 4) | (p[4] << 4) );
```

> **Endianness differs between the two modes — an easy source of bugs for anyone
> implementing both paths.** Factory mode packs `dx`/`dy` as **12-bit
> little-endian-ordered nibbles** (low byte first, the shared middle byte
> splitting the two). Raw mode packs x/y as **14-bit big-endian**, high bits
> first, sharing the top 2 bits of each leading byte with a flag field (§3.3).
> They are not the same layout and cannot share a decoder.

**What factory mode does and does not give you:**

| Capability | Factory mouse mode | Raw mode |
|---|---|---|
| Absolute coordinates | **No** — relative deltas only | Yes, 0..2832 × 0..2364 |
| Contact count / IDs | **None** | Up to 5, tracked |
| Per-contact position | **None** | Yes |
| Contact area | **None** | Yes |
| Vertical scroll | Yes — as wheel | Derive from contacts |
| Horizontal scroll | Yes — as AC Pan | Derive from contacts |
| Any other gesture | **No** | Derive from contacts |

Measured in the 25 s window: `dx` −67..115, `dy` −62..43, wheel non-zero in 373
reports, AC Pan non-zero in 290, buttons non-zero in 15. Report rate **52.5/s**
with an 8.0 ms median interval — i.e. the same ~125 Hz carrier, but **only sent
when something changes**, so the average is far lower than raw mode's.

**Precision:** 12-bit signed relative deltas with no absolute reference. The pad
performs its own gesture recognition internally and exposes the result *only* as
wheel and pan. Three-, four- and five-finger gestures, pinch, and per-contact
position are **simply not representable** in this mode — which is exactly why
the raw unlock is required.

Note also that `wtp_mouse_raw_xy_event()` — the kernel path that would decode
2 contacts from a mouse-mode report — requires `size >= 21`, i.e. a DJ **long**
report (`0x21`, 32 bytes). This T650 sent only short `0x20` reports in factory
mode, so **that code path never executes for this device**.

---

## 2. Connection and unlock sequence

### 2.1 Request framing (verified)

All HID++ 2.0 requests to this device use the 20-byte long report:

```
byte 0 : 0x11              report ID (long)
byte 1 : 0x01              HID++ device index (paired slot 1)
byte 2 : <feature index>   resolved at runtime, NOT the feature ID
byte 3 : (func << 4) | swid
byte 4.. : parameters, zero-padded to 20 bytes total
```

The **low nibble of byte 3 is a caller-chosen software ID**. It is echoed back in
the reply and exists so concurrent HID++ clients can tell their replies apart.
The Linux kernel uses `0x01`, Solaar uses `0x0f`, `tools/hidpp.py` uses `0x0e`.
**Pick a distinct value for the macOS driver** — the kernel driver is not the
only speaker on this bus.

Responses echo bytes 0–3 and carry 16 payload bytes. A protocol error arrives as
a **short** report with sub-id `0xff`:
`10 <dev> ff <feat> <func|swid> <errcode> ...`

### 2.2 Resolving the feature index

Root feature is always index `0x00`; function 0 is `getFeature(featureId)`.

```
request : 11 01 00 0e 61 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
                   ^^ ^^ ^^^^^
                   |  |  feature ID 0x6100
                   |  (func 0 << 4) | swid 0x0e
                   root feature index
reply   : payload[0] = feature index   (0x0f on this unit)
          payload[1] = feature type
          payload[2] = feature version
```

### 2.3 The unlock command (verified live)

Feature `0x6100`, **function 2** (`setRawReportState`). Exact bytes, as sent and
confirmed on this device in `captures/05-unlock-write-verify.txt`:

```
11 01 0f 2e 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
▲  ▲  ▲  ▲  ▲
│  │  │  │  └─ params[0] = 0x05  = enable raw + enhanced sensitivity
│  │  │  └──── (func 2 << 4) | swid 0x0e     — kernel sends 0x21 here
│  │  └─────── feature index for 0x6100 (resolve at runtime!)
│  └────────── device index 1
└───────────── report ID 0x11 (long)
```

Sent as a **control-transfer `SET_REPORT`** (§1.1 — there is no interrupt OUT).

`params[0]` bitfield, per `hidpp_touchpad_set_raw_report_state()`:

| Bit | Mask | Meaning |
|---|---|---|
| 0 | `0x01` | **enable raw reporting** |
| 1 | `0x02` | 16-bit Z, no area |
| 2 | `0x04` | **enhanced sensitivity** |
| 3 | `0x08` | width/height (4 bits each) instead of area |
| 4 | `0x10` | raw **and** gestures (degrades smoothness) |

`0x05` = bit 0 + bit 2, matching the kernel's
`hidpp_touchpad_set_raw_report_state(hidpp, idx, true, true)`.

The reply is an all-zero payload. Read back the state with **function 1**
(`getRawReportState`); this unit returns `0x05`.

### 2.4 Retry behaviour — mandatory

**The first request after an idle period is silently dropped.** No error reply,
no NAK — the request simply times out while the radio wakes. This was hit
repeatedly and is why `tools/hidpp.py` retries four times with a 50 ms gap.

**The macOS driver must retry the unlock**, not treat one timeout as failure.

### 2.5 Persistence across reconnect

**Not verified on hardware — see §6.2.** The kernel's own behaviour is strong
circumstantial evidence: `hidpp_connect_event()` calls `wtp_connect()` on
*every* connect event, and `wtp_connect()` ends with an **unconditional**
`set_raw_report_state(true, true)` — it never queries first. The kernel assumes
the unlock does **not** survive a reconnect.

**Recommendation regardless:** re-send the unlock on every connect and
power-cycle. It is idempotent (proven in §2.3 — re-sending the in-effect value
changed nothing), so re-sending costs nothing and removes the question.

---

## 3. Raw report format

### 3.1 Frame vs. report — the critical structure

A **report carries at most 2 contacts**. A **frame** is the complete set of
contacts at one instant, and spans **`ceil(finger_count / 2)` reports**.

Verified in `captures/21-gesture-session-segments.txt`:

Measured directly over every frame in the session
(`captures/23-three-contact-frames.txt`), broken out per contact count:

| `finger_count` | Reports per frame | Frames observed |
|---|---|---|
| 0 (terminator) | 1 | 18 |
| 1 | 1 | 1051 |
| 2 | 1 | 691 |
| **3** | **2** | **232** |
| 4 | 2 | 92 |
| 5 | 3 | 78 |

Every count is measured in isolation — the 3-contact case is **not** inferred
from the 4-contact segment. The relationship is exactly `ceil(n / 2)`, with the
trailing report carrying an empty slot B when `n` is odd:

```
eof=0 n=3 ts=8196 [fid=1 x=1597 y=1547 a=12] [fid=2 x=2368 y=1776 a=20]
eof=1 n=3 ts=8196 [fid=3 x=1889 y=1788 a=20] [empty]
```

All reports in one frame carry the **same hardware timestamp** and the **same
`finger_count`**; only the last has `end_of_frame = 1`. From
`captures/22-lift-and-frames.txt`, one complete 5-contact frame:

```
eof=0 n=5 [fid=1 x=693  y=1133 a=49] [fid=2 x=2299 y=2012 a=20]
eof=0 n=5 [fid=3 x=1905 y=2274 a=6 ] [fid=4 x=885  y=2037 a=9 ]
eof=1 n=5 [fid=5 x=1413 y=2319 a=0 ] [empty]
```

**The macOS driver must buffer reports until `end_of_frame = 1` and only then
emit a touch event.** Acting per-report will produce phantom 2-finger gestures
during any 3+ finger interaction.

### 3.2 Byte layout

Touch data arrives as an unsolicited **long report**, identified by
`feature index == <0x6100 index>` **and** `byte 3 == 0x00` (`EVENT_TOUCHPAD_RAW_XY`).
Note byte 3 is `0x00` — an event, not a reply, so it carries no software ID.

```
 byte │  0    1    2    3  │  4    5  │  6  7  8  9 10 11 12 │ 13 14 15 16 17 18 19
      │ 0x11 idx feat 0x00 │ ts_hi ts_lo │      contact A       │      contact B
```

Indexing the 16-byte **payload** (report bytes 4..19), which is how the kernel
addresses it:

```
payload[0..1]   u16 BE   hardware timestamp
payload[2..8]   7 bytes  contact A
payload[9..15]  7 bytes  contact B
```

**Two fields are shared/overlapped — the single easiest thing to get wrong:**

```
payload[8]  =  contact A finger_id  (bits 7..4)
               button               (bit 2)
               spurious_flag        (bit 1)
               end_of_frame         (bit 0)

payload[15] =  contact B finger_id  (bits 7..4)
               finger_count         (bits 3..0)
```

### 3.3 Per-contact structure (7 bytes) and coordinate bit-packing

```
 off │ 7  6 │ 5  4  3  2  1  0
─────┼──────┼──────────────────
  0  │ type │  x[13:8]
  1  │        x[7:0]
  2  │status│  y[13:8]
  3  │        y[7:0]
  4  │        z          (always 0 — see §5.3)
  5  │        area
  6  │ fid  │  (shared, see §3.2)
```

**Coordinates are 14-bit big-endian, with the top 6 bits sharing byte 0/2 with a
2-bit flag field:**

```c
x = ((b[0] & 0x3f) << 8) | b[1];     /* 0 .. 2832 */
y = ((b[2] & 0x3f) << 8) | b[3];     /* 0 .. 2364 */
contact_type   = b[0] >> 6;
contact_status = b[2] >> 6;
```

The kernel writes this as `(u8)(b[0] << 2) << 6 | b[1]`, relying on u8
truncation to mask off the flag bits. It is the same value; the mask form above
is clearer and less error-prone.

Worked example, first report of `captures/11-validate-drag.txt`:

```
11 01 0f 00 | 00 07 | 06 96 44 11 00 0c 11 | 00 00 00 00 00 00 01
              ts=7    contact A              contact B (empty)

x = (0x06 & 0x3f) << 8 | 0x96 = 0x0696 = 1686
y = (0x44 & 0x3f) << 8 | 0x11 = 0x0411 = 1041
contact_type   = 0x06 >> 6 = 0
contact_status = 0x44 >> 6 = 1
area = 0x0c = 12,  finger_id = 0x11 >> 4 = 1
payload[8]  = 0x11 -> eof=1, spurious=0, button=0
payload[15] = 0x01 -> finger_count=1
```

### 3.4 Coordinate space, origin and resolution

From `0x6100` fn0 (`getTouchpadInfo`), raw
`0b 10 09 3c 08 08 08 0a 01 00 00 00 00 02 58 00`:

| Field | Offset | Value | Notes |
|---|---|---|---|
| `x_size` | `[0..1]` BE | **2832** | verified: observed 29..2830 |
| `y_size` | `[2..3]` BE | **2364** | verified: observed 62..2307 |
| `z_range` | `[4]` | 8 | z is always 0 with unlock `0x05` — §5.3 |
| `area_range` | `[5]` | 8 | do **not** read as a maximum — §5.4 |
| *(unparsed)* | `[6]` | 8 | **identity unconfirmed — §6.10** |
| `max_contacts` | `[7]` | 10 | only 5 ever observed — §5.2 |
| `origin` | `[8]` | **1 = LOWER_LEFT** | **Y must be flipped, see below** |
| *(unparsed)* | `[9]` | 0 | **identity unconfirmed — §6.10** |
| resolution | `[13..14]` BE | 600 | units per **inch** |

> The kernel's `hidpp_touchpad_get_raw_info()` reads only `[4] [5] [7] [8]` and
> `[13..14]`. **`params[6]` and `params[9]` are never parsed by the kernel** —
> the names sometimes given to them come from field order in a struct that does
> not fully correspond to the wire format. Treated as unidentified here.

**Origin is lower-left.** `TOUCHPAD_RAW_XY_ORIGIN_LOWER_LEFT = 0x01`,
`_UPPER_LEFT = 0x03`. The kernel sets `flip_y` and reports
`y_out = y_size - y_raw`. **A macOS driver must apply the same flip**, or
vertical scrolling and all Y motion will be inverted.

**Resolution:** the raw field is **600 units per inch**. The kernel converts to
units per millimetre as `600 * 2 / 51 = 23`, matching the `res=23` seen in
`captures/04-evdev-capabilities.txt`. Physical active area is therefore
2832/23 ≈ **123 mm** × 2364/23 ≈ **103 mm**.

### 3.5 Contact lifecycle — no explicit lift

**There is no finger-up flag.** `contact_status` was `1` in every one of the
3887 real contacts captured, and `0` only in unused (empty) contact slots
(`captures/22-lift-and-frames.txt`).

A contact is released by **disappearing from the frame**. Release of the last
contact produces a distinct terminator report:

```
11 01 0f 00 01 2f 00 00 00 00 00 00 01 00 00 00 00 00 00 00
                                    ▲
                        payload[8] = 0x01 -> eof=1, finger_id=0
                        payload[15] = 0x00 -> finger_count=0
```

**The macOS driver must diff each completed frame against the previous one and
synthesise lift events for `finger_id`s that vanished.** The Linux driver gets
this for free from `INPUT_MT_DROP_UNUSED`; DriverKit has no equivalent.

`finger_id` is a **1-based tracking ID** (`0` means "slot empty"), stable for the
life of a contact. Observed values: 1–5.

> **`finger_id`s are sparse and non-contiguous.** Surviving contacts are **not**
> renumbered when one is released. Measured id sets per frame
> (`captures/23-three-contact-frames.txt`): `(1,3)` in 76 frames, `(2,)` in 26,
> `(2,3)` in 1, `(1,2,3,5)` in 1.
>
> **Never index an array by `finger_id`, and never assume ids run
> `1..finger_count`.** `finger_count` is a count of present contacts, not the
> highest id in use. Use a map keyed by id.

---

## 4. Gesture-to-raw-data mapping

From `captures/20-gesture-session.txt`, segmented in
`captures/21-gesture-session-segments.txt`. Segments are split on idle gaps
>1500 ms, which is unambiguous because **idle produces zero reports**
(`captures/10-idle-baseline.txt`: 0 reports in 4 s).

13 segments for 10 scripted gestures — the operator reported lifting mid-way
during step 9 and repeating step 10, and steps 6/7 ran together without a
pause. Mapping is annotated accordingly.

| Gesture | Seg | Reports | Dur | `finger_count` | ids | Reports/frame | Observed signature |
|---|---|---|---|---|---|---|---|
| 1 · Single tap | 1 | 29 | 290 ms | 1 | 1 | 1 | Static x=1529 y=1639, area 16, then `n=0` terminator |
| 2 · Full-area drag | 3 | 535 | 6.6 s | 1 | 1 | 1 | **x 29..2830, y 62..2307** — full coordinate range |
| 3 · 2-finger vertical | 5 | 163 | 1.7 s | 2 | 1,2 | 1 | y sweeps 942..2004, x near-constant 1242..1594 |
| 4 · 2-finger horizontal | 6 | 212 | 2.2 s | 2 | 1,2 | 1 | x sweeps 554..2714, y near-constant 1300..1717 |
| 5 · 2-finger tap | 7 | 12 | 118 ms | 2 | 1,2 | 1 | Shortest segment; 2 contacts appear and vanish |
| 6+7 · 3- and 4-finger swipes | 8 | 769 | 9.1 s | **4** | 1–4 | **{1:123, 2:323}** | Ran together without a pause; separated by frame analysis — 232 three-contact and 92 four-contact frames. Area peaks **154** |
| 8 · Five fingers | 9 | 239 | 1.9 s | **5** | 1–5 | **{1:3, 2:1, 3:78}** | 3 reports/frame |
| 9 · Pinch | 10, 11 | 234+78 | 2.4+0.8 s | 2 | 1,2 | 1 | Two segments (operator lifted between) |
| 10 · Physical click | 12, 13 | 44+205 | 0.5+2.1 s | 1 | 1 | 1 | **button bit set in 18 and 166 reports** |
| Idle | — | **0** | — | — | — | — | No reports at all |

Notes:

- **Pinch and zoom are not reported as gestures.** In raw mode the pad reports
  only contacts; segment 10/11 is two contacts whose separation changes. All
  gesture recognition — pinch, rotate, swipe, tap-to-click, two-finger
  right-click — is the **host's** job. The pad is a raw contact sensor.
- **Segments 2 and 4 are unscripted** (warm-up / stray contacts). They are left
  in rather than deleted, since they are real captured data.
- Vertical vs. horizontal scroll are distinguished purely by which axis moves;
  there is no scroll-specific field.

### 4.1 Timing and polling characteristics

| Property | Measured | Source |
|---|---|---|
| Report interval, median | **8.0–8.1 ms** (≈125 Hz) | all segments |
| Minimum observed | 5.5 ms | segment 13 |
| Common outlier | ~16 ms | exactly 2× the period — one dropped report |
| Idle traffic | **none** | `captures/10-idle-baseline.txt` |
| Receiver USB `bInterval` | 2 ms | `lsusb -v` |
| Hardware timestamp rate | **1.019 ± 0.01 units/ms** | 12 independent segments |

**The device is purely event-driven.** Nothing is transmitted while untouched —
a macOS driver should block on read, never poll.

**~125 Hz is the device's rate, not a USB limit** — the receiver polls at 2 ms.
Peak load with 5 contacts is 3 reports × 125 Hz = **375 reports/s**, ~7.5 KB/s.

**16 ms gaps are dropped reports, not coalescing** — the hardware timestamp
advances by the full interval across them. Frames are not merged; a dropped
report means a lost frame, since `end_of_frame` arrives with the last report.
**Do not treat a missing report as a lift** — rely on the terminator (§3.5).

**The hardware timestamp is the better clock.** It is jitter-free (identical
across all reports of one frame) at ≈1 ms/unit, u16, wrapping every ~65.5 s. Use
it for velocity, not host arrival time.

---

## 5. Known quirks and edge cases

### 5.1 Short (`0x10`) requests are never answered
Every short request timed out silently — no error, no NAK. Only long (`0x11`)
requests work. Verified across both device index `0x01` and broadcast `0xff`.
**Use long reports exclusively.**

### 5.2 `max_contacts` reports 10, hardware delivers 5
`0x6100` fn0 says `max_contacts = 10`, and Linux allocates 10 MT slots
(`ABS_MT_SLOT max=9`). **`finger_id` never exceeded 5** and `finger_count` never
exceeded 5 across 5284 contact samples, including a deliberate 5-finger hold.
Consistent with `BTN_TOOL_QUINTTAP` being the highest tool button exposed.
Allocate 10 slots defensively; expect 5.

### 5.3 The `z` field is dead — with unlock params `0x05`
**`z` was `0` in all 5284 contact samples**
(`captures/22-lift-and-frames.txt`). The kernel never uses it — it maps
`ABS_MT_PRESSURE` from `area`, not `z`. **Use `area`; ignore `z`.**

Scope: this holds for unlock params `0x05`. Bit 1 (`0x02`, "16-bit Z, no area")
is an **untested lever** — see §6.11.

### 5.4 `area_range` cannot be used as a maximum
Declared `area_range = 8`, yet **`area` was observed up to 154** (segment 8).

Two readings, and the captures do not distinguish them:

1. **"range" means field bit width.** `params[4]`, `[5]` and `[6]` are three
   consecutive bytes all reading `8`, and the contact struct has exactly an
   8-bit `z` and an 8-bit `area`. Under this reading 154 is perfectly in range
   and nothing is wrong.
2. **"range" means maximum value.** Then the device under-declares by ~19×.

Reading 1 fits the evidence better and is the more likely intent.

**Either way the actionable guidance is identical:** do not treat `area_range`
as a maximum. Note also that the Linux `ABS_MT_PRESSURE` range of `0..50` is
**kernel-invented**, not device-derived — the source says *"Max pressure is not
given by the devices, pick one"*. Calibrate empirically and treat `area` as a
full u8. Any area threshold is a **tuning knob**, not a device constant.

### 5.5 Hardware timestamp runs at ≈1 unit/ms
**Measured 1.019 units/ms across 12 independent segments**, consistent to ±1%
over intervals from 118 ms to 9 s — not noise. **Treat the timestamp as
milliseconds.**

This is a direct measurement and stands on its own. It is *sometimes* claimed
that `0x6100` fn0 declares a timestamp unit of 8; that byte (`params[6]`) is
never parsed by the kernel and its meaning is unconfirmed (§6.10), so this is
**not** presented as a device-vs-spec contradiction.

### 5.6 First request after idle is silently dropped
See §2.4. Costs one timeout. Always retry.

### 5.7 Hard press and physical click cannot be separated
The T650's click switches are **in the feet of the unit**, so the whole surface
tilts. Any press firm enough to produce a large contact `area` also trips the
button. Confirmed by the device owner during capture; step 11 of the capture
plan was dropped as physically impossible.

**A macOS driver cannot implement "force press" as a gesture distinct from a
click on this hardware.**

### 5.8 Y axis is inverted relative to screen coordinates
`origin = 1` (LOWER_LEFT). Emit `y_size - y_raw`. See §3.4.

### 5.9 Contacts vanish without notice
No lift flag; contacts disappear from the frame. See §3.5.

### 5.10 T650-specific driver quirks vs. sibling devices
From the `hidpp_devices[]` table in `hid-logitech-hidpp.c`:

| Device | Quirks |
|---|---|
| Wireless touchpad `0x4011` | `CLASS_WTP \| DELAYED_INIT \| **WTP_PHYSICAL_BUTTONS**` |
| **T650 `0x4101`** | `CLASS_WTP \| DELAYED_INIT` |
| T651 (Bluetooth) | `CLASS_WTP \| DELAYED_INIT` |

**The T650 deliberately lacks `WTP_PHYSICAL_BUTTONS`.** Consequences, all in
`wtp_populate_input()` / `wtp_send_raw_xy_event()`:

1. It is a **buttonpad** (`INPUT_PROP_BUTTONPAD`) — one button, not left+right.
   `BTN_RIGHT` is never reported. Right-click is a host-side interpretation of a
   two-contact tap.
2. `BTN_LEFT` comes from the raw report's **button bit** (`payload[8]` bit 2),
   emitted only on `end_of_frame`.
3. The child device's `0x02` report (post-demux, §1.4) is interpreted as
   `wtp_mouse_raw_xy_event()` rather than as a physical-button report. On this
   unit that branch is unreachable anyway — it needs `size >= 21`, and the pad
   sends only short DJ reports in factory mode.

`DELAYED_INIT` means the driver defers setup until the device actually connects,
which matters because a sleeping pad cannot answer `0x6100` fn0.

### 5.11 Receiver USB autosuspend makes the pad feel dead
Not a protocol issue, but it will be misdiagnosed as one. The receiver
autosuspends after 2 s of idle by default; the first touch is consumed waking
it. On this host it is pinned with a udev rule setting
`power/control = on` for `046d:c52b`. A macOS driver should expect a comparable
wake latency unless power management is pinned.

---

## 6. Open questions and unverified items

Flagged explicitly. **None of the following should be treated as fact.**

### 6.1 Mouse-emulation baseline — **RESOLVED, now verified**
Captured on hardware; see §1.4. The headline result is that the expected
report ID `0x02` **does not exist on the wire** — factory mode uses DJ short
reports (`0x20`). Retained here only to record that the earlier draft of this
document had it as source-derived and wrong.

### 6.2 Unlock persistence across power-cycle — **unverified**
Requires a `usbmon` capture across a power-cycle, which needs root; passwordless
sudo is unavailable on this host and `usbmon` is not loaded. §2.5 is an
inference from kernel behaviour, not an observation.

The discriminating test: with `usbmon` on bus 3, power-cycle the pad and check
whether raw reports resume **before** the host's `setRawReportState` write
(→ persisted) or only **after** (→ must be re-sent).

Mitigated in practice: re-sending is idempotent and harmless, so the
recommendation in §2.5 is safe either way.

### 6.3 The kernel's own bind-time unlock was never observed on the wire
For the same reason as 6.2. The unlock bytes in §2.3 are **this tool's** request,
verified to be accepted by the device — not a recording of the kernel's write.
The only expected difference is byte 3's software-ID nibble (`0x21` kernel vs
`0x2e` here).

### 6.4 Kernel source version
`hid-logitech-hidpp.c` and `hid-logitech-dj.c` were fetched from
`torvalds/linux` **master**, since the running kernel (`7.1.8-artix1-3`) ships no
local source. The WTP-relevant regions were diffed against tag **`v7.1`**:

- `0x6100` raw-XY block (structs, parsers, both commands): **identical**
- WTP driver block (`wtp_*` functions): **identical**
- T650 `hidpp_devices[]` entry: **identical**

So master is a valid map for this kernel. The rest of the file does differ
(master adds `HIDPP_QUIRK_HIDPP_REPROG_CONTROLS_BTNS` and reprogrammable-control
support), but none of it is on the touch path.

### 6.5 Contact-type field never exercised
`contact_type` (`b[0] >> 6`) was `0` in all 5284 samples. The kernel discards any
contact with non-zero `contact_type` as "no actual data". **Meaning of non-zero
values is unknown**, and there may be no way to produce one on this unit —
`params[9]` of `0x6100` fn0 reads `0`, and is *sometimes* said to be a
`pen_support` flag, but the kernel never parses that byte (§6.10).

### 6.6 `spurious_flag` never observed set
`payload[8]` bit 1 was `0` in every captured report. Its trigger condition and
correct handling are unknown; the kernel parses but **never uses** it.

### 6.7 Behaviour above 5 contacts unknown
See §5.2. Whether the declared 10 contacts are reachable — and what a 6+ contact
frame looks like — was not tested.

### 6.8 Multi-device receiver behaviour untested
Only one device is paired (slot 1 of 6). Device-index demultiplexing and
bandwidth sharing with other Unifying peripherals were not exercised.

### 6.9 Battery reporting not cross-checked
Feature `0x1000` reported `level=50%, next=20%, status=0x00`. Not validated
against actual charge state.

---

### 6.10 `params[6]` and `params[9]` of `0x6100` fn0 — identity unconfirmed
The kernel reads only `params[4] [5] [7] [8] [13..14]` from `getTouchpadInfo`.
On this unit `params[6] = 8` and `params[9] = 0`. They are commonly labelled
`timestamp_unit` and `pen_support` from struct field order, but **nothing in the
parsed code confirms that mapping**, so neither is asserted here. Resolving them
needs Logitech documentation or a device that varies them.

### 6.11 Alternative unlock modes untested
Only params `0x05` (raw + enhanced sensitivity) was exercised. Untested:

- bit 1 (`0x02`) — 16-bit Z, no area. **The candidate route to real pressure
  data**, given `z` is dead under `0x05` (§5.3).
- bit 3 (`0x08`) — width/height nibbles instead of area, i.e. contact ellipse.
- bit 4 (`0x10`) — raw **and** gestures; the source warns it degrades smoothness.

Each is a one-byte change to the §2.3 unlock and is reversible.

### 6.12 Undocumented byte in the factory-mode mouse report
Data byte `[7]` of the DJ mouse report (§1.4) is outside every field declared by
`mse_descriptor`, and the kernel ignores it. It is **not** a sequence counter —
consecutive deltas cluster at 0 and ±1 (231 zeros, 134 at −1, 120 at +1 across
1298 reports), so it varies smoothly rather than incrementing. 238 distinct
values observed. Candidates include a hi-res scroll accumulator or a link-quality
metric; **not resolved**. Data bytes `[8..11]` were zero in every report.

## Appendix A — Capture inventory

| File | Contents |
|---|---|
| `01-feature-enumeration.txt` | Full 23-feature table |
| `features.json` | Feature ID → index, machine-readable |
| `02-raw-xy-info.txt` | `0x6100` fn0/fn1, first firmware read |
| `03-fw-entities.txt` | Firmware entities, echo-matched |
| `04-evdev-capabilities.txt` | Linux evdev axes, ranges, resolution |
| `05-unlock-write-verify.txt` | Unlock write, exact bytes, state unchanged |
| `06-protocol-and-battery.txt` | Protocol version, battery, resolution math |
| `10-idle-baseline.txt` | Idle: zero reports in 4 s |
| `11-validate-drag.txt` | Single-finger drag, decoder validation |
| `20-gesture-session.txt` | Full 150 s gesture session, raw + decoded |
| `21-gesture-session-segments.txt` | Per-gesture segment analysis |
| `22-lift-and-frames.txt` | Lift encoding, frame structure, field histograms |
| `23-three-contact-frames.txt` | Reports/frame per contact count; `finger_id` sparseness |
| `30-mouse-emulation-baseline.txt` | 25 s of factory mouse mode, raw disabled |
| `31-mouse-emulation-analysis.txt` | DJ mouse report decode, timing, child descriptor |

## Appendix B — Tools

| File | Purpose |
|---|---|
| `tools/hidpp.py` | HID++ 2.0 request/response over hidraw; retry + echo matching |
| `tools/capture.py` | Passive raw logger with inline decode and timing |
| `tools/segment.py` | Splits a capture into gestures on idle gaps; summarises |

All read `/dev/hidraw4` — the **receiver's** HID++ interface. The Linux DJ child
node (`/dev/hidraw6`, `046d:4101`) is a Linux-only abstraction with no macOS
equivalent and was deliberately **not** used as the source of truth.
