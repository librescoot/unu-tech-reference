# Librescoot Service Interaction Map

Generated from source analysis of all service repositories.

## Architecture Overview

```
                                    Redis (192.168.7.1:6379)
                                    ========================

                    Hashes (state storage + pub/sub notification)
                    ─────────────────────────────────────────────
 vehicle-service ──writes──> vehicle, system, ota, dashboard, buttons, vehicle:fault, events:faults
 battery-service ──writes──> battery:0, battery:1, battery:N:fault
 ecu-service ────writes──> engine-ecu  (WARNING: publishes to broken channels, see gaps)
 keycard-service ─writes──> keycard  (with 10s TTL)
 bluetooth-service writes──> ble, ble:fault, system (mdb-version, nrf-fw-version), engine-ecu (odometer)
 pm-service ─────writes──> power-manager, power-manager:busy-services, system (cpu:governor)
 modem-service ──writes──> internet, modem, gps, internet:fault, events:faults
 dbc-backlight ──writes──> dashboard (backlight, brightness)
 dbc-illumination writes──> dashboard (illumination)
 alarm-service ──writes──> alarm
 version-service  writes──> os-release  (one-shot at boot, no pub/sub notification)
 settings-service writes──> settings  (WARNING: no PUBLISH on initial load, see gaps)
 update-service ──writes──> ota  (status:*, update-version:*, download-progress:*, etc.)
 ums-service ────writes──> usb
 scootui ────────writes──> dashboard (ready, serial-number)

                    Lists (command queues, LPUSH/BRPOP)
                    ────────────────────────────────────
 scooter:state   ── vehicle-service reads ── lsc, scootui, uplink-service, alarm-service write
 scooter:seatbox ── vehicle-service reads ── lsc, scootui, uplink-service write
 scooter:horn    ── vehicle-service reads ── lsc, scootui, uplink-service, alarm-service write
 scooter:blinker ── vehicle-service reads ── lsc, scootui, uplink-service, alarm-service write
 scooter:led:cue ── vehicle-service reads ── lsc writes
 scooter:led:fade── vehicle-service reads ── lsc writes
 scooter:update  ── vehicle-service reads ── update-service writes (start-dbc, complete-dbc)
 scooter:hardware── vehicle-service reads ── lsc, scootui, uplink-service write
 scooter:power   ── pm-service reads      ── lsc, update-service, uplink-service write
 scooter:governor── pm-service reads      ── vehicle-service writes
 scooter:modem   ── modem-service reads   ── pm-service writes ("disable")
 scooter:bluetooth─ bluetooth-service reads─ (firmware-update and BLE commands)
 scooter:alarm   ── alarm-service reads   ── lsc writes
 settings:overlay── settings-service reads ── lsc writes (apply:service, clear:service)
 scooter:update:<component> ── update-service reads ── update-service writes (check-now)
 power:inhibits  ── pm-service inhibitor redis listener reads ── (external inhibitors write)

                    Pub/Sub channels (notifications only; consumers HGET after receiving)
                    ──────────────────────────────────────────────────────────────────────
 vehicle       ← published by vehicle-service (payload = field name changed)
 battery:0     ← published by battery-service (payload = field name or "fault")
 battery:1     ← published by battery-service
 engine-ecu    ← published by bluetooth-service (odometer), NOT by ecu-service (see gaps)
 keycard       ← published by keycard-service
 dashboard     ← published by scootui (ready, serial-number), dbc-backlight, dbc-illumination
 power-manager ← published by pm-service
 system        ← published by vehicle-service (cpu:governor), bluetooth-service (mdb-version, nrf-fw-version)
 ota           ← published by update-service
 internet      ← published by modem-service
 modem         ← published by modem-service
 gps           ← published by modem-service
 alarm         ← published by alarm-service
 ble           ← published by bluetooth-service
 usb           ← published by ums-service
 settings      ← published externally (scootui, UMS updates); NOT by settings-service on load
 motion:sensors    ← published by motion-service (10 Hz IMU stream)
 motion:heading    ← published by motion-service (5 Hz tilt-compensated mag heading)
 motion:interrupt  ← published by motion-service (motion-engine edges + wake-hibernation)
 motion:ready      ← published by motion-service on startup
 motion:rpc        ← request channel for motion-service RPC (alarm-service Calls prepare-hibernation)
 buttons           ← published by vehicle-service (physical button events)

                    Sets (fault tracking)
                    ─────────────────────
 vehicle:fault  ── written by vehicle-service
 battery:0:fault── written by battery-service
 battery:1:fault── written by battery-service
 internet:fault ── written by modem-service
 ble:fault      ── written by bluetooth-service

                    Streams (event log)
                    ───────────────────
 events:faults  ── written by vehicle-service, modem-service; read by uplink-service (HGetAll)
```

