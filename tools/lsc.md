# lsc - LibreScoot Control CLI

`lsc` is a command-line interface for controlling and monitoring LibreScoot electric scooters via Redis. It provides a convenient, user-friendly interface to all LibreScoot services and features.

## Overview

The `lsc` tool acts as a bridge between human operators and the LibreScoot Redis-based communication system. Instead of manually crafting Redis commands, you can use intuitive commands to:

- Control vehicle state (lock/unlock, hibernate)
- Monitor system status and diagnostics
- Manage OTA updates
- Configure settings
- View logs and events
- Control hardware components

## Installation

The `lsc` binary is typically installed to `/usr/bin/lsc` on LibreScoot systems.

**Manual installation:**
```bash
# From the lsc source directory
make build              # Build for ARM
make build-native       # Build for local platform

# Or manually
GOOS=linux GOARCH=arm GOARM=7 go build -o lsc .
```

## Global Flags

All commands support these global flags:

- `--json` - Output in JSON format for automation and scripting
- `--redis-addr <host:port>` - Redis server address (default: `192.168.7.1:6379`)
- `--no-block` - Don't wait for state change confirmation (vehicle commands only)

## Commands

### Vehicle Control

Control vehicle state and hardware.

```bash
# Lock the scooter (also via: lsc lock)
lsc vehicle lock

# Unlock the scooter (also via: lsc unlock)
lsc vehicle unlock

# Force standby without waiting for locks
lsc vehicle force-lock

# Lock and request hibernation
lsc vehicle hibernate

# Open seatbox (also via: lsc open)
lsc vehicle open
```

**Redis operations:**
- Sends commands to `scooter:state` list (lock, unlock, force-lock, lock-hibernate)
- Sends commands to `scooter:seatbox` list (open)
- Monitors `vehicle` hash for state changes

### Power Management

Control system power states.

```bash
# Show power manager status
lsc power status

# Set power state to run (normal operation, highest priority)
lsc power run

# Set power state to suspend (low power)
lsc power suspend

# Set power state to hibernate (power off)
lsc power hibernate

# Reboot the system
lsc power reboot
```

**Redis operations:**
- Sends commands to `scooter:power` list
- Reads from `power-manager` hash

### Service Management

Manage systemd services with convenient shorthand names.

```bash
# List all services with status
lsc service list
lsc svc list         # Short alias

# Start/stop/restart a service
lsc svc start vehicle
lsc svc stop battery
lsc svc restart ecu

# Enable/disable service on boot
lsc svc enable alarm
lsc svc disable modem

# Show service status
lsc svc status pm

# View service logs
lsc svc logs vehicle
lsc svc logs battery --follow        # Follow in real-time (-f)
lsc svc logs redis --lines 100       # Show 100 lines (-n 100)
```

**Service name shortcuts:**
- `vehicle` → `librescoot-vehicle.service`
- `battery` → `battery-service.service`
- `ecu` → `ecu-service.service`
- `alarm` → `alarm-service.service`
- `modem` → `modem-service.service`
- `settings` → `settings-service.service`
- `bluetooth` → `bluetooth-service.service`
- `pm` → `librescoot-pm.service`
- `keycard` → `librescoot-keycard.service`
- `update` → `update-service.service`
- `redis` → `redis.service`

**System integration:**
- Uses `systemctl` commands via D-Bus
- Uses `journalctl` for log retrieval

### LED Control

Control LED cues and fade animations.

```bash
# Trigger LED cue by index
lsc led cue <index>

# Trigger LED fade animation
lsc led fade <channel> <index>
```

**Redis operations:**
- Sends commands to `scooter:led:cue` list
- Sends commands to `scooter:led:fade` list

### Battery Diagnostics

View detailed battery information.

```bash
# Show all batteries
lsc battery
lsc bat              # Short alias

# Show specific battery
lsc battery 0
lsc bat 1

# JSON output for scripting
lsc battery --json
```

**Redis operations:**
- Reads from `battery:0` and `battery:1` hashes

### GPS Tracking

Monitor GPS status and location.

