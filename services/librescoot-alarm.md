# librescoot-alarm (alarm-service)

## Description

Motion-based security alarm for the scooter. alarm-service is a pure FSM/policy layer — as of the [motion-service refactor](librescoot-motion.md), it does not touch the BMX055 directly. It publishes its FSM state (`alarm.status`) so motion-service can reactively configure the chip; consumes `motion:interrupt` events; and uses one synchronous `motion:rpc/prepare-hibernation` Call to gate pm-service's hibernation entry.

## Version

Librescoot alarm-service v0.10+ (Phase 4 of the motion-service refactor).

## Command-Line Options

```
--redis=localhost:6379         Redis address
--log-level=info               Log level (debug, info, warn, error)
--alarm-enabled=false          Enable alarm system (writes to Redis on startup)
--alarm-duration=10            Alarm duration in seconds
--horn-enabled=false           Enable horn during alarm (overrides Redis setting)
--seatbox-trigger=true         Trigger alarm on unauthorized seatbox opening
--hair-trigger=false           Enable hair trigger mode (immediate short alarm on first motion)
--hair-trigger-duration=3      Hair trigger alarm duration in seconds
--l1-cooldown=5                Level 1 cooldown duration in seconds
--version                      Print version and exit
```

`--i2c-bus`, `--evdev-device`, `--evdev-keycode`, `--poller-interval-ms` are gone. motion-service owns the chip.

## Redis Operations

### Hash: `alarm`

**Fields written:**
- `status` — current alarm status:
  - `disabled` — alarm system is disabled
  - `disarmed` — alarm enabled but not armed (vehicle not in stand-by)
  - `delay-armed` — 5 s arming delay
  - `armed` — armed and monitoring
  - `level-1-triggered` — Level 1 (cooldown + verification window)
  - `level-2-triggered` — Level 2 (horn + hazards)
  - `seatbox-access` — temporarily disabled while authorized seatbox opening is active

**Published channel:** `alarm`