## Per-Service Detail

### vehicle-service

**Writes (hash → pub/sub channel):**
| Hash | Fields | Channel |
|------|--------|---------|
| `vehicle` | `state`, `state:timestamp`, `blinker:switch`, `blinker:state`, `brake:left`, `brake:right`, `seatbox:lock`, `kickstand`, `handlebar:lock-sensor`, `handlebar:position`, `dashboard:power`, `dbc-updating`, `update:status`, `auto-standby-remaining` (deprecated), `auto-standby-deadline` | `vehicle` |
| `system` | `cpu:governor` | `system` |
| `ota` | `standby-timer-start` | `ota` |
| `dashboard` | `ready` (deletes on standby) | `dashboard` |
| `buttons` | `horn:on`, `horn:off`, `seatbox:on`, `seatbox:off` | `buttons` |
| `vehicle:fault` | fault codes (Redis Set) | `vehicle` (payload: "fault") |
| `events:faults` | fault events (Redis Stream) | — |

**Reads:**
- `vehicle/state` (self-reads for restart recovery)
- `vehicle/dbc-updating`, `vehicle/dashboard:power` (self-reads)
- `dashboard/ready` (from scootui)
- `keycard/authentication` (from keycard-service)
- `settings/*` (any field, for scooter.*, alarm settings via watch)
- `ota/status:mdb`, `ota/status:dbc` (checks OTA status on update commands)
- `ota/standby-timer-start` (indirectly via update-service)

**Consumes queues (BRPOP):**
- `scooter:state` → "unlock", "lock", "lock-hibernate", "force-lock"
- `scooter:seatbox` → "open"
- `scooter:horn` → "on", "off"
- `scooter:blinker` → "off", "left", "right", "both"
- `scooter:led:cue` → integer cue index
- `scooter:led:fade` → "channel:index" string
- `scooter:update` → "start", "complete", "start-dbc", "complete-dbc"
- `scooter:hardware` → "dashboard:on", "dashboard:off", "engine:on", "engine:off", "handlebar:lock", "handlebar:unlock" (and :force variants)

**Produces queues (LPUSH):**
- `scooter:governor` → "ondemand"/"powersave" (send to pm-service via intermediate; actually uses its own queue handler — see note)

**Hardware access:** GPIO via `/dev/gpiochip*`, PWM LED via kernel driver

---

### battery-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `battery:0` | `present`, `state`, `voltage`, `current`, `charge`, `temperature:0`–`3`, `temperature-state`, `cycle-count`, `state-of-health`, `serial-number`, `manufacturing-date`, `fw-version` | `battery:0` (on change: `present`, `state`, `charge`, `temperature-state`, `fault`) |
| `battery:1` | same fields | `battery:1` |
| `battery:N:fault` | fault codes (Redis Set) | `battery:N` (payload: "fault") |

**Reads:**
- `vehicle/state` (vehicle state for active/standby mode)
- `vehicle/seatbox:lock` (seatbox state for enabling battery readers)
- `settings/scooter.battery-ignores-seatbox`
- `settings/scooter.dual-battery`

**Subscribes to:**
- `vehicle` channel (payload: "state", "seatbox:lock")
- `settings` channel (payload: "scooter.battery-ignores-seatbox", "scooter.dual-battery")

**Hardware access:** NFC via `/dev/i2c-*`, PN7150 controller

---

