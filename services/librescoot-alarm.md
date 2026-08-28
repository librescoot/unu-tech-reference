# librescoot-alarm (alarm-service)

## Description

Security alarm for the scooter, driven by motion, button presses, the handlebar sensors and unauthorized seatbox openings. alarm-service is a pure FSM/policy layer — as of the [motion-service refactor](librescoot-motion.md), it does not touch the BMX055 directly. It publishes its FSM state (`alarm.status`) so motion-service can reactively configure the chip; consumes `motion:interrupt` events; and uses one synchronous `motion:rpc/prepare-hibernation` Call to gate pm-service's hibernation entry.

## Version

Librescoot alarm-service v0.10+ (Phase 4 of the motion-service refactor).

## Command-Line Options

```
--redis=localhost:6379         Redis address
--log-level=info               Log level (debug, info, warn, error)
--alarm-enabled=true           Enable alarm system (writes to Redis on startup)
--alarm-duration=30            Alarm duration in seconds
--horn-enabled=false           Enable horn during alarm (overrides Redis setting)
--seatbox-trigger=true         Trigger alarm on unauthorized seatbox opening
--hair-trigger=false           Enable hair trigger mode (immediate short alarm on first motion)
--hair-trigger-duration=3      Hair trigger alarm duration in seconds
--l1-cooldown=15               Level 1 cooldown duration in seconds
--version                      Print version and exit
```

`--i2c-bus`, `--evdev-device`, `--evdev-keycode`, `--poller-interval-ms` are gone. motion-service owns the chip.

These flags only take effect when explicitly passed; each one then writes its value to the `settings` hash on startup. The production unit passes none of them, so the settings-service schema defaults apply; the compiled-in flag defaults now match the schema (`alarm.duration` 30, `alarm.l1-cooldown` 15).

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
- `trigger:source` - the input that last set the alarm off: `motion`, `seatbox`,
  `handlebar_position`, `handlebar_lock`, `brake_left`, `brake_right`,
  `horn_button`, `seatbox_button`
- `trigger:timestamp` - when that trigger fired, RFC3339 UTC

Both trigger fields are written together in one round trip with a single
notification, so a consumer watching the hash never sees a source paired with
the previous timestamp.

Only a trigger that actually moved the state machine is recorded. An edge
dropped by the settling window, the position dwell or a disabled source never
claims the field. Neither field is cleared on disarm: they name the most recent
trigger, not the current state, which is what makes them useful for working out
after the fact why a parked scooter sounded its horn.

**Published channel:** `alarm`

