# librescoot-keycard (keycard-service)

## Description

Handles NFC-based authentication for the scooter. Detects physical keycards via the PN7150 controller and authenticates enrolled Android HCE phone keys by signed, fresh ISO-DEP challenge. It controls LED feedback and publishes authentication events to Redis. Supports master bootstrap on first boot, additive learn mode for authorized cards and phones, and a Redis command interface for credential management.

Two physical-card roles do not overlap. An **authorized** card unlocks the vehicle. A **master** card starts learn mode and never unlocks anything. A UID can hold one role or the other, never both. A phone key is a separate unlock credential, not a master; it does not authenticate by RF UID.

**UID format.** Every UID entering the service, from a tag read, a command, or a UID file, is normalized to bare uppercase hex: `:`, `-`, `.` and spaces are stripped, and anything that is not 1-10 bytes of hex is rejected. Commands may therefore be written `add:04:A1:B2:C3` or `add:04a1b2c3` interchangeably. Malformed lines in the UID files are dropped at load and logged.

## Command-Line Options

```
  --device string       NFC device path (default: /dev/pn5xx_i2c2)
  --data-dir string     Directory for UID storage (default: /data/keycard)
  --redis string        Redis server address (default: localhost:6379)
  --log int             Log level 0-3 (0=error, 3=debug) (default: 2)
  --led-device string   I2C device for LP5562 LED (empty = script-based control)
  --led-address uint    I2C address for LP5562 LED (default: 48 / 0x30)
  --debug               Enable debug logging
```

## Redis Operations

### Hash: `keycard` (written)

**Fields written on authentication:**

- `authentication` - `passed` when authorized UID detected
- `type` - `scooter`
- `uid` - UID of the card that authenticated

A successful auth sets a 10-second TTL on the entire `keycard` key, so all three fields (and any `command-result` written before it) expire together.

**Fields written on command response:**

- `command-result` - Result of the last management command, as prose (e.g. `ok`, `count:3`, `card:<uid>`, `error:not found`)
- `command-error` - The same outcome as a machine-readable code, empty on success

Both are written in one operation, with the notification on `command-result`, so a reader woken by that notification always sees the matching pair. Read `command-error` and fall back to `command-result` when the field is absent, which is what a keycard-service too old to write it looks like.

The prose in `command-result` is a compatibility surface and has not changed. Match on the code:

| `command-error` | `command-result` |
|-----------------|------------------|
| `empty-uid` | `error:empty uid` |
| `bad-uid` | `error:invalid uid` |
| `already-authorized` | `error:already authorized` |
| `already-registered` | `error:already registered as a master` |
| `not-found` | `error:not found` |
| `invalid-alias` | `error:invalid alias` |
| `last-credential` | `error:cannot remove last authorized card` |
| `save-failed` | `error:save failed` |
| `unknown-command` | `error:unknown command` |
| `wrong-mode:<mode>` | the wording that command used before, e.g. `error:not in learn mode` |

`<mode>` is `idle`, `learn`, `master-teach-in` or `master-bootstrap`.

**Published channel:** `keycard`

- `authentication` - Published when authorized keycard detected

### List: `scooter:keycard` (consumed)

Management commands via LPUSH:

| Command | Response |
|---------|----------|
| `list` | `count:<n>` then one `card:<uid>` per authorized card |
| `count` | `count:<n>` |
| `add:<uid>` | `ok`, or `already-authorized` / `already-registered` / `bad-uid` |
| `remove:<uid>` | `ok`, or `not-found` / `last-credential`; `remove:<uid>:force` permits removal of the last unlock credential |
| `master:list` | `count:<n>` then one `master:<uid>` per master |
| `phone:list` | `count:<n>` then one `phone:<fingerprint>` per enrolled phone |
| `phone:remove:<fingerprint>` | Revoke a phone; refuses to remove the last unlock credential without `:force` |
| `phone:remove:<fingerprint>:force` | Revoke a phone even if it is the last unlock credential |
| `alias:list` | `count:<n>` then one `alias:<kind>:<id>:<base64url-name>` per name |
| `alias:set:<kind>:<id>:<base64url-name>` | Name an enrolled `card` (authorized or master) or `phone`; name is unpadded base64url UTF-8, at most 32 bytes decoded |
| `alias:clear:<kind>:<id>` | Clear an enrolled credential's name |
| `master:add:<uid>` | Append a master. `ok`, or `already-registered` |
| `master:remove:<uid>` | Drop a master. `ok`, or `not-found`. Removing the last one is allowed |
| `master:clear` | Empty the master list, keeping authorized cards. The next start re-arms bootstrap |
| `master:bootstrap-cancel` | Leave master bootstrap without writing anything, so the next tap is not learned as master. Idempotent |
| `set-master:<uid>` | Replace the master list with this single UID, or with `NONE` to record that this vehicle wants no physical master. Authorized cards are untouched |
| `learn:start` | Enter learn mode programmatically. Supersedes master bootstrap |
| `learn:stop` | Exit learn mode, saving learned cards (additive) |
| `learn:master:start` | Enter master teach-in mode; next unregistered tap is appended as an additional master. Supersedes master bootstrap |
| `learn:master:stop` | Exit master teach-in mode without committing. Also ends master bootstrap, which is what the installer sends it blind for |
| `reset` | Reset all auth state (masters, authorized cards, phones and names); fails if the phone credential file is unhealthy |

