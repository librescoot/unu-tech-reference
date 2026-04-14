# librescoot-pm (pm-service)

## Description

The power manager (pm-service) controls system power states including suspend, hibernation, and reboot. It monitors service activity via a Unix socket inhibitor interface, tracks busy services via Redis, implements delays before power transitions, and manages a hibernation timer. The service uses a finite state machine (FSM) backed by librefsm to drive all power state transitions.

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
- None (hibernation timer settings in `settings` hash)

**Published channel:** `power-manager`
- `state` - Published when power state changes
- `wakeup-source` - Published when system wakes from suspend

### Hash: `power-manager:busy-services`

**Fields written:**
- `<who> <why> <what>` = `<type>` — inhibitor entry
- Example: `"pm-service delay default delay" = "delay"` (pm-service's own delay inhibitor)
- Example: `"connection-based connection-based connection-based" = "block"` (active socket connection)

This hash tracks all active inhibitors. Socket-based connections always use `"connection-based"` for `who`, `why`, and `what`. Redis-based inhibitors use values from the `power:inhibits` hash entry.

**Published channel:** `power-manager:busy-services`
- Updated atomically (DEL + HMSET + PUBLISH) when inhibitors change

### Hash: `power:inhibits`

**Fields written/read:**
- `<inhibit-id>` — JSON data with inhibit request details
- Format: `{"id": "...", "who": "...", "what": "...", "why": "...", "type": "block|delay|suspend-only", "duration": <unix_ns>, "created": <unix_ns>}`

Used for programmatic inhibitor management (downloading, installing, etc.)

pm-service subscribes to the `power:inhibits` channel and syncs entries into its inhibitor manager as manual inhibitors, so `update-service` power inhibits (e.g. during DBC boot partition writes) actually block suspend/hibernate/poweroff.

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
- `battery:0` → `state` - Battery slot 0 state monitoring (idle, active, charging)
- `battery:1` → `state` - Battery slot 1 state monitoring (idle, active, charging)

## Power Manager States

The FSM has these internal states:

- `running` - Normal operation
- `pre-suspend` - Waiting out the pre-suspend delay (natural suspend path only); publishes `<target>-pending` to Redis (e.g. `suspending-pending`)
- `suspend-imminent` - Suspend imminent timer running; publishes `suspending-imminent`
- `hibernate-imminent` - Hibernate/reboot imminent timer running
- `waiting-inhibitors` - Waiting for blocking inhibitors to clear
- `issuing-low-power` - Power command issued to systemd
- `suspended` - System has returned from suspend (transient)

Redis-published `power-manager state` values:

| Condition | Redis value |
|-----------|-------------|
| running | `running` |
| suspend target, pre-suspend phase | `suspending-pending` |
| suspend-imminent | `suspending-imminent` |
| hibernate-imminent | `hibernating-imminent` |
| hibernate-manual-imminent | `hibernating-manual-imminent` |
| hibernate-timer-imminent | `hibernating-timer-imminent` |
| reboot-imminent | `reboot-imminent` |
| issuing suspend | `suspending` |
| issuing hibernate | `hibernating` |
| issuing hibernate-manual | `hibernating-manual` |
| issuing hibernate-timer | `hibernating-timer` |
| issuing reboot | `reboot` |

See [States Documentation](../states/README.md) for complete state machine.

## Hardware Interfaces

### nRF52840 Communication

The power manager interacts with nRF hardware indirectly via Redis:
- Commands hibernation via `scooter:power` list (handled by vehicle-service)
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
- For suspend dry-run, simulates an immediate wakeup event

### Delay Configuration

Command-line flags control timing:
- **Pre-suspend delay** (`-pre-suspend-delay`): Time after stand-by before entering imminent state on the natural suspend path (default: 1m)
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
- **Activation:** Timer starts when vehicle leaves `ready-to-drive`; stops when vehicle re-enters `ready-to-drive`
- **Dynamic updates:** Can be changed at runtime via Redis settings; set to 0 to disable

## Observable Behavior

### Startup Sequence

1. Reads initial vehicle and battery states from Redis (`vehicle state`, `battery:0 state`, `battery:1 state`)
2. Creates inhibitor manager and opens Unix domain socket (default: `/tmp/suspend_inhibitor`)
3. Creates hibernation timer
4. Enables wakeup sources on serial ports (ttymxc0, ttymxc1)
5. Builds and starts the FSM
6. Publishes initial power state to Redis
7. Initializes hibernation timer if vehicle is not in `ready-to-drive`
8. Starts Redis hash watchers for `vehicle`, `battery:0`, `battery:1`, `settings`
9. Starts command listeners for `scooter:power` and `scooter:governor`
10. Starts Redis inhibitor listener for `power:inhibits`

### Runtime Behavior

#### Suspend Trigger

When vehicle enters `stand-by` state with target=`suspend`:
1. FSM transitions to `pre-suspend`; publishes `suspending-pending`
2. Pre-suspend delay timer starts (default 1m)
3. After pre-suspend delay, FSM transitions to `suspend-imminent`; publishes `suspending-imminent`
4. Suspend-imminent timer starts (default 5s)
5. After imminent timer, FSM enters `waiting-inhibitors`
6. Once no blocking inhibitors remain, FSM enters `issuing-low-power`; publishes `suspending`
7. Sends suspend command to systemd

Explicit `suspend` commands (LPUSH scooter:power suspend) skip the pre-suspend delay and go directly to `suspend-imminent`.

#### Hibernation Trigger

**Explicit hibernate command:**
- `LPUSH scooter:power hibernate` (or `hibernate-manual`, `hibernate-timer`)
- Skips pre-suspend delay; FSM goes directly to `hibernate-imminent`

**Hibernation timer:**
- After timer expires (default 5 days outside `ready-to-drive`)
- FSM goes to `hibernate-imminent` with timer target

#### Inhibitor System

The pm-service implements two inhibitor mechanisms:

**1. Unix Socket Inhibitors**
- Services connect to Unix domain socket (default: `/tmp/suspend_inhibitor`)
- Connection-based: inhibitor active while socket connection open
- All socket connections are `block` type
- Service receives acknowledgment byte (0x00) upon connection
- Automatically released when socket closes

**2. Redis-based Inhibitors**
- Stored in `power:inhibits` hash as JSON
- Synced into the inhibitor manager on startup and on channel notifications
- Three types: `block` (blocks everything), `delay` (short delay), `suspend-only` (blocks suspend but not hibernate/poweroff/reboot)

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
# Key format: "<who> <why> <what>" = "<type>"
# Socket connections: "connection-based connection-based connection-based" = "block"
```

The hash is replaced atomically on every change.

### Hibernation Procedure

1. Power manager receives hibernation command (via `scooter:power` list)
2. FSM transitions directly to `hibernate-imminent` (no pre-suspend delay)
3. Publishes imminent state to Redis (e.g. `hibernating-imminent`)
4. Suspend-imminent timer runs (5 seconds)
5. FSM enters `waiting-inhibitors`
6. If only modem has a blocking inhibitor, sends `LPUSH scooter:modem disable`
7. Waits for all blocking inhibitors to clear
8. Issues systemd `poweroff` command
9. System powers down

### Wakeup from Suspend

1. Wakeup source triggers (serial port, RTC, etc.)
2. Kernel resumes; systemd suspend call returns
3. Reads wakeup IRQ from `/sys/power/pm_wakeup_irq`
4. Publishes wakeup source to Redis (`power-manager wakeup-source`)
5. Routes FSM based on wakeup type:
   - RTC wakeup (IRQ 45): goes directly to `suspend-imminent` (fast path, skips pre-suspend)
   - Other wakeups with target=suspend: goes to `pre-suspend`
   - Otherwise: returns to `running`
6. Publishes `running` state to Redis

## Log Output

The service logs to journald. Common log patterns:

**Startup:**
- `Starting power management service <version>`
- `Enabled wakeup on ttymxc0` / `ttymxc1`
- `Initial vehicle state: stand-by`
- `Initial battery:0 state: idle`

**Power state changes:**
- `Received power command: hibernate`
- `FSM state transition: running -> hibernate-imminent`
- `Entering hibernate-imminent state`
- `Issuing poweroff command`

**Inhibitors:**
- `Redis inhibitor added: update-service (block) by update-service — downloading`
- `New inhibitor connected: @`
- `Inhibitor disconnected: @`

**Wakeup:**
- `Wakeup detected with reason: 45`
- `RTC wakeup detected, using fast path`
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
- **battery-service** - Monitors `battery:0` and `battery:1` state
- **modem-service** (optional) - Coordinated shutdown before hibernation
- **settings-service** (optional) - For hibernation timer configuration

## Architecture Details

### Key Components

**FSM (`internal/fsm/definition.go`, `internal/fsm/types.go`)**
- Defines all states, events, and transitions using librefsm
- States: `running`, `pre-suspend`, `suspend-imminent`, `hibernate-imminent`, `waiting-inhibitors`, `issuing-low-power`, `suspended`
- Priority-based transition guards

**Inhibitor Manager (`internal/inhibitor/inhibitor.go`)**
- Manages Unix socket for connection-based inhibitors (always `block` type)
- Tracks programmatically-added inhibitors
- Calls `onChange` callback on every change; FSM receives `EvInhibitorsChanged`

**Redis Inhibitor Listener (`internal/inhibitor/redis.go`)**
- Syncs `power:inhibits` hash entries into the inhibitor manager
- Supports `block`, `delay`, and `suspend-only` types from JSON `type` field

**Hibernation Timer (`internal/hibernation/timer.go`)**
- Tracks whether vehicle is in an idle state (not `ready-to-drive`)
- Configurable timer duration (default 5 days); set to 0 to disable
- Fires `EvHibernationTimerExpired` into the FSM on expiry

**Service Coordinator (`internal/service/service.go`)**
- Implements the FSM `Actions` interface
- Coordinates all components (FSM, inhibitors, hibernation timer)
- Handles Redis subscriptions and command lists
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

```bash
# Set CPU governor
redis-cli LPUSH scooter:governor powersave

# Current governor published to Redis
redis-cli HGET system cpu:governor
```

Supported governors: `ondemand`, `powersave`, `performance`.

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
- Monitors `vehicle state` for stand-by conditions
- Triggers power transitions based on vehicle state changes

**With battery-service:**
- Monitors `battery:0` and `battery:1` state
- Derived aggregate: if either slot is `active`, suspend is blocked

**With modem-service:**
- Sends `disable` command before hibernation when modem is the only blocker
- Waits for modem to clear its blocking inhibitor

**With settings-service:**
- Reads `settings hibernation-timer` for timer duration in seconds
- Subscribes to settings changes for dynamic updates

**With update-service:**
- Respects inhibitors written to `power:inhibits` hash
- Type `suspend-only` delays suspend only; `block` blocks all low-power transitions

## Related Documentation

- [Power Management States](../states/README.md) - Power manager state machine
- [nRF Power Management](../nrf/power-management.md) - Hibernation details
- [Redis Operations](../redis/README.md) - Power manager hash fields
- [Vehicle States](../states/README.md) - How vehicle state affects power management
- [LibreScoot Services](librescoot-services.md) - PM service details
