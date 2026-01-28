# librescoot-alarm (alarm-service)

## Description

The alarm service is a **new LibreScoot feature** that provides motion-based security alarm functionality for the scooter. It uses an integrated BMX055 accelerometer/gyroscope to detect movement and trigger multi-level alarms with visual (hazard lights) and audible (horn) notifications.

## Version

LibreScoot alarm-service v1.0.0+

## Command-Line Options

```
--i2c-bus=/dev/i2c-3           I2C bus device path for BMX055
--redis=localhost:6379         Redis address
--log-level=info               Log level (debug, info, warn, error)
--alarm-enabled=false          Enable alarm system (writes to Redis on startup)
--alarm-duration=10            Alarm duration in seconds
--horn-enabled=false           Enable horn during alarm (overrides Redis setting)
--seatbox-trigger=true         Trigger alarm on unauthorized seatbox opening
--hair-trigger=false           Enable hair trigger mode (immediate short alarm on first motion)
--hair-trigger-duration=3      Hair trigger alarm duration in seconds
--version                      Print version and exit
```

## Redis Operations

### Hash: `alarm`

**Fields written:**
- `status` - Current alarm status:
  - `disabled` - Alarm system is disabled
  - `disarmed` - Alarm enabled but not armed (vehicle not in stand-by)
  - `armed` - Alarm is armed and monitoring for motion
  - `level-1-triggered` - Level 1 alarm (notification only)
  - `level-2-triggered` - Level 2 alarm (horn + hazards)

**Published channel:** `alarm`

### Hash: `settings`

**Fields read:**
- `alarm.enabled` - Alarm system enabled ("true"/"false")
- `alarm.honk` - Horn enabled during alarm ("true"/"false")
- `alarm.duration` - Alarm duration in seconds
- `alarm.seatbox-trigger` - Trigger alarm on unauthorized seatbox opening ("true"/"false")
- `alarm.hairtrigger` - Hair trigger mode enabled ("true"/"false")
- `alarm.hairtrigger-duration` - Hair trigger alarm duration in seconds

**Fields written (if CLI flags set):**
- `alarm.enabled` - Overrides alarm enabled state
- `alarm.honk` - Overrides Redis value with CLI flag value
- `alarm.duration` - Overrides alarm duration
- `alarm.seatbox-trigger` - Overrides seatbox trigger setting
- `alarm.hairtrigger` - Overrides hair trigger setting
- `alarm.hairtrigger-duration` - Overrides hair trigger duration

**Subscribed channels:** `settings` (listens for changes to alarm settings)

### Hash: `bmx`

**Fields written (BMX055 control):**
- `initialized` - BMX sensor initialization status
- `interrupt` - Interrupt status
- `sensitivity` - Current sensitivity level (LOW/MEDIUM/HIGH)
- `pin` - Interrupt pin configuration

### Lists consumed (BRPOP)

- `scooter:alarm` - Alarm control commands:
  - `enable` - Enable alarm system
  - `disable` - Disable alarm system
  - `start:<seconds>` - Manual alarm trigger (e.g., `start:30`)
  - `stop` - Stop alarm immediately

### Lists produced (LPUSH)

- `scooter:bmx` - BMX055 configuration commands
- `scooter:horn` - Horn control (`on`, `off`)
- `scooter:blinker` - Blinker control (`both`, `off`)

### Subscribed Channels

- `vehicle` - Monitors vehicle state changes (payload: "state")
- `settings` - Monitors settings changes for alarm configuration
- `bmx:interrupt` - Receives motion detection events from BMX055

## Alarm State Machine

The alarm service implements an 8-state finite state machine:

```
init → waiting_enabled → disarmed → delay_armed (5s) → armed
                                         ↑                ↓ motion detected
                                         |        trigger_level_1_wait (15s cooldown)
                                         |                ↓
                                         |        trigger_level_1 (5s check)
                                         |                ↓ major movement
                                         |        trigger_level_2 (50s, max 4 cycles)
                                         |________________|
```

### State Descriptions

- **init**: Initial state on startup
- **waiting_enabled**: Alarm disabled, waiting for enable command
- **disarmed**: Alarm enabled but vehicle not in stand-by
- **delay_armed**: 5-second delay before arming (allows user to leave)
- **armed**: Armed and monitoring for motion
- **trigger_level_1_wait**: 15-second cooldown after motion detected (with hair trigger: immediate short alarm)
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
- Vehicle leaves `stand-by` state
- User disables alarm (`LPUSH scooter:alarm disable`)
- Alarm stopped manually (`LPUSH scooter:alarm stop`)