### ecu-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `engine-ecu` | `motor:voltage`, `motor:current`, `rpm`, `speed`, `raw-speed`, `throttle`, `brake`, `power`, `energy:consumed`, `energy:recovered` | (broken: see gaps) |
| `engine-ecu` | `temperature`, `fault:code`, `fault:description` | (no publish) |
| `engine-ecu` | `odometer` | (broken: see gaps) |
| `engine-ecu` | `kers`, `boost` | (broken: see gaps) |
| `engine-ecu` | `kers-reason-off` | (broken: see gaps) |
| `engine-ecu` | `gear`, `fw-version` | (no publish) |

**Reads:**
- `vehicle/state` (for engine ready state)
- `battery:0/state`, `battery:0/temperature-state`
- `battery:1/state`, `battery:1/temperature-state`
- `settings/engine-ecu.boost`

**Subscribes to:**
- `vehicle` channel (payload: "state")
- `battery:0`, `battery:1` channels (all fields → HGETALL)
- `settings` channel (payload: "engine-ecu.boost")

**Hardware access:** CAN bus via `/dev/can*`

---

### keycard-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `keycard` | `authentication` ("passed"), `type` ("scooter"), `uid` | `keycard` (payload: "authentication") |

Note: Sets 10-second TTL on `keycard` hash after publish.

**Reads:** None (hardware-driven)

**Hardware access:** NFC via PN7150, I2C LED controller LP5562

---

### bluetooth-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `system` | `mdb-version` (from nRF), `nrf-fw-version` | `system` |
| `engine-ecu` | `odometer` (from nRF) | `engine-ecu` |
| `ble` | status fields, `pin-code`, `firmware-update-status` | `ble` |
| `ble:fault` | fault codes (Redis Set) | `ble` (payload: "fault") |

**Reads:**
- `vehicle/state`, `vehicle/seatbox:lock`, `vehicle/handlebar:lock-sensor`
- `battery:0/state`, `battery:0/present`, `battery:0/charge`, `battery:0/cycle-count`
- `battery:1/state`, `battery:1/present`, `battery:1/charge`, `battery:1/cycle-count`
- `power-manager/state`
- `engine-ecu/odometer`
- `system/mdb-version`
- `ble/pin-code`

**Subscribes to:**
- `vehicle`, `battery:0`, `battery:1`, `power-manager`, `engine-ecu`, `system`, `ble` channels

**Consumes queues:**
- `scooter:bluetooth` → BLE commands ("advertising-start-with-whitelisting", "advertising-restart-no-whitelisting", "advertising-stop", "delete-bond", "delete-all-bonds", "remove", "firmware-update")

**Hardware access:** UART via usock to nRF52 at `/var/run/bluetooth-service.sock` or similar

---

### pm-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `power-manager` | `state` ("running", "suspending", "hibernating", etc.), `wakeup-source` | `power-manager` |
| `power-manager:busy-services` | inhibitor entries (field = "who why what", value = type) | `power-manager:busy-services` (payload: "replaced"/"cleared") |
| `system` | `cpu:governor` | `system` |

**Reads:**
- `vehicle/state` (watches for standby/parked/ready-to-drive transitions)
- `battery:0/state` (watches for active/inactive)
- `settings/hibernation-timer`

**Subscribes to:**
- `vehicle` channel via HashWatcher
- `battery:0` channel via HashWatcher
- `settings` channel (for hibernation-timer)
- `power:inhibits` hash (inhibitor redis listener)

**Consumes queues:**
- `scooter:power` → "run", "suspend", "hibernate", "hibernate-manual", "hibernate-timer", "reboot"
- `scooter:governor` → "ondemand", "powersave", "performance"

**Produces queues:**
- `scooter:modem` → "disable" (to disable modem before power state change)

**Hardware access:** `/sys/power/pm_wakeup_irq`, `/sys/class/tty/*/power/wakeup`, systemd D-Bus

---

### update-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `ota` | `status:<component>`, `update-version:<component>`, `download-progress:<component>`, `download-bytes:<component>`, `download-total:<component>`, `install-progress:<component>`, `error:<component>`, `error-message:<component>`, `update-method:<component>` | `ota` |
| `settings` | `updates.<component>.last-check-time` | `settings` |