`master:bootstrap-cancel` is the explicit way to stop the next tap being learned as master. `learn:start`, `learn:master:start` and `learn:master:stop` also end the bootstrap, since a caller driving modes by command has already answered the question the bootstrap was waiting on. `set-master:NONE` persists a decision (no physical master on this vehicle, ever) and suppresses the bootstrap on later starts too; `master:bootstrap-cancel` applies to the current run only and writes nothing.

Responses are written to `keycard command-result` and `keycard command-error`; the error names in this table are `command-error` codes. Multi-entry replies have no request ID: serialize list requests and consume exactly the reported number of entries. The `last-credential` guard counts both authorized physical cards and phone keys.

### Credential projections

- `keycard:authorized`, `keycard:masters`, `keycard:phones` are Redis sets of authorized UIDs, master UIDs and 32-hex-character phone fingerprints for the dashboard. They are refreshed on startup and successful credential changes; empty sets are deleted.
- `keycard:aliases` is a Redis set of `<kind>:<id>:<plain-name>` members. Split only the first two colons; a name may contain colons. Changes to a credential or its name refresh this projection. The service publishes each changed set name on the `system` channel after refresh.
- `system[keycard-last-used-uid]` records the last *physical authorized card* used, and clears when that card is removed. `system[keycard-learn-state]` exposes the current teach-in state. Master and authorized card counts also live in `system`.
- Bluetooth-service advertises `keycard=2` for physical-card management, phone management, master-card listing and credential names. It forwards these commands to keycard-service.

### Channel: `keycard:events` (published)

Every state change is published here, whether a command or a tap on the reader caused it, so a subscriber (installer, BLE bridge) can stay in step with the vehicle rather than only hearing about what it asked for itself.

Format is `<event>[:<uid>][:<trigger>]`, where trigger is `card`, `command`, `bootstrap` or `teach-in`.

| Event | Meaning |
|-------|---------|
| `mode-entered:learn:<trigger>` / `mode-exited:learn:<trigger>` | Learn mode boundaries |
| `mode-entered:master` / `mode-exited:master` | Master teach-in boundaries (no trigger suffix) |
| `mode-entered:master-bootstrap:boot` | Boot-time bootstrap armed: the next card presented becomes master |
| `mode-exited:master-bootstrap:<trigger>` | Bootstrap ended, by a tap or by a command |
| `card-learned:<uid>` | Learn-mode tap, queued until `learn:stop` |
| `phone-learned:<fingerprint>` / `phone-duplicate:<fingerprint>` | Phone tap queued for enrollment / already enrolled or seen in this session |
| `phone-added:<fingerprint>` / `phone-removed:<fingerprint>` | Phone list changed |
| `phone-rejected` | Phone authentication rejected |
| `card-duplicate:<uid>` | Already registered, or already seen this session |
| `card-added:<uid>:command` / `card-removed:<uid>:command` | Authorized list changed by command |
| `access-granted:<uid>` | An authorized card unlocked the vehicle |
| `master-added:<uid>:<trigger>` / `master-removed:<uid>:command` | Master list changed |
| `master-learned:<uid>` | Teach-in success; the same fact as `master-added:<uid>:teach-in` |
| `masters-cleared` | Master list emptied |
| `rejected:already-authorized:<uid>` | Teach-in tap refused, UID already registered |
| `error:save-failed:<uid>` | Write to `/data/keycard` failed |
| `reset` | Both lists wiped |

## Hardware

