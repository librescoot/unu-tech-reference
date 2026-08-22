# Redis Interface Documentation

## Connection Details

The scooter runs the datastore on the MDB accessible at:
- Host: 192.168.7.1  
- Port: 6379

Local connection command:
```bash
redis-cli -h 192.168.7.1 -p 6379
```

### Redis or Valkey - Librescoot Only

Librescoot 1.2 replaced Redis with Valkey 9 (wrynose's meta-oe ships it; the
tuned config was ported over directly). It speaks the same protocol on the same
port and `redis-cli` remains as a compat symlink, so everything documented here
applies unchanged, as do the `--redis-*` flags across the services.

What did change is the systemd unit name: service units now order against
`valkey.service`, not `redis.service`. Anything that hardcodes the old unit name
will not find it on 1.2 or later.

Stock ScooterOS and Librescoot 1.1 and earlier still run Redis.

## Key Structure

The Redis database uses hash sets for system state storage. All fields default to empty strings ("") when data is unavailable unless otherwise noted.

For potential values, also see the [Bluetooth reference](../bluetooth/README.md).

### Vehicle State (`vehicle`)
```
hgetall vehicle
```

| Field | Type | Description | Example |
|-------|---------|------------|---------|
| handlebar:position | "on-place"/"off-place" | Handlebar position | "on-place" |
| handlebar:lock-sensor | "locked"/"unlocked" | Handlebar lock state | "unlocked" |
| main-power | "on"/"off" | Main power state | "off" |
| kickstand | "up"/"down" | Side stand position | "down" |
| seatbox:button | "on"/"off" | Seat open button state (stock only; Librescoot 1.2.0's vehicle-service does not write this field, so dashboard reads come back empty) | "off" |
| seatbox:lock | "open"/"closed" | Seat lock state | "closed" |
| horn:button | "on"/"off" | Horn button state (stock only; Librescoot 1.2.0's vehicle-service does not write this field) | "off" |
| brake:left | "on"/"off" | Left brake state | "off" |
| brake:right | "on"/"off" | Right brake state | "off" |
| blinker:switch | "left"/"right"/"both"/"off" | Blinker switch position | "off" |
| blinker:state | "on"/"off" | Blinker active state | "off" |
| state | "stand-by"/"parked"/"hop-on"/"hop-on-learning"/"ready-to-drive"/"waiting-seatbox"/"shutting-down"/"updating"/"waiting-hibernation"/"waiting-hibernation-advanced"/"waiting-hibernation-seatbox"/"waiting-hibernation-confirm" | Vehicle operating state | "stand-by" |
| auto-standby-deadline | integer (Unix timestamp) | When auto-standby will trigger (only present when timer active) | "1734567890" |

### Engine ECU (`engine-ecu`)
```
hgetall engine-ecu
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| kers-reason-off | string | Reason KERS is disabled | "none" |
| kers | "on"/"off" | KERS active state | "on" |
| boost | "on"/"off" | Boost mode state | "off" |
| kers-accepted-voltage | integer (mV) | EBS regen voltage cap the ECU accepted, echoed after clamping (Bosch) | "0" |
| kers-accepted-current | integer (mA) | EBS regen current limit the ECU accepted (Bosch) | "0" |
| regen-available | "on"/"off" | Derived: can regen happen right now | "on" |
| regen-reason | string | Derived: none/cold/hot/off/full | "none" |
| regen-expected | integer (mA) | Derived: expected regen current envelope (0 on non-Bosch) | "0" |
| motor:voltage | integer (mV) | Motor voltage | "52140" |
| motor:current | integer (mA) | Motor current (signed; negative during regen) | "0" |
| power | integer (mW) | Instantaneous power | "0" |
| energy:consumed | integer (mWh) | Cumulative energy consumed | "0" |
| energy:recovered | integer (mWh) | Cumulative energy recovered via regen | "0" |
| rpm | integer | Motor RPM | "0" |
| speed | integer (km/h) | Vehicle speed (calibrated) | "0" |
| raw-speed | integer (km/h) | Raw speed before calibration | "0" |
| throttle | "on"/"off" | Throttle state | "off" |
| brake | "on"/"off" | Brake state | "off" |
| gear | integer | Current gear (Bosch 1-3, 0 if unknown; Votol reports 0) | "1" |
| fw-version | hex string | ECU firmware version | "0445400C" |
| odometer | integer (m) | Total distance | "632900" |
| temperature | integer (°C) | ECU temperature | "16" |
| fault:code | integer (32-bit) | Current fault code (0 when no fault) | "0" |
| fault:description | string | Active fault description (empty when no fault) | "" |

### Battery Management (`battery:0` and `battery:1`)
```
hgetall battery:0
hgetall battery:1
```

Note: When battery is not present (`"present": "false"`), all fields will show default values as shown in examples.

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| present | "true"/"false" | Battery presence | "false" |
| state | string | Battery state | "unknown" |
| voltage | integer (mV) | Battery voltage | "0" |
| current | integer (mA) | Battery current | "0" |
| charge | integer (%) | Battery charge level | "0" |
| temperature:0-3 | integer (°C) | Battery temperature sensors | "0" |
| temperature-state | string | Temperature status | "unknown" |
| cycle-count | integer | Battery cycle count | "0" |
| state-of-health | integer (%) | Battery health | "0" |
| serial-number | string | Battery serial number | "" |
| manufacturing-date | string | Manufacturing date | "" |
| fw-version | string | Firmware version | "" |

### Auxiliary Battery (`aux-battery`)
```
hgetall aux-battery
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| data-stream-enable | "0"/"1" | Enable data streaming | "0" |
| voltage | integer (mV) | Battery voltage | "11919" |
| charge | integer (%) | Battery charge level | "25" |
| charge-status | string | Charging status | "not-charging" |

### Connectivity Battery Box (`cb-battery`)
```
hgetall cb-battery
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| charge | integer (%) | Battery charge level | "72" |
| current | integer (μA) | Current draw | "-51041" |
| remaining-capacity | integer (μWh) | Remaining capacity | "16830000" |
| temperature | integer (°C) | Battery temperature | "21" |
| cycle-count | integer | Battery cycle count | "5" |
| time-to-empty | integer (sec) | Time until empty | "368634" |
| time-to-full | integer (sec) | Time until full | "368634" |
| cell-voltage | integer (μV) | Cell voltage | "4016328" |
| full-capacity | integer (μWh) | Total capacity | "23270000" |
| state-of-health | integer (%) | Battery health | "94" |
| present | "true"/"false" | Battery presence | "true" |
| charge-status | string | Charging status | "not-charging" |
| part-number | string | Part identification | "MAX17301" |
| serial-number | string | Serial number | "T-CBB 2107245036" |
| unique-id | string | Unique identifier | "420000508ff2c826" |

### System Information (`system`)
```
hgetall system
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| mdb-version | string | MDB firmware version | "v1.15.0+430538" |
| environment | string | System environment | "production" |
| nrf-fw-version | string | NRF firmware version | "v1.12.0" |
| dbc-version | string | Dashboard computer version | "v1.15.0+430553" |
| keycard-master-count | integer | Master keycards enrolled, written by keycard-service | "1" |
| keycard-authorized-count | integer | Authorized keycards enrolled, written by keycard-service | "3" |

### Power Management (`power-manager`)
```
hgetall power-manager
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| state | string | Current power state | "suspending" |
| wakeup-source | string | Source that woke system | "78" |
| nrf-reset-count | integer | nRF reset counter | "2" |
| nrf-reset-reason | hex string | nRF reset reason code | "0x00000001" |
| hibernate-level | string | Hibernation level | "L1"/"L2" |
| wake-timer-seconds | integer | Requested nRF52 wake-timer duration in seconds (`0` = disarm). Written by pm-service before hibernate-for poweroff. | "300" |
| wake-timer-armed | "true"/"false" | nRF52 ACK echo published by bluetooth-service after the wake-timer arm request | "true" |
| power-state-sent | string | nRF52 suspend-ACK published by bluetooth-service. pm-service gates entering suspend on this reaching "suspending". | "suspending" |

### Power Manager Busy Services (`power-manager:busy-services`)
```
hgetall power-manager:busy-services
```

Stores systemd inhibitors preventing suspend. Cleared and repopulated on updates.

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| <who> <why> <what> | string | Service inhibitor | "block" or "delay" |

Published to `power-manager:busy-services` channel with value "updated" when changed.

### Power Multiplexing (`power-mux`)
```
hgetall power-mux
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| selected-input | "cb"/"aux" | Selected power input source | "cb" |

### Internet Connectivity (`internet`)
```
hgetall internet
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| modem-state | string | Modem power state | "off" |
| connectivity | string | Debounced connectivity classification (see below) | "connected" |
| status | string | Connection status | "disconnected" |
| unu-cloud | string | Cloud connection status; written by whichever cloud client runs (`radio-gaga` or `uplink-service`). Field absent = no cloud client configured (de-clouded); the dashboard hides the cloud icon in that case | "disconnected" |
| ip-address | string | IP address | "1.2.3.4" |
| access-tech | string | Access technology | "LTE" |
| signal-quality | integer | Signal strength (0-100) | "0" |
| sim-imei | string | SIM IMEI | "" |
| sim-iccid | string | SIM ICCID | "" |

### Dashboard Interface (`dashboard`)
```
hgetall dashboard
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| ready | "true"/"false" | Dashboard ready state | "false" |
| mode | string | Current display mode | "speedometer" |
| serial-number | string | Dashboard serial number | "379999993" |

See [Dashboard](../dashboard/README.md).

### Bluetooth Interface (`ble`)
```
hgetall ble
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| mac-address | string | Bluetooth MAC address (lowercase with colons) | "ce:df:f6:c0:ff:ee" |
| status | string | Connection status | "disconnected" |
| pin-code | string | Pairing PIN code (temporary, removed after pairing) | "123456" |

#### Bluetooth Commands

The Bluetooth service accepts commands via the `scooter:bluetooth` Redis list. Commands are sent as strings:

```bash
# Send a command to the Bluetooth service
redis-cli -h 192.168.7.1 LPUSH scooter:bluetooth "command-name"
```

Available commands:
- `advertising-start-with-whitelisting` - Start BLE advertising with whitelist filtering (only paired devices can connect)
- `advertising-restart-no-whitelisting` - Restart advertising without whitelist restrictions (any device can connect)
- `advertising-stop` - Stop BLE advertising completely
- `delete-bond` - Remove a single paired/bonded device
- `delete-all-bonds` - Remove all paired/bonded devices from the system
- `remove` - Remove the currently connected device
- `ltc-enable` / `ltc-disable` - Enable/disable the LTC4020 aux charger
- `ltc-force-enable` / `ltc-force-disable` - Force the LTC4020 aux charger on/off (bypass safety gating)
- `ltc-status` - Query the LTC4020 aux charger state
- `data-stream-sync` - Re-push the current data-stream state to the nRF52
- `firmware-update` - Trigger an nRF52 firmware update from `/usr/share/nrf-fw/`

#### Bluetooth Event Subscriptions

The Bluetooth service subscribes to several Redis channels and automatically updates the nRF52 module when values change:

**Vehicle State Updates:**
- `vehicle:state` - Vehicle operating state changes
- `vehicle:seatbox:lock` - Seatbox lock status changes
- `vehicle:handlebar:lock-sensor` - Handlebar lock status changes

**Battery Status Updates:**
- `battery:0:state` - Main battery 0 state changes
- `battery:0:present` - Main battery 0 presence detection
- `battery:0:charge` - Main battery 0 charge level
- `battery:1:state` - Main battery 1 state changes
- `battery:1:present` - Main battery 1 presence detection
- `battery:1:charge` - Main battery 1 charge level

**Power Management Updates:**
- `power-manager:state` - Power state changes trigger automatic data stream management

#### Bluetooth-Triggered Redis Requests

The Bluetooth service can write requests to Redis when receiving commands via BLE:

**Scooter Control:**
- `scooter:state` → `unlock` / `lock` / `lock-hibernate`
- `scooter:seatbox` → `open`
- `scooter:blinker` → `right` / `left` / `both` / `off`

**Power Management:**
- `scooter:power` → `hibernate` / `hibernate-manual`

### Keycard Authentication (`keycard`)
```
hgetall keycard
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| authentication | "passed"/"failed" | Authentication result | "passed" |
| type | string | Card type | "scooter"/"factory"/"activation" |
| uid | string | Card UID (hex) | "04a1b2c3" |

**Note**: This hash expires after 10 seconds. Authentication is published on the `keycard` channel (the field name `authentication` is sent as the message payload), not on a separate `keycard:authentication` channel.

Keycard management commands go through the `scooter:keycard` list:

```bash
redis-cli -h 192.168.7.1 LPUSH scooter:keycard learn:start
```

**Available commands**: `list`, `count`, `add:<uid>`, `remove:<uid>`, `set-master:<uid>` (`NONE` to disable), `learn:start`, `learn:stop`, `learn:master:start`, `learn:master:stop`, `reset`

Command results land in the `keycard` hash field `command-result`. During teach-in flows, per-tap progress events (`card-learned:<uid>`, `master-learned:<uid>`, `mode-entered:master`, ...) are published on the `keycard:events` channel. See [keycard-service documentation](../services/librescoot-keycard.md).

### Navigation (`navigation`)
```
hgetall navigation
```

Destination for the dashboard's navigation mode. Written by bluetooth-service (BLE nav commands) and `lsc nav`; consumed by scootui-qt.

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| destination | "lat,lon" | Destination coordinates (6 decimal places) | "52.520008,13.404954" |
| latitude | string | Destination latitude | "52.520008" |
| longitude | string | Destination longitude | "13.404954" |
| address | string | Human-readable destination name (optional) | "Alexanderplatz" |
| timestamp | string | Last destination update | "2026-06-11T12:00:00Z" |

Clearing navigation sets all fields to empty strings rather than deleting them, so hash watchers get notified.

### GPS Data (`gps`)
```
hgetall gps
```

Published by modem-service from gpsd data.

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| latitude | string | Current latitude (6 decimal places) | "52.520008" |
| longitude | string | Current longitude (6 decimal places) | "13.404954" |
| altitude | string | Current altitude in meters (6 decimal places) | "34.500000" |
| speed | string | Speed in km/h (6 decimal places) | "0.000000" |
| course | string | Course over ground in degrees (6 decimal places) | "0.000000" |
| timestamp | string | GPS timestamp (RFC3339) | "2026-06-11T12:00:00Z" |
| updated | string | When the hash was last refreshed (RFC3339) | "2026-06-11T12:00:00Z" |
| state | string | GPS state ("off"/"searching"/"fix-established"/"error") | "fix-established" |
| mode | string | GNSS positioning mode (currently always "standalone") | "standalone" |
| fix | string | Fix mode ("none"/"2d"/"3d") | "3d" |
| snr | float | Mean signal-to-noise ratio (dBHz) | "32.4" |
| hdop / vdop / pdop | float | Horizontal / vertical / position dilution of precision | "1.2" |
| eph / eps / ept | float | Estimated position (m) / speed (m/s) / time (s) error | "8.5" |
| satellites-used | integer | Satellites used in the fix | "9" |
| satellites-visible | integer | Satellites in view | "14" |
| active | "true"/"false" | GPS has a valid fix | "true" |
| connected | "true"/"false" | Connected to gpsd | "true" |

The hash is updated silently; a pub/sub notification on `timestamp` is published only when GPS recovers after an outage. For a continuous stream, subscribe to the **`gps:tpv`** channel, which carries the full snapshot (same fields, JSON) for every fix.

GPS has no commands; modem-service manages it automatically (see `scooter:modem` below). The legacy `gps:raw` and `gps:filtered` hashes no longer exist.

### Over-the-Air Updates (`ota`)
```
hgetall ota
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| system | string | Update system type | "foundries" |
| migration | string | Migration status | "successful" |
| status | string | Update status | "initializing" |
| fresh-update | "true"/"false" | Fresh update flag | "false" |

### Settings (`settings`)
```
hgetall settings
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| customer:type | string | Customer type | "D2C" |
| cloud:mqtt-ca | string | MQTT CA certificate path | "/etc/keys/unu-mqtt-production.pub" |
| cloud:url | string | Cloud URL | "cloud-iot-v1.unumotors.com" |
| cloud:key | string | Cloud key path | "/etc/keys/unu-cloud-production.pub" |
| cloud:mqtt-url | string | MQTT server URL | "zeus-iot-v3.unumotors.com:8883" |

#### Librescoot Additional Settings

Librescoot adds persistent settings managed by the settings-service:

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| alarm.enabled | "true"/"false" | Alarm system enabled | "true" |
| alarm.honk | "true"/"false" | Horn enabled during alarm | "false" |
| alarm.duration | integer (sec) | Alarm duration in seconds | "30" |
| alarm.seatbox-trigger | "true"/"false" | Trigger alarm on unauthorized seatbox opening | "true" |
| alarm.trigger.motion | "true"/"false" | Declared in the settings schema (default true) but not yet honoured by alarm-service in this release | "true" |
| alarm.trigger.buttons | "true"/"false" | Declared in the settings schema (default true) but not yet honoured by alarm-service in this release | "true" |
| alarm.trigger.handlebar | "true"/"false" | Declared in the settings schema (default true) but not yet honoured by alarm-service in this release | "true" |
| alarm.hairtrigger | "true"/"false" | Hair trigger mode (immediate short alarm on first motion) | "false" |
| alarm.hairtrigger-duration | integer (sec) | Hair trigger alarm duration in seconds | "3" |
| alarm.l1-cooldown | integer (sec) | Level 1 cooldown duration in seconds | "15" |
| battery.ignore-seatbox | "true"/"false" | Ignore seatbox state for battery management | "false" |
| cellular.apn | string | Cellular APN | "internet.provider.com" |
| hibernation-timer | integer (sec) | Hibernation timeout (0=disabled) | "259200" |
| pm.hibernation-timer | integer (sec) | New name for hibernation-timer (idle-driven auto-hibernate; 0=disabled) | "259200" |
| pm.default-state | string | Default target power state when idle (run / suspend) | "suspend" |
| pm.suspend-when-online | "true"/"false" | With no main battery present, allow suspend even while online (default true; set false to keep an online scooter awake). A present/active main battery always blocks suspend regardless | "false" |
| pm.scheduled-hibernate-enabled | "true"/"false" | Enable cron-driven scheduled hibernation | "true" |
| pm.scheduled-hibernate-cron | string | 5-field cron expression for scheduled hibernation | "0 22 * * *" |
| pm.scheduled-hibernate-duration | duration | Wake-by duration applied at each cron fire | "8h" |
| pm.wake-timer-max-seconds | integer (sec) | Safety cap on a single hibernate-for / scheduled wake-timer arm | "604800" |
| pm.wake-timer-ack-timeout | duration | How long pm-service waits for the nRF52 wake-timer ACK before aborting hibernation | "10s" |
| scooter.auto-standby-seconds | integer (sec) | Auto-lock timeout when parked (0=disabled) | "0" |
| scooter.lock-on-bluetooth-disconnect-seconds | integer (sec) | Lock (enter stand-by) this many seconds after the connected phone's Bluetooth disconnects while parked (0=disabled; floored at 5 when set) | "0" |
| scooter.brake-hibernation | "enabled"/"disabled" | Enable brake lever hibernation | "enabled" |
| updates.mdb.channel | string | MDB update channel | "nightly" |
| updates.mdb.check-interval | duration | MDB update check interval ("never" to disable) | "6h" |
| updates.mdb.dry-run | "true"/"false" | MDB update dry-run mode | "false" |
| updates.mdb.method | string | MDB update method | "full" or "delta" |
| updates.mdb.github-releases-url | string | GitHub Releases API endpoint for MDB | "https://api.github.com/repos/librescoot/librescoot/releases" |
| updates.mdb.last-check-time | string (ISO8601) | Last MDB update check timestamp | "2025-01-15T10:30:00Z" |
| updates.dbc.channel | string | DBC update channel | "stable" |
| updates.dbc.check-interval | duration | DBC update check interval ("never" to disable) | "6h" |
| updates.dbc.dry-run | "true"/"false" | DBC update dry-run mode | "false" |
| updates.dbc.method | string | DBC update method | "full" or "delta" |
| updates.dbc.github-releases-url | string | GitHub Releases API endpoint for DBC | "https://api.github.com/repos/librescoot/librescoot/releases" |
| updates.dbc.last-check-time | string (ISO8601) | Last DBC update check timestamp | "2025-01-15T10:30:00Z" |
| dashboard.show-raw-speed | "true"/"false" | Show raw uncorrected speed from ECU | "false" |
| dashboard.show-clock | string | Clock visibility (always/never) | "always" |
| dashboard.show-gps | string | GPS indicator visibility (always/active-or-error/error/never) | "error" |
| dashboard.show-bluetooth | string | Bluetooth indicator visibility | "active-or-error" |
| dashboard.show-cloud | string | Cloud indicator visibility (hidden unless `internet[unu-cloud]` is present) | "active-or-error" |
| dashboard.show-internet | string | Internet indicator visibility (gated on `internet[connectivity]`) | "active-or-error" |
| dashboard.battery-display-mode | string | Battery display mode (percentage/range) | "percentage" |
| dashboard.map.type | string | Map tile source (online/offline) | "offline" |
| dashboard.map.render-mode | string | Map rendering mode (vector/raster) | "raster" |
| dashboard.theme | string | UI theme (light/dark/auto) | "dark" |
| dashboard.mode | string | Default screen mode (speedometer/navigation) | "speedometer" |
| dashboard.valhalla-url | string | Valhalla routing service endpoint | "http://localhost:8002/" |

The full settings schema (types, defaults, ranges, labels) is served as a JSON document in the `settings:schema` key by settings-service:

```bash
redis-cli -h 192.168.7.1 GET settings:schema
```

See [settings-service documentation](../services/librescoot-settings.md) for details on persistent settings.

#### Settings Overlay Commands (`settings:overlay`) - Librescoot Only

Apply or clear a named settings overlay. Overlays override live `settings` values in memory without ever writing them to `/data/settings.toml`; clearing restores the user's base values.

```bash
# Enable Service mode
redis-cli -h 192.168.7.1 LPUSH settings:overlay apply:service

# Disable Service mode
redis-cli -h 192.168.7.1 LPUSH settings:overlay clear:service
```

**Available commands**: `apply:service`, `clear:service`

**Service mode overrides** (applied in memory only, not persisted):

| Setting | Overlay value |
|---------|---------------|
| `scooter.auto-standby-seconds` | `0` |
| `pm.hibernation-timer` | `0` |
| `pm.default-state` | `run` |
| `alarm.enabled` | `false` |
| `scooter.usb0-policy` | `always-on` |
| `dashboard.mode` | `debug` |
| `scooter.handlebar-unlocked` | `true` |

Service mode persists across reboots until cleared. The base values in `/data/settings.toml` are never modified.

**Status field:** `settings` hash field `dashboard.service-mode-active` = `"true"`/`"false"` (read-only; written by settings-service).

**New setting `scooter.handlebar-unlocked`** (bool, transient - only set via overlay): vehicle-service releases the handlebar latch and suppresses auto re-lock while `"true"`.

**CLI:** `lsc service-mode on|off|status` (alias: `lsc servicemode`)

### Alarm System (`alarm`) - Librescoot Only

```
hgetall alarm
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| status | string | Current alarm status | "armed" |

**Possible status values:**
- `disabled` - Alarm system is disabled
- `disarmed` - Alarm enabled but not armed (vehicle not in stand-by)
- `armed` - Alarm is armed and monitoring for motion
- `level-1-triggered` - Level 1 alarm (notification only)
- `level-2-triggered` - Level 2 alarm (horn + hazards)

See [alarm-service documentation](../services/librescoot-alarm.md) for details.

### Motion / IMU (`motion`) - Librescoot Only

```
hgetall motion
```

motion-service owns the BMX055 9-axis IMU and publishes its state here. The legacy `bmx` hash and `scooter:bmx` command list are gone.

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| initialized | "true"/"false" | Sensors are up | "true" |
| streaming | "enabled"/"disabled" | Telemetry streaming state | "enabled" |
| polling-rate-hz | integer | Sensor poll rate | "10" |
| current-profile | string | Chip profile (idle/armed-awake/armed-hibernation/level1/waiting) | "idle" |
| interrupt / pin / mode / bandwidth / threshold / duration | string | Motion-engine config as programmed, written by the profile controller on every apply | "enabled" / "both" / "any-motion" / "0x0A" / "0x06" / "0x03" |
| last-interrupt-timestamp | integer (unix-ms) | Last motion interrupt | "1777996408778" |
| error-count / last-error | string | Diagnostic counters | "0" |
| heading | integer (0-359°) | Magnetic heading | "192" |
| heading-deg / heading-accuracy / heading-tilt / heading-tilt-comp | string | Smoothed heading, 1-σ accuracy, tilt, tilt-compensation flag | "192.50" |

**Pub/sub channels:**
- `motion:sensors` (10 Hz) - JSON sensor reading: `timestamp`, `accel`, `gyro`, optional `mag`, each axis as `{x, y, z, magnitude, unit}`
- `motion:heading` (5 Hz) - JSON heading payload (`heading_deg`, `accuracy_deg`, `tilt_deg`, ...)
- `motion:interrupt` - JSON motion event: `{"type": "edge"|"wake-hibernation", "timestamp": ..., "engine": "any-motion"|"slow-motion"}`
- `motion:ready` - fired once at startup after the first profile-apply; payload is a unix-ms timestamp

**RPC channel `motion:rpc`** (redis-ipc CallServer): methods `prepare-hibernation`, `get-calibration`, `clear-latch`, `soft-reset`.

`soft-reset` resets accel + gyro and then reprograms the current profile. It does not leave the chip at register defaults, since that would mean no motion detection on an armed scooter.

The `motion` hash still carries a `sensitivity` field. motion-service seeds it to `"none"` at startup and rewrites it whenever a `sensitivity:<level>` command arrives on `scooter:motion`. It is advisory: the profile controller reprograms threshold and duration on the next `alarm` or `power-manager` transition regardless of it.

Chip configuration is reactive: motion-service derives the profile from the `alarm` and `power-manager` hashes, consumers never write registers. The `bmx:interrupt` channel survives only as a relay: bluetooth-service publishes `wake-suspend` / `wake-hibernation` there when the nRF52 reports an accelerometer wake event.

See [motion-service documentation](../services/librescoot-motion.md) for profiles, payload schemas, and the hibernation handshake.

### Dashboard Backlight (`dashboard`) - Librescoot Enhancement

Librescoot adds these fields to the dashboard hash:

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| brightness | float (lux) | Ambient light level from the OPT3001 | "42.00" |
| backlight | integer | Current backlight brightness, 0 to 10240 | "9700" |
| backlight-enabled | string | Override; "false" forces the backlight to 0 | "true" |

`dbc-backlight-service` on the DBC owns all three. It reads the OPT3001 through
IIO itself, publishes the reading to `brightness`, maps it through a
lux-to-brightness curve, and writes the level it applied to `backlight`. Each
write is followed by a `PUBLISH dashboard <field>`.

`backlight` is an index into the interpolated step range the `pwm-backlight`
device tree node exposes, not a raw duty cycle. `max_brightness` is 10240.

`backlight-enabled` is a hard override rather than a mode: false writes 0 and
holds, true releases back to whatever the ambient level calls for. vehicle-service
asserts it on entering parked and ready-to-drive, scootui-qt clears it for the
hop-on lock overlay and the OTA and maintenance screens, and `lsc backlight on|off`
drives it by hand. The mode itself lives in settings, as
`dashboard.backlight-mode` (auto, low, medium, high).

scootui-qt reads `brightness` for its automatic light/dark theme when
`dashboard.theme` is `auto`, which is why the field keeps updating even while
the backlight is overridden off or pinned to a fixed level.

### Modem Management (`modem`) - Librescoot Only

```
hgetall modem
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| power-state | string | Modem power state | "on" |
| sim-state | string | SIM card state ("present"/"missing"/"locked"/"inactive") | "present" |
| sim-lock | string | SIM lock status | "disabled" |
| registration | string | Network registration state ("home"/"roaming"/"searching"/"denied"/"idle"/"unknown") | "home" |
| operator-name | string | Network operator name | "T-Mobile" |
| operator-code | string | Network operator code | "26201" |
| is-roaming | "true"/"false" | Roaming status | "false" |
| registration-fail | string | Registration failure reason | "" |
| error-state | string | Consolidated error state ("ok"/"powered-off"/"sim-missing"/"sim-inactive"/"sim-locked"/"registration-denied"/"registration-failed"/"disconnected"/"no-modem"/"status-error") | "ok" |
| pin-action | string | Outcome of the last SIM PIN reconcile ("unconfigured"/"ok"/"unlocked"/"lock-enabled"/"wrong-pin"/"low-retries-bail"/"puk-required"/"error") | "ok" |
| apn-action | string | Outcome of the last APN reconcile ("no-sim"/"unconfigured"/"ok"/"applied"/"iccid-changed-cleared"/"error") | "ok" |

### SMS (`sms` hash, `sms:received` / `sms:sent` streams) - Librescoot Only

Per-message SMS data lives on two Redis streams, each with a dedicated pub/sub
channel of the same name; the `sms` hash only carries latest-value convenience
state. Redis is not persistent on librescoot, so the streams are a live window
(capped at 100 entries), not an archive.

#### `sms` hash

```
hgetall sms
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| state | string | Send state of the last outbound message ("idle"/"sending"/"error"), published as a `state` notification on the `sms` channel | "idle" |
| last-sent-to | string | Recipient number of the last successfully sent SMS | "+4915112345678" |
| last-sent-at | string | RFC 3339 timestamp the last send completed | "2026-07-15T09:30:00+02:00" |
| last-received-from | string | Sender number of the last inbound SMS | "+4915112345678" |
| last-received-text | string | Body of the last inbound SMS | "Hello" |
| last-received-at | string | RFC 3339 timestamp the last inbound SMS arrived | "2026-07-15T09:30:00+02:00" |
| unread-count | string | Inbound messages received since service start | "3" |

The `last-received-*` fields are refreshed silently; the per-message
notification is the dedicated `sms:received` channel below.

#### `sms:received` stream + channel

One stream entry per inbound message, fields `from`, `text`, `timestamp`
(RFC 3339). Each entry is also PUBLISHed on the `sms:received` channel as
JSON including its stream `id`:

```
SUBSCRIBE sms:received        # {"id":"1752...-0","from":"+4930...","text":"Hello","timestamp":"..."}
XREAD STREAMS sms:received 0  # catch-up from the beginning of the window
```

A message is only deleted from modem storage after its XADD succeeds, so a
Redis outage doesn't lose mail (the modem store buffers it and modem-service
retries). Messages that arrived while the service was offline are drained on
startup.

#### `sms:sent` stream + channel

One stream entry per terminal send outcome, fields `request-id` (the caller's
`id` token from the `scooter:sms` payload, empty if none), `to`, `text`,
`outcome` (`sent`/`error`), `error` (empty on success), `timestamp`. Each
entry is also PUBLISHed on the `sms:sent` channel as JSON including its
stream `id`.

### Internet Connectivity (`internet`) - Librescoot Enhancement

Librescoot adds modem health tracking:

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| modem-health | string | Modem recovery state | "normal" |
| sim-imsi | string | SIM IMSI | "262010123456789" |
| reachability | string | Probe verdict: `ok`, `unreachable` (nothing answered but the local stack is healthy, the normal steady state on a restricted APN), `no-path` (local stack broken) | "ok" |
| link-layer | string | Local stack assessment: `ok`, or `<failed-layer>` / `<failed-layer>: <reason>` | "ok" |

**Modem health states:**
- `normal` - Modem operating normally
- `recovering` - Attempting recovery
- `recovery-failed-waiting-reboot` - Recovery failed, waiting for reboot
- `permanent-failure-needs-replacement` - Hardware failure

**Connectivity classification (`connectivity`):**

modem-service folds modem state, SIM state, registration, the enable flag and
health into a single debounced verdict. Consumers (e.g. the dashboard internet
icon) use it to decide whether being offline is worth surfacing:

- `connected` - modem connected, data path up
- `disconnected` - enabled with a SIM present, but searching/registering/no signal (provisioned, currently down)
- `disabled` - modem intentionally powered off by command
- `no-sim` - SIM missing or inactive
- `denied` - registration denied/failed, e.g. a carrier-deactivated SIM (debounced ~60s)
- `failed` - modem broken/absent (health terminal)

Hysteresis: `connected`->`disconnected` waits 3 min (ride out tunnels), `denied`
waits 60 s before committing; `disabled`/`no-sim`/`failed` commit immediately.

### OTA Updates (`ota`) - Librescoot Enhancement

Librescoot adds per-component update tracking:

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| status:mdb | string | MDB update status | "downloading" |
| status:dbc | string | DBC update status | "idle" |
| update-version:mdb | string | MDB target version | "20251009t162327" |
| update-version:dbc | string | DBC target version | "20251008t143210" |
| download-progress:mdb | integer (0-100) | MDB download progress | "45" |
| download-progress:dbc | integer (0-100) | DBC download progress | "0" |
| download-bytes:mdb | integer | MDB bytes downloaded | "47185920" |
| download-bytes:dbc | integer | DBC bytes downloaded | "0" |
| download-total:mdb | integer | MDB total download size | "104857600" |
| download-total:dbc | integer | DBC total download size | "0" |
| error:mdb | string | MDB error type | "" |
| error:dbc | string | DBC error type | "" |
| error-message:mdb | string | MDB error message | "" |
| error-message:dbc | string | DBC error message | "" |
| status | string | Flat status, not namespaced, stock convention | "downloading-updates" |
| update-type | string | Whether the flat status blocks use of the vehicle | "blocking" |

**Update status values:** `idle`, `downloading`, `preparing`, `installing`, `pending-reboot`, `error`

`status` and `update-type` are the non-namespaced pair from the stock convention,
describing the vehicle rather than one board. Both components feed them and the least
advanced one wins, so the pair only clears once neither board is busy. The MDB's
update-service is the sole writer. They carry nothing the namespaced fields lack; read
`status:{component}` instead. See
[services/librescoot-update.md](../services/librescoot-update.md) for the full mapping.
 `download-bytes` and
`download-total` are preserved across such an abort so the partial's progress stays
visible; the next attempt resumes from it.

A heartbeat that has stopped advancing while `status` is `downloading`, `preparing` or
`installing` means the reporter is gone rather than merely quiet. `pending-reboot` is
excluded: a DBC install ends there and the heartbeat legitimately stops until the next
power cycle. An absent heartbeat is not a stale one either, since older images never
wrote the field. See [services/librescoot-update.md](../services/librescoot-update.md)
for the full caveats and for what vehicle-service actually does, which is not an age
test.
 they say what a switch to that channel *would* fetch, and the
update status fields are never touched by a preview. `preview-status` is `checking`,
`ready`, `unavailable` (that channel carries nothing for this board's `variant_id`) or
`error` (bad channel, or the release index could not be reached inside 20 seconds).
`preview-channel` is echoed on every write so a reader can tell the answer it asked for
from a stale one. All four are cleared at service start. Each component answers only for
itself; a reader wanting the cost of a scooter-wide switch asks both and sums the sizes.
The size is always the full artifact, because a channel switch has no delta base to
patch against and so forces a full update regardless of
`updates.{component}.method`.

See [update-service documentation](../services/librescoot-update.md) for details.

### BLE OTA Transfer Status (`ota:ble`) - Librescoot Only

Written by bluetooth-service's OTA receiver while a phone pushes a firmware bundle over BLE (see [BLE OTA Firmware Transfer](../bluetooth/ota-transfer.md)):

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| state | string | Receiver state: `idle`, `receiving`, `installing` | "receiving" |
| bundle-id | string | Bundle ID of the active session | "librescoot-nightly-20260701" |
| component | string | Target board: `mdb`, `dbc` | "mdb" |
| received-bytes | integer | In-order bytes received so far | "3145728" |
| total-bytes | integer | Declared bundle size | "104857600" |
| rate-bps | integer | Rolling transfer rate in bytes/second | "9200" |
| updated-at | integer | Unix timestamp of last update | "1780000000" |

Session fields (all but `state`/`updated-at`) are only present while a session is active.

### Version Information - Librescoot Only

#### MDB Version (`version:mdb`)

```
hgetall version:mdb
```

Contains all fields from `/etc/os-release` with lowercase keys (e.g., `version_id`, `build_id`), plus the board serial:

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| serial_number_real | string | Full i.MX6 OCOTP UID, `CFG1` concatenated with `CFG0`, lowercase hex | "3a1d59d4d1e145d2" |
| serial_number | string | Decimal sum of `CFG0` and `CFG1`. Lossy, since the sum discards which fuse contributed what; prefer `serial_number_real` | "4496203686" |

#### DBC Version (`version:dbc`)

```
hgetall version:dbc
```

Contains all fields from `/etc/os-release` with lowercase keys, plus `serial_number_real` and `serial_number` as above.

version-service populates these hashes on startup, as a oneshot unit per board
(`version-service-mdb.service` passing `-hash version:mdb`,
`version-service-dbc.service` passing `-hash version:dbc`; the MDB unit also
orders itself after `valkey.service`, the DBC unit restarts on failure). The
binary itself has no board-specific logic: the hash name is the only difference.
It reads the serial from `/sys/bus/nvmem/devices/imx-ocotp0/nvmem`
(offsets 4 and 8 for CFG0 and CFG1), falling back to `/sys/fsl_otp/HW_OCOTP_CFG*`
where that exists. A missing serial source is logged and skipped; the OS release
fields are still published.

These are the authoritative board serials. Read them here.

### Physical Inputs (`buttons`, `input-events`)

vehicle-service exposes the handlebar controls on two pub/sub channels. Neither
is a state store: read `vehicle` for the current level of `brake:left`,
`brake:right`, `blinker:switch` and friends.

#### `buttons` channel - raw edges

One message per input edge, payload `<source>:<edge>` or
`<source>:<position>:<edge>`:

```
SUBSCRIBE buttons
horn:on
horn:off
seatbox:on
seatbox:off
brake:left:on
brake:left:off
brake:right:on
brake:right:off
blinker:left:on
blinker:left:off
blinker:right:on
blinker:right:off
```

The payload always reflects the triggering input's own edge, independently of
any combined state. Releasing one side of a hazard pair emits
`blinker:right:off` even though the combined `blinker:switch` moves to `left`
rather than `off`. Consumers that want the combined switch position read
`vehicle[blinker:switch]`.

Nothing on this channel carries a timestamp or duration. For press duration
semantics use `input-events`; for the current level of an input read the
`vehicle` hash (`brake:left`, `brake:right`, `blinker:switch`). `horn:button`
and `seatbox:button` are not written in this release.

There is no `buttons` hash. Between Librescoot 1.x (2025-12) and this release a
`buttons` hash existed with fields `horn:on` / `horn:off` / `seatbox:on` /
`seatbox:off` set to the literal `"1"` and never cleared; it had no readers and
was removed. Over the same period `vehicle[horn:button]` and
`vehicle[seatbox:button]` were not written and read back empty. Both are fixed:
the level fields are in the `vehicle` hash again, and each edge is published on
`buttons` exactly once.

#### `input-events` channel - synthesized gestures

vehicle-service runs a gesture detector over the same inputs and publishes
higher-level events, payload `<source>:<gesture>`:

```
SUBSCRIBE input-events
horn:press
horn:release
horn:tap
brake:left:long-tap
brake:right:hold
seatbox:double-tap
```

| Source | Meaning |
|--------|---------|
| `horn` | Horn button |
| `seatbox` | Seatbox button |
| `brake:left` | Left brake lever |
| `brake:right` | Right brake lever |

| Gesture | Fires when |
|---------|-----------|
| `press` | Input goes active |
| `release` | Input goes inactive |
| `long-tap` | Still held after 800 ms |
| `hold` | Still held after 3 s |
| `tap` | Released before the long-tap threshold |
| `double-tap` | Second `tap` within 800 ms of the previous one |

`press` and `release` fire on every edge. `long-tap` and `hold` fire while the
input is still down, so a 4-second press emits `press`, `long-tap`, `hold`,
`release` in that order and no `tap`. A long-tap or hold clears the pending tap,
so a long press between two taps does not glue them into a `double-tap`.

Unlike `buttons`, each gesture is emitted exactly once, which makes this the
channel to use for anything that counts or reacts to discrete user actions.

### Event Streams

#### Fault Events (`events:faults`)

Stream of system fault events using XADD:

```
XREAD STREAMS events:faults 0
```

Each entry contains:
- `group` - Component group (e.g., "cb-battery", "modem")
- `code` - Fault code
- `description` - Human-readable fault description

## Command Channels

The scooter accepts control commands via Redis list-based channels using `LPUSH`. Commands are queued and processed by the vehicle service.

### Scooter State Control (`scooter:state`)

Controls the lock/unlock state of the scooter.

```bash
# Lock the scooter
redis-cli -h 192.168.7.1 LPUSH scooter:state lock

# Unlock the scooter
redis-cli -h 192.168.7.1 LPUSH scooter:state unlock

# Lock and request hibernation
redis-cli -h 192.168.7.1 LPUSH scooter:state lock-hibernate
```

**Available commands**: `lock`, `unlock`, `lock-hibernate`, `force-lock`

### Seatbox Control (`scooter:seatbox`)

Controls the seatbox lock mechanism.

```bash
# Open the seatbox
redis-cli -h 192.168.7.1 LPUSH scooter:seatbox open
```

**Available commands**: `open`

### Horn Control (`scooter:horn`)

Controls the horn/buzzer.

```bash
# Turn horn on
redis-cli -h 192.168.7.1 LPUSH scooter:horn on

# Turn horn off
redis-cli -h 192.168.7.1 LPUSH scooter:horn off
```

**Available commands**: `on`, `off`

### Blinker Control (`scooter:blinker`)

Controls the turn signals/blinkers.

```bash
# Left blinker
redis-cli -h 192.168.7.1 LPUSH scooter:blinker left

# Right blinker
redis-cli -h 192.168.7.1 LPUSH scooter:blinker right

# Hazard mode (both blinkers)
redis-cli -h 192.168.7.1 LPUSH scooter:blinker both

# Turn off blinkers
redis-cli -h 192.168.7.1 LPUSH scooter:blinker off
```

**Available commands**: `left`, `right`, `both`, `off`

### Alarm Control (`scooter:alarm`) - Librescoot Only

Controls the motion-based alarm system.

```bash
# Enable alarm system (persists settings.alarm.enabled=true)
redis-cli -h 192.168.7.1 LPUSH scooter:alarm enable

# Disable alarm system (persists settings.alarm.enabled=false)
redis-cli -h 192.168.7.1 LPUSH scooter:alarm disable

# Runtime arm/disarm (does not change settings.alarm.enabled)
redis-cli -h 192.168.7.1 LPUSH scooter:alarm arm
redis-cli -h 192.168.7.1 LPUSH scooter:alarm disarm

# Manual alarm trigger (30 seconds)
redis-cli -h 192.168.7.1 LPUSH scooter:alarm start:30

# Stop alarm immediately
redis-cli -h 192.168.7.1 LPUSH scooter:alarm stop
```

**Available commands**: `enable`, `disable`, `arm`, `disarm`, `start:<seconds>`, `stop`

### Motion Sensor Control - Librescoot Only

The `scooter:motion` command queue still exists (the older `scooter:bmx` queue is gone). motion-service BRPOPs it and accepts `sensitivity:<level>`, `pin:<pin>`, `interrupt:<enable|disable>`, `reset`, `polling:<hz>` and `streaming:<enable|disable>`.

These are dev conveniences, not configuration: chip configuration is reactive, and the profile controller reprograms the registers on the next `alarm` or `power-manager` transition, so a manual `sensitivity`, `pin` or `interrupt` looks like it worked and then reverts. `reset` duplicates the `soft-reset` RPC.

There are also RPC methods on `motion:rpc`. See [Motion / IMU (`motion`)](#motion--imu-motion---librescoot-only).

### Power Control (`scooter:power`) - Librescoot Enhanced

Librescoot adds more power control commands:

```bash
# Request running state (highest priority)
redis-cli -h 192.168.7.1 LPUSH scooter:power run

# Request suspend
redis-cli -h 192.168.7.1 LPUSH scooter:power suspend

# Request hibernation
redis-cli -h 192.168.7.1 LPUSH scooter:power hibernate

# Manual hibernation (user-initiated)
redis-cli -h 192.168.7.1 LPUSH scooter:power hibernate-manual

# Timer-based hibernation
redis-cli -h 192.168.7.1 LPUSH scooter:power hibernate-timer

# Hibernate for a specific duration; nRF52 wakes the iMX6 after N seconds
redis-cli -h 192.168.7.1 LPUSH scooter:power "hibernate-for:300"

# Cancel a pending hibernate-for and disarm the wake timer
redis-cli -h 192.168.7.1 LPUSH scooter:power hibernate-cancel

# Reboot system
redis-cli -h 192.168.7.1 LPUSH scooter:power reboot
```

**Available commands**: `run`, `suspend`, `hibernate`, `hibernate-manual`, `hibernate-timer`, `hibernate-for:<seconds>`, `hibernate-cancel`, `reboot`

### Modem Control (`scooter:modem`) - Librescoot Only

Controls modem power state.

```bash
# Enable modem
redis-cli -h 192.168.7.1 LPUSH scooter:modem enable

# Disable modem
redis-cli -h 192.168.7.1 LPUSH scooter:modem disable
```

**Available commands**: `enable`, `disable`

There are no GPS commands; modem-service manages GPS automatically based on connectivity state. The `modem.gps` setting toggles GPS overall.

### SMS Send (`scooter:sms`) - Librescoot Only

Sends an SMS through the modem. Unlike the other command queues (plain-string
commands), the payload is JSON, because a send needs both a recipient and a
body. The optional `id` token is echoed back as `request-id` on the `sms:sent`
stream so concurrent senders can correlate outcomes:

```bash
redis-cli -h 192.168.7.1 LPUSH scooter:sms '{"to":"+4915112345678","text":"Hello from the scooter"}'
redis-cli -h 192.168.7.1 LPUSH scooter:sms '{"id":"trip-42","to":"+4915112345678","text":"Hello"}'
```

The terminal outcome lands on the `sms:sent` stream/channel; send progress is
also reflected in the `sms` hash (`state` goes `sending`, then `idle` or
`error`).

### Update Control (`scooter:update`, `scooter:update:mdb`, `scooter:update:dbc`) - Librescoot Only

Controls the OTA update system. Per-component lists target one updater instance.

```bash
# Force immediate update check on one component
redis-cli -h 192.168.7.1 LPUSH scooter:update:mdb check-now

# Install from a local file (optional checksum)
redis-cli -h 192.168.7.1 LPUSH scooter:update:dbc "update-from-file:/data/ota/image.mender#sha256=<hex>"

# Install from a URL
redis-cli -h 192.168.7.1 LPUSH scooter:update:mdb "update-from-url:https://example.com/update.mender"

# Ask what a switch to another channel would download (changes nothing)
redis-cli -h 192.168.7.1 LPUSH scooter:update:mdb preview-channel:stable
redis-cli -h 192.168.7.1 HMGET ota preview-status:mdb preview-version:mdb preview-size:mdb
```

**Per-component commands** (`scooter:update:mdb` / `scooter:update:dbc`): `check-now`, `update-from-file:<path>[#sha256=<hex>]`, `update-from-url:<url>[#sha256=<hex>]`

`preview-channel:<channel>` reports the latest release on `<channel>` for this
component's `variant_id` and the size of its `.mender` artifact, into the `ota` hash's
`preview-*` fields. It sets nothing and downloads nothing; the dashboard uses it to
price a channel switch before asking the rider to confirm.

The shared `scooter:update` list is consumed by **vehicle-service**, not the updaters: update-service pushes lifecycle commands (`start`, `complete`, `start-dbc`, `complete-dbc`) there to drive the vehicle's `updating` state.

See [update-service documentation](../services/librescoot-update.md).

### Settings Overlay Control (`settings:overlay`) - Librescoot Only

Apply or clear a named settings overlay. See [Settings Overlay Commands](#settings-overlay-commands-settingsoverlay---librescoot-only) above for full details.

```bash
# Enable Service mode
redis-cli -h 192.168.7.1 LPUSH settings:overlay apply:service

# Disable Service mode
redis-cli -h 192.168.7.1 LPUSH settings:overlay clear:service
```

**Available commands**: `apply:service`, `clear:service`

### CPU Governor Control (`scooter:governor`) - Librescoot Only

Consumed by pm-service; switches the CPU frequency governor. vehicle-service and update-service push `ondemand` here (when leaving stand-by, and at download start, respectively).

```bash
redis-cli -h 192.168.7.1 LPUSH scooter:governor performance
```

**Available commands**: `ondemand`, `powersave`, `performance`

### Command Channel Notes

- Commands use the `LPUSH` operation to queue requests
- Services subscribe to these channels using `BRPOP` and process commands sequentially
- State changes resulting from commands are published to the corresponding hash fields and pub/sub channels
- Command results can be monitored by subscribing to the relevant state hashes (e.g., `vehicle` hash for lock/unlock state)
- Librescoot adds several new command channels for alarm, motion, modem, keycard, governor, and update control