**Reads:**
- `vehicle/state` (watches; state-based update triggering)
- `vehicle/state:timestamp` (for standby duration check)
- `ota/standby-timer-start` (from vehicle-service, for timing)
- `ota/status:<component>` (self-read)
- `ota/update-version:<component>`, `ota/update-method:<component>`
- `version:<component>/version_id`, `version:<component>/variant_id`
- `settings/updates.<component>.method`
- `settings/updates.<component>.last-check-time`

**Subscribes to:**
- `vehicle` channel (via HashWatcher)
- `ota` channel (via HashWatcher)
- `settings` channel (via HashWatcher)

**Consumes queues:**
- `scooter:update:<component>` → "check-now"

**Produces queues:**
- `scooter:update` → "start-dbc", "complete-dbc" (to vehicle-service)
- `scooter:power` → "reboot" (after MDB update)

**External:** GitHub Releases API, Mender

---

### modem-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `internet` | connectivity fields | `internet` |
| `modem` | modem status fields | `modem` |
| `gps` | location data (`lat`, `lon`, `accuracy`, `speed`, `heading`, `altitude`, `updated`, `timestamp`) | `gps` (payload: "timestamp" on recovery, no publish on regular update) |
| `internet:fault` | fault codes (Redis Set) | `internet` (payload: "fault") |
| `events:faults` | modem fault events (Redis Stream) | — |

**Reads:**
- `vehicle/state` (via HashWatcher, for hibernation behavior)

**Consumes queues:**
- `scooter:modem` → "disable", "enable"

**Hardware access:** ModemManager via D-Bus, GPIO modem power, USB

---

### version-service

**Writes (one-shot at boot, no pub/sub publish):**
| Hash | Fields |
|------|--------|
| `os-release` | All fields from `/etc/os-release` (lowercase), `serial_number`, `serial_number_real` |

Note: version-service does NOT publish to the `os-release` channel. It runs once at boot via systemd (Type=oneshot) and exits. The `system` hash for `mdb-version` is written by bluetooth-service (from nRF).

**Hardware access:** `/sys/bus/nvmem/devices/imx-ocotp0/nvmem`, `/sys/fsl_otp/HW_OCOTP_CFG0`/`CFG1`

---

### settings-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `settings` | All TOML fields: `scooter.*`, `cellular.*`, `updates.*`, `dashboard.*`, `alarm.*`; overlay-injected values (in-memory only, not persisted); `dashboard.service-mode-active` status field | NONE (critical gap — see gaps section) |

**Reads:**
- `settings/*` (all fields, to save back to TOML)

**Subscribes to:**
- `settings` channel (to detect changes and flush to TOML)
- `internet` channel (for WireGuard manager)

**Consumes queues (BRPOP):**
- `settings:overlay` → `apply:service`, `clear:service` — owns the overlay command list; the `service` overlay fans out to pm-service, vehicle-service, alarm-service, and scootui purely via existing `settings`-channel reactions

**Hardware access:** `/data/settings.toml`, NetworkManager D-Bus

---

### alarm-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `alarm` | `status` ("disabled", "disarmed", "armed", "level-1-triggered", "level-2-triggered") | `alarm` |

**Produces queues (LPUSH):**
- `scooter:horn` → "on", "off"
- `scooter:blinker` → "both", "off"

**Publishes:**
- `alarm` hash `status` field — motion-service watches this and reactively re-derives the BMX055 chip profile

**Calls (synchronous RPC via redis-ipc CallMethod):**
- `motion:rpc/prepare-hibernation` — gates pm-service's hibernation entry on motion-service confirming the chip is in armed-hibernation profile

**Reads:**
- `vehicle/state` (via HashWatcher)
- `vehicle/seatbox:lock` (via HashWatcher)
- `settings/alarm.enabled`, `settings/alarm.honk`, `settings/alarm.duration`
- `settings/alarm.seatbox-trigger`, `settings/alarm.hairtrigger`, `settings/alarm.hairtrigger-duration`
- `settings/alarm.l1-cooldown`
- `motion/wake-cause` (once on startup — durable backstop for wake-from-hibernation indicator)