### NFC Reader
- **Chip:** PN7150, I2C interface at `/dev/pn5xx_i2c2`
- **Library:** [github.com/librescoot/pn7150](https://github.com/librescoot/pn7150)
- **UID format:** uppercase hex string (e.g. `04A1B2C3D4E5F6`)

### LED Controllers

**I2C LED (LP5562 tri-color):**

- I2C bus 2, address `0x30`
- Enabled with `--led-device /dev/i2c-2`
- Green: authorized card; Red: unauthorized; Amber: lookup in progress and for the duration of learn mode; Blinking: master bootstrap or teach-in
- **Shared chip.** vehicle-service writes the same LP5562 (also via `I2C_SLAVE_FORCE` on `/dev/i2c-2`, address `0x30`) as the DBC blinker indicator when `settings[scooter.dbc-blinker-led]` is enabled. There is no arbitration: last writer wins, and blinker activity repaints whatever colour keycard-service left on the LED. keycard-service re-asserts the operating-mode, clock, enable and drive-current registers before every colour change, because vehicle-service leaves the chip on a lower drive current.
- A kernel `lp5562` driver is also bound to the chip and exposes `/sys/class/leds/{R,G,B,W}`. Both services bypass it deliberately.

**PWM LEDs (learn mode):**

- `/dev/pwm_led3`, `/dev/pwm_led7` — on during learn mode
- Controlled via `/usr/bin/ledcontrol.sh`

**Script-based fallback** (when `--led-device` not set):

- `/usr/bin/greenled.sh` — color/on/off
- `/usr/bin/ledcontrol.sh` — PWM pattern control

## Operational Modes

### Master Bootstrap (first boot)

Activated at startup when the master file is missing or empty, and only on a reader that has no authorized cards and is not in service mode. A vehicle with cards enrolled must not crown the owner's next tap: a master starts learn mode and never unlocks, so that card would stop opening the scooter. The `NONE` sentinel counts as an entry, so a vehicle that has recorded "no physical master" does not re-arm this either.

1. `mode-entered:master-bootstrap:boot` is published, and the RGB LED blinks (500 ms)
2. The **first card presented becomes the master**, saved to `master_uids.txt`
3. RGB LED flashes once to confirm; `master-added:<uid>:bootstrap` and `mode-exited:master-bootstrap:card` are published
4. Switches to normal operation

Authorized cards are not touched at any point. To leave this mode without a card, send `master:bootstrap-cancel`; to leave it and record that this vehicle wants no physical master at all, send `set-master:NONE`.

### Normal Operation

| Card type | LED | Redis |
|-----------|-----|-------|
| Authorized | Amber → Green flash | Publish auth, write UID |
| Master | Amber → enter learn mode | — (a master never unlocks) |
| Unauthorized | Amber → Red flash | — |

### Learn Mode

Activated by presenting master UID or via `learn:start`:

1. PWM LEDs 3 + 7 turn on; the RGB LED stays amber for the whole session when learn mode was entered by a card tap
2. Each new card presented: added to session queue, Green LED flash, then back to amber
3. Present master UID again or `learn:stop` to exit
4. Learned cards are **appended** to `authorized_uids.txt`; phone keys are appended to `phone_keys.txt` (additive)
5. If no cards learned: existing list unchanged
6. PWM LEDs 3 + 7 turn off, RGB LED turns off (a green flash first if cards were added)

### Android phone enrollment

Set up a device-bound phone key in the Android app's Keycards screen. Tap a master card to enter learn mode, present the unlocked Android phone with its screen and NFC on, then tap the master again to save it. A duplicate phone tap is rejected, not revoked. A fresh scooter needs its normal master/bootstrap setup first. Android NFC host card emulation is required; iOS/Apple Watch HCE is not implemented. Losing or reinstalling the app loses its Android Keystore key; revoke the old fingerprint and enroll the new one. Phone authentication uses a signed challenge, not the legacy physical-card UID. NFC challenge–response is not distance bounding and does not prevent live relays.

## File Locations

| Path | Purpose |
|------|---------|
| `/data/keycard/authorized_uids.txt` | Authorized keycard UIDs (one per line) |
| `/data/keycard/master_uids.txt` | Master UIDs (one per line; multiple masters supported). A single line reading `NONE` records that this vehicle wants no physical master |
| `/data/keycard/phone_keys.txt` | Android phone public keys (P-256 SPKI, hex-encoded, one per line) |
| `/data/keycard/key_aliases.json` | Optional scooter-owned display names, keyed by `card:<UID>` or `phone:<fingerprint>`; mode `0600` |

Credential files are written atomically (write to `.tmp`, sync, rename). UIDs are stored as bare uppercase hex, but any separator form is accepted on read, so hand-edited UID files work. Names are display metadata, not authentication inputs. Successful removals and reset prune names; snapshots filter orphaned names. An unreadable or invalid phone file disables phone authentication and phone management without disabling physical cards; it is not silently overwritten, and reset fails rather than claiming to revoke unknown phones. A damaged names file makes names read-only without disabling credentials.

`lsc keycard list` and `export` read the physical-card UID files directly because multi-entry command replies have no request correlation. Mutating commands go through the Redis interface while keycard-service is running, so its in-memory state and events remain authoritative. If the service is stopped or absent, lsc warns and falls back to editing the files directly; those fallback changes emit no events.

## Systemd Unit

- **Unit:** `librescoot-keycard.service`
- **Binary:** `/usr/bin/keycard-service`
- **Requires:** `valkey.service` (`redis.service` before Librescoot 1.2)
- **After:** `valkey.service`, `librescoot-vehicle.service`

## Building

```bash
make build        # ARM
make build-host   # Host
```

## Related Documentation

- [Electronic Components](../electronic/README.md) — PN7150 and LP5562 hardware
- [Redis Operations](../redis/README.md) — Keycard hash details
- [Librescoot Services](README.md)
