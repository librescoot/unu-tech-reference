# librescoot-vehicle (vehicle-service)

## Description

The vehicle service implements the vehicle state machine, managing transitions between states like stand-by, parked, ready-to-drive, and shutting-down. It monitors GPIO inputs (kickstand, brakes, blinker switch, seatbox button, handlebar sensors), controls PWM outputs (8-channel LED system, blinker LEDs, seatbox lock, handlebar lock), and coordinates with other services via Redis to determine when the vehicle is ready to drive.

## Command-Line Options

```
Usage of vehicle-service:
  -log int
        Service log level (0=NONE, 1=ERROR, 2=WARN, 3=INFO, 4=DEBUG) (default 3)
```

**Note:** vehicle-service has minimal command-line options. Redis host and port are hardcoded to 127.0.0.1:6379. Most configuration is done via Redis and hardware interfaces.

## Redis Operations

### Hash: `vehicle`

**Fields written:**
- `state` - Vehicle state (see States section below)
- `brake:left` - Left brake state ("on", "off")
- `brake:right` - Right brake state ("on", "off")
- `blinker:state` - Blinker active state ("on", "off")
- `blinker:switch` - Blinker switch position ("left", "right", "both", "off")
- `horn:button` - Horn button state ("on", "off")
- `seatbox:button` - Seatbox button state ("on", "off")
- `seatbox:lock` - Seatbox lock state ("open", "closed")
- `kickstand` - Kickstand position ("up", "down")
- `main-power` - Main power state ("on", "off")
- `handlebar:position` - Handlebar position ("on-place", "off-place")
- `handlebar:lock-sensor` - Handlebar lock sensor ("locked", "unlocked")

**Published channel:** `vehicle`

### Lists consumed (BRPOP)

- `scooter:state` - State change commands ("lock", "unlock", "lock-hibernate", "force-lock")
- `scooter:seatbox` - Seatbox commands ("open")
- `scooter:horn` - Horn commands ("on", "off")
- `scooter:blinker` - Blinker commands ("left", "right", "both", "off")
- `scooter:led:cue` - LED cue playback commands (integer cue index)
- `scooter:led:fade` - LED fade playback commands ("channel:fadeIndex")
- `scooter:update` - Update commands ("start", "complete", "start-dbc", "complete-dbc", "cycle-dashboard-power")
- `scooter:hardware` - Hardware control commands ("dashboard:on", "dashboard:off", "engine:on", "engine:off", "handlebar:lock", "handlebar:unlock")

### Hashes read

- `dashboard` - Reads `ready` field to check if dashboard initialized
- `settings` - Reads behavior settings (e.g., `scooter.brake-hibernation`)
- `ota` - Reads OTA status for DBC updates (`status:dbc`)

### Channels subscribed (PUBSUB)

- `dashboard` - Dashboard ready notifications (payload: "ready")
- `keycard` - Keycard authentication events (payload: "authentication")
- `ota` - OTA update notifications
- `power-manager` - Power manager events
- `vehicle` - Vehicle state change notifications
- `settings` - Settings update notifications (payload: setting key that changed)

### Channels published

- `vehicle` - All vehicle state changes and sensor updates
- `buttons` - Button press events for immediate UI response (horn, seatbox, brakes, blinkers)

### Commands sent to other services

- `scooter:power` - Hibernation command ("hibernate-manual")

## Vehicle States

The service implements the canonical vehicle state machine with these states:

- `init` - Initial/uninitialized state
- `stand-by` - Powered but motor disabled
- `parked` - Unlocked with kickstand down
- `ready-to-drive` - All conditions met, motor enabled
- `waiting-seatbox` - Waiting for seatbox to close
- `shutting-down` - Transitioning to power down (~4s)
- `updating` - OTA firmware update in progress
- `waiting-hibernation` - Manual hibernation sequence (15s initial hold, then 30s confirmation timeout)
- `waiting-hibernation-advanced` - Deprecated (unused in current implementation)
- `waiting-hibernation-seatbox` - Hibernation confirmation phase with seatbox open notification
- `waiting-hibernation-confirm` - Final 3-second non-abortable hibernation confirmation

### Hibernation State Machine

The manual hibernation sequence works as follows:

1. **Idle** → **Initial Hold** (15s): Both brakes pressed continuously
2. **Initial Hold** → **Waiting Hibernation**: After 15s, enter confirmation phase
3. **Waiting Hibernation**: User can release brakes or keep holding
   - If brakes released: 30s timeout starts (can be reset by touching brakes)
   - If brakes held continuously for 30s total: auto-confirm (skip seatbox check)
   - If brakes re-pressed after release: hold for 15s to auto-confirm
