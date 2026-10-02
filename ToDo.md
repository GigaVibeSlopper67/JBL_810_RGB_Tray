Observations with the LED:
- When I use the light change Feature it turns the light off. When I turn it back on it is lit up again in the chosen color but i am getting mix ups over time like described in the following points.
- The option to turn it white does only make the logo white. And it cycles through red, and it doesn't affect ring color.
- Setting it to color blue makes the Color cycle through blue and red
- The option to turn it red has a last second of blue in it.
- Picking a color like yellow actually creates white.
- My Asumption: The JBL headset has some weird color Palette.
- Seting to Factory Teal doesn't seem to cxhange the colors.
- The "Pick a color" feature only affects the Logo and not the Ring.
    - Also the color seems to added to the sequence with residue of the previous color. 

For the color management: I am assuming that something in the implementation is mixing up the colors.
Would resetting the colors before each change maybe fix these mixups?

---

Diagnosis (2026-09-17, from the observations above) - implemented in the tray and `tools/jbl_rgb.py`:

- Not a weird device palette and not a GTK picker bug (the picker converts
  0-1 floats to 0-255 bytes correctly). Two real causes in the write path:
  1. **Dropped writes**: all 14 SET_REPORTs (arm -> 4b 00 -> 6 reports per
     zone -> 4b 01) were sent back-to-back with no pacing. The ring's
     reports are the LAST in the burst and were dropped entirely - that is
     why "Pick a color" only ever changed the logo. Partially dropped logo
     frames also leave stale segments in the running effect.
  2. **Stale segments (the "residue")**: the device's color table holds
     more than the 5 segments we write, so old colors keep cycling. The
     factory table itself contains a red/magenta segment at index 2
     (`ff 00 cc`) - that is the "red" residue seen with white/blue.
     "Yellow -> white" is the new yellow (255,255,0) blended with a stale
     blue (0,0,255) residue.
- Fix implemented: every color change now (a) paces each SET_REPORT by
  ~20 ms (`LIGHT_SET_DELAY` / `--delay`) and (b) overwrites the whole
  table with 16 identical segments per element (`LIGHT_RESET_SEGMENTS` /
  `--segments 16`) - i.e. the "reset the colors before each change" idea,
  done by overwriting (no separate clear report is known; `0x4c`/`0x4d`
  have no read-back either).
- Verify with `tools/jbl_rgb.py`: blue -> red (no blue tail), yellow
  (stays yellow, no white), `--element ring --solid 00ff00` (ring must
  change), `--default --lights on` (factory teal restored).

---

Round 2 (2026-09-17, after the live test):
- Colors now apply correctly (white worked, the ring is reachable) - the
  pacing fixed the dropped-write side. Two follow-ups from that test:
  - The 16-segment table pulsed "super fast": the `0x4c` segment count
    sets how many segments share the tempo cycle - higher count = faster
    pulse. The write is now TWO passes: a clearing pass (16 identical
    frames, wipes stale colors) followed by the final QuantumENGINE-shape
    table (5 frames = stock pulse tempo). CLI knobs: `--reset-segments`
    (clear pass) / `--segments` (final table, default 5).
  - The paced writes blocked the GTK main loop (tray felt "very slow"/
    froze): the lighting write now runs in a background worker thread
    (busy-guarded, renders via `GLib.idle_add`).
- Open: a slight teal residue was still visible in white - if it comes
  back, widen the clearing pass (`--reset-segments 32`) to find the
  device's real table size.

---

Round 3 (2026-09-17, "very slow" clarified = latency until the lighting reacts):
- Cause: every change re-ran the 12-GET arming round plus 48 paced SETs
  (20 ms each) -> ~1.5 s until the commit. Fixes:
  - the arming round is skipped while fresh (`LIGHT_ARM_TTL` = 60 s; the
    armed state persists for several minutes - verified earlier),
  - the per-SET pause is 10 ms (tray: `--lighting-delay`, CLI: `--delay`),
  - rapid menu clicks are coalesced: the newest color is queued and
    applied right after the in-flight write (nothing is dropped).
- Expected reaction time now ~0.5 s per change. If color mixing ever
  reappears at 10 ms, raise the delay back to 0.02 - dropped writes are
  worse than latency.

---

Round 4 (2026-09-17, "turn off doesn't register" + rapid flashing):
- The rapid flashing = the device was still playing a 16-slot table from
  the earlier single-pass writes (tempo cycle divided over 16 segments).
- The lights toggle could lose a race: an in-flight lighting write ends
  with its own lights-on commit, silently re-lighting the headset after a
  toggle. Fixed: "Lights: toggle" now aborts an in-flight write (the
  toggle is authoritative; a later color pick re-enables the write) and
  logs the `0x4a` read-back after every toggle.
