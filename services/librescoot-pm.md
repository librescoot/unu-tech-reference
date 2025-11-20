# librescoot-pm (pm-service)

## Description

The power manager (pm-service) controls system power states including suspend, hibernation, and reboot. It coordinates with systemd-logind, monitors service activity via D-Bus inhibitors, tracks busy services via Redis, communicates with the nRF52840 for hibernation control, and implements delays before power transitions. The service manages both automatic and manual hibernation modes with configurable timers.

## Command-Line Options

```
Usage of pm-service:
  -default-state string
        Default power state (run, suspend, hibernate, hibernate-manual, hibernate-timer, reboot) (default "suspend")
  -dry-run
        Dry run state (don't actually issue power state changes)
  -hibernation-timer duration
        Duration of the hibernation timer (default 120h0m0s) [5 days]
  -inhibitor-duration duration
        Duration the system is held active after suspend is issued (default 500ms)
  -pre-suspend-delay duration
        Delay between standby and low-power-state-imminent state (default 1m0s)
  -redis-host string
        Redis host (default "localhost")
  -redis-port int
        Redis port (default 6379)
  -socket-path string
        Path for the Unix domain socket for inhibitor connections (default "/tmp/suspend_inhibitor")
  -suspend-imminent-delay duration
        Duration for which low-power-state-imminent state is held (default 5s)
```

**Note:** The hibernation timer default is 120 hours (5 days). The systemd unit file typically overrides the default state to `run` to prevent automatic suspends during development.

## Redis Operations

### Hash: `power-manager`

**Fields written:**
- `state` - Power manager state (see States section below)
- `wakeup-source` - IRQ number of wakeup source (e.g., "45" for RTC)

**Fields read:**
- None (hibernation timer settings now in `settings` hash)

**Published channel:** `power-manager`
- `state` - Published when power state changes
- `wakeup-source` - Published when system wakes from suspend

### Hash: `power-manager:busy-services`

**Fields written:**
- `<who> <why> <what>` - Inhibitor type ("block" or "delay")
- Example: `"pm-service default delay" = "delay"`
- Example: `"modem-service busy operation" = "block"`

This hash tracks which services are blocking suspend/hibernation via the Unix socket inhibitor interface.

**Published channel:** `power-manager:busy-services`
- `updated` - Published when inhibitors change

### Hash: `power:inhibits`

**Fields written/read:**
- `<inhibit-id>` - JSON data with inhibit request details
- Format: `{"id": "...", "reason": "downloading", "duration": ..., "defer": true/false}`

Used for programmatic inhibitor management (downloading, installing, etc.)

### Hash: `hibernation`

**Fields written:**
- `state` - Hibernation sequence state (idle, waiting-hibernation, waiting-hibernation-advanced, waiting-hibernation-seatbox, waiting-hibernation-confirm)

**Published channel:** `hibernation`
- `state` - Published when hibernation sequence state changes

### Hash: `settings`

**Fields read:**
- `hibernation-timer` - Hibernation timer duration in seconds

**Subscribed channel:** `settings`
- `hibernation-timer` - Notification when hibernation timer setting changes

### Hash: `system`

**Fields written:**
- `cpu:governor` - CPU governor setting (ondemand, powersave, performance)

**Published channel:** `system`
- `cpu:governor` - Published when CPU governor changes

### Lists consumed (BRPOP via HandleRequests)

- `scooter:power` - Power commands
  - `run` - Set target state to running (highest priority)
  - `suspend` - Request suspend
  - `hibernate` - Request hibernation
  - `hibernate-manual` - Manual hibernation (user-initiated)
  - `hibernate-timer` - Timer-based hibernation
  - `reboot` - System reboot

- `scooter:governor` - CPU governor commands
  - `ondemand` - On-demand frequency scaling
  - `powersave` - Power-saving mode
  - `performance` - Performance mode

### Lists published (LPUSH)