4. **Keycard tap** or **continuous hold timeout**: Check safety conditions (kickstand down, seatbox closed)
5. **Waiting Hibernation Confirm**: 3-second final countdown before hibernation

See [States Documentation](../states/README.md) for complete state machine.

## Hardware Interfaces

### GPIO Inputs (via /dev/input)

- **Input device:** `/dev/input/by-path/platform-gpio-keys-event`

**Monitored inputs:**
- `kickstand` - Kickstand position sensor (true = down, false = up)
- `brake_left` - Left brake lever sensor (true = pressed)
- `brake_right` - Right brake lever sensor (true = pressed)
- `blinker_left` - Left blinker button
- `blinker_right` - Right blinker button
- `horn_button` - Horn button
- `seatbox_button` - Seatbox unlock button
- `seatbox_lock_sensor` - Seatbox lock position sensor (true = closed, false = open)
- `handlebar_position` - Handlebar position sensor (true = on-place, false = off-place)
- `handlebar_lock_sensor` - Handlebar lock sensor (true = unlocked, false = locked)
- `48v_detect` - 48V power detection

### GPIO Outputs (via gpiocdev)

**Digital outputs:**
- `seatbox_lock` - Seatbox lock solenoid (GPIO chip 2, line 10) - pulsed for 200ms
- `horn` - Horn control (GPIO chip 2, line 9)
- `engine_brake` - Motor brake control (GPIO chip 2, line 11)
- `handlebar_lock_close` - Handlebar lock motor close (GPIO chip 4, line 6) - pulsed for 1100ms
- `handlebar_lock_open` - Handlebar lock motor open (GPIO chip 4, line 7) - pulsed for 1100ms
- `dashboard_power` - Dashboard power enable (GPIO chip 1, line 18)
- `engine_power` - Motor controller power enable (GPIO chip 2, line 17)

### PWM LED System

The service controls 8 PWM LED channels via the `imx_pwm_led` kernel module:

**LED device paths:** `/dev/pwm_led0` through `/dev/pwm_led7`

**PWM Configuration:**
- Period: 12000 ticks
- Prescaler: 0 (default)
- Invert: 0 (default)
- Repeat: 3

**LED patterns:**
- Fades: `/usr/share/led-curves/fades/fade*` (up to 4096 samples per fade)
- Cues: `/usr/share/led-curves/cues/cue*` (up to 16 cues)

**Blinker timing:**
- Blinker interval: 800ms

## Configuration

### Systemd Unit

- **Unit file:** `/usr/lib/systemd/system/librescoot-vehicle.service`
- **Binary:** `/usr/bin/vehicle-service`
- **Started by:** systemd at boot (after redis.service)
- **Restart policy:** Always
- **Priority:** Nice value -10
- **User:** root
- **Type:** idle

## Observable Behavior

### Startup Sequence

1. Connects to Redis at 127.0.0.1:6379
2. Reads saved vehicle state from Redis (if any)
3. Reads brake hibernation setting from Redis (`settings` hash, `scooter.brake-hibernation`)
4. Checks if DBC update is in progress (restores `dbcUpdating` flag if needed)
5. Reloads PWM LED kernel module (`rmmod imx_pwm_led && modprobe imx_pwm_led`)
6. Waits for `/dev/pwm_led0` to appear (up to 1 second)
7. Initializes hardware:
   - Opens all 8 LED device files (`/dev/pwm_led0` through `/dev/pwm_led7`)
   - Configures PWM parameters for each channel
   - Sets adaptive mode for non-blinker LEDs (channels 0, 1, 2, 5)
   - Activates all LED channels
   - Loads LED fades and cues from `/usr/share/led-curves/`
   - Plays initial LED cue (cue 0)
   - Opens GPIO input device
   - Opens GPIO output lines
8. Checks initial handlebar lock sensor state
9. Registers input callbacks for all monitored inputs
10. Publishes initial sensor states to Redis
11. Restores LED state based on saved vehicle state (if parked or ready-to-drive)
12. Marks system as initialized
13. Handles initial dashboard ready state (if dashboard was already ready)
14. Publishes initial vehicle state to Redis
15. Transitions from `init` to `stand-by` if still in init state
16. Starts Redis listeners (PUBSUB and BRPOP)

### State Machine Behavior

#### Ready-to-Drive Conditions

Vehicle enters `ready-to-drive` when ALL are true:
- Dashboard ready (`dashboard` hash `ready` field = "true")
- Kickstand up
- Current state is `parked`

