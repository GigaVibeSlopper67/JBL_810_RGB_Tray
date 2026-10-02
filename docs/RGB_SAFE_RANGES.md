# JBL Quantum 810 RGB lighting - safe value ranges & deadlock finding

> Portable reference for anyone implementing Quantum 810 lighting control
> (HeadsetControl, OpenRGB, this project, etc.). Read this before writing
> **any** `0x4c`/`0x4d`/`0x4b` feature report to the device.

## Scope

- **Device**: JBL Quantum 810 wireless headset, USB dongle `0ecb:2069`
  (HID interface 5). The Quantum 910 (`0ecb:2088`) shares the battery/mute
  events but its lighting is not covered here.
- **Source of truth**: **QuantumENGINE** software captured on Windows
  (USBPcap, link-type 249) - `pcaps/jbl quantum 810 - Initial first cap -
  just random setting changes.pcapng` (older firmware) and `pcaps/JBL
  Quantum 810 Switch between RGB Modes.pcapng` (newest firmware, RGB mode
  presets).

## The lighting protocol (what is actually sent)

Per lighting **element** (`0` = logo, `1` = ring on the earcups) an effect
plays a sequence of color **segments**. It is pushed over HID feature reports:

| Report | Payload | Field | Meaning |
|--------|---------|-------|---------|
| `0x4c` | `[4c, element, speed, segments]` | element | `0` logo / `1` ring |
| | | speed | tempo/speed selector (`0x19` = 2x is excluded) |
| | | segments | number of `0x4d` frames that follow |
| `0x4d` | `[4d, element, index, R, G, B, mode, last]` | index | 0-based frame number |
| | | R,G,B | color (bytes 3-5) |
| | | mode | mode selector (Wave/Glitch/Solid/Breathing) |
| | | last | per-segment parameter (NOT `index*2`) |
| `0x4b` | `[4b, 0/1]` | — | lights off/on (the commit) |

Required sequence, in order:

1. **Arm** - GET the connect-time round `0x68, 0x67, 0x62, 0x5c, 0x75, 0x49,
   0x51, 0x47, 0x4a, 0x45`. Without it the dongle caches the SETs but the
   headset ignores them (no LED change). Arming persists for minutes.
2. **Write** the per-element table (`0x4c` header + N × `0x4d` frames).
3. **Commit** via a lights **off → on** transition (`0x4b 00` then `0x4b 01`);
   the table only applies on that transition.

A solid color is expressed as **5 identical segments** and renders as a
breathing-style pulse.

## The safe value ranges (observed set, incl. newest firmware)

These are the values QuantumENGINE was observed to emit. The newest-firmware
capture (`Switch between RGB Modes`) widens the set vs. the older capture.
Treat every value outside these as untested and potentially device-bricking.

| Field | Safe range |
|-------|------------|
| `0x4c` segment count | **1–5** (never more than 5) |
| `0x4c` speed byte | **`0x28` `0x32` `0x3c` `0x46` `0x4b` `0x50` `0x64`** (excl. `0x19` = 2x) |
| `0x4d` element | **0 or 1** |
| `0x4d` frame index | **0–4** |
| `0x4d` R / G / B | **0x00–0xFF** (any byte is fine) |
| `0x4d` mode byte (M) | **`0x00` `0x01` `0x02` `0x03` `0x04` `0x05` `0x06`** |
| `0x4d` last byte | **0–8** (per-segment parameter, *not* `index*2`) |

> The only dangerous field is the segment count: keep it `<= 5`. Every other
> value above is one QuantumENGINE itself emits, so reproducing any of them is
> safe. The `0x4d` last byte is a per-segment parameter (0..8 observed) and is
> **not** `index*2` in general - `index*2` only happens to be the default for
> the plain "breathing" shape (the factory table).

## ⚠️ The deadlock finding (why RGB can get "bricked")

Writing a value **outside the safe ranges can permanently deadlock the RGB
lighting**, and it is **not recoverable by factory reset or a normal
power-off**.

What happens, step by step:

1. The lighting runs on a **separate MCU** from the audio/battery MCU.
2. A bad table value (observed: a segment count of **16 or 32**, from a
   "clearing pass" intended to wipe stale colors) latches the lighting MCU
   into a tight loop - the "absurd strobe".
3. The extra frames pushed `0x4d` index to 0..15/31 and the last byte to
   `0x1e`/`0x3e`, far outside the device's 0..4 / 0..8.
