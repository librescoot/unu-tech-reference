# librescoot-pm (pm-service)

## Description

The power manager (pm-service) controls system power states including suspend, hibernation, and reboot. It monitors service activity via a Unix socket inhibitor interface, tracks busy services via Redis, implements delays before power transitions, and manages a hibernation timer. The service uses a finite state machine (FSM) backed by librefsm to drive all power state transitions.

Two user-facing hibernation features are layered on top of the base FSM:

- **`hibernate-for <duration>`** — ad-hoc command to hibernate for a specific duration. The nRF52 arms a single-shot wake timer before the iMX6 powers off and pulls the iMX6 back up when the timer expires.
- **Scheduled hibernation** — a 5-field cron expression plus a wake-by duration. Fires automatically when the scooter is locked (`stand-by`); if the cron triggers while the user is riding or parked-unlocked, the request defers until the next transition into `stand-by` and the wake time is preserved (so a `22:00 + 8h` schedule still wakes at `06:00` even if the user actually locks at `23:00`).

## Command-Line Options

```
Usage of pm-service:
  -default-state string
        Default power state (run, suspend, hibernate, hibernate-manual, hibernate-timer, reboot) (default "suspend")
  -dry-run
        Dry run state (don't actually issue power state changes)
  -hibernation-timer duration
        Duration of the hibernation timer (default 72h0m0s) [3 days]
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

**Note:** The hibernation timer default is 72 hours (3 days). The systemd unit file typically overrides the default state to `run` to prevent automatic suspends during development.

## Redis Operations

### Hash: `power-manager`

**Fields written:**
- `state` - Power manager state (see States section below)
- `wakeup-source` - IRQ number of wakeup source (e.g., "45" for RTC)
- `wake-timer-seconds` - Requested wake-timer duration for the next nRF52 wake (decimal seconds; `0` disarms). Written when a `hibernate-for` flow enters `low-power-imminent`, before `EnterIssuingLowPower` blocks for the ACK.

**Fields read:**
- `wake-timer-armed` - Set to `"true"` by bluetooth-service when the nRF52 acknowledges the wake-timer arm, `"false"` on disarm. pm-service blocks (up to `pm.wake-timer-ack-timeout`) on this field flipping to `true` in `EnterIssuingLowPower`; on timeout it aborts the hibernation rather than power off without a confirmed wake source.
- `power-state-sent` - The nRF suspend-ACK, written by bluetooth-service when it confirms it forwarded a power state to the nRF52. Only the value `"suspending"` is acted on. Before suspending, pm-service publishes the `suspending` state and then blocks (up to `suspendQuiesceTimeout`, 3 s) in `EnterIssuingLowPower` for `power-state-sent=suspending`. The nRF must stop its USOCK TX before the iMX6 sleeps; otherwise routine traffic on the armed ttymxc1 wakeup pulls the iMX6 straight back out of suspend-to-RAM. On ACK it settles a 200 ms margin (so the nRF's reply to the suspending frame can drain) and then suspends; on timeout it aborts back to `running` rather than suspend into the wake loop. This gate applies only to the `suspend` target, not to hibernate/poweroff/reboot.

**Published channel:** `power-manager`
- `state` - Published when power state changes
- `wakeup-source` - Published when system wakes from suspend
- `wake-timer-seconds` - Published when pm-service requests a wake-timer change
- `wake-timer-armed` - Published by bluetooth-service when the nRF52 ACK arrives

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
- `pm.hibernation-timer` - Inactivity-based hibernation timer duration in seconds (0 = disabled)
- `pm.default-state` - Default target power state when idle (`run` / `suspend`)
- `pm.suspend-when-online` - Bool, default `false`. Gates whether a locked scooter that is online and still has a main battery present is allowed to suspend. When `false` (the default), such a scooter stays awake so cloud commands can still reach it; the suspend is blocked with a `Suspend blocked: online with a main battery present and pm.suspend-when-online disabled` log line. When `true`, an online locked scooter may suspend normally. The guard only applies to the `suspend` target (not hibernate/reboot) and is checked before the battery-active guard.
- `pm.scheduled-hibernate-enabled` - Bool: enable cron-driven scheduled hibernation
- `pm.scheduled-hibernate-cron` - 5-field cron expression (e.g. `0 22 * * *`)
- `pm.scheduled-hibernate-duration` - Wake-by duration (Go duration syntax: `8h`, `30m`, ...)
- `pm.wake-timer-max-seconds` - Safety cap on a single wake-timer arm (default 604800 = 1 week)
- `pm.wake-timer-ack-timeout` - How long to wait for the nRF52 ACK before aborting (default `10s`)

**Subscribed channel:** `settings`
- Each of the fields above triggers a re-read on change.

### Hash: `gps`

**Fields read:**
- `active` - Polled by pm-service (every 30 s, immediate first check) as the proxy for "the wall clock has been bootstrapped from GPS". modem-service calls `chronyc settime` in the same loop iteration that flips `gps.active` to `true` on a valid fix. The scheduler latches this signal — once observed `true`, the wall-clock validity gate stays open even if the GPS fix is later lost (chrony retains the bootstrap). NTP-only scooters with a broken or absent GPS receiver would never flip this; that's a documented limitation.

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
  - `hibernate-for:<seconds>` - Ad-hoc hibernate-for. The integer suffix is the wake-timer duration in seconds (clamped to `pm.wake-timer-max-seconds`).
  - `hibernate-cancel` - Return target to `run` and disarm any pending wake timer.
  - `reboot` - System reboot

- `scooter:governor` - CPU governor commands
  - `ondemand` - On-demand frequency scaling
  - `powersave` - Power-saving mode
  - `performance` - Performance mode

### Lists published (LPUSH)

- `scooter:modem` - Commands sent to modem service
  - `disable` - Request modem shutdown before hibernation

### Hash subscriptions (field updates)

- `vehicle` -> `state` - Vehicle state monitoring (stand-by, parked, etc.); also drives scheduled-hibernation deferral and the last-ditch standby pre-filter
- `battery:0` -> `state`, `present`, `charge` - Battery slot 0 state monitoring (idle, active, charging) plus `present`/`charge` for the last-ditch hibernate inputs
- `battery:1` -> `state`, `present`, `charge` - Battery slot 1 state monitoring plus `present`/`charge` for the last-ditch hibernate inputs
- `cb-battery` -> `charge` - CBB charge, last-ditch hibernate input
- `aux-battery` -> `voltage` - Aux 12V rail voltage (millivolts), last-ditch hibernate input
- `internet` -> `status` - Tracks connectivity (`connected` => online) for the `pm.suspend-when-online` guard
- `power-manager` -> `wake-timer-armed`, `power-state-sent` - Wake-timer ACK and the nRF suspend-ACK from the nRF52 (both written by bluetooth-service)
- `settings` -> `pm.suspend-when-online` (among the other `pm.*` fields above) - re-read on change

## Power Manager States

The FSM has these internal states:

- `running` - Normal operation
- `pre-suspend` - Waiting out the pre-suspend delay (natural suspend path only); publishes `<target>-pending` to Redis (e.g. `suspending-pending`)
- `suspend-imminent` - Suspend imminent timer running; publishes `suspending-imminent`
- `low-power-imminent` - Generic prep state for any non-suspend low-power transition (hibernate, hibernate-manual, hibernate-timer, hibernate-for, reboot); the published Redis label is target-derived (e.g. `hibernating-for-imminent`)
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
| hibernate-for-imminent | `hibernating-for-imminent` |
| reboot-imminent | `reboot-imminent` |
| issuing suspend | `suspending` |
| issuing hibernate | `hibernating` |
| issuing hibernate-manual | `hibernating-manual` |
| issuing hibernate-timer | `hibernating-timer` |
| issuing hibernate-for | `hibernating-for` |
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
- After timer expires (default 3 days outside `ready-to-drive`)
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

### Hibernate-for (nRF-driven scheduled wake)

The `hibernate-for` family of commands hibernates the system for a specific duration and relies on the nRF52 to wake the iMX6 back up. The wake source is independent of the iMX6's own RTC because `systemctl poweroff` fully cuts iMX6 power; only the nRF52 keeps running during hibernation.

#### Ad-hoc

```bash
redis-cli LPUSH scooter:power "hibernate-for:300"   # hibernate for 5 minutes
redis-cli LPUSH scooter:power "hibernate-cancel"    # abort and disarm
```

`lsc hibernate-for <duration>` is a convenience wrapper. Over BLE, mobile apps can issue `pm:hibernate-for <duration>` / `pm:hibernate-cancel` via the extended-command channel.

#### Scheduled

Cron-driven schedule, defined entirely through settings:

```bash
lsc settings set pm.scheduled-hibernate-cron "0 22 * * *"
lsc settings set pm.scheduled-hibernate-duration 8h
lsc settings set pm.scheduled-hibernate-enabled true
```

Wake-by semantics: the cron fire time + duration is treated as the desired wake-by wall-clock target. If the scooter is in `stand-by` (locked, idle) at fire time, the hibernation goes out immediately with that remaining-time value. If the scooter is in `parked`, `ready-to-drive`, or any other state, the request is **deferred** until the next transition into `stand-by`. The wake-by time is preserved across the defer, so a `22:00 + 8h` schedule still wakes at `06:00` even if the user locks at `23:00`. If the target time has already passed by the time `stand-by` is reached, the pending fire is dropped with a `Pending wake target already in the past on standby; dropping` log line.

#### Wake-timer arm-and-ACK flow

Both flows go through the same FSM transitions as `hibernate-manual` (event `EvPowerHibernateFor`), with an extra arm-and-block step around the systemd call:

```
EnterLowPowerImminent       Publishes wake-timer-seconds=<N> on power-manager
        │                   (HSET + PUBLISH)
        ▼