**Manual Ready-to-Drive Activation:**
In `parked` state, if dashboard is not ready, pressing the seatbox button while:
- Kickstand is up
- Both brakes are held

Will manually transition to `ready-to-drive` and blink the main light once for confirmation.

#### Lock/Unlock Handling

**Lock command** (`LPUSH scooter:state lock`):
1. Must be in `parked` state
2. Transitions to `shutting-down`
3. After ~4 seconds, transitions to `stand-by`
4. Power manager then suspends/hibernates

**Unlock command** (`LPUSH scooter:state unlock`):
1. Reads kickstand state
2. If dashboard ready and kickstand up: transitions to `ready-to-drive`
3. Otherwise: transitions to `parked` (if currently in `stand-by`)

**Lock-Hibernate command** (`LPUSH scooter:state lock-hibernate`):
1. Must be in `parked` state
2. Sets hibernation request flag
3. Transitions to `shutting-down`
4. Sends "hibernate-manual" command to power manager via `scooter:power` list

**Force-Lock command** (`LPUSH scooter:state force-lock`):
1. Sets `forceStandbyNoLock` flag
2. Immediately transitions to `stand-by` without handlebar locking
3. Used for emergency shutdown or special cases (e.g., DBC update)

#### Hibernation Sequence

**Brake-lever hibernation** (can be disabled via `settings` hash `scooter.brake-hibernation` = "disabled"):

1. **Trigger:** Both brakes pressed in `parked` state for 15 seconds
2. **Initial Hold (15s):** Brakes must be held continuously
   - If brakes released: sequence cancelled, return to `parked`
   - After 15s: transition to `waiting-hibernation` state
3. **Confirmation Phase:**
   - User can release brakes or keep holding
   - If brakes released: 30-second timeout starts
     - Timeout can be reset by touching brakes again
     - If timeout expires: cancel hibernation, return to `parked`
   - If brakes held continuously for 30s total from start: auto-confirm (warehouse mode)
   - If brakes re-pressed after release: hold for 15s to auto-confirm
   - **Keycard tap during confirmation:** triggers immediate safety check and confirmation
4. **Safety Checks:**
   - Kickstand must be down (always required)
   - Seatbox must be closed (skipped for auto-confirm scenarios)
   - If seatbox open: transition to `waiting-hibernation-seatbox` state to notify user
5. **Final Confirmation:**
   - Transition to `waiting-hibernation-confirm` state
   - 3-second non-abortable countdown
   - Then transition to `shutting-down` with hibernation flag
   - Send "hibernate-manual" command to power manager

**Keycard force-standby:**
- Tap keycard 3 times while holding brake lever
- Immediately transitions to `stand-by` without handlebar lock
- Useful for emergency situations or servicing

#### Blinker Control

The service implements automatic blinker logic:
- Blink interval: 800ms
- Physical blinker switches only work in active states (parked, ready-to-drive, waiting states)
- In other states, blinker control comes from software commands only
- LED cues used:
  - Cue 9: LED_BLINK_NONE (blinkers off)
  - Cue 10: LED_BLINK_LEFT (left blinker)
  - Cue 11: LED_BLINK_RIGHT (right blinker)
  - Cue 12: LED_BLINK_BOTH (hazard lights)
- Publishes blinker switch and state changes to Redis
- Publishes immediate button events to `buttons` channel for UI response

#### Seatbox Control

**Open command** (`LPUSH scooter:seatbox open`):
1. Pulses seatbox lock solenoid for 200ms
2. Publishes seatbox opened event to `vehicle` channel (payload: "seatbox:opened")

**Button press:**
- In `parked` state: pressing seatbox button opens seatbox
- In other states: button press is logged but no action taken
- Button events published to `buttons` channel for UI feedback
- Pressing seatbox button cancels any active hibernation sequence

#### Brake Control

**Brake state handling:**
- Brake pressed: plays LED cue 4 (LED_BRAKE_OFF_TO_BRAKE_ON)
- Brake released: plays LED cue 5 (LED_BRAKE_ON_TO_BRAKE_OFF)
- Engine brake logic:
  - In `ready-to-drive`: engine brake follows brake levers (engaged if either pressed)
  - In all other states: engine brake always engaged (motor disabled)
- Brake state published to Redis (`vehicle` hash, `brake:left` and `brake:right`)
- Button events published to `buttons` channel for immediate UI response

**Park debounce:**
- After entering `ready-to-drive`, kickstand down events are ignored for 1 second
- Prevents accidental transition to parked during kickstand retraction

### Command Processing