- `scooter:modem` - Commands sent to modem service
  - `disable` - Request modem shutdown before hibernation

### Hash subscriptions (field updates)

- `vehicle` → `state` - Vehicle state monitoring (stand-by, parked, etc.)
- `battery:0` → `state` - Battery state monitoring (idle, active, charging)

## Power Manager States

The service publishes these states to the `power-manager` hash in Redis:

- `running` - Normal operation (maps from internal "run" state)
- `suspend-imminent` - About to suspend (pre-suspend delay active)
- `suspending` - Suspend in progress
- `hibernate-imminent` - About to hibernate
- `hibernating` - Hibernation in progress
- `hibernate-manual-imminent` - Manual hibernation about to occur
- `hibernating-manual` - Manual hibernation in progress
- `hibernate-timer-imminent` - Timer hibernation about to occur
- `hibernating-timer` - Timer-based hibernation in progress
- `reboot-imminent` - About to reboot
- `reboot` - Reboot in progress

Internal power states (not directly published):
- `run` - Target state for normal operation
- `suspend` - Target state for suspend
- `hibernate` - Target state for hibernation
- `hibernate-manual` - Target state for manual hibernation
- `hibernate-timer` - Target state for timer hibernation
- `reboot` - Target state for reboot

See [States Documentation](../states/README.md) for complete state machine.

## Hardware Interfaces

### nRF52840 Communication

The power manager communicates with bluetooth-service service (which talks to nRF) via Redis:
- Monitors nRF reset information
- Commands hibernation via `scooter:power` list
- nRF firmware handles actual hardware power control

### Hibernation Levels

When hibernating, the nRF firmware selects between two levels based on CB battery charge:
- **L1:** CB battery >5%, periodic wakeup checks
- **L2:** CB battery ≤5%, switches to AUX battery, minimal power

See [nRF Power Management](../nrf/power-management.md) for details.

## Configuration

### Systemd Unit

- **Unit file:** `librescoot-pm.service` (installed to systemd system directory)
- **Binary location:** `/usr/bin/pm-service`
- **Started by:** systemd at boot (requires redis.service)
- **Restart policy:** on-failure with 5 second delay
- **User/Group:** root (required for systemd power operations)

### Dry-Run Mode

When started with `--dry-run`, the service:
- Operates normally
- Does NOT actually suspend/hibernate the system
- Logs all power state transitions
- Useful for testing power management logic

### Delay Configuration

Command-line flags control timing:
- **Pre-suspend delay** (`-pre-suspend-delay`): Time after stand-by before entering imminent state (default: 1m)
- **Suspend imminent delay** (`-suspend-imminent-delay`): Minimum duration in imminent state (default: 5s)
- **Inhibitor duration** (`-inhibitor-duration`): How long system stays active after suspend request (default: 500ms)

These delays allow services to complete operations before power down.

### Default Power State

The `-default-state` option sets the target power state at startup:
- `run` - No automatic power transitions
- `suspend` - Allow suspend when vehicle is in stand-by (default)
- `hibernate` - Target hibernation when conditions met
- `hibernate-manual` - Manual hibernation mode
- `hibernate-timer` - Timer-based hibernation
- `reboot` - Reboot when conditions met

### Hibernation Timer

- **Configuration:** Via `-hibernation-timer` option (duration) or `settings hibernation-timer` Redis field (seconds)
- **Default:** 5 days (120 hours)
- **Purpose:** Auto-hibernate after extended inactivity
- **Activation:** Timer starts when vehicle enters stand-by or parked state
- **Dynamic updates:** Can be changed at runtime via Redis settings

## Observable Behavior

### Startup Sequence

