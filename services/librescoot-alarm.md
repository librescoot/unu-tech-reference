# librescoot-alarm (alarm-service)

## Description

The alarm service is a **new LibreScoot feature** that provides motion-based security alarm functionality for the scooter. It uses an integrated BMX055 accelerometer/gyroscope to detect movement and trigger multi-level alarms with visual (hazard lights) and audible (horn) notifications.

## Version

LibreScoot alarm-service v0.10.0 (v1.0.5 pinned SRCREV a20b0c5)

## Command-Line Options

```
--i2c-bus=/dev/i2c-3           I2C bus device path for BMX055
--redis=localhost:6379         Redis address
--log-level=info               Log level (debug, info, warn, error)
--alarm-enabled=true           Enable alarm system (writes to Redis on startup)
--alarm-duration=10            Alarm duration in seconds
--horn-enabled=false           Enable horn during alarm (overrides Redis setting)
--seatbox-trigger=true         Trigger alarm on unauthorized seatbox opening
--hair-trigger=false           Enable hair trigger mode (immediate short alarm on first motion)
--hair-trigger-duration=3      Hair trigger alarm duration in seconds
--l1-cooldown=5                Level 1 cooldown duration in seconds
--evdev-device=/dev/input/by-path/platform-gpio-keys-event
                               Input device for the BMX055 INT1 gpio-keys edge (empty to disable and use poller only)
--evdev-keycode=0x2b           Keycode from gpio-keys device that corresponds to BMX055 INT1
--poller-interval-ms=1000      Interval in ms between I2C status polls (watchdog when the evdev path is active, primary source when evdev is disabled)
--version                      Print version and exit
```

## Redis Operations

### Hash: `alarm`

**Fields written:**

- `status` - Current alarm status:
  - `disabled` - Alarm system is disabled
  - `disarmed` - Alarm enabled but not armed (vehicle not in stand-by)
  - `delay-armed` - Arming delay in progress (5 seconds)
  - `armed` - Alarm is armed and monitoring for motion
  - `level-1-triggered` - Level 1 alarm (notification only)
  - `level-2-triggered` - Level 2 alarm (horn + hazards)
  - `seatbox-access` - Authorized seatbox opening; monitoring suspended until the seatbox closes
- `alarm-active` - "true" while the horn/hazard output is running, "false" once it stops

**Published channel:** `alarm`

### Hash: `settings`

**Fields read:**

- `alarm.enabled` - Alarm system enabled ("true"/"false")
- `alarm.honk` - Horn enabled during alarm ("true"/"false")
- `alarm.duration` - Alarm duration in seconds
- `alarm.seatbox-trigger` - Trigger alarm on unauthorized seatbox opening ("true"/"false")
- `alarm.hairtrigger` - Hair trigger mode enabled ("true"/"false")
- `alarm.hairtrigger-duration` - Hair trigger alarm duration in seconds
- `alarm.l1-cooldown` - Level 1 cooldown duration in seconds

**Fields written (if CLI flags set):**

- `alarm.enabled` - Overrides alarm enabled state
- `alarm.honk` - Overrides Redis value with CLI flag value
- `alarm.duration` - Overrides alarm duration
- `alarm.seatbox-trigger` - Overrides seatbox trigger setting
- `alarm.hairtrigger` - Overrides hair trigger setting
- `alarm.hairtrigger-duration` - Overrides hair trigger duration
- `alarm.l1-cooldown` - Overrides L1 cooldown duration

**Subscribed channels:** `settings` (listens for changes to alarm settings)

### Hash: `bmx`

**Fields written once at startup (informational; never updated afterwards):**

- `initialized` - always "true"
- `interrupt` - always "disabled"
- `sensitivity` - always "none"
- `pin` - always "none"

The live BMX configuration is not mirrored into Redis; it is applied over I2C directly.

### Lists consumed (BRPOP)

- `scooter:alarm` - Alarm control commands:
  - `enable` - Enable alarm system (writes to `settings alarm.enabled`)
  - `disable` - Disable alarm system (writes to `settings alarm.enabled`)
  - `arm` - Force immediate arming (transitions to `StateDelayArmed` without changing `alarm.enabled`)
  - `disarm` - Force disarm from any armed/triggered state (without changing `alarm.enabled`; alarm re-arms automatically on next standby)
  - `start:<seconds>` - Runs the horn/hazard output directly for N seconds (e.g., `start:30`); the FSM state and `alarm status` are not changed
  - `stop` - Stops the horn/hazard output immediately; the FSM state is not changed