Commands are consumed via BRPOP with 5-second timeout:
- `scooter:state` - State change commands
- `scooter:seatbox` - Seatbox control
- `scooter:horn` - Horn control
- `scooter:blinker` - Blinker control
- `scooter:led:cue` - LED cue playback
- `scooter:led:fade` - LED fade playback
- `scooter:update` - Update coordination
- `scooter:hardware` - Direct hardware control

### Fault Detection

The service supports fault reporting via Redis:
- Faults are added to the `vehicle:fault` set (using SADD)
- Fault events are logged to the `events:faults` stream (using XADD)
- Fault notifications published to `vehicle` channel (payload: "fault")
- Fault codes are numeric identifiers
- Cleared faults are reported with negative code values

Current implementation does not actively monitor for faults, but the infrastructure is in place for future fault detection.

## Log Output

The service logs to journald. Common log patterns:
- State transitions (e.g., "Transitioning from PARKED to READY_TO_DRIVE")
- Input events (e.g., "Input kickstand => true")
- Command processing (e.g., "Received command from scooter:state: lock")
- Redis operations (e.g., "Publishing vehicle state: parked")
- Hardware operations (e.g., "Seatbox lock toggled for 0.2s")
- LED operations (e.g., "Playing LED cue 4")
- Hibernation sequence events
- Button events published to UI
- Settings updates

**Log levels:**
- 0 = NONE: No logging
- 1 = ERROR: Fatal errors only
- 2 = WARN: Warnings and errors
- 3 = INFO: Informational messages (default)
- 4 = DEBUG: Detailed debugging output

**View logs:**
```bash
journalctl -u librescoot-vehicle.service
journalctl -u librescoot-vehicle.service -f  # Follow mode
journalctl -u librescoot-vehicle.service --since "10 minutes ago"
```

## Dependencies

**Required:**
- **Redis server** - Must be running at 127.0.0.1:6379
- **GPIO input device** - `/dev/input/by-path/platform-gpio-keys-event`
- **GPIO chip devices** - For digital outputs (gpiochip1, gpiochip2, gpiochip4)
- **PWM LED kernel module** - `imx_pwm_led` must be loadable
- **PWM LED device files** - `/dev/pwm_led0` through `/dev/pwm_led7`
- **LED curve files** - `/usr/share/led-curves/fades/` and `/usr/share/led-curves/cues/`

**Optional:**
- **dashboard** - Service waits for `dashboard ready` = "true" before allowing ready-to-drive
- **keycard** - Authentication via keycard events
- **settings-service** - For persistent settings like brake-hibernation
- **update-service** - For OTA update coordination
- **power-manager** - For hibernation execution

## LibreScoot Implementation Details

The LibreScoot **vehicle-service** is a Go-based implementation with the following architecture:

### Technical Implementation

- **Language:** Go (Golang)
- **Concurrency:** Uses goroutines for parallel I/O handling
- **GPIO library:** `github.com/warthog618/go-gpiocdev` for digital I/O
- **Redis library:** `github.com/redis/go-redis/v9` for Redis operations
- **System calls:** `golang.org/x/sys/unix` for low-level hardware access
- **Binary size:** Optimized for ARM Cortex-A7 architecture
- **Cross-compilation:** Supports AMD64 for development/testing

### Key Features

- **Enhanced LED control:** Full 8-channel PWM LED system with adaptive and active/inactive modes
- **Robust hibernation:** Multi-stage hibernation state machine with safety checks
- **Settings integration:** Dynamic settings updates via Redis PUBSUB
- **Update coordination:** Handles DBC dashboard updates with power state management
- **Button feedback:** Immediate button event publishing for responsive UI
- **State persistence:** Saves and restores vehicle state across reboots
- **Graceful shutdown:** Proper cleanup of hardware resources and timers

### LED Channel Mapping

LibreScoot vehicle-service controls 8 PWM LED channels:

| Index | LED Name              | Description                    | Mode     |
|-------|-----------------------|--------------------------------|----------|
| 0     | Headlight            | Main front illumination       | Adaptive |
| 1     | Front ring           | Front accent lighting          | Adaptive |
| 2     | Brake light          | Rear brake indicator           | Adaptive |
| 3     | Blinker front left   | Left front turn signal        | Active/Inactive |
| 4     | Blinker front right  | Right front turn signal       | Active/Inactive |
| 5     | Number plates        | License plate illumination    | Adaptive |
| 6     | Blinker rear left    | Left rear turn signal         | Active/Inactive |
| 7     | Blinker rear right   | Right rear turn signal        | Active/Inactive |

### LED Channel Modes