1. Creates Redis client connection
2. Creates systemd D-Bus client for power operations
3. Initializes power manager with configured target state
4. Opens Unix domain socket for inhibitor connections (default: `/tmp/suspend_inhibitor`)
5. Subscribes to `vehicle` and `battery:0` Redis channels
6. Starts listening for commands on `scooter:power` and `scooter:governor` lists
7. Starts hibernation state machine and timer
8. Reads initial vehicle and battery states from Redis (with retries)
9. Publishes initial power state to Redis
10. Enables wakeup sources on serial ports (ttymxc0, ttymxc1)
11. Begins event loop processing

### Runtime Behavior

#### Suspend Trigger

When vehicle enters `stand-by` state:
1. Pre-suspend delay timer starts
2. State transitions to `suspending-imminent`
3. Services can register inhibitors to block suspend
4. After suspend-imminent delay, checks if suspend allowed
5. If allowed, sends suspend command to systemd-logind
6. State transitions to `suspending`

#### Hibernation Trigger

**Automatic hibernation:**
- Triggered by low CB battery
- Vehicle service sends `LPUSH scooter:power hibernate`
- Power manager coordinates with nRF via bluetooth-service

**Manual hibernation:**
- User holds brakes + taps keycard
- Vehicle service sends `LPUSH scooter:power hibernate-manual`
- Special state sequence with user confirmation

**Timer hibernation:**
- After hibernation timer expires (e.g., 5 days of stand-by)
- Automatic hibernation to preserve battery
- State: `hibernating-timer-imminent` → `hibernating-timer`

#### Inhibitor System

The pm-service implements multiple inhibitor mechanisms:

**1. Unix Socket Inhibitors (Custom)**
- Services connect to Unix domain socket (default: `/tmp/suspend_inhibitor`)
- Connection-based: inhibitor active while socket connection open
- Service receives acknowledgment byte upon connection
- Two types:
  - `block` - Completely blocks power state changes
  - `delay` - Delays power state changes briefly
- Automatically released when socket closes
- Tracked in `power-manager:busy-services` hash

**2. Programmatic Inhibitors (Redis-based)**
- Stored in `power:inhibits` hash with JSON data
- Used by update-service and other system services
- Reasons: `downloading`, `installing`
- Can specify duration or be indefinite
- Can be set to `defer` (completely block) or delay (5 minute delay for downloads)
- Support callbacks when inhibit is removed

**Example socket inhibitor connection:**
```bash
# Connect and hold connection to block suspend
nc -U /tmp/suspend_inhibitor
# Service is now blocking - close connection to release
```

#### Busy Services Tracking

The `power-manager:busy-services` hash shows active inhibitors:
```bash
redis-cli HGETALL power-manager:busy-services
# Example output:
# "pm-service default delay" = "delay"
# "modem-service busy operation" = "block"
# "update-service downloading update" = "block"
```

Format: `<who> <why> <what>` = `<type>`

Services are removed from the hash when inhibitors are released.

### Hibernation Procedure

1. Power manager receives hibernation command (via `scooter:power` list)
2. Sets target state to hibernate/hibernate-manual/hibernate-timer
3. If vehicle in stand-by/parked, starts pre-suspend timer (1 minute)
4. After pre-suspend, transitions to `*-imminent` state
5. Publishes imminent state to Redis (e.g., `hibernating-imminent`)
6. Starts suspend-imminent timer (5 seconds)
7. Services receive state notification and prepare for shutdown
8. After imminent timer, checks for blocking inhibitors
9. If only modem has blocking inhibitor, sends `LPUSH scooter:modem disable`
10. Waits for all blocking inhibitors to clear
11. Issues systemd `poweroff` command
12. System powers down

### Wakeup from Suspend

1. Wakeup source triggers (serial port, RTC, etc.)
2. Kernel resumes from suspend
3. Power manager detects wakeup
4. Reads wakeup IRQ from `/sys/power/pm_wakeup_irq`
5. Publishes wakeup source to Redis (`power-manager wakeup-source`)
6. Transitions internal state back to `run`
7. Publishes `running` state to Redis
8. If target state still allows low-power and vehicle in stand-by:
   - For RTC wakeup (IRQ 45): starts short suspend-imminent timer
   - For other wakeups: starts full pre-suspend timer