### Lists produced (LPUSH)

- `scooter:horn` - Horn control (`on`, `off`)
- `scooter:blinker` - Blinker control (`both`, `off`)
- `scooter:power` - `hibernate-manual`, sent to pm-service to re-hibernate after a motion wake

### Subscribed Channels

- `vehicle` - Monitors vehicle state changes (payload: "state", "seatbox:lock", "seatbox:opened")
- `settings` - Monitors settings changes for alarm configuration
- `power-manager` - Watches `state`; a hibernating/hibernating-imminent value switches the armed BMX profile to the stricter hibernation threshold
- `bmx:interrupt` - Receives motion detection events from BMX055

## Alarm State Machine

The alarm service implements a 10-state finite state machine:

```
init → waiting_enabled → disarmed → delay_armed (5s) → armed
                                         ↑                ↓ motion detected
                                         |        trigger_level_1_wait (5s cooldown, configurable)
                                         |                ↓
                                         |        trigger_level_1 (5s check)
                                         |                ↓ major movement
                                         |        trigger_level_2 (50s, max 6 cycles)
                                         |________________|
```

### State Descriptions

- **init**: Initial state on startup
- **waiting_enabled**: Alarm disabled, waiting for enable command
- **disarmed**: Alarm enabled but vehicle not in stand-by
- **delay_armed**: 5-second delay before arming (allows user to leave)
- **armed**: Armed and monitoring for motion
- **trigger_level_1_wait**: Cooldown after motion detected (default 5s, configurable via `--l1-cooldown`; with hair trigger: immediate short alarm)
- **trigger_level_1**: 5-second check for continued movement
- **trigger_level_2**: Full alarm activated (horn + hazards, 50s duration, max 4 cycles)

### State Transitions

The alarm arms when:

- Alarm is enabled (`settings alarm.enabled` = "true")
- Vehicle enters `stand-by` state
- 5-second delay_armed period completes

The alarm triggers when:

- BMX055 detects motion while armed
- Level 1: Minor movement detected
- Level 2: Major movement detected or Level 1 continues

The alarm disarms when:

- Vehicle enters `parked`, `ready-to-drive` or `waiting-seatbox`. Other states, including `updating` and the hibernation-wait states, keep the alarm armed
- User disables alarm (`LPUSH scooter:alarm disable`)
- Runtime disarm (`LPUSH scooter:alarm disarm`). `stop` only silences the horn and hazards; it does not change FSM state

## Hardware Interfaces

### BMX055 Motion Sensor

The alarm service **directly controls** the BMX055 sensor via I2C (no separate bmx-service required):

- **Accelerometer (0x18):** Slow/no-motion interrupt detection
- **Gyroscope (0x68):** Opened and soft-reset alongside the accelerometer; not used for motion detection or interrupt validation
- **I2C Bus:** Default `/dev/i2c-3` (configurable via `--i2c-bus`)
- **Interrupt sources:** primary path is evdev key events from the gpio-keys node wired to BMX055 INT1 (`--evdev-device`, `--evdev-keycode=0x2b`); an I2C status poll every 1000 ms acts as a watchdog (`--poller-interval-ms`), and is the only source when the evdev device is unavailable

### BMX055 Configuration

The service automatically configures BMX sensitivity based on alarm state:

