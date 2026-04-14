# librescoot-settings (settings-service)

## Description

The settings service is a LibreScoot-only service that provides bidirectional synchronization between Redis and persistent TOML configuration files. It enables persistent storage of scooter settings across reboots and provides automatic network configuration management.

## Version

LibreScoot settings-service v1.0.0+

## Command-Line Options

```
REDIS_ADDR=localhost:6379             Redis server address (environment variable)
-settings-file <path>                 Path to settings TOML file (default: /data/settings.toml)
-wireguard-config-dir <path>          Path to WireGuard config directory (default: /data/wireguard)
-schema <path>                        Path to settings schema JSON (default: /usr/share/settings-service/settings.schema.json)
-version                              Print version and exit
```

## Redis Operations

### Hash: `settings`

**Fields read and written:**
- Any field with format `<section>.<key>` (e.g., `scooter.speed_limit`, `cellular.apn`)

The service syncs all fields in the `settings` hash with the TOML file.

**Subscribed channel:** `settings`

When a field is published to the `settings` channel, the service:
1. Reads the new value from Redis
2. Updates the TOML file
3. Performs special handling for certain fields (e.g., APN updates)

### Settings Structure

Settings are organized by section. Examples:

**Alarm settings:**
- `alarm.enabled` - Alarm system enabled ("true"/"false")
- `alarm.honk` - Horn enabled during alarm ("true"/"false")
- `alarm.duration` - Alarm duration in seconds
- `alarm.seatbox-trigger` - Trigger alarm on unauthorized seatbox opening ("true"/"false")
- `alarm.hairtrigger` - Hair trigger mode enabled ("true"/"false")
- `alarm.hairtrigger-duration` - Hair trigger alarm duration in seconds
- `alarm.l1-cooldown` - Level 1 cooldown duration in seconds

- `scooter.max-voltage-delta` - Maximum voltage difference between batteries in mV before dual battery activation is refused (default: 1000; 0 to disable)
- `scooter.battery-ignores-seatbox` - Runtime override of `--dangerously-ignore-seatbox` (default: false)
- `scooter.battery-keep-active-on-seatbox-open` - Keep active battery on across seatbox opens (default: false)
- `scooter.dual-battery` - Enable dual battery mode (default: false)
- `scooter.dbc-blinker-led` - Blink DBC boot LED with blinkers ("enabled"/"disabled"; default: "disabled")
- `scooter.enable-horn` - Horn enable mode ("true"/"false"/"in-drive"; default: "true")

**Cellular settings:**
- `cellular.apn` - Cellular APN for data connection

**Power management settings:**
- `hibernation-timer` - Hibernation timeout in seconds (0=disabled)

**Scooter settings:**
- `scooter.auto-standby-seconds` - Auto-lock timeout when parked in seconds (default: 0 = disabled; max 3600). The last 60 s are shown as a cancellable countdown on the dashboard; any user input (brake, kickstand, seatbox button) resets the timer.
- `scooter.brake-hibernation` - Enable brake lever hibernation ("enabled"/"disabled")

**Update settings:**
- `updates.mdb.channel` - MDB update channel (stable/testing/nightly)
- `updates.mdb.check-interval` - Update check interval as Go duration ("6h", "24h", "never")
- `updates.mdb.method` - Update method (full/delta)
- `updates.mdb.dry-run` - Dry-run mode ("true"/"false")
- `updates.mdb.releases-url` - Releases API endpoint
- `updates.mdb.last-check-time` - Last check timestamp (ISO8601)
- `updates.dbc.channel` - DBC update channel
- `updates.dbc.check-interval` - DBC update check interval as Go duration
- `updates.dbc.method` - DBC update method (full/delta)
- `updates.dbc.dry-run` - DBC dry-run mode
- `updates.dbc.releases-url` - DBC releases API endpoint
- `updates.dbc.last-check-time` - DBC last check timestamp
- `updates.mdb.orchestrate-dbc` - Auto power-on DBC and trigger update check when newer DBC release available (default: false)