## Log Output

The service logs to journald. Common log patterns:

**Startup:**
- `Starting power management service <version>`
- `Enabled wakeup on ttymxc0` / `ttymxc1`
- `Successfully read initial states - Vehicle: stand-by, Battery: idle`
- `Publishing power state: suspend (Redis: suspending)`

**Power state changes:**
- `Received power command: hibernate`
- `Setting target power state to hibernate`
- `Publishing power state: hibernate-imminent (Redis: hibernating-imminent)`
- `Issuing poweroff command`

**Inhibitors:**
- `Adding power inhibit: id=update-service, reason=downloading, duration=5m, defer=false`
- `New inhibitor connected: @`
- `Inhibitor disconnected: @`
- `Power state change delayed for 5m due to active inhibitors`

**Vehicle/Battery state:**
- `Vehicle state: stand-by`
- `Battery state: idle`
- `Pre-suspend timer elapsed`
- `Suspend imminent timer elapsed`

**Hibernation timer:**
- `Hibernation timer started with 432000 seconds` (5 days)
- `Hibernation timer expired, triggering hibernation`
- `Updated hibernation timer setting: 604800 seconds` (7 days)

**Modem coordination:**
- `Issuing modem to turn off`

**Wakeup:**
- `IRQ wakeup reason: 45` (RTC)
- `Publishing wakeup source: 45`

**CPU governor:**
- `Received governor command: powersave`
- `Setting CPU governor to: powersave`
- `Successfully set CPU governor to powersave`

Use `journalctl -u librescoot-pm.service` to view logs.

## Dependencies

- **systemd** - For power state commands (suspend, poweroff, reboot)
- **D-Bus** - For systemd communication
- **Redis server** - For state coordination and service communication
- **vehicle-service** - Monitors `vehicle state` for power transition triggers
- **battery-service** - Monitors `battery:0 state` for power management decisions
- **modem-service** (optional) - Coordinated shutdown before hibernation
- **settings-service** (optional) - For hibernation timer configuration

## Architecture Details

### Key Components

**Power Manager (`internal/power/manager.go`)**
- Manages power state transitions (run, suspend, hibernate, reboot)
- Interfaces with systemd via D-Bus for power commands
- Tracks current and target power states
- Implements power state priority system
- Handles inhibitor checking before state transitions

**Inhibitor Manager (`internal/inhibitor/inhibitor.go`)**
- Manages Unix socket for connection-based inhibitors
- Tracks active inhibitor connections
- Supports block and delay inhibitor types
- Publishes inhibitor status to Redis

**Power Inhibitor (`internal/power/inhibitor.go`)**
- Programmatic inhibitor management
- JSON-based inhibit requests with reasons (downloading, installing)
- Duration-based automatic expiration
- Defer vs delay modes (block completely vs 5 minute delay)

**Hibernation State Machine (`internal/hibernation/statemachine.go`)**
- Manages manual hibernation sequence
- States: idle → waiting-hibernation → advanced → seatbox → confirm
- Publishes hibernation sequence state to Redis
- Handles user input and timing for hibernation confirmation

**Hibernation Timer (`internal/hibernation/timer.go`)**
- Monitors vehicle state for stand-by/parked conditions
- Configurable timer duration (default 5 days)
- Dynamically adjustable via Redis settings
- Triggers automatic hibernation when timer expires

**Service Coordinator (`internal/service/service.go`)**
- Event-driven architecture with single event loop
- Coordinates all components (power, inhibitors, hibernation)
- Handles Redis subscriptions and command lists
- Manages modem power coordination
- Processes vehicle and battery state changes

### Power State Priority System

Power state transitions follow strict priority rules (highest to lowest):

