# Redis Interface Documentation

## Connection Details

The scooter runs a Redis instance on the MDB accessible at:
- Host: 192.168.7.1  
- Port: 6379

Local connection command:
```bash
redis-cli -h 192.168.7.1 -p 6379
```

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
| seatbox:button | "on"/"off" | Seat open button state | "off" |
| seatbox:lock | "open"/"closed" | Seat lock state | "closed" |
| horn:button | "on"/"off" | Horn button state | "off" |
| brake:left | "on"/"off" | Left brake state | "off" |
| brake:right | "on"/"off" | Right brake state | "off" |
| blinker:switch | "left"/"right"/"both"/"off" | Blinker switch position | "off" |
| blinker:state | "on"/"off" | Blinker active state | "off" |
| state | "stand-by"/"ready-to-drive"/"off"/"parked"/"booting"/"shutting-down"/"hibernating"/"hibernating-imminent"/"suspending"/"suspending-imminent"/"updating" | Vehicle operating state | "stand-by" |
| auto-standby-deadline | integer (Unix timestamp) | When auto-standby will trigger (only present when timer active) | "1734567890" |

### Engine ECU (`engine-ecu`)
```
hgetall engine-ecu
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| state | "on"/"off" | ECU power state | "off" |
| kers-reason-off | string | Reason KERS is disabled | "none" |
| kers | "on"/"off" | KERS active state | "on" |
| motor:voltage | integer (mV) | Motor voltage | "52140" |
| motor:current | integer (mA) | Motor current | "0" |
| rpm | integer | Motor RPM | "0" |
| speed | integer (km/h) | Vehicle speed | "0" |
| throttle | "on"/"off" | Throttle state | "off" |
| fw-version | hex string | ECU firmware version | "0445400C" |
| odometer | integer (m) | Total distance | "632900" |
| temperature | integer (°C) | ECU temperature | "16" |

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

### Connectivity Battery (`cb-battery`)
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
| status | string | Connection status | "disconnected" |
| unu-cloud | string | Cloud connection status | "disconnected" |
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
- `delete-all-bonds` - Remove all paired/bonded devices from the system

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

**Note**: This hash expires after 10 seconds. Authentication events are also published to the `keycard:authentication` channel.

### Navigation System
The navigation system uses two related hashes:

Main Navigation Status (`navigation`)
```
hgetall navigation
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| status | string | Navigation status | "unset" |

Navigation Coordinates (`navigation:coord`)
```
hgetall navigation:coord
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| location | ? | probably packed coords? | "378993323372" |

### GPS Data (`gps`)
```
hgetall gps
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| latitude | string | Current latitude (6 decimal places) | "0.000000" |
| longitude | string | Current longitude (6 decimal places) | "0.000000" |
| altitude | string | Current altitude (6 decimal places) | "0.000000" |
| timestamp | string | GPS timestamp (ISO format) | "0000-00-00T00:00:00" |
| speed | string | GPS speed (6 decimal places) | "0.000000" |
| course | string | GPS course (6 decimal places) | "0.000000" |

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

#### LibreScoot Additional Settings

LibreScoot adds persistent settings managed by the settings-service:

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| alarm.enabled | "true"/"false" | Alarm system enabled | "true" |
| alarm.honk | "true"/"false" | Horn enabled during alarm | "false" |
| alarm.duration | integer (sec) | Alarm duration in seconds | "60" |
| alarm.seatbox-trigger | "true"/"false" | Trigger alarm on unauthorized seatbox opening | "true" |
| alarm.hairtrigger | "true"/"false" | Hair trigger mode (immediate short alarm on first motion) | "false" |
| alarm.hairtrigger-duration | integer (sec) | Hair trigger alarm duration in seconds | "3" |
| alarm.l1-cooldown | integer (sec) | Level 1 cooldown duration in seconds | "15" |
| battery.ignore-seatbox | "true"/"false" | Ignore seatbox state for battery management | "false" |
| cellular.apn | string | Cellular APN | "internet.provider.com" |
| hibernation-timer | integer (sec) | Hibernation timeout (0=disabled) | "432000" |
| scooter.auto-standby-seconds | integer (sec) | Auto-lock timeout when parked (0=disabled) | "0" |
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
| dashboard.show-cloud | string | Cloud indicator visibility | "error" |
| dashboard.show-internet | string | Internet indicator visibility | "always" |
| dashboard.battery-display-mode | string | Battery display mode (percentage/range) | "percentage" |
| dashboard.map.type | string | Map tile source (online/offline) | "offline" |
| dashboard.map.render-mode | string | Map rendering mode (vector/raster) | "raster" |
| dashboard.theme | string | UI theme (light/dark/auto) | "dark" |
| dashboard.mode | string | Default screen mode (speedometer/navigation) | "speedometer" |
| dashboard.valhalla-url | string | Valhalla routing service endpoint | "http://localhost:8002/" |

See [settings-service documentation](../services/librescoot-settings.md) for details on persistent settings.

### Alarm System (`alarm`) - LibreScoot Only

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

### BMX055 Motion Sensor (`bmx`) - LibreScoot Only

