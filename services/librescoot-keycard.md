# librescoot-keycard (keycard-service)

## Description

Handles NFC-based authentication for the scooter. Detects keycards via the PN7150 controller, checks UIDs against authorized and master lists, controls LED feedback, and publishes authentication events to Redis. Supports master learning mode on first boot, learn mode for replacing the authorized card set, and a Redis command interface for UID management.

## Command-Line Options

```
  --device string       NFC device path (default: /dev/pn5xx_i2c2)
  --data-dir string     Directory for UID storage (default: /data/keycard)
  --redis string        Redis server address (default: localhost:6379)
  --log int             Log level 0-3 (0=error, 3=debug) (default: 2)
  --led-device string   I2C device for LP5662 LED (empty = script-based control)
  --led-address string  I2C address for LP5662 LED (default: 0x30)
  --debug               Enable debug logging
```

## Redis Operations

### Hash: `keycard` (written)

**Fields written on authentication:**
- `authentication` - `passed` when authorized UID detected
- `type` - `scooter`
- `uid` - UID of the card that authenticated (expires after 10 seconds)

**Fields written on command response:**
- `command-result` - Result of last management command (e.g. `ok`, `count:3`, `card:<uid>`, `error:<reason>`)

**Published channel:** `keycard`
- `authentication` - Published when authorized keycard detected

### List: `scooter:keycard` (consumed)

Management commands via LPUSH:

| Command | Response |
|---------|----------|
| `list` | `count:<n>` then one `card:<uid>` per authorized card |
| `count` | `count:<n>` |
| `add:<uid>` | `ok` or `error:<reason>` |
| `remove:<uid>` | `ok` or `error:<reason>` (cannot remove last card) |
| `set-master:<uid>` | Sets master UID; use `NONE` to disable; clears authorized list |
| `learn:start` | Enter learn mode programmatically |
| `learn:stop` | Exit learn mode, saving learned cards |

Responses are written to `keycard command-result`.

## Hardware

### NFC Reader
- **Chip:** PN7150, I2C interface at `/dev/pn5xx_i2c2`
- **Library:** [github.com/librescoot/pn7150](https://github.com/librescoot/pn7150)
- **UID format:** uppercase hex string (e.g. `04A1B2C3D4E5F6`)

### LED Controllers

**I2C LED (LP5662 tri-color):**
- I2C bus 2, address `0x30`
- Enabled with `--led-device /dev/i2c-2`
- Green: authorized card; Red: unauthorized; Amber: lookup in progress; Blinking: master learning mode

**PWM LEDs (learn mode):**
- `/dev/pwm_led3`, `/dev/pwm_led7` — on during learn mode
- Controlled via `/usr/bin/ledcontrol.sh`

**Script-based fallback** (when `--led-device` not set):
- `/usr/bin/greenled.sh` — color/on/off
- `/usr/bin/ledcontrol.sh` — PWM pattern control

## Operational Modes

### Master Learning Mode (first boot)

Activated when `master_uids.txt` does not exist:
1. RGB LED blinks (500ms) — waiting for master card
2. First card presented becomes master UID, saved to `master_uids.txt`
3. Authorized list cleared; RGB LED flashes once to confirm
4. Switches to normal operation

### Normal Operation

| Card type | LED | Redis |
|-----------|-----|-------|
| Authorized | Amber → Green flash | Publish auth, write UID |
| Master | Amber → enter learn mode | — |
| Unauthorized | Amber → Red flash | — |

### Learn Mode

Activated by presenting master UID or via `learn:start`:
1. PWM LEDs 3 + 7 turn on
2. Each new card presented: added to session queue, Green LED flash
3. Present master UID again or `learn:stop` to exit
4. If cards were learned: **replaces** entire authorized list in `authorized_uids.txt`
5. If no cards learned: existing list unchanged
6. PWM LEDs 3 + 7 turn off

## File Locations

| Path | Purpose |
|------|---------|
| `/data/keycard/authorized_uids.txt` | Authorized keycard UIDs (one per line) |
| `/data/keycard/master_uids.txt` | Master UID |

Files are written atomically (write to `.tmp`, sync, rename).

## Systemd Unit

- **Unit:** `librescoot-keycard.service`
- **Binary:** `/usr/bin/keycard-service`
- **Requires:** `redis.service`, `librescoot-vehicle.service`

## Building

```bash
make build        # ARM
make build-local  # Host
```

## Related Documentation

- [Electronic Components](../electronic/README.md) — PN7150 and LP5662 hardware
- [Redis Operations](../redis/README.md) — Keycard hash details
- [LibreScoot Services](README.md)