1. **run** - Cancels all lower priority states
2. **hibernate-manual** - User-initiated hibernation (brake + keycard)
3. **hibernate** - Low battery or explicit hibernate command
4. **hibernate-timer** - Timer-based auto-hibernation
5. **suspend/reboot** - Normal suspend or reboot operations

When a higher priority state is requested, lower priority requests are ignored. To change from high to low priority, first request `run` to reset, then request the desired state.

### CPU Governor Management

The service manages CPU frequency scaling via `/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`:

**Supported governors:**
- `ondemand` - Dynamic frequency scaling based on load
- `powersave` - Lowest frequency for power savings
- `performance` - Highest frequency for performance

**Control:**
```bash
# Set CPU governor
redis-cli LPUSH scooter:governor powersave

# Current governor published to Redis
redis-cli HGET system cpu:governor
```

### Event-Driven Architecture

The service uses a single-threaded event loop to process all events sequentially:

**Event types:**
- Power commands (run, suspend, hibernate, etc.)
- Governor commands (ondemand, powersave, performance)
- Vehicle state changes
- Battery state changes
- Inhibitor changes (socket connect/disconnect)
- Timer expiration (pre-suspend, suspend-imminent)
- Wakeup events
- Hibernation timer expiration
- Settings changes

This design ensures all state is owned by the event loop, preventing race conditions.

### Wakeup Source Management

The service enables wakeup on serial ports at startup:
- `/sys/class/tty/ttymxc0/power/wakeup` → `enabled`
- `/sys/class/tty/ttymxc1/power/wakeup` → `enabled`

After wakeup, reads IRQ from `/sys/power/pm_wakeup_irq` and publishes to Redis.

### Building and Testing

```bash
# Build for ARM target (armv7eabi)
make build

# Build for local architecture
make build-local

# Install to /usr/bin
sudo make install

# Run with dry-run mode (no actual power transitions)
./pm-service -dry-run

# Monitor power state changes
redis-cli SUBSCRIBE power-manager

# Check busy services
redis-cli HGETALL power-manager:busy-services

# Request hibernation
redis-cli LPUSH scooter:power hibernate

# Change CPU governor
redis-cli LPUSH scooter:governor powersave
```

### Integration Points

**With vehicle-service:**
- Monitors `vehicle state` for stand-by/parked conditions
- Triggers power transitions based on vehicle state changes
- Resets to run state when vehicle becomes active

**With battery-service:**
- Monitors `battery:0 state` for active/idle/charging
- Blocks suspend when battery is active

**With modem-service:**
- Sends `disable` command before hibernation
- Waits for modem to clear blocking inhibitor
- Special handling: modem inhibitor doesn't prevent shutdown sequence

**With settings-service:**
- Reads `settings hibernation-timer` for timer duration
- Subscribes to settings changes for dynamic updates

**With update-service:**
- Honors `downloading` inhibitors (5 minute delay)
- Respects `installing` inhibitors (complete defer)
- Callbacks for inhibit removal

### Manual Hibernation Sequence

The hibernation state machine manages the multi-step manual hibernation process:

1. **Trigger:** User holds brakes + taps keycard for 15 seconds
2. **waiting-hibernation:** Initial confirmation period
3. **waiting-hibernation-advanced:** User continues holding (10 seconds)
4. **waiting-hibernation-seatbox:** Waiting for seatbox closure (60 second timeout)
5. **waiting-hibernation-confirm:** Final confirmation (3 seconds)
6. **Execute:** Triggers hibernate-manual power state

The sequence can be cancelled at any time by releasing the hibernation input or by timeout.

## Related Documentation

- [Power Management States](../states/README.md) - Power manager state machine
- [nRF Power Management](../nrf/power-management.md) - Hibernation details
- [Redis Operations](../redis/README.md) - Power manager hash fields
- [Vehicle States](../states/README.md) - How vehicle state affects power management
- [LibreScoot Services](librescoot-services.md) - PM service details
