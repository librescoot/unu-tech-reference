# librescoot-scootui (scootui)

## Description

ScootUI is the primary user interface for LibreScoot. Built with **Flutter/Dart**, it provides a modern, responsive dashboard with real-time telemetry, navigation, and system controls. The application runs on the DBC (Dashboard Controller) and communicates with all LibreScoot services via Redis.

**Technology Stack:**
- **Flutter/Dart** - UI framework and language
- **Bloc/Cubit** - State management
- **Redis** - Real-time data communication with vehicle systems
- **Flutter Map** - Mapping and navigation display
- **MBTiles** - Offline map data storage

ScootUI replaces the proprietary unu-dashboard-ui with an open-source, community-developed interface.

## Features

### Real-time Telemetry Display
- Speed (raw or wheel-corrected), power output, battery levels
- Odometer, trip meter
- GPS status, connectivity indicators
- System warnings and fault codes

### Multiple View Modes
- **Cluster View** - Speedometer and vehicle status dashboard
- **Map View** - Navigation with turn-by-turn directions
- **Destination Selection** - Address input and route planning
- **OTA Update Interface** - System update progress and control

### Navigation
- Online and offline map support (MBTiles)
- Integration with BRouter for routing
- Turn-by-turn directions
- GPS tracking

### System Integration
- Connects to Redis-based MDB (Main Driver Board)
- Monitors battery, engine, GPS, Bluetooth, and all vehicle systems
- OTA update support for MDB and DBC
- Alarm status display
- Modem health monitoring

### Adaptable Design
- Light and dark themes
- Configurable dashboard elements

## Configuration

ScootUI uses Redis for dynamic configuration. Settings are stored in the `settings` hash.

### Dashboard Display Settings

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `dashboard.show-raw-speed` | `true`/`false` | `false` | Show ECU speed vs wheel-corrected |
| `dashboard.show-gps` | `always`/`active-or-error`/`error`/`never` | `error` | GPS icon visibility |
| `dashboard.show-bluetooth` | `always`/`active-or-error`/`error`/`never` | `active-or-error` | Bluetooth icon visibility |
| `dashboard.show-cloud` | `always`/`active-or-error`/`error`/`never` | `error` | Cloud connection icon visibility |
| `dashboard.show-internet` | `always`/`active-or-error`/`error`/`never` | `always` | Cellular icon visibility |

### Map Settings

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `dashboard.map.type` | `online`/`offline` | `offline` | Map source (CartoDB online or local MBTiles) |
| `dashboard.map.render-mode` | `vector`/`raster` | `raster` | Offline map rendering mode |

**Examples:**
```bash
# Show raw GPS speed
redis-cli HSET settings dashboard.show-raw-speed true
redis-cli PUBLISH settings dashboard.show-raw-speed

# Always show GPS indicator
redis-cli HSET settings dashboard.show-gps always
redis-cli PUBLISH settings dashboard.show-gps

# Switch to online maps
redis-cli HSET settings dashboard.map.type online
redis-cli PUBLISH settings dashboard.map.type

# Use vector rendering for offline maps
redis-cli HSET settings dashboard.map.render-mode vector
redis-cli PUBLISH settings dashboard.map.render-mode
```

## Redis Operations

### Subscriptions (SUBSCRIBE)

The dashboard subscribes to these channels:
- `aux-battery`
- `battery:0`, `battery:1`
- `ble`
- `cb-battery`
- `dashboard`
- `engine-ecu`
- `gps`
- `internet`
- `navigation`
- `navigation:coord`
- `scooter`
- `scooter-activation`
- `settings`
- `system`
- `vehicle`

### BLPOP Command Lists

The dashboard uses BLPOP to read commands:
- `scooter:dashboard-mode` - Mode control (speedometer/navigation/debug)
- `scooter:navigation` - Navigation commands (never written by dashboard)
- `scooter:state` - State commands (dashboard only writes "lock")

### HGET/HGETALL Reads