- Live device state during the diagnosis: `4b 00` accepted but no `0x07`
  ACK; `0x4a` answered `4a 00 00 02` (4-byte payload, dongle view = off).
  Factory table re-written (clear pass + final 5-segment pass), lights
  left off - the next lights-on applies stock teal at stock tempo.
- Headset power-off: hold the power button ~10 s. If unresponsive, replug
  the dongle first (resets the lighting pipeline and the arming state),
  then hold power again. Sound/charging working = core firmware is fine;
  the lighting controller recovers on replug. QuantumENGINE on Windows
  can always restore the lighting defaults.
- QuantumENGINE could NOT control the lights either while the headset was
  wedged (installed on a Windows system) - the lighting MCU ignores
  everything until a dongle replug / headset power cycle. Note: an active
  dongle (QuantumENGINE polling or our GET polling) can wake/keep the
  headset alive - to power it off, unplug the dongle first, then hold
  power 15-30 s.

---

Round 5 (2026-09-23, after parsing the original QuantumENGINE capture in
`pcaps/`): the RGB lockup / strobe was caused by the 16/32-segment
"clearing pass". The capture shows QuantumENGINE only ever sends **2 or 5**
segments, tempo **0x28/0x32/0x64**, frame index **0..4**, last byte **0..8**,
and M byte **0x00/0x01/0x02/0x04/0x05**. The code now hard-clamps every
lighting value to these ranges (`MAX_SEGMENTS` / `LIGHT_MAX_SEGMENTS`,
`SAFE_TEMPOS` / `LIGHT_SAFE_TEMPOS`, `SAFE_MODES` / `LIGHT_SAFE_MODES`),
and the `LIGHT_RESET_SEGMENTS` / `RESET_SEGMENTS` defaults dropped from 16
to 5. The arming GET round was also aligned to the captured order
(`0x68, 0x67, 0x62, 0x5c, 0x75, 0x49, 0x51, 0x47, 0x4a, 0x45`).

Round 6 (2026-10-02, after parsing the newest-firmware capture
`pcaps/JBL Quantum 810 Switch between RGB Modes.pcapng`): the safe set was
wider than Round 5 assumed. The `0x4c` 3rd byte is really an **effect/mode
selector** (not just a tempo), and the newest firmware emits segment counts
**1/3/5**, effect bytes **0x28/0x32/0x3c/0x46/0x4b/0x50/0x64**, and `0x4d`
`M` bytes **0x00..0x06**. The `0x4d` last byte is a **per-segment parameter,
not `index*2`** (it never was - the older capture already had `4d 01 01 ff fe
00 05 08`). `SAFE_TEMPOS`/`LIGHT_SAFE_TEMPOS` and `SAFE_MODES`/
`LIGHT_SAFE_MODES` were expanded accordingly; the hard cap remains
`MAX_SEGMENTS`/`LIGHT_MAX_SEGMENTS = 5` (only segment counts above 5 wedge the
MCU). The 5 captured mode recipes are recorded in `docs/RGB_SAFE_RANGES.md`.
Two open items: the exact UI mode-name -> table mapping, and why the new
capture has no arming GET round (see the same doc).

Round 7 (2026-10-02, granular RGB from the tray): the tray's `Lighting`
submenu now exposes per-element and per-segment control - **Solid color…** +
presets (both elements), **Logo color…** / **Ring color…** (one element),
**Custom (segments)…** (a 2×5 swatch grid, one color per segment) and
**Reset to factory**. This uses the per-segment color list now accepted by
`build_lighting_reports` and an in-memory `_lighting_table`; the verified
safe write recipe (arm -> lights off -> clear pass -> final table -> lights
on) is unchanged.

---

Round 8 (2026-10-02, `pcaps/06 ... Switch RGB Speeds and Modes.pcapng`): the
"modes" vs "presets" confusion is resolved. The `0x4c` tempo byte is the
**SPEED** (`1x`=`0x4b`, `1.5x`=`0x32`, `2x`=`0x19`; `0.5x` start value not
re-sent) and the `0x4d` M byte is the **MODE** (`Wave`=`0x02`,
`Breathing`=`0x00`, `Glitch`=`0x03`, `Solid`=`0x01`). `0x19` (2x) is the
fastest speed and reads as a strobe on a wedged MCU, so it is deliberately
kept OUT of `SAFE_TEMPOS`/`LIGHT_SAFE_TEMPOS` (the clamp pins it to `0x28`).
Comments/docstrings in `tools/jbl_rgb.py` and `jbl_quantum_810_910_tray.py`
now say "speed byte"/"mode byte" instead of "tempo/effect"/"M"; the same
correction is in `docs/RGB_SAFE_RANGES.md` and `docs/HID_REPORTS.md`.