**Subscribes to:**
- `vehicle` channel (state, seatbox:opened event, seatbox:lock)
- `settings` channel
- `power-manager` channel (state field — drives hibernation handshake)
- `motion:interrupt` channel (JSON envelope `{type, timestamp, engine}`)

**Consumes queues:**
- `scooter:alarm` → "enable", "disable", "start:N", "stop"

**Hardware access:** I2C BMX055 accelerometer/gyroscope at `/dev/i2c-3`

---

### dbc-backlight-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `dashboard` | `backlight` (int), `brightness` (float lux) | `dashboard` |

**Reads:**
- `dashboard/brightness` (illuminance value from dbc-illumination-service)

**Hardware access:** `/sys/class/backlight/*` or sysfs PWM

---

### dbc-illumination-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `dashboard` | `illumination` (float lux) | `dashboard` |

**Reads:** None (hardware-driven)

**Hardware access:** OPT3001 ambient light sensor via I2C

---

### scootui (Flutter dashboard)

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `dashboard` | `ready` ("true"), `serial-number` | `dashboard` |

**Reads (HGETALL / HGET):**
- `vehicle`, `battery:0`, `battery:1`, `engine-ecu`, `power-manager`, `internet`, `modem`, `gps`, `keycard`, `ble`, `dashboard`, `system`

**Subscribes to (pub/sub):**
- Multiple channels for real-time updates (subscription details in app UI layers)

**Produces queues (LPUSH):**
- `scooter:state` → "lock", "unlock", "lock-hibernate"
- `scooter:seatbox` → "open"
- `scooter:horn` → "on", "off"
- `scooter:hardware` → various
- (via `push()` method)

**Publishes:**
- `buttons` channel (button events)

**Hardware access:** Display via Flutter framebuffer/DRM backend

---

### uplink-service

**Reads (telemetry, HGETALL):**
- `vehicle`, `battery:0`, `battery:1`, `aux-battery`, `cb-battery`, `engine-ecu`, `power-manager`, `internet`, `modem`, `gps`, `keycard`, `ble`, `dashboard`, `system`

**Produces queues (LPUSH) — from remote server commands:**
- `scooter:state` → "unlock", "lock", "lock-hibernate", "force-lock"
- `scooter:seatbox` → "open"
- `scooter:horn` → "on", "off"
- `scooter:blinker` → "left", "right", "both", "off"
- `scooter:hardware` → "dashboard:on/off", "engine:on/off", "handlebar:lock/unlock"
- `scooter:power` → "reboot", "hibernate", "hibernate-manual"

---

### ums-service

**Writes:**
| Hash | Fields | Channel |
|------|--------|---------|
| `usb` | `mode` ("normal", "ums", "ums-by-dbc") | `usb` |

**Reads:**
- `usb/mode` (via HashWatcher, to trigger mode changes)

**Hardware access:** USB gadget via configfs, `/data/dbc/`

---

### lsc (CLI tool)

**Reads (HGETALL / HGET):** All state hashes for display

**Produces queues (LPUSH):**
- `scooter:state`, `scooter:seatbox`, `scooter:horn`, `scooter:blinker`, `scooter:hardware`, `scooter:power`, `scooter:alarm`, `scooter:led:cue`, `scooter:led:fade`, `settings:overlay` (`apply:service`, `clear:service` via `lsc service-mode on|off`)

---

## Complete Redis Key Inventory

### Hash Keys