## Hardware Interfaces

### BMX055 Motion Sensor

The alarm service **directly controls** the BMX055 sensor via I2C (no separate bmx-service required):

- **Accelerometer (0x18):** Slow/no-motion interrupt detection
- **Gyroscope (0x68):** Rotation detection for interrupt validation
- **I2C Bus:** Default `/dev/i2c-3` (configurable via `--i2c-bus`)
- **Interrupt Polling:** 100ms polling loop monitoring accelerometer interrupt status

### BMX055 Configuration

The service automatically configures BMX sensitivity based on alarm state:

| State | Wake Lock | Sensitivity | INT Pin |
|-------|-----------|-------------|---------|
| armed | No | MEDIUM | NONE |
| delay_armed | Yes | LOW | INT2 |
| trigger_level_1 | Yes | MEDIUM | NONE |
| trigger_level_2 | Yes | HIGH | NONE |

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
5. Starts interrupt polling loop (100ms interval)
6. Enters `init` state, then `waiting_enabled` or `disarmed`

### Arming Sequence

When vehicle enters `stand-by` with alarm enabled:

1. State: `disarmed` → `delay_armed`
2. 5-second countdown begins
3. BMX055 configured with LOW sensitivity
4. After 5 seconds: `delay_armed` → `armed`
5. BMX055 reconfigured with MEDIUM sensitivity
6. Alarm now monitoring for motion

### Level 1 Trigger (Notification)

1. BMX055 detects motion
2. State: `armed` → `trigger_level_1_wait`
3. Hazard lights blink once
4. If hair trigger enabled: immediate short alarm (horn + hazards) for configured duration
5. 15-second cooldown period
6. If motion continues: `trigger_level_1_wait` → `trigger_level_1`
7. 5-second verification period
8. If no major movement: returns to `armed`
9. If major movement detected: escalates to Level 2

### Level 2 Trigger (Full Alarm)

1. Major movement detected during Level 1
2. State: `trigger_level_1` → `trigger_level_2`
3. Horn activated (400ms on/off pattern) if enabled
4. Hazard lights activated (continuous)
5. Alarm duration: 50 seconds
6. Maximum 4 cycles before returning to `armed`
7. State: `trigger_level_2` → `armed`

### Disarming

Alarm disarms when:
- Vehicle leaves `stand-by` (user unlocks)
- Alarm disabled via `LPUSH scooter:alarm disable`
- Manual stop via `LPUSH scooter:alarm stop`

## Suspend Inhibitor Management

The alarm service uses wake locks to prevent system suspend during critical states:

- **delay_armed**: Wake lock held during 5-second arming delay
- **trigger_level_1**: Wake lock held during Level 1 check
- **trigger_level_2**: Wake lock held during full alarm

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
# Enable alarm system
redis-cli LPUSH scooter:alarm enable

# Disable alarm system
redis-cli LPUSH scooter:alarm disable
```

## Log Output

The alarm service logs to stdout/stderr (captured by systemd). Common log patterns:

- BMX055 initialization
- State transitions
- Motion detection events
- Interrupt polling status
- Horn and hazard commands
- Configuration changes

Use `journalctl -u alarm-service` (or your systemd unit name) to view logs.

## Dependencies

- **BMX055 sensor** - Must be accessible via I2C
- **Redis server** - For configuration and command/control
- **vehicle service** - Monitors vehicle state for arming
- **Horn control** - Via vehicle service or dedicated GPIO
- **Blinker control** - Via vehicle service LED system

## Differences from unu Firmware

This is a **new LibreScoot feature** not present in original unu firmware. The alarm service provides:

- Motion-based theft detection
- Multi-level alarm system
- Integrated BMX055 control (simplified architecture)
- Configurable horn and hazard patterns
- Redis-based control and monitoring

## Related Documentation

- [BMX055 Datasheet](../electronic/README.md) - Accelerometer/gyroscope specifications
- [Redis Operations](../redis/README.md) - Alarm hash fields
- [Vehicle States](../states/README.md) - How vehicle state affects alarm arming
- [LibreScoot Services](librescoot-services.md) - Complete service overview