```
hgetall bmx
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| initialized | "true"/"false" | BMX sensor initialization status | "true" |
| interrupt | string | Interrupt status | "active" |
| sensitivity | string | Current sensitivity level | "MEDIUM" |
| pin | string | Interrupt pin configuration | "INT2" |

**Sensitivity levels:** `LOW`, `MEDIUM`, `HIGH`

The alarm-service manages BMX055 configuration automatically based on alarm state.

### Dashboard Backlight (`dashboard`) - LibreScoot Enhancement

LibreScoot adds these fields to the dashboard hash:

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| illumination | integer (lux) | Ambient light level | "42" |
| backlight | integer | Current backlight brightness | "9700" |
| brightness | integer (lux) | Alias for illumination | "42" |

The `dbc-illumination-service` monitors the OPT3001 sensor and publishes to `illumination`.
The `dbc-backlight-service` reads `illumination` and adjusts `backlight` automatically.

### GPS State (`gps`) - LibreScoot Enhancement

LibreScoot adds GPS state tracking:

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| state | string | GPS state | "fix-established" |

**GPS states:**
- `off` - GPS is disabled
- `searching` - Actively searching for GPS signal
- `fix-established` - Valid GPS fix obtained (2D or 3D)
- `error` - GPS configuration or connection failed

### Modem Management (`modem`) - LibreScoot Only

```
hgetall modem
```

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| power-state | string | Modem power state | "on" |
| sim-state | string | SIM card state | "active" |
| sim-lock | string | SIM lock status | "disabled" |
| operator-name | string | Network operator name | "T-Mobile" |
| operator-code | string | Network operator code | "26201" |
| is-roaming | "true"/"false" | Roaming status | "false" |
| registration-fail | string | Registration failure reason | "" |

### Internet Connectivity (`internet`) - LibreScoot Enhancement

LibreScoot adds modem health tracking:

| Field | Type | Description | Example |
|-------|------|-------------|----------|
| modem-health | string | Modem recovery state | "normal" |
| sim-imsi | string | SIM IMSI | "262010123456789" |

**Modem health states:**
- `normal` - Modem operating normally
- `recovering` - Attempting recovery
- `recovery-failed-waiting-reboot` - Recovery failed, waiting for reboot
- `permanent-failure-needs-replacement` - Hardware failure

### OTA Updates (`ota`) - LibreScoot Enhancement

LibreScoot adds per-component update tracking:

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

**Update status values:** `idle`, `downloading`, `installing`, `rebooting`, `error`

See [update-service documentation](../services/librescoot-services.md#update-service) for details.

### Version Information - LibreScoot Only

#### MDB Version (`version:mdb`)

```
hgetall version:mdb
```

Contains all fields from `/etc/os-release` with lowercase keys (e.g., `version_id`, `build_id`).

#### DBC Version (`version:dbc`)

```
hgetall version:dbc
```

Contains all fields from `/etc/os-release` with lowercase keys.

The version-service populates these hashes on startup from the OS release information.

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

The scooter accepts control commands via Redis list-based channels using `LPUSH`. Commands are queued and processed by the unu-vehicle service.

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

**Available commands**: `lock`, `unlock`, `lock-hibernate`

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

### Alarm Control (`scooter:alarm`) - LibreScoot Only

Controls the motion-based alarm system.

```bash
# Enable alarm system
redis-cli -h 192.168.7.1 LPUSH scooter:alarm enable

# Disable alarm system
redis-cli -h 192.168.7.1 LPUSH scooter:alarm disable

# Manual alarm trigger (30 seconds)
redis-cli -h 192.168.7.1 LPUSH scooter:alarm start:30

# Stop alarm immediately
redis-cli -h 192.168.7.1 LPUSH scooter:alarm stop
```

**Available commands**: `enable`, `disable`, `start:<seconds>`, `stop`

### BMX Sensor Control (`scooter:bmx`) - LibreScoot Only

Controls BMX055 accelerometer/gyroscope configuration. Typically used by alarm-service.

```bash
# Configure sensitivity
redis-cli -h 192.168.7.1 LPUSH scooter:bmx sensitivity:MEDIUM

# Configure interrupt pin
redis-cli -h 192.168.7.1 LPUSH scooter:bmx pin:INT2

# Enable interrupt
redis-cli -h 192.168.7.1 LPUSH scooter:bmx interrupt:enable
```

**Available commands**: `sensitivity:<LOW|MEDIUM|HIGH>`, `pin:<NONE|INT1|INT2>`, `interrupt:<enable|disable>`

### Power Control (`scooter:power`) - LibreScoot Enhanced

LibreScoot adds more power control commands:

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

# Reboot system
redis-cli -h 192.168.7.1 LPUSH scooter:power reboot
```

**Available commands**: `run`, `suspend`, `hibernate`, `hibernate-manual`, `hibernate-timer`, `reboot`

### Modem Control (`scooter:modem`) - LibreScoot Only

Controls modem power state and GPS.

```bash
# Enable modem
redis-cli -h 192.168.7.1 LPUSH scooter:modem enable

# Disable modem
redis-cli -h 192.168.7.1 LPUSH scooter:modem disable

# Enable GPS
redis-cli -h 192.168.7.1 LPUSH scooter:modem gps:enable

# Disable GPS
redis-cli -h 192.168.7.1 LPUSH scooter:modem gps:disable
```

**Available commands**: `enable`, `disable`, `gps:enable`, `gps:disable`

### Update Control (`scooter:update`) - LibreScoot Only

Controls OTA update system.

```bash
# Force immediate update check (both MDB and DBC)
redis-cli -h 192.168.7.1 LPUSH scooter:update check-now
```

**Available commands**: `check-now`

### Command Channel Notes

- Commands use the `LPUSH` operation to queue requests
- Services subscribe to these channels using `BRPOP` and process commands sequentially
- State changes resulting from commands are published to the corresponding hash fields and pub/sub channels
- Command results can be monitored by subscribing to the relevant state hashes (e.g., `vehicle` hash for lock/unlock state)
- LibreScoot adds several new command channels for alarm, BMX, modem, and update control