| State | Wake Lock | Engine | Bandwidth | Threshold | Duration | INT Pin |
|-------|-----------|--------|-----------|-----------|----------|---------|
| init | No | slow-motion | 0x08 (7.81 Hz) | 0x14 | 0x02 | INT2 |
| waiting_enabled | No | slow-motion | 0x08 (7.81 Hz) | 0x14 | 0x02 | INT2 |
| disarmed | No | slow-motion | 0x08 (7.81 Hz) | 0x14 | 0x02 | NONE |
| delay_armed | Yes | slow-motion | 0x08 (7.81 Hz) | 0x14 | 0x02 | INT2 |
| armed | No | any-motion | 0x0A (31.25 Hz) | 0x06, or 0x08 when hibernation is imminent | 0x03 | BOTH (INT1 for the evdev/poll path, INT2 for nRF wake) |
| trigger_level_1_wait | Yes | unchanged (soft reset only) | - | - | - | unchanged |
| trigger_level_1 | Yes | slow-motion | 0x09 (15.63 Hz) | 0x08 | 0x03 | BOTH |
| trigger_level_2 | Yes | unchanged (soft reset only) | - | - | - | unchanged |
| waiting_movement | Yes (held from trigger_level_2) | slow-motion | 0x08 (7.81 Hz) | 0x06 | 0x03 | NONE, programmed 47s into the 50s window |
| seatbox_access | Yes | slow-motion | 0x08 (7.81 Hz) | 0x14 | 0x02 | NONE |

**Note:** threshold is 1 LSB = 3.91 mg in the 2 g range, and duration N means N+1 consecutive samples above threshold. Bandwidth is not uniform: the armed profile runs at 31.25 Hz and the Level 1 profile at 15.63 Hz; only the idle and waiting profiles sit at 7.81 Hz.

### Alarm Outputs

**Horn Pattern:**

- 400ms on, 400ms off alternating (800ms per cycle)
- Runs for integral cycles only (no partial honks)
- Active during Level 2 trigger and hair trigger (if enabled)
- Controlled via `scooter:horn` list

**Hazard Lights:**

- Continuous during Level 2 alarm
- Controlled via `scooter:blinker` list (`both` command)

## Configuration

### Settings via Redis

```bash
# Enable alarm system
redis-cli HSET settings alarm.enabled true
redis-cli PUBLISH settings alarm.enabled

# Enable horn during alarm
redis-cli HSET settings alarm.honk true
redis-cli PUBLISH settings alarm.honk

# Enable hair trigger mode (immediate short alarm on first motion)
redis-cli HSET settings alarm.hairtrigger true
redis-cli PUBLISH settings alarm.hairtrigger

# Set hair trigger duration to 5 seconds
redis-cli HSET settings alarm.hairtrigger-duration 5
redis-cli PUBLISH settings alarm.hairtrigger-duration

# Disable seatbox trigger
redis-cli HSET settings alarm.seatbox-trigger false
redis-cli PUBLISH settings alarm.seatbox-trigger
```

### Settings via Command Line

CLI flags override Redis settings when explicitly provided:

```bash
# Enable horn and hair trigger
alarm-service --horn-enabled=true --hair-trigger=true --hair-trigger-duration=3

# Disable seatbox trigger
alarm-service --seatbox-trigger=false

# Use Redis settings (default)
alarm-service
```

## Observable Behavior

### Startup Sequence

1. Opens I2C bus to BMX055
2. Connects to Redis
3. Initializes BMX055 accelerometer and gyroscope
4. Reads alarm settings from Redis
5. Starts the I2C interrupt poller (1000ms interval by default) and opens the evdev interrupt watcher if the gpio-keys device is present
6. Enters `init` state, then `waiting_enabled` or `disarmed`

### Arming Sequence

When vehicle enters `stand-by` with alarm enabled:

1. State: `disarmed` → `delay_armed`
2. 5-second countdown begins
3. BMX055 configured with the idle slow-motion profile (7.81 Hz, threshold 0x14), INT2 only
4. After 5 seconds: `delay_armed` → `armed`
5. BMX055 reconfigured with the armed any-motion profile (31.25 Hz, threshold 0x06), both INT pins mapped
6. Alarm now monitoring for motion

**Startup fast-track:** On startup with alarm enabled and vehicle already in `stand-by`, the 5-second delay is skipped and the alarm goes directly to `armed`. INT2 only carries an interrupt while a motion engine is mapped to it (the any-motion engine in the armed states), so an INT2 wakeup from hibernation is self-proving — no file-based persistence required.

### Level 1 Trigger (Notification)

1. BMX055 detects motion
2. State: `armed` → `trigger_level_1_wait`
3. Hazard lights blink three times (600ms on, 400ms off)
4. If hair trigger enabled: immediate short alarm (horn + hazards) for configured duration
5. Cooldown period (default 5 seconds, `alarm.l1-cooldown` / `--l1-cooldown`)
6. If motion continues: `trigger_level_1_wait` → `trigger_level_1`
7. 5-second verification period
8. If no major movement: returns to `delay_armed`, and to `armed` 5 seconds later
9. If major movement detected: escalates to Level 2

