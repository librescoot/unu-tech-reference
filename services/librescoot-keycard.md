# librescoot-keycard

## Description

The keycard service handles NFC-based authentication for the scooter using a Python script that interfaces with the PN7150 NFC reader. It detects NFC keycards, checks UIDs against authorized and master lists, controls LED feedback, and publishes authentication events to Redis. The service supports master learning mode on first boot, learn mode for adding new authorized cards, and simple UID-based authentication.

## Implementation

- **Language:** Python 3
- **Main script:** `/opt/librescoot-keycard/keycard.py`
- **NFC library:** PN7150 Python library
- **NFC demo app:** `/usr/sbin/nfcDemoApp poll` (NXP NFC demo application)
- **Helper scripts:**
  - `/usr/bin/keycard.sh` - Redis publication script
  - `/usr/bin/ledcontrol.sh` - PWM LED control
  - `/usr/bin/greenled.sh` - I2C LED control

## Configuration Files

### UID Storage

- **Location:** `/data/keycard/`
- **Files:**
  - `authorized_uids.txt` - List of authorized keycard UIDs (one per line)
  - `master_uids.txt` - Master UID for entering learn mode (single UID)

### Systemd Unit

- **Unit file:** `/usr/lib/systemd/system/librescoot-keycard.service`
- **Service name:** `librescoot-keycard.service`
- **Started by:** systemd at boot (after redis.service and librescoot-vehicle.service)
- **Type:** simple
- **Restart policy:** always
- **Working directory:** `/opt/librescoot-keycard`
- **Memory limit:** 128MB (LimitAS)

## Redis Operations

### Hash: `keycard`

**Fields written by `/usr/bin/keycard.sh`:**
- `authentication` - Always "passed" when authorized UID detected
- `type` - Always "scooter"
- `uid` - Always "11111111111111" (hardcoded placeholder)
- **Expiration:** 10 seconds

**Published channel:** `keycard`
- Message: "authentication" (published when authorized keycard detected)

Note: The current implementation uses a hardcoded placeholder UID value in the Redis publication script. The actual detected UID is logged but not published to Redis.

## Hardware Interfaces

### NFC Reader

- **Chip:** PN7150 NFC controller
- **Interface:** I2C (device path managed by PN7150 library)
- **Application:** `/usr/sbin/nfcDemoApp poll` (NXP demo application)
- **Detection:** Polls continuously for ISO14443 Type A/B tags
- **UID format:** NFCID1 hex string (e.g., "04A1B2C3D4E5F6")

The service parses output from nfcDemoApp looking for lines containing `NFCID1 :` followed by the UID value.

### LED Controllers

#### I2C LED (Green/Red/Amber) - LP5562

- **Interface:** I2C bus 2, address 0x30
- **Controlled by:** `/usr/bin/greenled.sh`
- **Colors:**
  - Green: `greenled.sh 1` or `greenled.sh green`
  - Red: `greenled.sh red`
  - Amber: `greenled.sh amber`
  - Off: `greenled.sh 0` (or any other argument)

#### PWM LEDs

- **Interface:** `/dev/pwm_led[N]` character devices
- **Controlled by:** `/usr/bin/ledcontrol.sh <led_number> <mode>`
- **Usage:** `ledcontrol.sh [1-7] [0-10]`
- **Modes:**
  - 2: Linear on
  - 3: Linear off
  - 10: Blink

## Operational Modes

### 1. Master Learning Mode (First Boot)

Activated when `/data/keycard/master_uids.txt` does not exist.

**Behavior:**
1. Service starts with green LED blinking (0.5s on, 0.5s off)
2. First NFC card detected becomes the master UID
3. Master UID saved to `/data/keycard/master_uids.txt`
4. Green LED stops blinking
5. PWM LEDs 3 and 7 blink to confirm
6. Service switches to normal operation mode

**Visual feedback:**
- Blinking green LED: Waiting for master card
- PWM LEDs 3+7 blink: Master learned successfully

### 2. Normal Operation Mode

Standard mode after master UID is set.

**When authorized UID detected:**
1. Green LED turns on
2. Execute `/usr/bin/keycard.sh` (publishes to Redis)
3. Wait 1 second
4. Green LED turns off

**When master UID detected:**
1. Enter learn mode
2. PWM LEDs 3 and 7 turn on (linear-on mode)

**When unauthorized UID detected:**
- Log "Unauthorized UID detected: [uid]"
- No LED feedback
- No action taken

### 3. Learn Mode

Activated by presenting the master UID in normal operation mode.

**Behavior:**
1. PWM LEDs 3 and 7 remain on (indicating learn mode active)
2. Any non-master UID presented is added to learning queue
3. For each learned UID:
   - Green LED turns on
   - PWM LED 1 blinks 3 times
   - Wait 1 second
   - Green LED turns off
