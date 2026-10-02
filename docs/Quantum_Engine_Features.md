# Observations on the Quantum engine Software features

## USB Features (Assumed or confirmed)

### RGB Features

#### Presets

There are several RGB Presets with cool Names, I previously mistook these for modes:

- Spectrum
- Sound is Survival
- Sniper
- Dystopia
- Arena

#### Modes
These modes affect how the RGB is moving.
The actual modes seem to be the following:
- Breathing 
- Glitch 
- Solid 
- Wave

#### Speeds
Quantum Engine only has these speed settings for the LED Moving Speed:
- 0.5x
- 1.0x
- 1.5x
- 2.0x 

#### Light Synch

This means that the Logo and the Ring have the same color when it is on.
It is a separate on/off switch.

#### Byte mapping (from the USB captures)

- **Mode** = the `0x4d` frame M byte: `Wave` = `0x02`, `Breathing` = `0x00`,
  `Glitch` = `0x03`, `Solid` = `0x01`.
- **Speed** = the `0x4c` header tempo byte: `1x` = `0x4b`, `1.5x` = `0x32`,
  `2x` = `0x19` (`0.5x` was the start value and was not re-sent). `0x19` (2x)
  is the fastest and is deliberately excluded from the tool's safe set (see
  `docs/RGB_SAFE_RANGES.md`).

### Audio Features

#### Side Tone

has several modes:

- Off
- Low
- Mid
- High

Turning on side tone turns off ANC completely -> ANC is greyed out in this
mode and not toggleable.

Turning side tone off restores the previous ANC state.

#### Muting

- You can Mute via button or boom arm
- Boom Arm up = Muted, it overrides the button.
- When the boom arm is up -> Side Tone is greyed out in this mode and not
  toggleable

### Power Saving / Auto Power Off

The auto power-off / power-saving timeout **is a dongle setting** (unlike
DRC and the sound profile below). QuantumENGINE sends it as a HID
SET_REPORT(Feature) on interface 5, report id `0x75`, with the timeout in
**5-minute units**:

| Setting | `0x75` value |
|---------|--------------|
| OFF     | `0x00` |
| 30 min  | `0x06` |
| 1 h     | `0x0c` |
| 2 h     | `0x18` |

Decoded from `pcaps/07 - JBL Quantum 810 Switch Auto power Off modes.pcapng`
(SET `0x75 0c/0x06/0x00` for 1 h / 30 min / off). `0x18` (2 h) is inferred -
2 h was the initial value and never re-sent - but it matches the `0x75` GET
read-back (`[0x75, 0x18, 0x02, …]`). The GET and SET share the same id `0x75`
(no `0x74` mirror), and there is no event ACK - the value is confirmed via the
`0x75` read-back only.

## Software-Only Features (Confirmed)

### DRC

There is also a feature called "DRC" in the "more" tab. It stops loud sound
from getting distorted and amplifies quiet sound for better recordings. It is
a feature meant to improve recordings. (DRC is applied in software: toggling
it generates no USB traffic, so it is not a dongle setting - same as the
Natural/Bright/Powerful sound profile. Only the side tone level
off/low/mid/high goes over USB as 0x5d.)