```bash
# Show GPS status
lsc gps status

# Watch GPS location in real-time
lsc gps watch

# JSON output
lsc gps status --json
```

**Redis operations:**
- Reads from `gps` hash
- Subscribes to `gps` channel for real-time updates

### Alarm System

Control the motion-based alarm system.

```bash
# Check alarm status
lsc alarm status

# Enable the alarm
lsc alarm arm

# Disable the alarm
lsc alarm disarm

# Manually trigger the alarm
lsc alarm trigger
```

**Redis operations:**
- Sends commands to `scooter:alarm` list (enable, disable, start, stop)
- Reads from `alarm` hash
- Reads from `settings` hash (alarm.enabled, alarm.honk)

### Settings Management

View and modify scooter configuration.

```bash
# List all settings
lsc settings

# Get a specific setting (also via: lsc get)
lsc settings get alarm.enabled
lsc get scooter.mode

# Set a setting (also via: lsc set)
lsc settings set alarm.honk true
lsc set scooter.speed_limit 25

# Delete a setting (also via: lsc del)
lsc settings del custom.field
lsc del custom.field
```

**Common settings:**
- `alarm.enabled` - Enable/disable alarm system (true/false)
- `alarm.honk` - Enable horn during alarm (true/false)
- `scooter.speed_limit` - Speed limit in km/h
- `scooter.mode` - Drive mode (eco/sport)
- `cellular.apn` - Cellular APN configuration
- `updates.mdb.channel` - MDB update channel (stable/testing/nightly)
- `updates.dbc.channel` - DBC update channel

**Redis operations:**
- Reads/writes `settings` hash
- Publishes to `settings` channel for changes

### OTA Updates

Manage over-the-air updates.

```bash
# View OTA update status
lsc ota status

# Install update from local file
lsc ota install /path/to/update.mender

# Install update from URL
lsc ota install https://example.com/update.mender

# JSON output
lsc ota status --json
```

**Redis operations:**
- Reads from `ota` hash (status:mdb, status:dbc, download-progress, etc.)
- Sends commands to `scooter:update` list (check-now)

### Diagnostics

System diagnostics and fault monitoring.

```bash
# Show firmware versions (also via: lsc ver)
lsc diag version
lsc version

# Show active faults (also via: lsc faults)
lsc diag faults
lsc faults

# View fault event stream (also via: lsc events)
lsc diag events
lsc events

# Follow events in real-time
lsc events --follow

# Show events since duration
lsc events --since 1h
lsc events --since 24h
lsc events --since 7d

# Filter events by regex
lsc events --filter "battery.*"

# Control blinkers
lsc blinkers off
lsc blinkers left
lsc blinkers right
lsc blinkers both

# Control horn
lsc diag horn on
lsc diag horn off

# Control handlebar lock
lsc diag handlebar lock
lsc diag handlebar unlock
```

**Redis operations:**
- Reads from `version:mdb` and `version:dbc` hashes
- Reads from `battery:0:fault`, `battery:1:fault`, `engine-ecu:fault` sets
- Reads from `events:faults` stream using XREAD
- Sends commands to `scooter:blinker`, `scooter:horn`, `scooter:handlebar` lists

### Hardware Control

Direct hardware control commands.

```bash
# Control dashboard power (also via: lsc dbc)
lsc dashboard on
lsc dashboard off
lsc dbc on
lsc dbc off

# Control engine power (also via: lsc engine)
lsc engine on
lsc engine off
```

**Redis operations:**
- Sends commands to `scooter:hardware` list (dashboard:on, dashboard:off, engine:on, engine:off)

### Status Overview

Get overall system status.

```bash
# Show comprehensive status
lsc status

# JSON output for automation
lsc status --json
```

Shows summary of:
- Vehicle state
- Motor status (speed, odometer, temperature)
- Battery status for all batteries
- Power manager state
- GPS status
- Internet connectivity
- Active faults

### Real-time Monitoring

Monitor Redis pub/sub channels and record metrics.

```bash
# Watch Redis pub/sub channels
lsc watch

# Record metrics over time
lsc monitor
```