4. Once wedged, the lighting MCU **ignores all further writes**, including
   from QuantumENGINE on Windows. A factory reset does not help (it doesn't
   touch the lighting config), and a firmware update may fail to complete
   because the headset re-applies the corrupt table during the boot/handshake.
5. A **soft** power-off (button, dongle replug) does not clear it because the
   power button is handled by the *main* MCU and never hard-cuts power to the
   *lighting* MCU.

### Recovery (best → most invasive)

1. **True cold boot via full battery drain** - unplug the dongle (so its
   polling can't keep the headset awake), power the headset on, and leave it
   until the battery is completely empty (all LEDs dead). Charge, power on,
   then retry the firmware update.
2. **Wired USB-C reflash** - connect wired and force a full firmware
   *reinstall* (not "update") via QuantumENGINE; a full reflash reinitializes
   the lighting MCU.
3. **Physical battery disconnect** - open an earcup and unplug the battery
   connector ~30 s. Definitive, but voids warranty.
4. **RMA** - a firmware value that bricks the lighting against a factory reset
   is a JBL firmware bug; the capture is strong evidence for a warranty claim.

### Rules for implementers

- **Never emit a value QuantumENGINE does not emit.** The table above is the
  observed set (older + newest firmware).
- **Hard-clamp** segment count to `1..5`, the speed byte to
  `0x28/0x32/0x3c/0x46/0x4b/0x50/0x64` (exclude `0x19` = 2x), and the mode
  (M) byte to `0x00..0x06` *before* building any report - never rely on the caller.
- A raw/"unsafe" escape hatch (e.g. `--raw`) must be clearly marked as capable
  of bricking the lighting and should not be exposed in normal UI paths.
- Prefer **writing 5 segments** (the stock shape). A single correctly-paced
  5-segment write fully overwrites the 5-slot table; there is no need for a
  larger "clearing pass" - that larger pass is exactly what caused the lockup.

## Raw SET_REPORT payloads observed (for reference)

The factory table QuantumENGINE pushes on connect (teal, tempo `0x64`):

```
4c 00 64 05
4d 00 00 33 ff cc 02 00
4d 00 01 33 ff cc 02 02
4d 00 02 ff 00 cc 02 04
4d 00 03 33 ff cc 02 06
4d 00 04 33 ff cc 02 08
4c 01 64 05
4d 01 00 33 ff cc 05 00
4d 01 01 33 ff cc 05 02
4d 01 02 ff 00 cc 05 04
4d 01 03 33 ff cc 05 06
4d 01 04 33 ff cc 05 08
4b 01
```

Note the index-2 segment `ff 00 cc` (magenta) is part of the **factory**
table - it is *not* residue from a bad write, and it shows through whenever a
write drops/leaves that slot stale.

## RGB mode presets (newest firmware capture)

`pcaps/JBL Quantum 810 Switch between RGB Modes.pcapng` (newest firmware)
shows QuantumENGINE cycling through its RGB *modes*. Each mode is a full
recipe: the `0x4c` header's **effect byte** + **segment count** select the
effect, and the `0x4d` frames carry that mode's default **palette** plus
per-frame `M` / `last` values. Switching modes therefore changes the colors
too, even without touching the color picker.

Five distinct table writes were captured (in order; each committed with
`4b 01` and ACKed by an `07 01` event):

| # | effect (logo / ring) | segments (logo / ring) | palette (logo / ring) |
|---|----------------------|------------------------|-----------------------|
| 1 | `0x64` / `0x64` | 5 / 5 | teal `33ffcc` (frame 2 = `ff00cc`) |
| 2 | `0x28` / `0x28` | 2 / 2 | `006a80`,`000000` / `000000`,`fffe00` |
| 3 | `0x50` / `0x3c` | 3 / 3 | `ff3300`×3 / `ccff00`,`ff3200`,`ccff00` |
| 4 | `0x46` / `0x64` | 1 / 3 | `ff0099` / `00bfac`,`00ff33`,`b3ff00` |
| 5 | `0x4b` / `0x4b` | 1 / 1 | `ff0099` / `ff0099` |

Raw frames (logo then ring, per write):

```
# 1 - factory default (effect 0x64)
4c 00 64 05 ; 4d 00 00 33 ff cc 02 00 ; 4d 00 01 33 ff cc 02 02 ; 4d 00 02 ff 00 cc 02 04 ; 4d 00 03 33 ff cc 02 06 ; 4d 00 04 33 ff cc 02 08
4c 01 64 05 ; 4d 01 00 33 ff cc 05 00 ; 4d 01 01 33 ff cc 05 02 ; 4d 01 02 ff 00 cc 05 04 ; 4d 01 03 33 ff cc 05 06 ; 4d 01 04 33 ff cc 05 08
4b 01
# 2 - effect 0x28
4c 00 28 02 ; 4d 00 00 00 6a 80 02 00 ; 4d 00 01 00 00 00 01 02
4c 01 28 02 ; 4d 01 00 00 00 00 01 00 ; 4d 01 01 ff fe 00 05 08
4b 01
# 3 - logo effect 0x50, ring effect 0x3c
4c 00 50 03 ; 4d 00 00 ff 33 00 01 00 ; 4d 00 01 ff 33 00 00 02 ; 4d 00 02 ff 33 00 01 04
4c 01 3c 03 ; 4d 01 00 cc ff 00 05 00 ; 4d 01 01 ff 32 00 02 03 ; 4d 01 02 cc ff 00 05 07
4b 01
# 4 - logo effect 0x46, ring effect 0x64
4c 00 46 01 ; 4d 00 00 ff 00 99 03 00
4c 01 64 03 ; 4d 01 00 00 bf ac 03 00 ; 4d 01 01 00 ff 33 05 05 ; 4d 01 02 b3 ff 00 06 08
4b 01
# 5 - effect 0x4b
4c 00 4b 01 ; 4d 00 00 ff 00 99 03 00
4c 01 4b 01 ; 4d 01 00 ff 00 99 03 00
4b 01
```

Notes:

- The **speed byte** (`0x4c[2]`) is the tempo; the newest capture
  (`Switch RGB Speeds and Modes`) shows the speed slider maps `1x`=`0x4b`,
  `1.5x`=`0x32`, `2x`=`0x19`, with `0x64` the factory default (slowest).
  `0x19` (2x) is deliberately excluded from the safe set (fast/strobe). The
  **MODE** is the `0x4d` M byte (see the new section below).
- Recipe #2 (`effect 0x28, 2 segments`) is byte-identical to a table in the
  *older* capture - the protocol did not change structurally; the new
  firmware just exposes more effects.
- **No arming GET round** was captured before these writes (the older capture
  had `0x68, 0x67, 0x62, 0x5c, 0x75, 0x49, 0x51, 0x47, 0x4a, 0x45`), yet every
  write applied and was ACKed - the headset was likely already armed, or the
  new firmware does not require arming.
- The exact UI mode-name -> table mapping is not yet confirmed; "Light Sync
  On" appears to send **no** HID report at all.

## Speed & mode (newest capture: "Switch RGB Speeds and Modes")

`pcaps/06 JBL Quantum 810 - Switch RGB Speeds and Modes.pcapng` (newest
firmware) separates the two things the older "modes" capture conflated:

- **`0x4c[2]` = SPEED** (tempo). QuantumENGINE's speed slider emits
  `1x`=`0x4b`, `1.5x`=`0x32`, `2x`=`0x19` (the `0.5x` start value was not
  re-sent). Smaller byte = faster; `0x19` is the fastest and reads as a
  strobe, so it is **excluded** from the safe set (the clamps pin it to
  `0x28`).
- **`0x4d[5]` (M) = MODE**. `Wave`=`0x02`, `Breathing`=`0x00`,
  `Glitch`=`0x03`, `Solid`=`0x01`.

Seven writes were captured (1 segment each, color `ff0099`, `last`=`0x00`):

| # | speed (`0x4c[2]`) | mode (`0x4d[5]`) |
|---|-------------------|------------------|
| 1 | `0x4b` | `0x02` (Wave) |
| 2 | `0x32` | `0x02` (Wave) |
| 3 | `0x19` | `0x02` (Wave) |
| 4 | `0x19` | `0x00` (Breathing) |
| 5 | `0x19` | `0x03` (Glitch) |
| 6 | `0x19` | `0x01` (Solid) |
| 7 | `0x19` | `0x02` (Wave) |

This corrects the earlier note that the `0x4c` byte "selects the mode": it is
the speed; the mode lives in the `0x4d` M byte.