**Dashboard settings:**
- `dashboard.show-raw-speed` - Show raw uncorrected speed ("true"/"false")
- `dashboard.show-clock` - Clock visibility (always/never)
- `dashboard.show-gps` - GPS indicator visibility (always/active-or-error/error/never)
- `dashboard.show-bluetooth` - Bluetooth indicator visibility
- `dashboard.show-cloud` - Cloud indicator visibility
- `dashboard.show-internet` - Internet indicator visibility
- `dashboard.blinker-style` - Blinker indicator style (icon/overlay)
- `dashboard.language` - UI language (en, de, ...)
- `dashboard.map.type` - Map tile source (online/offline)
- `dashboard.map.render-mode` - Map rendering mode (vector/raster)
- `dashboard.theme` - UI theme (light/dark/auto)
- `dashboard.mode` - Default screen mode (speedometer/navigation)
- `dashboard.valhalla-url` - Valhalla routing service endpoint
- `dashboard.app` - Display app to launch on DBC boot ("scootui-qt"/"scootui-tui"; default: "scootui-qt")
- `dashboard.power-display-mode` - Power display unit (kw/amps; default: "kw")
- `dashboard.battery-display-mode` - Battery display mode (percentage/range)
- `dashboard.hop-on-combo` - Custom hop-on unlock combo, pipe-delimited tokens (empty = no combo)
- `dashboard.maps.check-for-updates` - Auto-check for map updates weekly when online (default: true)
- `dashboard.maps.auto-download` - Auto-download map updates (default: false)
- `dashboard.maps-available` - Offline map tiles available (system-managed; default: false)
- `dashboard.navigation-available` - Full navigation available (system-managed; default: false)

**ECU settings:**
- `engine-ecu.kers` - KERS enable/disable ("enabled"/"disabled"; default: "enabled")
- `engine-ecu.kers-power` - KERS regenerative braking current in mA
- `engine-ecu.boost` - Enable motor boost mode (default: false)
- `engine-ecu.kers-power-dual` - KERS current in mA when both batteries active

## File Operations

### Settings File: `/data/settings.toml`

The service maintains a TOML file with this structure:

```toml
[alarm]
enabled = "true"
honk = "false"
duration = "60"
seatbox-trigger = "true"
hairtrigger = "false"
hairtrigger-duration = "3"
l1-cooldown = "15"

[cellular]
apn = "internet.provider.com"

[scooter]
auto-standby-seconds = "0"
brake-hibernation = "enabled"
battery-ignores-seatbox = "false"

[dashboard]
theme = "dark"
mode = "speedometer"

[updates.mdb]
channel = "nightly"
check-interval = "6h"

[updates.dbc]
channel = "stable"
check-interval = "12h"
```

### NetworkManager APN Configuration

When `cellular.apn` is updated, the service automatically updates:

**File:** `/etc/NetworkManager/system-connections/wwan.nmconnection`

The service:
1. Reads the existing nmconnection file
2. Updates the `apn=` field in the `[gsm]` section
3. Writes the updated file
4. NetworkManager automatically reloads the connection

### WireGuard Configuration Management

On startup, the service manages WireGuard VPN connections:

1. **Deletes all existing WireGuard connections** from NetworkManager
2. **Waits for internet connectivity** (event-driven: subscribes to `internet` channel and polls `internet` hash; falls back to a 120s timeout if Redis is unavailable or internet never connects)
3. **Imports all `*.conf` files** from `/data/wireguard/` directory
4. Each `.conf` file becomes a new WireGuard connection in NetworkManager

This ensures clean WireGuard state on boot and allows easy VPN configuration via files.

## Observable Behavior

### Startup Sequence

1. Connects to Redis
2. Checks if `/data/settings.toml` exists
3. If exists and non-empty:
   - Flushes existing Redis `settings` hash
   - Reads TOML file
   - Populates Redis with all settings
   - Publishes each setting to `settings` channel
4. If doesn't exist or empty `[scooter]` section:
   - Flushes Redis `settings` hash
   - Creates empty TOML file
5. Deletes existing WireGuard connections from NetworkManager
6. Waits for internet connectivity (event-driven; max 120s timeout)
7. Imports all WireGuard configs from `/data/wireguard/`
8. Begins monitoring Redis for setting changes

### Runtime Behavior

#### Redis to TOML Sync

When a setting is changed via Redis:

```bash
# Update a setting
redis-cli HSET settings scooter.speed_limit "30"
redis-cli PUBLISH settings scooter.speed_limit
```

The service:
1. Receives the publish notification
2. Reads the new value from Redis
3. Parses the section and key (e.g., "scooter" and "speed_limit")
4. Updates the TOML file
5. Saves to disk

#### TOML to Redis Sync (Startup Only)

On startup, if `/data/settings.toml` exists:
1. Entire file is read
2. All sections and keys are converted to Redis format
3. Redis `settings` hash is flushed
4. All settings written to Redis
5. Each setting published to `settings` channel

This ensures Redis reflects the persistent configuration.

### Key: `settings:schema`

On startup, the service publishes the raw schema JSON to this string key so other services can introspect available settings and their metadata.

#### APN Special Handling

When `cellular.apn` is updated:
1. TOML file is updated (normal behavior)
2. Service checks if `/etc/NetworkManager/system-connections/wwan.nmconnection` exists
3. If exists:
   - Reads the file
   - Finds the `[gsm]` section
   - Updates the `apn=` line
   - Writes the file back
