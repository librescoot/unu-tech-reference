# librescoot-motion (motion-service)

## Description

The motion service is the sole owner of the BMX055 9-axis IMU on the MDB. It exposes raw sensor telemetry, tilt-compensated magnetic heading, and motion-engine events (any-motion + slow/no-motion). Steady-state chip configuration is reactive: motion-service watches the `alarm` and `power-manager` hashes and re-derives the chip profile from `(alarm.status, power-manager.state)`, so consumers (alarm-service primarily) never write registers themselves. A small synchronous RPC surface (`motion:rpc`) covers the cases where a consumer needs a confirmed-applied answer — most importantly the hibernation handshake.

The repo is at [`github.com/librescoot/motion-service`](https://github.com/librescoot/motion-service). Public; CC-BY-NC-SA.

## Version

LibreScoot motion-service v0.1+ (semver via git tags; PV from `git describe`).

## Command-Line Options

```
--i2c-bus=/dev/i2c-3                                    I2C bus device path for BMX055
--redis=localhost:6379                                  Redis address
--polling-rate=10                                       Sensor polling rate (Hz)
--evdev-device=/dev/input/by-path/platform-gpio-keys-event   gpio-keys input for the BMX INT line (empty -> poller-only)
--evdev-keycode=43                                      Keycode for the BMX INT line on the gpio-keys device
--log-level=info                                        Log level (debug, info, warn, error)
--version                                               Print version and exit
```

## Hardware

The BMX055 is a single package with three independently I²C-addressable devices on `/dev/i2c-3`:

- **0x18** — BMA253 accelerometer (data + slope/any-motion + slow/no-motion engines + INT pins)
- **0x68** — BMG160 gyroscope (3-axis rate)
- **0x10** — BMM150 magnetometer (3-axis field, with on-chip trim compensation)

motion-service unbinds the kernel driver at startup and drives all three over `/dev/i2c-3` directly. The chip is mounted on the underside of the MDB; magnetometer readings are remapped (axis order + signs) into a vehicle NED frame and tilt-compensated using the accelerometer.

## Redis Operations

### Hash: `motion`

**Fields written:**
- `initialized` — `true` once sensors are up
- `streaming` — `enabled`/`disabled`
- `polling-rate-hz` — current sensor poll rate
- `current-profile` — profile name applied to chip (`idle`, `armed-awake`, `armed-hibernation`, `level1`, `waiting`)
- `interrupt`, `pin`, `sensitivity`, `threshold`, `duration` — current motion-engine config
- `last-interrupt-timestamp` — unix-ms of last interrupt
- `error-count`, `last-error` — diagnostic counters
- `wake-cause` — unix-ms timestamp written **once on startup** if INT_STATUS_0 had a latched bit at boot. Durable backstop for the wake-from-hibernation indicator. alarm-service reads + deletes this on its own startup.
- Heading fields (refreshed from each magnetometer publish):
  - `heading` — 0–359 degrees, integer
  - `heading-deg` — float, medium-EMA-smoothed
  - `heading-accuracy` — heuristic 1-σ degrees
  - `heading-tilt` — angle from level
  - `heading-tilt-comp` — `true` if accel-based tilt compensation was applied to this sample

**Published channel:** `motion`

### Subscribed Hashes (HashWatcher with 50 ms debounce + StartWithSync)

- `alarm` — field `status`. Drives chip profile derivation.
- `power-manager` — field `state`. Hibernation-imminent states route armed → armed-hibernation profile.

### Pub/Sub Channels

- **`motion:sensors`** (10 Hz) — JSON `SensorReading` with `timestamp`, `accel`, `gyro`, optional `mag`, each as `{x, y, z, magnitude, unit}`.
- **`motion:heading`** (5 Hz) — JSON `HeadingReading`:
  ```json
  {
    "timestamp": 1777996408778,
    "heading_deg": 192.5,        // medium EMA, canonical "smoothed" value
    "heading_raw_deg": 191.7,    // unsmoothed, this sample only
    "heading_fast_deg": 192.1,   // fast EMA, τ ≈ 0.3 s
    "heading_slow_deg": 193.4,   // slow EMA, τ ≈ 3.9 s
    "accuracy_deg": 4.32,        // heuristic 1-σ
    "tilt_compensated": true,
    "tilt_deg": 15.7,
    "mag_strength_ut": 26.6,
    "excess_g": 0.018,
    "yaw_rate_dps": 1.4
  }
  ```
- **`motion:interrupt`** — JSON `MotionEvent`:
  ```json
  {"type": "edge", "timestamp": 1777996408778, "engine": "any-motion"}
  ```
  - `type` is `edge` for normal motion-engine fires, or `wake-hibernation` for the once-per-startup post-resume sentinel
  - `engine` is `any-motion` (slope) or `slow-motion`. Decided by reading `INT_STATUS_0` before clearing the latch.
- **`motion:ready`** — fired once on first successful profile-apply at startup. Payload: unix-ms timestamp.

### RPC Channel: `motion:rpc`

motion-service hosts a single redis-ipc `CallServer` on this channel, dispatching by method name. One BRPOP loop regardless of method count.

| Method | Request | Response | Use |
|---|---|---|---|
| `prepare-hibernation` | `{profile: "armed-hibernation"}` | `{programmed: bool, profile: string}` | Synchronous chip-config confirmation. alarm-service Calls this before releasing pm-service's suspend inhibitor. ~180 ms round-trip on the bench. |
| `get-calibration` | `{}` | `{hard_iron_offset, axis_order, axis_sign, yaw_offset_deg}` | Diagnostic — returns the magnetometer calibration applied to the heading pipeline. |
| `clear-latch` | `{}` | `{ok: bool}` | Clears the BMX055 latched INT bits. Useful for support if the chip is stuck asserted. |
| `soft-reset` | `{}` | `{ok: bool}` | Soft-resets accel + gyro. Caller is responsible for triggering profile re-apply. |

## Chip Profile Derivation

motion-service watches `alarm.status` and `power-manager.state`. The mapping table:

| `alarm.status` | `power-manager.state` | Profile | Engine | BW | Threshold | N | INT pin |
|---|---|---|---|---|---|---|---|
| `disabled` / `disarmed` / `delay-armed` / `seatbox-access` / unknown | * | `idle` | slow-motion | 7.81 Hz | 0x14 (~78 mg) | 3 | none, interrupt off |
| `armed` | not hibernating-imminent | `armed-awake` | any-motion (slope) | 31.25 Hz | 0x06 (~23 mg) | 4 | both, interrupt on |
| `armed` | `hibernating-*-imminent` / `hibernating-*` | `armed-hibernation` | any-motion (slope) | 31.25 Hz | 0x08 (~31 mg) | 4 | both, interrupt on |
| `level-1-triggered` | * | `level1` | slow-motion | 15.63 Hz | 0x08 (~31 mg) | 4 | both, interrupt on |
| `level-2-triggered` | * | `waiting` | slow-motion | 7.81 Hz | 0x06 (~23 mg) | 3 | none, interrupt off |

Profile values match alarm-service's pre-Phase-4 sensor configs verbatim — the production tunings carry over.

### Apply Sequence

`controller.Apply(profile)` is idempotent (re-applying the current profile is a no-op). Sequence on a real change:

1. Disable poller + watcher (so they don't observe transient INT activity from the bandwidth-settle period).
2. Soft-reset accel + gyro; sleep 10 ms.
3. Set BMA253 bandwidth.
4. Configure the active motion engine (any-motion or slow-motion); disable the other.
5. Configure interrupt pin output (active-high, latched).
6. **Double-clear the latch with a 100 ms settle window in between** — load-bearing. The bandwidth change kicks off a low-pass filter settle that can produce a transient slope large enough to set the status bit. If the pin mapping is in place during that transient, INT spikes from a stale status bit and the gpio-keys edge fires before the status is cleared. Clear → 100 ms → clear → only then add the engine to the pin map.
7. Map the engine to the configured INT pin(s).
8. Re-arm poller + watcher.

Total elapsed ~150–180 ms on the bench. With the 50 ms HashWatcher debounce, total propagation from `alarm.status` write to chip-in-new-profile is ~200–230 ms.

## Interrupt Path

**Two redundant sources, one envelope shape:**

- **Fast path: `InterruptWatcher`** — reads the gpio-keys input device for the BMX055 INT line (`/dev/input/by-path/platform-gpio-keys-event`, keycode 43 by default). Wakes within milliseconds of the GPIO edge.
- **Watchdog path: `InterruptPoller`** — 100 ms polling of `INT_STATUS_0`. Catches anything the watcher missed (e.g. evdev unavailable, kernel tick delays).

Both publish identical `MotionEvent` JSON envelopes on `motion:interrupt` and clear the chip latch. They're enabled in lockstep with the profile (gated by `controller.Apply`).

## Startup Invariants

1. Unbind kernel BMX055 driver.
2. Initialize accel, gyro, mag (with retries on I²C transient errors).
3. Start sensor + magnetometer pollers (telemetry).
4. Start interrupt poller + watcher (initially disabled).
5. **Read `INT_STATUS_0` BEFORE the first `controller.Apply`.** If a slope or slow-no-motion bit is latched, this is a wake-from-hibernation; record it.
6. Apply `Idle` profile (always — defends against any half-state from a previous owner).
7. If wake-from-hibernation was detected: `PUBLISH motion:interrupt {type:"wake-hibernation",...}` AND `HSET motion wake-cause <unix-ms>`. The hash field is the durable backstop for consumers that started after motion-service published.
8. Connect redis-ipc client (JSON codec, pool size 8).
9. Start `Subscriber` (HashWatchers on alarm + power-manager, `StartWithSync` so the chip syncs to current vehicle state on first dispatch).
10. Start `CallServer` with `prepare-hibernation`, `get-calibration`, `clear-latch`, `soft-reset`.
11. `PUBLISH motion:ready`.

## Magnetometer Calibration

motion-service applies a hard-coded hard-iron offset + axis-order/sign remap + a yaw offset, derived from a sphere fit on bench-collected data:

```go
HardIronOffset: [3]int16{13, 339, 989}
AxisOrder:      [3]int{1, 0, 2}        // chip Y -> vehicle X, etc
AxisSign:       [3]float64{-1, 1, 1}
YawOffsetDeg:   107
```

The chip is mounted face-down on the MDB underside, rotated 90°. The compensation transforms readings into vehicle NED (North=X, East=Y, Down=Z). Heading is computed as `atan2(-magY_NED, magX_NED)` after tilt compensation using accelerometer roll/pitch.

For long-term accuracy, an ellipsoid fit (accounting for soft-iron from the chassis steel) would be preferable; deferred to a future calibration capture.

## Magnetometer Operating Mode

BMM150 in `forced` mode at 5 Hz with `high-accuracy` REPXY/REPZ presets (47/83 reps). The trim compensation is the full Bosch BMM050 reference port (int64 to avoid the integer-truncation pitfall).

## systemd Unit

`librescoot-motion.service`:
```
[Unit]
Description=LibreScoot Motion Service (BMX055 IMU)
After=network.target redis.service
Wants=redis.service

[Service]
ExecStart=/usr/bin/motion-service \
    --i2c-bus=/dev/i2c-3 \
    --redis=localhost:6379 \
    --polling-rate=10 \
    --log-level=info
Restart=always
RestartSec=5
```

Auto-enabled (`SYSTEMD_AUTO_ENABLE = "enable"` in the meta-librescoot recipe). alarm-service's unit declares `Wants=`/`After=librescoot-motion.service` so the chip is in a known state before alarm-service starts driving it.

## Diagnostic Tool

`motion-calibrate` (separate binary) is a one-shot data-capture tool for re-deriving the hard-iron offset. Triggered manually via `systemctl start motion-calibrate.service` — `Conflicts=` librescoot-motion so the capture has exclusive chip access; `ExecStopPost=` brings librescoot-motion back up automatically. CSVs written to `/data/motion-cal-<unix-ts>.csv`.

## Testing

### Inspect live state

```bash
# Current chip profile
redis-cli HGET motion current-profile

# Live heading at 5 Hz
redis-cli SUBSCRIBE motion:heading

# Live IMU stream at 10 Hz
redis-cli SUBSCRIBE motion:sensors

# Watch motion edges
redis-cli SUBSCRIBE motion:interrupt
```

### Drive a profile change manually

```bash
# Force armed-hibernation profile
redis-cli HSET alarm status armed
redis-cli PUBLISH alarm status
redis-cli HSET power-manager state hibernating-imminent
redis-cli PUBLISH power-manager state

# Verify
redis-cli HGET motion current-profile  # -> armed-hibernation
```

### RPC call (manual one-liner)

```bash
CHANNEL=motion:rpc
REPLY=$CHANNEL:reply:test
DEADLINE=$(($(date +%s%3N) + 2000))
ENV="{\"id\":\"test\",\"method\":\"get-calibration\",\"reply_channel\":\"$REPLY\",\"deadline\":$DEADLINE,\"payload\":{}}"

( timeout 3 redis-cli SUBSCRIBE "$REPLY" > /tmp/reply 2>&1 ) &
sleep 0.3
redis-cli LPUSH "$CHANNEL" "$ENV"
wait
cat /tmp/reply
```

## Dependencies

- **BMX055** — accessible via I²C on `/dev/i2c-3`
- **gpio-keys evdev** at `/dev/input/by-path/platform-gpio-keys-event` (graceful fallback to poller-only)
- **Redis** — for state hashes, pub/sub, RPC
- **redis-ipc v0.13.0+** — `CallServer` / `RegisterCall` / `CallMethod` primitive

## Related Documentation

- [librescoot-alarm](librescoot-alarm.md) — primary consumer of `motion:interrupt` and `motion:rpc/prepare-hibernation`
- [Redis Operations](../redis/README.md) — full Redis surface
- [Service interactions](../service-interactions.md) — Redis interaction map
- [BMX055 datasheet](../electronic/README.md) — chip-level reference