4. Present master UID again to exit learn mode
5. All learned UIDs saved to `/data/keycard/authorized_uids.txt`
6. PWM LEDs 3 and 7 turn off (linear-off mode)
7. Authorized UID list reloaded from file

**Visual feedback:**
- PWM LEDs 3+7 on: Learn mode active
- Green LED + PWM LED 1 blinks: UID learned
- PWM LEDs 3+7 off: Learn mode exited

## Startup Sequence

1. Initialize PN7150Extended class
2. Check if `/data/keycard/master_uids.txt` exists
   - If missing: Enter master learning mode, start green LED blinking
   - If exists: Load master UIDs, turn off green LED
3. Load authorized UIDs from `/data/keycard/authorized_uids.txt` (creates empty list if missing)
4. Start nfcDemoApp polling process via PTY
5. Begin reading thread to parse NFC detection events

## Runtime Behavior

### UID Detection Flow

```
nfcDemoApp output → Parse "NFCID1 : [uid]" → Check mode:

Master Learning Mode?
  └─> Save as master_uids.txt → Exit master learning → Blink confirmation

Learn Mode Active?
  ├─> Master UID? → Exit learn mode → Save learned UIDs
  └─> Other UID? → Add to learning queue → Visual feedback

Normal Mode?
  ├─> Master UID? → Enter learn mode → Turn on PWM LEDs
  ├─> Authorized UID? → Green LED on → Execute keycard.sh → Green LED off
  └─> Unauthorized? → Log only
```

### Thread Safety

- Main thread: Runs nfcDemoApp subprocess and parses output
- Green LED blink thread: Daemon thread for master learning mode LED blinking
- Uses subprocess.run() for synchronous LED control
- Green LED blink thread stopped when master UID learned

## Log Output

The service logs to journald via stdout/stderr. Common log messages:

**Startup:**
- `No master UIDs file found. Entering master learning mode...`
- `Starting NFC tag reading in master learning mode...`
- `Starting NFC tag reading with UID checking...`

**Master Learning:**
- `Blink` (repeated while waiting for master card)
- `Learning first master UID: [uid]`
- `Master UID learned and saved. Switching to normal mode.`

**Learn Mode:**
- `Master UID detected: [uid] - Switching to learn mode`
- `UID detected: [uid] - Learning`
- `Master UID detected: [uid] - Switching off learn mode`
- `nothing learned` (if no cards learned)

**Normal Operation:**
- `Authorized UID detected: [uid] - Executing script`
- `Unauthorized UID detected: [uid]`

**Errors:**
- `Error controlling LED`

Use `journalctl -u librescoot-keycard.service` to view logs.

## Dependencies

### Hardware
- **PN7150 NFC reader** - Must be accessible via I2C
- **LP5562 LED controller** - I2C bus 2, address 0x30
- **PWM LED devices** - `/dev/pwm_led[1-7]` character devices

### Software
- **Python 3** - Runtime environment
- **PN7150 Python library** - NFC reader interface
- **NXP nfcDemoApp** - `/usr/sbin/nfcDemoApp` binary
- **Redis server** - Must be running (default: 127.0.0.1:6379)
- **i2cset utility** - For LP5562 LED control (i2c-tools package)
- **ioctl utility** - For PWM LED control

### Files
- **UID storage directory** - `/data/keycard/` must exist and be writable
- **Helper scripts** - `/usr/bin/keycard.sh`, `/usr/bin/ledcontrol.sh`, `/usr/bin/greenled.sh`

## Implementation Details

### UID Authentication

The service uses simple UID matching - no cryptographic authentication:
1. Read UID from nfcDemoApp output
2. Check if UID in `authorized_uids` list
3. If match: Execute keycard.sh and show green LED
4. If no match: Log and take no action

This is a basic authentication scheme suitable for access control but not cryptographically secure.

### NFC Detection

Uses NXP's nfcDemoApp in poll mode:
- Command: `/usr/sbin/nfcDemoApp poll`
- Output parsed via PTY (pseudo-terminal)
- Detects ISO14443 compliant cards
- Reads NFCID1 (UID) from card
- Continuous polling (card must remain present briefly)

### File Management

- Creates `/data/keycard/` directory automatically if missing
- `authorized_uids.txt`: Overwrites entire file when exiting learn mode
- `master_uids.txt`: Written once during master learning, contains single UID
- UIDs stored as plain text, one per line
- Empty lines and whitespace stripped when loading

### LED Control Methods

**I2C LED (greenled.sh):**
- Direct I2C register writes via i2cset
- Controls LP5562 chip registers
- Immediate on/off control

**PWM LED (ledcontrol.sh):**
- ioctl calls to PWM LED kernel driver
- Supports various modes (on, off, blink, etc.)
- Used for status indication during learning

## Related Documentation

- [Electronic Components](../electronic/README.md) - PN7150 and LP5562 hardware details
- [Redis Operations](../redis/README.md) - Keycard hash and expiration details
- [States](../states/README.md) - How keycard auth affects vehicle state