4. NetworkManager detects the change and reloads the connection
5. New APN takes effect on next modem connection

#### Empty Config Handling

If the TOML file is empty or has an empty `[scooter]` section:
- Redis `settings` hash is flushed
- Service treats this as "factory reset" of settings
- Services using settings will fall back to their defaults

### WireGuard Management

**Directory:** `/data/wireguard/`

**File format:** Standard WireGuard `.conf` files

**Example WireGuard config:**
```ini
[Interface]
PrivateKey = your-private-key
Address = 10.0.0.2/24

[Peer]
PublicKey = peer-public-key
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

**Management process:**
1. On startup: Service deletes all existing WireGuard connections
2. Waits for internet connectivity (event-driven; falls back to 120s timeout)
3. Scans `/data/wireguard/` for `*.conf` files
4. Imports each file as a NetworkManager connection
5. Connections are named based on filename (e.g., `vpn.conf` → "vpn")

This allows easy VPN configuration by placing `.conf` files in `/data/wireguard/`.

## Configuration Examples

### Setting Speed Limit

```bash
# Set speed limit to 30 km/h
redis-cli HSET settings scooter.speed_limit "30"
redis-cli PUBLISH settings scooter.speed_limit

# Verify in TOML file
cat /data/settings.toml
# [scooter]
# speed_limit = "30"
```

### Configuring Cellular APN

```bash
# Set APN (also updates NetworkManager)
redis-cli HSET settings cellular.apn "internet.lebara.de"
redis-cli PUBLISH settings cellular.apn

# Verify in TOML
cat /data/settings.toml
# [cellular]
# apn = "internet.lebara.de"

# Verify in NetworkManager
cat /etc/NetworkManager/system-connections/wwan.nmconnection
# [gsm]
# apn=internet.lebara.de
```

### Configuring Updates

```bash
# Set MDB to stable channel
redis-cli HSET settings updates.mdb.channel "stable"
redis-cli PUBLISH settings updates.mdb.channel

# Set DBC update check interval
redis-cli HSET settings updates.dbc.check-interval "12h"
redis-cli PUBLISH settings updates.dbc.check-interval
```

### Enabling Alarm

```bash
# Enable alarm system
redis-cli HSET settings alarm.enabled "true"
redis-cli PUBLISH settings alarm.enabled

# Enable horn
redis-cli HSET settings alarm.honk "true"
redis-cli PUBLISH settings alarm.honk
```

### Factory Reset Settings

```bash
# Delete TOML file
rm /data/settings.toml

# Restart settings service
systemctl restart librescoot-settings

# Redis settings hash is now empty
# Services will use default values
```

## Building

```bash
# Build for ARM target
make build

# Build for AMD64 (development)
make build-amd64
```

## Installation

The service is typically installed via systemd:

**Unit file:** `/etc/systemd/system/librescoot-settings.service`

```ini
[Unit]
Description=LibreScoot Settings Service
After=redis.service
Requires=redis.service

[Service]
Type=simple
ExecStart=/usr/bin/settings-service
Restart=always
Environment="REDIS_ADDR=localhost:6379"

[Install]
WantedBy=multi-user.target
```

## Log Output

The service logs to stdout/stderr (captured by systemd):
- TOML file read/write operations
- Redis synchronization events
- APN configuration updates
- WireGuard connection management
- Parse errors or file I/O errors

Use `journalctl -u librescoot-settings` to view logs.

## Dependencies

- **Redis server** - For settings storage and pub/sub
- **NetworkManager** - For APN and WireGuard management
- **File system** - `/data/` directory must be writable

## Integration with Other Services

All LibreScoot services can use the settings system:

- **alarm-service**: Reads `alarm.enabled`, `alarm.honk`
- **update-service**: Reads `updates.{component}.*` settings
- **vehicle-service**: Can read scooter behavior settings
- **modem-service**: APN is configured via NetworkManager

Services should:
1. Subscribe to `settings` channel
2. Read from `settings` hash when notified
3. Apply new settings immediately
4. Fall back to defaults if setting not present

## LibreScoot Feature

This is a LibreScoot-only service. Benefits:

- **Persistent configuration:** Settings survive reboots
- **Easy backup:** Single TOML file contains all settings
- **Network management:** Automatic APN and WireGuard configuration
- **Flexibility:** Any service can add new settings
- **No cloud dependency:** All configuration is local

## Related Documentation

- [Redis Operations](../redis/README.md) - Settings hash structure
- [LibreScoot Services](librescoot-services.md) - How other services use settings
- [Update Service](librescoot-update.md) - Update channel configuration
- [Alarm Service](librescoot-alarm.md) - Alarm settings