### Level 2 Trigger (Full Alarm)

1. Major movement detected during Level 1
2. State: `trigger_level_1` → `trigger_level_2`
3. Horn activated (400ms on/off pattern) if enabled
4. Hazard lights activated (continuous)
5. Alarm duration: 50 seconds per cycle, alternating `trigger_level_2` and `waiting_movement`
6. Maximum 6 cycles (roughly 10 minutes) before the FSM gives up
7. On give-up the FSM drops to `disarmed`, which starts a 5-minute post-alarm cooldown before re-arming. With no further motion, `waiting_movement` instead falls through to `delay_armed` and back to `armed`

### Disarming

Alarm disarms when:

- Vehicle enters `parked`, `ready-to-drive` or `waiting-seatbox` (user unlocks)
- Alarm disabled via `LPUSH scooter:alarm disable`
- Runtime disarm via `LPUSH scooter:alarm disarm` (`stop` only silences horn and hazards)

## Suspend Inhibitor Management

The alarm service uses wake locks to prevent system suspend during critical states:

- **delay_armed**: Wake lock held during 5-second arming delay
- **trigger_level_1_wait** and **trigger_level_1**: Wake lock acquired at the start of the Level 1 cooldown and held across the Level 1 check
- **trigger_level_2** and **waiting_movement**: Wake lock held for the whole Level 2 cycle
- **seatbox_access**: Wake lock held while an authorized seatbox opening is in progress

This ensures the alarm can complete its sequence even if the power manager tries to suspend.

## Testing

### Enable and Test Alarm

```bash
# Enable alarm
redis-cli HSET settings alarm.enabled true
redis-cli PUBLISH settings alarm.enabled

# Enable horn
redis-cli HSET settings alarm.honk true
redis-cli PUBLISH settings alarm.honk

# Put vehicle in stand-by (arms alarm after 5s)
redis-cli HSET vehicle state stand-by
redis-cli PUBLISH vehicle state

# Monitor alarm status
redis-cli SUBSCRIBE alarm

# Watch for state changes
redis-cli HGET alarm status
```

### Manual Alarm Trigger

```bash
# Trigger alarm for 10 seconds (testing)
redis-cli LPUSH scooter:alarm start:10

# Stop alarm immediately
redis-cli LPUSH scooter:alarm stop
```

### Enable/Disable Commands

```bash
# Enable alarm system (persistent, writes settings)
redis-cli LPUSH scooter:alarm enable

# Disable alarm system (persistent, writes settings)
redis-cli LPUSH scooter:alarm disable
```

### Runtime Arm/Disarm (Without Changing Settings)

```bash
# Force arming now via delay_armed (the 5-second delay still applies, doesn't change alarm.enabled)
redis-cli LPUSH scooter:alarm arm

# Force disarm without disabling (alarm will re-arm on next standby)
redis-cli LPUSH scooter:alarm disarm
```

## Log Output

The alarm service logs to stdout/stderr (captured by systemd). Common log patterns:

- BMX055 initialization
- State transitions
- Motion detection events
- Interrupt polling status
- Horn and hazard commands
- Configuration changes

Use `journalctl -u librescoot-alarm` to view logs.

## Dependencies

- **BMX055 sensor** - Must be accessible via I2C
- **Redis server** - For configuration and command/control
- **vehicle service** - Monitors vehicle state for arming
- **Horn control** - Via vehicle service or dedicated GPIO
- **Blinker control** - Via vehicle service LED system

## LibreScoot Feature

The alarm service is a LibreScoot-only feature providing:

- Motion-based theft detection
- Multi-level alarm system
- Integrated BMX055 control (simplified architecture)
- Configurable horn and hazard patterns
- Redis-based control and monitoring

## Related Documentation

- [BMX055 Datasheet](../electronic/README.md) - Accelerometer/gyroscope specifications
- [Redis Operations](../redis/README.md) - Alarm hash fields
- [Vehicle States](../states/README.md) - How vehicle state affects alarm arming
- [LibreScoot Services](README.md) - Complete service overview
