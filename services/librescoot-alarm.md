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
                               Input device for the BMX055 INT1 gpio-keys edge
                               (empty to disable and use the poller only)
--evdev-keycode=43             Keycode (0x2b) from the gpio-keys device for BMX055 INT1
--poller-interval-ms=1000      Interval in ms between I2C status polls; watchdog when
                               the evdev path is active, primary source when it is not
--version                      Print version and exit
```

## Redis Operations

### Hash: `alarm`

**Fields written:**
- `status` - Current alarm status:
  - `disabled` - Alarm system is disabled
  - `disarmed` - Alarm enabled but not armed (vehicle not in stand-by)
  - `delay-armed` - 5-second arming delay running
  - `armed` - Alarm is armed and monitoring for motion
  - `level-1-triggered` - Level 1 alarm (states `trigger_level_1_wait` and `trigger_level_1`)
  - `level-2-triggered` - Level 2 alarm (states `trigger_level_2` and `waiting_movement`)
  - `seatbox-access` - Authorized seatbox opening, motion detection suspended
  - `unknown` - Fallback while the FSM is still in `init`
- `alarm-active` - "true" while the horn/hazard output is running, "false" otherwise

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

**Fields written (once at startup only):**
- `initialized` - always written as "true"
- `interrupt` - always written as "disabled"
- `sensitivity` - always written as "none"
- `pin` - always written as "none"

These four fields are set once by the startup status publish and are never updated
again as the FSM reprograms the sensor, so they do not reflect the live BMX055
configuration. The active profile is only visible in the service log.

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

The BMX055 is driven directly over I2C; there is no `scooter:bmx` command list.

### Subscribed Channels

- `vehicle` - Monitors vehicle changes (payloads `state`, `seatbox:lock`, `seatbox:opened`)
- `settings` - Monitors settings changes for alarm configuration
- `power-manager` - Monitors `state`; a `hibernating*`/`hibernating*-imminent` value switches the armed BMX profile to the stricter hibernation thresholds
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
                                         |        trigger_level_2 (50s) <-> waiting_movement (50s), max 6 cycles
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
- Vehicle enters `parked`, `ready-to-drive` or `waiting-seatbox`. Other states, including `shutting-down` and `waiting-hibernation`, leave the alarm armed
- User disables alarm (`LPUSH scooter:alarm disable`)
- Runtime disarm (`LPUSH scooter:alarm disarm`)

## Hardware Interfaces

### BMX055 Motion Sensor

The alarm service **directly controls** the BMX055 sensor via I2C (no separate bmx-service required):

- **Accelerometer (0x18):** Slow/no-motion interrupt detection
- **Gyroscope (0x68):** Probed and soft-reset alongside the accelerometer; its rate data is not read for alarm decisions
- **I2C Bus:** Default `/dev/i2c-3` (configurable via `--i2c-bus`)
- **Interrupt sources:** an evdev watcher on the BMX055 INT1 gpio-keys edge (`/dev/input/by-path/platform-gpio-keys-event`, keycode 0x2b) is the fast path; an I2C status poller runs every 1000 ms (`--poller-interval-ms`) as a watchdog, and is the only source when the evdev device is unavailable or disabled

### BMX055 Configuration

The service automatically configures BMX sensitivity based on alarm state:

| State | Wake Lock | Motion engine | Bandwidth | Threshold | Duration | INT Pin |
|-------|-----------|---------------|-----------|-----------|----------|---------|
| init / waiting_enabled | No | slow-motion | 7.81 Hz (0x08) | 0x14 | 0x02 | INT2 |
| disarmed | No | slow-motion | 7.81 Hz (0x08) | 0x14 | 0x02 | NONE |
| delay_armed | Yes | slow-motion | 7.81 Hz (0x08) | 0x14 | 0x02 | INT2 |
| armed | No | any-motion | 31.25 Hz (0x0A) | 0x06, or 0x08 when hibernation is imminent | 0x03 | BOTH (INT1 for polling, INT2 for nRF wake) |
| trigger_level_1_wait | Yes | soft reset only, profile unchanged | - | - | - | unchanged |
| trigger_level_1 | Yes | slow-motion | 15.63 Hz (0x09) | 0x08 | 0x03 | BOTH |
| trigger_level_2 | Yes | soft reset only, profile unchanged | - | - | - | unchanged |
| waiting_movement | Yes | slow-motion | 7.81 Hz (0x08) | 0x06 | 0x03 | NONE (reprogrammed 47s into the state) |
| seatbox_access | Yes | slow-motion | 7.81 Hz (0x08) | 0x14 | 0x02 | NONE |

**Note:** the accelerometer bandwidth is not constant. It is 7.81 Hz, 15.63 Hz or 31.25 Hz depending on the state, and the armed state uses the any-motion (slope) engine rather than slow/no-motion. There is no LOW/MEDIUM/HIGH sensitivity applied by the FSM.

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
3. Hazard lights flash three times (600ms on / 400ms off)
4. If hair trigger enabled: immediate short alarm (horn + hazards) for configured duration
5. Cooldown of `alarm.l1-cooldown` seconds (default 5)
6. If motion continues: `trigger_level_1_wait` → `trigger_level_1`
7. 5-second verification period
8. If no major movement: returns to `delay_armed`, and to `armed` 5 seconds later
9. If major movement detected: escalates to Level 2

### Level 2 Trigger (Full Alarm)

1. Major movement detected during Level 1
2. State: `trigger_level_1` → `trigger_level_2`
3. Horn activated (400ms on/off pattern) if enabled
4. Hazard lights activated (continuous)
5. Horn/hazard burst runs for `alarm.duration` seconds (default 10); the `trigger_level_2` state itself lasts 50 seconds
6. After 50 seconds the FSM moves to `waiting_movement`; renewed motion starts another Level 2 cycle, up to 6 cycles per episode
7. No motion during `waiting_movement`: -> `delay_armed` -> `armed`. Cycle cap reached: -> `disarmed`, with a 5-minute quiet window before re-arming

### Disarming

Alarm disarms when:
- Vehicle enters `parked`, `ready-to-drive` or `waiting-seatbox` (user unlocks)
- Alarm disabled via `LPUSH scooter:alarm disable`
- Runtime disarm via `LPUSH scooter:alarm disarm`

`LPUSH scooter:alarm stop` only silences the horn and hazards; it does not change the FSM state.

## Suspend Inhibitor Management

The alarm service uses wake locks to prevent system suspend during critical states:

- **delay_armed**: Wake lock acquired for the 5-second arming delay
- **trigger_level_1_wait**: Wake lock acquired when Level 1 fires, and held through `trigger_level_1`
- **trigger_level_2**: Wake lock acquired for the full alarm
- **seatbox_access**: Wake lock acquired for an authorized seatbox opening

The lock is released on entering `armed`, `disarmed` or `waiting_enabled`, and on leaving `seatbox_access`.

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
# Force arm from disarmed (still goes through the 5-second delay_armed state, doesn't change alarm.enabled)
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

Use `journalctl -u librescoot-alarm` to view logs. The unit installed by meta-librescoot is `librescoot-alarm.service`.

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