**Redis operations:**
- Subscribes to all channels and displays real-time updates
- Samples and logs metrics at intervals

### Saved Locations

Manage GPS location bookmarks (if supported by implementation).

```bash
# Manage saved locations
lsc locations
```

## JSON Output Mode

All commands support `--json` flag for automation:

```bash
# Get structured output
lsc status --json | jq '.vehicle.state'
lsc battery --json | jq '.[0].charge'
lsc settings --json | jq '.["alarm.enabled"]'

# Check if alarm is enabled
if [ "$(lsc get alarm.enabled --json | jq -r .value)" = "true" ]; then
  echo "Alarm is enabled"
fi

# Get battery charge percentage
CHARGE=$(lsc bat 0 --json | jq '.charge')
echo "Battery charge: $CHARGE%"
```

## Shell Completion

Generate completion scripts for your shell:

```bash
# Bash
lsc completion bash > /etc/bash_completion.d/lsc
source /etc/bash_completion.d/lsc

# Zsh
lsc completion zsh > "${fpath[1]}/_lsc"

# Fish
lsc completion fish > ~/.config/fish/completions/lsc.fish

# PowerShell
lsc completion powershell > lsc.ps1
```

After installing completion, you can use Tab to autocomplete commands, flags, and arguments.

## Common Use Cases

### Check System Health
```bash
# Quick status check
lsc status

# Check for faults
lsc faults

# View battery health
lsc battery
```

### Lock/Unlock Scooter
```bash
# Lock (will wait for state change confirmation)
lsc lock

# Unlock
lsc unlock

# Force lock without waiting
lsc lock --no-block

# Lock and hibernate
lsc vehicle hibernate
```

### Configure Alarm
```bash
# Enable alarm
lsc set alarm.enabled true

# Enable horn during alarm
lsc set alarm.honk true

# Arm the alarm
lsc alarm arm

# Check alarm status
lsc alarm status
```

### Monitor Updates
```bash
# Check update status
lsc ota status

# Watch for update progress
watch -n 1 lsc ota status

# JSON monitoring
watch -n 1 'lsc ota status --json | jq'
```

### Debugging Services
```bash
# List all services
lsc svc list

# Check specific service
lsc svc status vehicle

# View logs
lsc svc logs vehicle --follow

# Restart problematic service
lsc svc restart modem
```

### Tracking Location
```bash
# Show current GPS status
lsc gps status

# Watch location in real-time
lsc gps watch

# Get coordinates in JSON
lsc gps status --json | jq '.latitude, .longitude'
```

## Architecture

`lsc` communicates with LibreScoot services via Redis:

### Command Pattern
Commands are sent using LPUSH to command lists:
```
LPUSH scooter:state lock
LPUSH scooter:alarm enable
LPUSH scooter:power hibernate
```

### State Reading
Current state is read from Redis hashes:
```
HGETALL vehicle
HGETALL battery:0
HGETALL power-manager
```

### State Monitoring
Real-time updates via pub/sub:
```
SUBSCRIBE vehicle
SUBSCRIBE gps
SUBSCRIBE alarm
```

### Event History
Historical events via streams:
```
XREAD STREAMS events:faults 0
```

## Error Handling

`lsc` provides clear error messages for common issues:

- **Redis connection failed**: Check Redis server is running and accessible
- **Command timeout**: Service may not be running or responding
- **Invalid setting**: Check setting key spelling and format
- **Permission denied**: Check user has access to systemd commands

## Development

Source code: `/home/teal/src/librescoot/lsc/`

```bash
# Build for development
cd /home/teal/src/librescoot/lsc
go build -o lsc .

# Build for target (ARM)
make build

# Run tests
go test ./...

# Install
sudo cp lsc /usr/bin/
```

## Related Documentation

- [Redis Interface](../redis/README.md) - Redis hashes, lists, and channels
- [LibreScoot Services](../services/librescoot-services.md) - Service architecture
- [Settings Service](../services/librescoot-settings.md) - Configuration management
- [OTA Updates](../services/librescoot-services.md#update-service) - Update system