| Key | Owner (Writer) | Primary Readers |
|-----|---------------|-----------------|
| `vehicle` | vehicle-service | battery-service, ecu-service, pm-service, bluetooth-service, modem-service, alarm-service, update-service, uplink-service, scootui, lsc |
| `battery:0` | battery-service | ecu-service, pm-service, bluetooth-service, uplink-service, scootui |
| `battery:1` | battery-service | ecu-service, bluetooth-service, uplink-service, scootui |
| `engine-ecu` | ecu-service (data), bluetooth-service (odometer) | bluetooth-service, uplink-service, scootui |
| `keycard` | keycard-service (10s TTL) | vehicle-service |
| `ble` | bluetooth-service | scootui, uplink-service |
| `dashboard` | scootui (ready/serial-number), dbc-backlight (backlight/brightness), dbc-illumination (illumination) | vehicle-service (ready), dbc-backlight (brightness) |
| `power-manager` | pm-service | bluetooth-service, scootui, uplink-service |
| `power-manager:busy-services` | pm-service | monitoring only |
| `system` | vehicle-service (cpu:governor), bluetooth-service (mdb-version, nrf-fw-version), pm-service (cpu:governor) | bluetooth-service, uplink-service, scootui |
| `ota` | update-service | vehicle-service (reads status), update-service (self), scootui |
| `internet` | modem-service | scootui, uplink-service |
| `modem` | modem-service | scootui, uplink-service |
| `gps` | modem-service | scootui, uplink-service |
| `alarm` | alarm-service | lsc, monitoring |
| `settings` | settings-service (from TOML), update-service (last-check-time) | vehicle-service, battery-service, ecu-service, alarm-service, pm-service |
| `os-release` | version-service (one-shot) | Nothing (dead key — see gaps) |
| `usb` | ums-service | ums-service (self), scootui |
| `motion` | motion-service | alarm-service (wake-cause), scootui (heading), monitoring |

### Set Keys

| Key | Owner | Readers |
|-----|-------|---------|
| `vehicle:fault` | vehicle-service | scootui, uplink-service |
| `battery:0:fault` | battery-service | scootui |
| `battery:1:fault` | battery-service | scootui |
| `internet:fault` | modem-service | scootui |
| `ble:fault` | bluetooth-service | scootui |

### Stream Keys

| Key | Writers | Readers |
|-----|---------|---------|
| `events:faults` | vehicle-service, modem-service | uplink-service (via HGetAll — see gaps) |

### List Keys (Command Queues)

| Key | Consumer | Producers |
|-----|---------|---------|
| `scooter:state` | vehicle-service | lsc, scootui, uplink-service |
| `scooter:seatbox` | vehicle-service | lsc, scootui, uplink-service |
| `scooter:horn` | vehicle-service | lsc, scootui, uplink-service, alarm-service |
| `scooter:blinker` | vehicle-service | lsc, scootui, uplink-service, alarm-service |
| `scooter:led:cue` | vehicle-service | lsc |
| `scooter:led:fade` | vehicle-service | lsc |
| `scooter:update` | vehicle-service | update-service |
| `scooter:update:<component>` | update-service | update-service (self check-now) |
| `scooter:hardware` | vehicle-service | lsc, scootui, uplink-service |
| `scooter:power` | pm-service | lsc, update-service, uplink-service |
| `scooter:governor` | pm-service | vehicle-service (sends cpu governor changes) |
| `scooter:modem` | modem-service | pm-service |
| `scooter:bluetooth` | bluetooth-service | external/lsc |
| `scooter:alarm` | alarm-service | lsc |
| `settings:overlay` | settings-service | lsc |
| `power:inhibits` | pm-service inhibitor manager | update-service, vehicle-service, modem-service (hold pm inhibitors) |

---

## Identified Gaps and Issues

### GAP-1: ecu-service publishes to wrong channel names (Critical Bug)

**File:** `/home/teal/src/librescoot/ecu-service/ipc_tx.go`

The ecu-service publishes notifications using channel names with **spaces** embedded:
```go
tx.redis.Publish(tx.ctx, "engine-ecu throttle", nil)  // line 53
tx.redis.Publish(tx.ctx, "engine-ecu odometer", nil)  // line 94
tx.redis.Publish(tx.ctx, "engine-ecu kers", nil)      // line 116
tx.redis.Publish(tx.ctx, "engine-ecu kers-reason-off", nil) // line 165
```

The correct pattern (used everywhere else) is: publish to `"engine-ecu"` with payload being the field name (e.g., `"throttle"`, `"odometer"`, `"kers"`). Instead, ecu-service publishes to channels named `"engine-ecu throttle"` etc., which no subscriber listens to.