**motion-service watches this hash.** A change on `alarm.status` triggers a profile re-derivation in motion-service via `(alarm.status, power-manager.state)`. See [librescoot-motion](librescoot-motion.md#chip-profile-derivation) for the full mapping table.

### Hash: `settings`

**Fields read:**
- `alarm.enabled`, `alarm.honk`, `alarm.duration`, `alarm.seatbox-trigger`
- `alarm.hairtrigger`, `alarm.hairtrigger-duration`, `alarm.l1-cooldown`

**Fields written (if CLI flags set):** same fields, overrides Redis values on startup.

**Subscribed channels:** `settings`

### Hash: `power-manager`

**Fields read:** `state`. Hibernation-imminent transitions trigger the synchronous `prepare-hibernation` Call.

**Subscribed channels:** `power-manager`

### Hash: `motion`

**Fields read on startup:** `wake-cause` (deleted after consumption). Durable backstop for the wake-from-hibernation indicator across the startup-ordering race with motion-service's pub/sub.

### Pub/Sub Channels

**Subscribes to:**
- `vehicle` — state, seatbox:opened event, seatbox:lock
- `settings` — alarm.* changes
- `power-manager` — state field
- `motion:interrupt` — JSON envelope `{type, timestamp, engine}` from motion-service. `type` becomes `BMXInterruptEvent.Data` (the FSM discriminates `wake-hibernation` from regular edges).

### RPC Calls (synchronous, via redis-ipc CallMethod)

- **`motion:rpc/prepare-hibernation`** — called when `power-manager.state` flips to `hibernating-imminent` while in `StateArmed`, OR on entry to `StateArmed` if `hibernationImminent` is already true. Blocks until motion-service confirms the chip is in `armed-hibernation` profile. ~180 ms round-trip. On failure: alarm-service holds the suspend inhibitor and pm-service stays blocked rather than hibernating with an unverified chip profile.

### Lists Consumed (BRPOP)

- `scooter:alarm`:
  - `enable`, `disable` — set `settings alarm.enabled`
  - `arm`, `disarm` — runtime override (doesn't change `settings.alarm.enabled`)
  - `start:<seconds>` — manual alarm trigger
  - `stop` — stop alarm immediately

### Lists Produced (LPUSH)

- `scooter:horn` — `on`, `off`
- `scooter:blinker` — `both`, `off`

## Alarm State Machine

```
init → waiting_enabled → disarmed → delay_armed (5s) → armed
                                         ↑                ↓ motion detected (motion:interrupt)
                                         |        trigger_level_1_wait (configurable cooldown)
                                         |                ↓
                                         |        trigger_level_1 (5s check)
                                         |                ↓ major movement
                                         |        trigger_level_2 (50s, max 4 cycles)
                                         |________________|
```

Plus `seatbox_access` (transient state during authorized seatbox openings) and `waiting_movement` (between L2 cycles).

### State Descriptions

- **init**: Initial state on startup
- **waiting_enabled**: Alarm disabled, waiting for enable command
- **disarmed**: Alarm enabled but vehicle not in stand-by
- **delay_armed**: 5-second delay before arming (allows user to leave)
- **armed**: Armed and monitoring for motion (motion:interrupt drives transitions)
- **trigger_level_1_wait**: Cooldown after motion detected (default 5s, configurable; with hair trigger: immediate short alarm)
- **trigger_level_1**: 5-second check for continued movement
- **trigger_level_2**: Full alarm activated (horn + hazards, 50s duration, max 4 cycles)
- **seatbox_access**: Authorized seatbox opening — alarm temporarily inhibited
- **waiting_movement**: Between L2 cycles, waiting for re-trigger

### Arming

- Alarm enabled (`settings alarm.enabled = true`)
- Vehicle enters `stand-by`
- 5-second `delay_armed` countdown (skipped on startup if already in stand-by)
- Transition to `armed`

### Triggering

- `motion:interrupt` arrives while in `armed`
- `armed` → `trigger_level_1_wait`
- Hazards blink once
- If hair trigger enabled: short horn pulse (skipped if this edge was the wake-from-hibernation edge — `wakeFromHibernation` flag gates it)
- Cooldown (default 5s, configurable) → `trigger_level_1`
- 5s verification window → if more motion: `trigger_level_2`; else: back through `delay_armed` to `armed`

### Disarming

- Vehicle leaves `stand-by` (user unlocks)
- `LPUSH scooter:alarm disable` (persistent — sets `settings.alarm.enabled=false`)
- `LPUSH scooter:alarm disarm` (runtime — re-arms on next stand-by)
- `LPUSH scooter:alarm stop` (immediate)

## Hibernation Handshake

When pm-service publishes `power-manager.state = hibernating-imminent` AND alarm-service is in `StateArmed`:

1. alarm-service sees the state change (HashWatcher).
2. FSM dispatches `confirmHibernationProfile(ctx)`.
3. `ipc.CallMethod(rpcClient, "motion:rpc", "prepare-hibernation", ...)` — synchronous, 1.5 s timeout.
4. motion-service applies armed-hibernation profile to the chip; replies.
5. On success: alarm-service logs "motion-service confirmed armed-hibernation profile". pm-service can now suspend; the chip is guaranteed to be in the right profile.
6. On failure: alarm-service acquires its D-Bus suspend inhibitor and **holds it** — pm-service stays blocked rather than hibernating with an unverified chip profile.

This is the only synchronous call alarm-service makes. All other chip-config flows reactively through the `alarm` hash that motion-service watches.

## Wake-from-Hibernation Detection

When motion-service starts up after a hibernation wake AND finds `INT_STATUS_0` already latched, it publishes a one-shot `motion:interrupt {type: "wake-hibernation", ...}` AND writes `motion.wake-cause = <unix-ms>` to its hash. The hash field is durable across the startup-ordering race.

alarm-service on startup:
1. Calls `MotionClient.ConsumeWakeCause(ctx)` — HGET + HDEL on `motion.wake-cause`. If the timestamp is within 30 s of now, returns true.
2. If true: sends `BMXInterruptEvent{Data:"wake-hibernation"}` to the FSM at `StateInit`. Sets `wakeFromHibernation=true`.
3. FSM init checks the flag at `InitCompleteEvent`: if alarm-enabled + standby + wakeFromHibernation, transitions directly to `StateTriggerLevel1Wait` (treats the wake-edge as the L1 trigger). Hair trigger is skipped on this entry — the wake-edge isn't a tampering event by itself.

## Suspend Inhibitor Management

D-Bus inhibitor (via systemd-logind) used to gate pm-service:

- **delay_armed**: held during 5-s arming delay
- **trigger_level_1_wait / trigger_level_1**: held during cooldown + verification
- **trigger_level_2 / waiting_movement**: held during full alarm
- **seatbox_access**: held during authorized opening
- **prepare-hibernation failure** (rare): held indefinitely until alarm-service is restarted or the chip-config issue is resolved

`armed` state intentionally does NOT hold the inhibitor — that's the state where hibernation IS allowed.

## Configuration

### Settings via Redis

```bash
# Enable alarm system
redis-cli HSET settings alarm.enabled true
redis-cli PUBLISH settings alarm.enabled

# Enable horn during alarm
redis-cli HSET settings alarm.honk true
redis-cli PUBLISH settings alarm.honk

# Enable hair trigger
redis-cli HSET settings alarm.hairtrigger true
redis-cli PUBLISH settings alarm.hairtrigger
```

### Settings via Command Line

CLI flags override Redis settings when explicitly provided:

```bash
alarm-service --horn-enabled=true --hair-trigger=true --hair-trigger-duration=3
```

## Testing

### Drive a complete trigger cycle

```bash
# Make sure motion-service is up
redis-cli HGET motion current-profile  # -> armed-awake when alarm armed

# Synthetic motion edge
redis-cli PUBLISH motion:interrupt "{\"type\":\"edge\",\"timestamp\":$(date +%s%3N),\"engine\":\"any-motion\"}"

# Watch alarm transitions
redis-cli SUBSCRIBE alarm
```

### Manual trigger

```bash
redis-cli LPUSH scooter:alarm start:10  # 10-s alarm
redis-cli LPUSH scooter:alarm stop      # cancel
```

## Dependencies

- **motion-service** — owns the BMX055; provides motion events + the prepare-hibernation RPC
- **redis-ipc v0.13.0+** — for `CallMethod`
- **Redis** — for hashes, pub/sub, command queues
- **vehicle-service** — provides vehicle state for arm/disarm gating
- **horn / blinker** — typically provided by vehicle-service via `scooter:horn` / `scooter:blinker` queues

## systemd

`librescoot-alarm.service`:
```
[Unit]
After=redis.service librescoot-vehicle.service librescoot-settings.service librescoot-motion.service
Wants=redis.service librescoot-motion.service

[Service]
ExecStart=/usr/bin/alarm-service \
    --redis=localhost:6379 \
    --log-level=info
```

The `Wants=`/`After=librescoot-motion.service` ordering ensures the chip is in a known state before alarm-service starts watching the alarm hash.

## Related Documentation

- [librescoot-motion](librescoot-motion.md) — chip owner; provider of `motion:interrupt` + `motion:rpc/prepare-hibernation`
- [Vehicle states](../states/README.md) — how vehicle state affects alarm arming
- [Librescoot Services](README.md) — complete service overview