- **Adaptive Mode** (channels 0,1,2,5): When enabled, the channel adapts fade playback by finding the first duty-cycle value in the fade that is nearest to the current duty-cycle, then starting the fade from that point. This prevents abrupt brightness jumps during transitions between different LED states. Non-blinker channels use adaptive mode for smooth transitions.

- **Active/Inactive Mode** (channels 3,4,6,7): Controls whether fade values are actually output to the LED. When active, fade values are set as the channel's duty-cycle normally. When inactive, the output is forced to 0% regardless of the fade being played. Blinker channels rely on precise active/inactive control for their flashing patterns and do NOT use adaptive mode.

**Kernel module:** The PWM LED system is implemented via the `imx_pwm_led` kernel module, which provides `/dev/pwm_led*` character devices for each channel. The service reloads this module on startup to ensure clean state.

See [i.MX PWM LED kernel module documentation](https://github.com/unumotors/kernel-module-imx-pwm-led/blob/master/README.md) for detailed mode specifications and ioctl interface.

### Special Features

**DBC Update Support:**
During DBC (Dashboard Controller) firmware updates:
- Dashboard power is kept on regardless of vehicle state
- Power state changes are deferred until update completes
- Dashboard power can be cycled remotely via `scooter:update` command
- Service tracks update status via `ota` hash `status:dbc` field

**Force Standby:**
Three keycard taps while holding brake lever triggers immediate transition to standby without handlebar lock. Useful for:
- Emergency situations
- Service/warehouse operations
- Forcing standby when handlebar lock is non-functional

**Settings Integration:**
The service responds to settings changes via PUBSUB:
- `scooter.brake-hibernation`: "enabled" or "disabled"
- Changes take effect immediately
- Active hibernation sequences are cancelled when disabled

### Architecture

**Package structure:**
- `cmd/vehicle-service/` - Main entry point
- `internal/core/` - Core system logic and state machine
- `internal/hardware/` - Hardware I/O abstraction (GPIO, LED)
- `internal/messaging/` - Redis communication layer
- `internal/types/` - Shared type definitions
- `internal/logger/` - Leveled logging implementation

**Concurrency model:**
- Main goroutine handles system coordination
- Separate goroutines for:
  - Redis PUBSUB listener
  - 8 Redis BRPOP command listeners (one per list)
  - Blinker timer (when active)
  - Various hardware timers (hibernation, shutdown, handlebar lock)
- Thread-safe state access via sync.RWMutex

**Error handling:**
- Hardware errors are logged but don't crash the service
- Redis disconnection causes service exit (systemd will restart)
- Invalid commands are logged and rejected
- State transition errors are logged and may be retried

### Building

```bash
# Build for ARM Cortex-A7 (default target)
make build

# Build for AMD64 (development/testing)
make build-amd64

# Output: bin/vehicle-service
```

### Compatibility

LibreScoot vehicle-service maintains Redis protocol compatibility:
- Same hash fields and structure as original implementation
- Same command interface (LPUSH to command lists)
- Same PUBSUB channel usage
- Compatible with any dashboard that follows the LibreScoot Redis protocol
- No changes required to other services

### Integration Points

LibreScoot vehicle-service integrates with:
- **Redis** - Central message bus (required)
- **Dashboard service** - Waits for ready signal before allowing drive
- **Settings service** - Reads persistent behavior settings
- **Update service** - Coordinates OTA firmware updates
- **Power manager** - Sends hibernation commands
- **Keycard service** - Receives authentication events
- **UI/HMI** - Publishes button events for immediate feedback

## Related Documentation

- [Vehicle States](../states/README.md) - Complete state machine documentation
- [Redis Operations](../redis/README.md) - Redis protocol and data structures
- [LibreScoot Services Overview](librescoot-services.md) - All LibreScoot services
- [i.MX PWM LED kernel module](https://github.com/unumotors/kernel-module-imx-pwm-led) - LED hardware interface

## Source Code

- **Repository:** `/home/teal/src/librescoot/vehicle-service/`
- **Language:** Go 1.21+
- **License:** CC BY-NC-SA 4.0 (Creative Commons Attribution-NonCommercial-ShareAlike 4.0)
- **Main files:**
  - `cmd/vehicle-service/main.go` - Entry point
  - `internal/core/system.go` - Main system logic
  - `internal/core/state_transitions.go` - State machine
  - `internal/core/redis_handlers.go` - Redis command handlers
  - `internal/messaging/redis.go` - Redis client
  - `internal/hardware/io.go` - GPIO operations
  - `internal/hardware/leds.go` - LED control
  - `internal/hardware/constants.go` - Hardware constants
