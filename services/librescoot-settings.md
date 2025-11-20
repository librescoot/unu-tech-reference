# librescoot-settings (settings-service)

## Description

The settings service is a **new LibreScoot service** that provides bidirectional synchronization between Redis and persistent TOML configuration files. It enables persistent storage of scooter settings across reboots and provides automatic network configuration management.

This service has **no equivalent in unu firmware**.

## Version

LibreScoot settings-service v1.0.0+

## Command-Line Options

```
REDIS_ADDR=localhost:6379    Redis server address (environment variable)
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

**Scooter settings:**
- `scooter.speed_limit` - Speed limit in km/h
- `scooter.mode` - Drive mode (eco, sport, etc.)

**Cellular settings:**
- `cellular.apn` - Cellular APN for data connection

**Alarm settings:**
- `alarm.enabled` - Alarm system enabled ("true"/"false")
- `alarm.honk` - Horn enabled during alarm ("true"/"false")

**Update settings:**
- `updates.mdb.channel` - MDB update channel (stable/testing/nightly)
- `updates.mdb.check-interval` - Update check interval
- `updates.dbc.channel` - DBC update channel
- `updates.dbc.check-interval` - DBC update check interval

## File Operations

### Settings File: `/data/settings.toml`

The service maintains a TOML file with this structure:

```toml
[scooter]
speed_limit = "25"
mode = "eco"

[cellular]
apn = "internet.provider.com"

[alarm]
enabled = "true"
honk = "false"

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
2. **Waits 120 seconds** (configurable delay)
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
6. Waits 120 seconds
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
2. Waits 120 seconds (allows system to stabilize)
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

## Differences from unu Firmware

This is a **new LibreScoot service** with no unu equivalent. Benefits:

- **Persistent configuration:** Settings survive reboots
- **Easy backup:** Single TOML file contains all settings
- **Network management:** Automatic APN and WireGuard configuration
- **Flexibility:** Any service can add new settings
- **No cloud dependency:** All configuration is local

unu firmware stores some settings in Redis but they're lost on reboot, requiring cloud sync.

## Related Documentation

- [Redis Operations](../redis/README.md) - Settings hash structure
- [LibreScoot Services](librescoot-services.md) - How other services use settings
- [Update Service](librescoot-update.md) - Update channel configuration
- [Alarm Service](librescoot-alarm.md) - Alarm settings