Additionally, the message payload is `nil`. Other services send the field name as the payload.

**Impact:** bluetooth-service subscribes to `"engine-ecu"` watching for `"odometer"` field updates. It won't receive notifications from ecu-service's own data. Bluetooth-service works around this by writing odometer itself (from nRF UART). But any future subscriber watching `"engine-ecu"` for throttle, kers, or speed data changes will never receive notifications.

**Severity:** High — all throttle/kers/speed pub/sub notifications from ecu-service are silently dropped.

### GAP-2: settings-service does not PUBLISH when loading settings at boot (High Bug)

**File:** `/home/teal/src/librescoot/settings-service/internal/redis/client.go`

`ReplaceSettings()` and `SetSettings()` use DEL + HSET in a pipeline but never call PUBLISH. Services that subscribe to `settings` for startup configuration (vehicle-service, battery-service, ecu-service, alarm-service, pm-service) won't receive notifications when settings-service loads the TOML on boot.

The services handle this by reading settings on startup directly (HGET), so they don't miss the initial values. However, if settings-service starts **after** these services (due to race or restart), the services will miss any new settings values because there's no PUBLISH to trigger a re-read.

**Severity:** High — services may silently use stale or default settings if settings-service restarts after them.

### GAP-3: version-service writes to `os-release` but no service reads it (Normal)

**File:** `/home/teal/src/librescoot/version-service/cmd/version-service/main.go`

version-service writes OS release data to the `os-release` Redis hash. The hash name is configurable (`--hash` flag, default `"os-release"`). No other service in the codebase reads `HGET os-release` or subscribes to an `os-release` channel.

The `bluetooth-service` looks for `"system"` hash with field `"mdb-version"` (written by nRF via UART). The `uplink-service` telemetry reads `"system"` but not `"os-release"`. `lsc` does not appear to read it either.

**Impact:** The version information is lost. Intended consumer not implemented.

**Severity:** Normal — the data is written but never consumed; functionality gap.

### GAP-4: `version:<component>` hash written by nobody, read by update-service (Normal)

**File:** `/home/teal/src/librescoot/update-service/internal/redis/client.go` lines 113–130

update-service reads `version:<component>/version_id` and `version/<component>/variant_id` to check if an update is needed. Nothing in the analyzed codebase writes these hashes. The hash appears intended to be populated by the Mender boot updater or an init script, not a running service.

If the `version:*` hashes are absent (new device, or after factory reset), update-service falls back gracefully (returns empty string, treats it as "no version installed" → always updates). This is documented behavior but creates unnecessary update cycles.

**Severity:** Normal — by-design but undocumented dependency on external init scripts.

### GAP-5: `events:faults` stream is written correctly but consumed incorrectly (Normal)

**File:** `/home/teal/src/librescoot/uplink-service/internal/telemetry/collector.go`

The `events:faults` key is a Redis **Stream** (written via XADD by vehicle-service and modem-service). The uplink-service telemetry collector does `HGetAll("events:faults")` which is a **hash** operation against a stream key. This will always return empty and silently fail — HGETALL on a stream returns nothing.

**Impact:** Fault event history is never included in telemetry snapshots sent to the uplink server.

**Severity:** Normal — telemetry data is incomplete, faults not forwarded to fleet management.

### GAP-6: battery-service subscribes to `vehicle` channel but misses `seatbox:opened` event (Normal)

**File:** `/home/teal/src/librescoot/battery-service/battery/service.go` lines 145–148

battery-service handles `msg.Payload == "seatbox:lock"` (the field update) but not `"seatbox:opened"` (the event from `vehicle-service/PublishSeatboxOpened`). The alarm-service correctly handles the `"seatbox:opened"` event via its `OnEvent()` handler. Battery-service uses `seatbox:lock` field changes instead.

This is mostly fine in practice since `seatbox:lock` changes from "closed" to "open" on the same operation. But the battery-service will see the lock change **after** the opened event, potentially creating a small timing window.

**Severity:** Low — functional but subtly different timing from intended protocol.

### GAP-7: pm-service reads `battery:0` only — ignores battery:1 state (Normal)