The dashboard reads from approximately 16 different Redis hashes. See [dashboard/REDIS.md](../dashboard/REDIS.md) for complete list.

### HSET Writes

The dashboard writes to:
- `dashboard ready` - Set to "true" after serial number read
- `dashboard serial-number` - Hardware serial from sysfs
- `dashboard mode` - Current display mode
- `system dbc-version` - Version from /etc/os-release
- `navigation status` - Navigation status updates
- `scooter state` - Triggered by user actions

### LPUSH Commands

The dashboard only pushes:
- `LPUSH scooter:state lock` - On battery timeout notifications

See [dashboard/REDIS.md](../dashboard/REDIS.md) for complete Redis operations reference.

## Display Modes

- **speedometer** - Default mode showing speed and status
- **navigation** - Map view with route guidance (vestigial, non-functional)
- **debug** - Development diagnostics (partially broken)

Activate debug mode:
```bash
LPUSH scooter:dashboard-mode debug
```

## Hardware Interfaces

### Display

- Integrated display on Dashboard Controller (DBC)
- Resolution and specs vary by hardware version

### System Files Read

**Serial Number:**
- `/sys/fsl_otp/HW_OCOTP_CFG0` - Hardware serial (hex)
- `/sys/fsl_otp/HW_OCOTP_CFG1` - Hardware serial (hex)

**OS Version:**
- `/etc/os-release` - VERSION_ID and BUILD_ID fields

### System Commands

- `poweroff` - Executed during shutdown (unless `--disable-poweroff`)

## Configuration

### Systemd Unit

- **Unit file:** Likely `/usr/lib/systemd/system/unu-dashboard-ui.service` (on DBC)
- **Started by:** systemd at boot
- **Restart policy:** Always

## Observable Behavior

### Startup Sequence

1. Connects to Redis (default 127.0.0.1:6379, or custom via `-b`/`-p`)
2. Subscribes to all service channels
3. Reads OS version from `/etc/os-release`
4. Sets `system dbc-version` to VERSION_ID+BUILD_ID
5. Reads hardware serial from sysfs
6. Sets `dashboard serial-number`
7. Sets `dashboard ready true` (only if serial read succeeds)
8. Starts in speedometer mode
9. Begins polling non-published properties

### Shutdown Behavior

When `vehicle state` becomes "shutting-down":
1. Sets `dashboard ready false`
2. Executes `poweroff` command after 2-second delay
3. Can be disabled with `--disable-poweroff` flag

### Battery Timeout Notifications

When battery charge becomes critically low:
- Dashboard receives timeout notification (AutomaticTurnOffMainBatteryNotification or AutomaticTurnOffAuxBatteryNotification)
- Automatically executes: `LPUSH scooter:state lock`
- This triggers vehicle shutdown

## UI Components

- **Status bar:** Time, connection status, odometer, battery, Bluetooth, seatbox
- **Central display:** Speedometer, navigation, or debug view
- **Notifications:** Battery warnings, system alerts, faults

See [dashboard/README.md](../dashboard/README.md) for UI details.

## Log Output

The dashboard logs to journald. Common messages:
- `"Could not read serial number. NOT setting dashboard:ready = true"`
- `"Could not load translations for any of the languages requested"`
- `"Power off is disabled."`
- `"Could not power off the system!"`
- `"Could not set up keep-alive socket, Redis connection handling might not work properly"`
- `"Could not find enum for [value]"`

Use `journalctl -u unu-dashboard-ui` to view logs (service name may vary).

## Dependencies

- **Redis server** - All other services via Redis
- **Qt/QML runtime** - Graphics framework
- **Display hardware** - Integrated display on DBC
- **Serial number files** - Must be readable from sysfs

## Related Documentation

- **[dashboard/README.md](../dashboard/README.md)** - Complete dashboard documentation
- **[dashboard/REDIS.md](../dashboard/REDIS.md)** - Comprehensive Redis operations reference
- [Redis Operations](../redis/README.md) - Dashboard hash fields
- [States](../states/README.md) - How dashboard displays vehicle states