suspend-imminent timer (5 s default)
        │
        ▼
EnterWaitingInhibitors
        │
        ▼
EnterIssuingLowPower        Blocks for wake-timer-armed=true on power-manager,
                            up to pm.wake-timer-ack-timeout (default 10 s).
        │
        ├─ on ACK → systemctl poweroff
        └─ on timeout → emit EvPowerRun, abort
```

bluetooth-service is the bridge: it watches `power-manager:wake-timer-seconds`, forwards the value to the nRF52 over UART (subtype 0x0805 under 0x0800), and writes `wake-timer-armed` back when the nRF52 echoes the ACK.

The system never powers off without a confirmed wake source. If bluetooth-service is down or the nRF52 fails to ACK, the hibernation is aborted and the FSM returns to `running`.

#### Time-sync gate

The scheduler refuses to dispatch any cron occurrence until the wall clock has been confirmed plausible. A polling goroutine (immediate check + every 30 s) reads `gps.active`; once it observes `"true"`, the time-sync latch flips on permanently for the session. Reasoning:

- The iMX6 boots with the system-image build timestamp seeded into the clock, so year-based heuristics ("is the clock recent?") falsely pass.
- modem-service calls `chronyc settime` in the same loop iteration that flips `gps.active` to `true` on a valid GPS fix, so `gps.active=true` is a reliable proxy for "chrony has been bootstrapped". chrony.conf has `manual`, so settime samples accumulate, and `local stratum 1` is present (which is what makes `chronyc tracking` an unreliable gate on its own).
- A `Scheduled hibernation fire suppressed: wall clock not time-synced` log line means the latch hasn't flipped yet.

#### Clock-jump resilience

A separate 30 s monitor loop in the scheduler compares monotonic elapsed vs wall-clock elapsed. A delta beyond ±60 s indicates a wall-clock jump (typical when chrony first converges from a wrong startup time). On jump:

1. The cron entry is re-installed so the next-fire is recomputed against the new wall clock.
2. Any pending deferred wake target is re-evaluated; if it's now in the past, the pending fire is dropped.

### Last-ditch hibernate

A safety feature that force-hibernates the scooter when it has lost enough reserve to risk a brown-out and no main battery is available to recover. pm-service watches the following hashes as inputs:

- `cb-battery` -> `charge` - CBB charge percent
- `aux-battery` -> `voltage` - aux 12V rail in millivolts
- `battery:0` / `battery:1` -> `present` and `charge` - per-slot main battery presence and charge

The trigger condition is level-triggered and evaluated inside the FSM guard (`IsLastDitchTriggered`) at transition time:

- Both main slots unusable: a slot counts as missing when `present=false` OR `charge==0`. Both slots must be missing.
- AND a depleted reserve: CBB charge below `lastDitchHibernateCBBThreshold` (50%) OR the aux rail latched low.

Aux uses a Schmitt trigger to avoid thrash near the threshold: it latches low when voltage drops below `lastDitchHibernateAuxEnterMv` (11500 mV) and releases only once it rises back above `lastDitchHibernateAuxExitMv` (11700 mV). A reading of `-1` (unparseable / no reading yet) means "unknown" and suppresses its sub-condition; CBB and aux both default to unknown until first synced, and the two slot-present flags default to `true` so a missing first sync cannot fire the trigger.

When the condition holds and the vehicle is in `stand-by`, a watcher enqueues `EvLastDitchCheck` carrying a plain `hibernate` target, so the regular priority guard and power-command path apply. The FSM can also route a wake-from-suspend straight into hibernate when the condition holds (for example the CBB drained during suspend-to-RAM). When the trigger fires, pm-service logs which reserve ran low with a `Last-ditch hibernate: no main battery, <reserve>` line, where `<reserve>` is `CBB=NN%`, `aux=NNNN mV`, or both.

**Post-boot grace window:** the trigger is suppressed for the first `lastDitchHibernateBootGrace` (5 minutes) after pm-service starts. After waking from a last-ditch hibernation, Redis still holds the pre-hibernate battery state (slots absent, CBB low) until battery-service re-detects the pack, so firing on the seeded values would power the scooter straight back off before a freshly inserted battery is recognized. During the grace, a met condition is logged once with `Last-ditch hibernate condition met within boot grace; deferring up to <remaining>`. A timer re-evaluates the condition once the grace expires (so a genuinely battery-less scooter still hibernates, just not within the first 5 minutes), even if no further battery/CBB/aux update arrives in the meantime.

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
- States: `running`, `pre-suspend`, `suspend-imminent`, `low-power-imminent`, `waiting-inhibitors`, `issuing-low-power`, `suspended`
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

**Hibernation Scheduler (`internal/hibernation/scheduler.go`)**
- Cron-driven scheduler for `pm.scheduled-hibernate-*` settings (uses `github.com/robfig/cron/v3`, standard 5-field parser)
- Latches a wall-clock validity gate based on `gps.active`; suppresses fires until first observed `"true"`
- Defers cron fires while the vehicle is not in `stand-by` and dispatches on the next standby transition with the remaining time until the original wake-by target
- 30 s background monitor detects wall-clock jumps and rebuilds the cron entry / re-evaluates pending deferred wakes accordingly

**Service Coordinator (`internal/service/service.go`)**
- Implements the FSM `Actions` interface
- Coordinates all components (FSM, inhibitors, hibernation timer)
- Handles Redis subscriptions and command lists
- Processes vehicle and battery state changes

### Power State Priority System

Power state transitions follow strict priority rules (highest to lowest):

1. **run** - Cancels all lower priority states
2. **hibernate-manual** / **hibernate-for** - Explicit user-initiated hibernation (brake + keycard, or `hibernate-for <duration>`)
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
- [Librescoot Services](README.md) - Service overview