**File:** `/home/teal/src/librescoot/pm-service/internal/service/service.go` line 134

pm-service only subscribes to `battery:0` state changes. For dual-battery configurations, if battery:0 becomes inactive but battery:1 is still active, pm-service will believe "battery is inactive" and may allow suspend. This is a potential data integrity risk in dual-battery setups.

**Severity:** Normal — relevant only for dual-battery mode, but could cause data loss on incorrect suspend.

### GAP-8: Startup race — vehicle-service subscribes after reading initial dashboard state (Low)

**File:** `/home/teal/src/librescoot/vehicle-service/internal/messaging/redis.go` lines 102–115

vehicle-service reads `dashboard/ready` in `Connect()` and then starts the `dashboardWatcher` later in `StartListening()`. There is a window between the initial read and the subscription where `dashboard/ready` could change (scootui publishes) without vehicle-service noticing.

This is not critical because scootui publishes `ready=true` only once at startup, and vehicle-service's `Connect()` runs very early. But if scootui restarts after vehicle-service has already initialized, vehicle-service subscribes correctly via `dashboardWatcher` and will catch the new publication.

**Severity:** Low — timing window is small and consequences are benign (vehicle would need a keycard auth to advance state anyway).

### GAP-9: ecu-service uses go-redis v8, all others use v9 (Low)

**File:** `/home/teal/src/librescoot/ecu-service/ipc_rx.go`, `ipc_tx.go`

```go
import "github.com/go-redis/redis/v8"
```

All other services use `github.com/redis/go-redis/v9` (the renamed, actively maintained version). v8 uses a different import path and context handling. This creates a maintenance burden and prevents ecu-service from using the shared redis-ipc library.

**Severity:** Low — functional but creates maintenance debt.

### GAP-10: `system` hash has two conflicting writers for `cpu:governor` (Low)

Both `vehicle-service` (`redis.go:576`) and `pm-service` (`service.go:812`) write to `system/cpu:governor`. If they write different values concurrently, or if one doesn't know about the other's write, the hash value could be misleading. Currently pm-service handles the actual sysfs write and publishes to the hash; vehicle-service also writes to the hash when it sends the governor command to pm-service via `scooter:governor`. This double-write is redundant at best.

**Severity:** Low — the value in Redis may be briefly inconsistent between the command send and the pm-service processing it.

### GAP-11: keycard hash has 10s TTL — no consumer handles key expiry (Low)

**File:** `/home/teal/src/librescoot/keycard-service/keycard/redis.go` line 51

keycard-service sets a 10-second TTL on the `keycard` hash. vehicle-service subscribes to `keycard/authentication` changes. When the key expires, there is no TTL expiry notification in the pub/sub protocol used (keyspace notifications are not enabled by default in Redis). If vehicle-service somehow reads `keycard/authentication` after expiry, it would get a redis.Nil error, which it handles gracefully. But a consumer polling this value could be confused.

**Severity:** Low — edge case, current usage (event-driven) is safe.

---

## Summary of Critical Issues

| # | Severity | Service | Issue |
|---|----------|---------|-------|
| 1 | High | ecu-service | Publishes to broken channel names with spaces — all throttle/kers/speed notifications silently dropped |
| 2 | High | settings-service | No PUBLISH when loading settings from TOML — services miss initial settings on settings-service restart |
| 3 | Normal | version-service | `os-release` hash written but never read — intended consumer not implemented |
| 4 | Normal | update-service | Reads `version:<component>` hash that nothing writes — depends on undocumented external init |
| 5 | Normal | uplink-service | Uses HGETALL on `events:faults` stream — always returns empty, fault history never telemetrized |
| 6 | Normal | pm-service | Only tracks `battery:0` state — dual-battery suspend guard incomplete |
| 7 | Low | vehicle-service | Tiny startup race between initial dashboard state read and subscription |
| 8 | Low | ecu-service | Uses go-redis v8 while all others use v9 — maintenance burden |
| 9 | Low | vehicle+pm | Double-write to `system/cpu:governor` — minor inconsistency window |
| 10 | Low | keycard-service | 10s TTL with no keyspace notification support for expiry |