**motion-service watches this hash.** A change on `alarm.status` triggers a profile re-derivation in motion-service via `(alarm.status, power-manager.state)`. See [librescoot-motion](librescoot-motion.md#chip-profile-derivation) for the full mapping table.

### Hash: `settings`

**Fields read:**

- `alarm.enabled`, `alarm.honk`, `alarm.duration`, `alarm.seatbox-trigger`
- `alarm.hairtrigger`, `alarm.hairtrigger-duration`, `alarm.l1-cooldown`
- `alarm.trigger.motion`, `alarm.trigger.buttons`, `alarm.trigger.handlebar` (per-source trigger gates, see [Trigger Sources](#trigger-sources))

**Fields written (if CLI flags set):** same fields, overrides Redis values on startup.

**Subscribed channels:** `settings`

### Hash: `power-manager`

**Fields read:** `state`. Hibernation-imminent transitions trigger the synchronous `prepare-hibernation` Call.

**Subscribed channels:** `power-manager`

### Hash: `motion`

**Fields read on startup:** `wake-cause` (deleted after consumption). Durable backstop for the wake-from-hibernation indicator across the startup-ordering race with motion-service's pub/sub.

### Pub/Sub Channels

**Subscribes to:**

- `vehicle` — state, seatbox:opened event, seatbox:lock, handlebar:lock-sensor, handlebar:position
- `settings` — alarm.* changes
- `power-manager` — state field
- `motion:interrupt` — JSON envelope `{type, timestamp, engine}` from motion-service. `type` becomes `BMXInterruptEvent.Data` (the FSM discriminates `wake-hibernation` from regular edges).
- `buttons`: raw input edges from vehicle-service (`brake:left:{on,off}`, `brake:right:{on,off}`, `horn:{on,off}`, `seatbox:{on,off}`). Blinker edges share the channel and are ignored.

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
- `scooter:power` (`hibernate-manual`, sent 5 minutes after a wake from hibernation if nothing triggers again)

## Trigger Sources

Four inputs escalate the alarm out of `armed`. Each has its own settings gate.

| Setting | Source | Default |
|---|---|---|
| `alarm.trigger.motion` | `motion:interrupt` events from motion-service | `true` |
| `alarm.trigger.buttons` | brake left/right, horn and seatbox button presses on the `buttons` channel | `true` |
| `alarm.trigger.handlebar` | `vehicle[handlebar:lock-sensor]` going `unlocked`, `vehicle[handlebar:position]` going `off-place` | `false` |
| `alarm.seatbox-trigger` | unauthorized `vehicle[seatbox:lock]` = `open` | `true` |

The defaults are the settings-service schema values, which settings-service
writes into the `settings` hash at startup. Without settings-service the
compiled-in fallbacks apply: `true` for `alarm.trigger.motion` and
`alarm.trigger.buttons`, `false` for `alarm.trigger.handlebar`.

Button and handlebar edges are filtered in the Redis subscriber, so a source
that is switched off never reaches the FSM. Motion is filtered in the FSM
instead: a motion event also carries the wake-from-hibernation stamp that the
re-hibernate bookkeeping depends on, and the stamp has to survive the drop.

Switching a source off suppresses the alarm, not the wake. The accelerometer
still asserts its interrupt and the nRF52 still wakes the MDB;
`alarm.trigger.motion=false` only means the resulting event is dropped instead
of escalated.

Only the pressed edge of a button counts, so one press is one trigger. Throttle
is not a source: it exists only as an ECU CAN payload and the ECU is powered
down in stand-by.

### Handlebar Baseline

The two handlebar fields count only on a genuine safe-to-unsafe transition,
`locked` -> `unlocked` and `on-place` -> `off-place`. The first value each field
delivers after startup is recorded as a baseline and triggers nothing. Plenty of
scooters park with the handlebar lock never engaged and report `unlocked` as
their resting value, which the initial hash sync would otherwise turn into an
alarm on every service restart.

### Handlebar Settling Window

Both handlebar sources stay muted for **90 seconds** after every entry into
`armed` (`handlebarSettleDelay` in `internal/fsm/state_machine.go`). Locking the
vehicle is itself a handlebar event: vehicle-service drives the lock solenoid
for 1.1 s with up to 3 retries, and a rider who still has to swing the bars into
place gets a 60 s positioning window that pulses again at the end of it. Either
can bounce the lock sensor or move the position sensor while the alarm has
already armed.

Arming starts ~5 s after the vehicle reaches stand-by, so a 60 s window here
would expire just as vehicle-service's own closes, and the retry pulses of a
late positioning would land outside it entirely. 90 s clears both with ~30 s to
spare.

Edges inside the window are dropped rather than queued. Replaying a stale edge
once the window closes would sound the alarm for something that finished a
minute ago. The timer keeps running when `armed` is left, so an escalation
cannot strand the sources muted, and a disarm/rearm cycle opens a fresh window.
Motion, buttons and the seatbox are never muted, so the vehicle keeps a live
tamper path throughout.

### Handlebar Position Dwell

`vehicle[handlebar:position]` must read `off-place` continuously for
**1 second** (`defaultHandlebarPositionDwell` in `internal/redis/subscribers.go`)
before it counts as tampering. The off-place edge starts a timer instead of
firing; returning to `on-place` cancels it, and a fresh off-place edge restarts
it, so a chattering sensor never accumulates a full window.

`handlebar:position` and `handlebar:lock-sensor` are separate sensors, and a
parked vehicle can report a brief `off-place` without the bars having been
turned. The dwell exists to filter those. A real tamper leaves the bars
off-place, so the only cost is delaying the alarm by that second.

The dwell deliberately does **not** consult `handlebar:lock-state`. A `locked`
reading is not proof the bars are held: a forced or broken lock pin can leave
that sensor reading `locked` while the bars turn freely, which is a hallmark of
a theft attempt rather than a reason to suppress the trigger.

Note the dwell only filters brief excursions. If the bars come to rest outside
the `on-place` zone, the reading stays `off-place`, the dwell expires and the
trigger stands, which is correct: at that point it is indistinguishable from
bars that someone has actually turned.

Suppressed excursions are logged at info with how long they lasted
(`off_place_ms`), so the constant can be retuned from what the sensor and the
weather actually do rather than guessed at again.

The lock sensor has no dwell. `locked` -> `unlocked` is unambiguous and fires as
soon as the baseline and settling-window guards allow.

## Alarm State Machine

```
init → waiting_enabled → disarmed → delay_armed (5s) → armed
                                         ↑                ↓ motion detected (motion:interrupt)
                                         |        trigger_level_1_wait (configurable cooldown)
                                         |                ↓
                                         |        trigger_level_1 (5s check)
                                         |                ↓ major movement
                                         |        trigger_level_2 (alarm.duration, max 6 cycles)
                                         |________________|
```

Plus `seatbox_access` (transient state during authorized seatbox openings) and `waiting_movement` (between L2 cycles).

### State Descriptions

- **init**: Initial state on startup
- **waiting_enabled**: Alarm disabled, waiting for enable command
- **disarmed**: Alarm enabled but vehicle not in stand-by
- **delay_armed**: 5-second delay before arming (allows user to leave)
- **armed**: Armed and monitoring the enabled trigger sources (motion, buttons, handlebar, seatbox)
- **trigger_level_1_wait**: Cooldown after a trigger. `alarm.l1-cooldown`, default 15s. With hair trigger: immediate short alarm.
- **trigger_level_1**: 5-second check for continued movement
- **trigger_level_2**: Full alarm activated (horn + hazards). Duration is `alarm.duration`, default 30s. Capped at 6 cycles.
- **seatbox_access**: Authorized seatbox opening — alarm temporarily inhibited
- **waiting_movement**: Between L2 cycles, waiting for re-trigger

### Arming

- Alarm enabled (`settings alarm.enabled = true`)
- Vehicle enters `stand-by`
- 5-second `delay_armed` countdown (skipped on startup if already in stand-by)
- Transition to `armed`

### Triggering

- An enabled [trigger source](#trigger-sources) fires while in `armed`: a `motion:interrupt`, a button press, or a handlebar edge past the settling window
- `armed` → `trigger_level_1_wait`
- Hazards blink once
- If hair trigger enabled: short horn pulse (skipped if this edge was the wake-from-hibernation edge — `wakeFromHibernation` flag gates it)
- Cooldown (default 15s, configurable) → `trigger_level_1`
- 5s verification window → if another trigger arrives: `trigger_level_2`; else: back through `delay_armed` to `armed`

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
6. On failure: alarm-service acquires its `power:inhibits` block inhibitor and **holds it** — pm-service stays blocked rather than hibernating with an unverified chip profile.

This is the only synchronous call alarm-service makes. All other chip-config flows reactively through the `alarm` hash that motion-service watches.

## Wake-from-Hibernation Detection

When motion-service starts up after a hibernation wake AND finds `INT_STATUS_0` already latched, it publishes a one-shot `motion:interrupt {type: "wake-hibernation", ...}` AND writes `motion.wake-cause = <unix-ms>` to its hash. The hash field is durable across the startup-ordering race.

alarm-service on startup:

1. Calls `MotionClient.ConsumeWakeCause(ctx)` — HGET + HDEL on `motion.wake-cause`. If the timestamp is within 30 s of now, returns true.
2. If true: sends `BMXInterruptEvent{Data:"wake-hibernation"}` to the FSM at `StateInit`. Sets `wakeFromHibernation=true`.
3. FSM init checks the flag at `InitCompleteEvent`: if alarm-enabled + standby + wakeFromHibernation, transitions directly to `StateTriggerLevel1Wait` (treats the wake-edge as the L1 trigger). Hair trigger is skipped on this entry — the wake-edge isn't a tampering event by itself.

## Suspend Inhibitor Management

A `block` inhibitor in pm-service's `power:inhibits` hash (id `alarm-active`, who `librescoot-alarm`, what `power-state-change`) keeps pm-service from suspending or hibernating the MDB while the alarm is delaying or triggered. pm-service's suspend gate reads its own registry (`power:inhibits` + the `/tmp/suspend_inhibitor` socket). The `who` is deliberately not `librescoot-modem`, so pm-service's `hasOnlyModemBlockingInhibitors` does not let it suspend through. alarm-service clears any stale `alarm-active` entry on startup so a crash mid-alarm can't wedge power management.

Held in:

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

# Switch off one trigger source
redis-cli HSET settings alarm.trigger.handlebar false
redis-cli PUBLISH settings alarm.trigger.handlebar
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
After=valkey.service librescoot-vehicle.service librescoot-settings.service librescoot-motion.service
Wants=valkey.service librescoot-motion.service

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
