# LibreScoot Services

LibreScoot is an open-source replacement firmware for unu Scooter Pro systems. This document describes the services that comprise the LibreScoot platform.

## Overview

LibreScoot services replace the proprietary unu services with open-source alternatives that provide enhanced functionality, better configurability, and community-driven development. All services communicate via Redis and follow a consistent architecture pattern.

## Service Catalog

### Core System Services

#### alarm-service
Motion-based alarm system with integrated BMX055 accelerometer control.

**Key Features:**
- 8-state finite state machine for alarm logic
- Integrated BMX055 hardware control (no separate bmx-service required)
- Direct I2C communication with accelerometer (0x18) and gyroscope (0x68)
- Multi-level triggering:
  - Level 1: notification only
  - Level 2: alarm with horn (400ms on/off pattern) + hazard lights
- Automatic BMX configuration based on alarm state
- Suspend inhibitor management (wake locks)
- 100ms interrupt polling loop

**Redis Interface:**
- Reads: `settings alarm.enabled`, `settings alarm.honk`, `settings alarm.duration`, `settings alarm.seatbox-trigger`, `settings alarm.hairtrigger`, `settings alarm.hairtrigger-duration`, `settings alarm.l1-cooldown`
- Writes: `alarm status`
- Subscribes: `vehicle`, `settings`, `bmx:interrupt`
- Commands: `scooter:alarm` (enable/disable/start/stop)
- Publishes commands to: `scooter:bmx`, `scooter:horn`, `scooter:blinker`

**State Machine:**
```
init → waiting_enabled → disarmed → delay_armed (5s) → armed
                                         ↑                ↓ motion
                                         |        trigger_level_1_wait (15s)
                                         |                ↓
                                         |        trigger_level_1 (5s check)
                                         |                ↓ major movement
                                         |        trigger_level_2 (50s, max 4 cycles)
                                         |________________|
```

#### battery-service
Manages dual battery monitoring via NFC communication with PN7150 controllers.

**Key Features:**
- Dual battery monitoring (single thread per reader)
- Real-time battery state management
- NFC-based communication with battery management systems
- Temperature monitoring and safety controls
- Configurable update intervals for different battery states
- Automatic battery presence detection
- Heartbeat timeout monitoring (40s default)

**Configuration:**
- Device paths: `/dev/pn5xx_i2c0`, `/dev/pn5xx_i2c1`
- Separate log levels per battery reader
- Configurable off-update time (default: 1800s)

**Redis Interface:**
- Writes: `battery:0`, `battery:1` hashes
- Subscribes: `vehicle:state`, `vehicle:seatbox:lock`

#### bluetooth-service
Communication bridge between nRF52 module and Redis backend.

**Key Features:**
- Serial communication using custom USOCK protocol
- UART interface (default: `/dev/ttymxc1` at 115200 baud)
- Vehicle systems interface (battery, locks, mileage, firmware info)
- Bidirectional message translation between serial and Redis
- Initialization sequence for nRF52 module
- Graceful shutdown handling

**Architecture:**
- USOCK protocol layer for serial communication
- Data translation layer (CBOR encoding/decoding)
- System integration via Redis

#### ecu-service
Unified interface for electric motor control units via CAN bus.

**Key Features:**
- Support for multiple ECU types:
  - Bosch ECU
  - Votol ECU
- Real-time vehicle metrics monitoring:
  - Speed (km/h)
  - Motor RPM
  - Temperature
  - Voltage/Current
  - Odometer
  - Fault codes
- KERS (Kinetic Energy Recovery System) management
- CAN bus communication (default: can0)

**Redis Interface:**
- Writes: `engine-ecu` hash with motor control and telemetry data

#### keycard-service
NFC keycard authentication system.

**Key Features:**
- NFC card detection and authentication via PN7150 reader
- LED feedback via LP5662 controller:
  - Green: success
  - Red: failure
  - Yellow: authenticating
- Support for multiple card types:
  - Scooter cards
  - Factory cards
  - Activation cards
- Block list support for unauthorized cards
- Low power card detection (LPCD) support

**Configuration:**
- NFC device: `/dev/pn5xx_i2c2`
- LED device: `/dev/i2c-2`
- Authorized UIDs: `/etc/reunu-keycard/authorized_uids.txt`
- Master UIDs: `/etc/reunu-keycard/master_uids.txt`
- Block list: `/home/root/blocklist`

**Redis Interface:**
- Writes: `keycard` hash
- Publishes authentication events

#### modem-service
Cellular connectivity and GPS tracking via ModemManager.

**Key Features:**
- Real-time modem state monitoring
- Connectivity information tracking:
  - Connection status
  - Public and interface IP addresses
  - Signal quality (0-100%)
  - Access technology (2G/3G/4G/5G)
  - IMEI, IMSI, ICCID
- GPS location tracking via gpsd:
  - Position (latitude/longitude)
  - Altitude, speed, course
  - GPS state management (off/searching/fix-established/error)
- Modem recovery and health monitoring

**Configuration:**
- Network interface: `wwan0` (default)
- GPSD server: `localhost:2947`
- Polling interval: 5s (modem), 30s (internet check)

**Redis Interface:**
- Writes: `internet` hash (modem connectivity), `modem` hash (detailed modem state), `gps` hash (location)
- Publishes to: `internet`, `gps` channels

#### pm-service (Power Management)
System power state management and hibernation control.

**Key Features:**
- Power state management:
  - run, suspend, hibernate, hibernate-manual, hibernate-timer, reboot
- Vehicle and battery state monitoring
- Inhibitor management (block/delay power changes)
- Timer-based hibernation (default: 5 days)
- Modem power coordination during low-power transitions
- Unix domain socket for inhibitor connections
- Pre-suspend delay (default: 1m) and suspend-imminent delay (5s)

**Power State Priority:**
1. run (highest)
2. hibernate-manual
3. hibernate
4. hibernate-timer
5. suspend/reboot (lowest)

**Redis Interface:**
- Subscribes: `vehicle`, `battery:0`
- Publishes: `power-manager`, `power-manager:busy-services`
- Commands from: `scooter:power` (run/suspend/hibernate/reboot)
- Commands to: `scooter:modem` (disable)

#### settings-service
Settings synchronization between Redis and persistent storage.

**Key Features:**
- Bidirectional sync between Redis and `/data/settings.toml`
- Automatic APN management:
  - Updates `/etc/NetworkManager/system-connections/wwan.nmconnection`
- WireGuard connection management:
  - Deletes existing WireGuard connections on startup
  - Imports all `*.conf` files from `/data/wireguard/` after 120s delay
- Startup sync: reads TOML and populates Redis
- Empty config handling: flushes Redis if TOML is empty

**TOML Structure:**
```toml
[scooter]
speed_limit = "25"
mode = "eco"

[cellular]
apn = "internet.provider.com"
```

**Redis Interface:**
- Reads/Writes: `settings` hash with section-prefixed keys
  - Example: `scooter.speed_limit`, `cellular.apn`

#### vehicle-service
Core vehicle state machine and hardware control.

**Key Features:**
- Real-time vehicle state management
- Hardware I/O control via GPIO
- 8-channel PWM LED control system:
  - Headlight, front ring, brake light
  - 4x blinker channels (front/rear left/right)
  - Number plate lighting
- Handlebar locking mechanism
- Blinker control system
- Seat box locking mechanism
- Horn control
- Safety state transitions
- Key card authentication integration

**LED Channel Modes:**
- **Adaptive Mode**: Smooth brightness transitions (channels 0,1,2,5)
- **Active/Inactive Mode**: Precise on/off control for blinkers (channels 3,4,6,7)

**Redis Interface:**
- Writes: `vehicle` hash
- Reads: `battery:*`, `dashboard`, `keycard`
- Consumes commands from: `scooter:state`, `scooter:seatbox`, `scooter:horn`, `scooter:blinker`

### Dashboard Services (DBC)

#### dbc-backlight-service
Adaptive backlight control based on ambient light.

**Key Features:**
- 5-level discrete state machine with hysteresis
- Prevents oscillation between brightness levels
- Fully configurable brightness values and thresholds
- States: VERY_LOW (9350) → LOW (9500) → MID (9700) → HIGH (9950) → VERY_HIGH (10240)
- Hysteresis gaps prevent rapid state changes (3-10 lux gaps)

**Configuration:**
- Backlight path: `/sys/class/backlight/backlight/brightness`
- Polling interval: 1s
- Hysteresis threshold: 512 (minimum change to trigger Redis update)

**Redis Interface:**
- Reads: `dashboard brightness` (illuminance in lux)
- Writes: `dashboard backlight` (brightness value)

#### dbc-illumination-service
OPT3001 ambient light sensor monitoring.

**Key Features:**
- Real-time illumination sensor monitoring
- Configurable sampling and averaging (default: 3 samples with 100ms delay)
- Polling interval: 5s
- Sensor path: `/sys/bus/iio/devices/iio:device0/in_illuminance_input`

**Redis Interface:**
- Writes: `dashboard illumination` (current lux value)
- Publishes to: `dashboard` channel

### Update and Version Services

#### update-service
Over-the-air (OTA) update management via Mender.

**Key Features:**
- Component-specific instances (MDB, DBC)
- GitHub Releases API integration for update discovery
- Update channels: stable, testing, nightly
- Power management integration with inhibitor client
- Controlled reboots based on vehicle state:
  - MDB: only in stand-by mode after 3 minutes
  - DBC: on next natural power-on
- Startup commit check for pending updates
- Dry-run mode for testing
- Full and delta update methods

**Configuration:**
- Default check interval: 6h
- GitHub Releases URL: configurable
- Redis-based runtime configuration

**Redis Interface:**
- Writes: `ota` hash with status keys per component:
  - `status:{component}` (idle/downloading/installing/rebooting/error)
  - `update-version:{component}`
  - `download-progress:{component}` (0-100%)
  - `download-bytes:{component}`
  - `download-total:{component}`
  - `error:{component}`, `error-message:{component}`
- Commands from: `scooter:update` (check-now)
- Settings: `updates.{component}.*` (channel, check-interval, dry-run, method)

#### version-service
System version information tracking.

**Key Features:**
- Reads OS release information from `/etc/os-release`
- Stores in Redis with lowercase keys
- One-shot systemd service (runs after network available)
- Separate instances for MDB and DBC

**Redis Interface:**
- Writes: `version:mdb` or `version:dbc` hash with OS release fields

### Communication Services

#### teal-nrf52-service
UART communication layer for nRF52 module.

**Key Features:**
- Frame-based protocol with sync bytes (0xF6, 0xD9)
- CRC16-CCITT validation (header and payload)
- Event-driven architecture for message handling
- Power management state support (standby, hibernation)
- UART configuration: 115200 baud, 8N1

**Frame Structure:**
```
+--------+--------+---------+-------------+------------+-------------+
| Sync 1 | Sync 2 | Frame ID| Payload Len | Header CRC | Payload CRC |
|  0xF6  |  0xD9  |  1 byte | 2 bytes BE  | 2 bytes    | 2 bytes     |
+--------+--------+---------+-------------+------------+-------------+
```

**Common Frame IDs:**
- Commands: 0x01 (Ping), 0x02 (Get Battery), 0x03 (Set Power), 0x04 (Get Info)
- Responses: 0x81 (Ping), 0x82 (Battery), 0x83 (Power), 0x84 (Info)
- Events: 0x90 (Battery), 0x91 (Power), 0x92 (Bluetooth)

## Service Communication Patterns

### Event Publishing
Services publish events to Redis channels when state changes:
- `PUBLISH <hash-name> <field>` notifies subscribers
- Individual fields publish separately (e.g., `PUBLISH vehicle state`)

### Command Lists
Producer-consumer pattern using LPUSH/BRPOP:
- **Producers**: Push commands to `scooter:*` lists
- **Consumers**: Block-pop from specific lists
- Example: `LPUSH scooter:state lock` → `BRPOP scooter:state`

### State Storage
Services store state in Redis hashes:
- Each service writes only to its own hashes
- Services read from other services' hashes as needed
- Example: `HSET vehicle state ready-to-drive`

## Key Service Relationships

- **battery-service** is independent - monitors batteries via NFC, writes to `battery:0/1`
- **bluetooth-service** reads from `battery:*` and `vehicle` but doesn't write to them
- **vehicle-service** reads from `battery:*`, `dashboard`, `keycard` but doesn't write to them
- **Power management** fields in `power-manager` written by both `pm-service` and `bluetooth-service`

## Critical Path for "Ready to Drive"

1. nRF52840 powers on system (brake lever or other wakeup)
2. `battery-service` detects batteries via NFC
3. `keycard-service` authenticates user
4. `vehicle-service` transitions to ready-to-drive
5. Dashboard UI displays status

## Power Management Flow

1. `vehicle-service` requests shutdown
2. `pm-service` manages suspend/hibernate
3. nRF52 controls power mux
4. System enters low-power state

## Service Lifecycle

### Startup
1. Connect to Redis (typically 192.168.7.1:6379)
2. Initialize hardware interfaces
3. Write initial state to Redis hash
4. Start command list loops (BRPOP) if applicable
5. Publish initial state update

### Runtime
- Poll hardware at service-specific intervals
- Update Redis hash fields on state changes
- Publish to Redis channel on updates
- Process commands from Redis lists

### Shutdown
- Cleanup handled by systemd
- No graceful shutdown protocol observed

## Configuration Management

All services are managed by systemd:
- Service files in `/etc/systemd/system/`
- Started via `systemctl start <service>`
- Logs via `journalctl -u <service>`

## LibreScoot vs unu Services Mapping

| LibreScoot Service | Replaces unu Service | Notes |
|--------------------|---------------------|-------|
| alarm-service | (new feature) | Motion-based alarm not in original unu |
| battery-service | unu-battery | Enhanced with more configuration options |
| bluetooth-service | unu-bluetooth | USOCK protocol implementation |
| dbc-backlight-service | (dashboard component) | Separate service for adaptive backlight |
| dbc-illumination-service | (dashboard component) | OPT3001 sensor monitoring |
| ecu-service | unu-engine-ecu | Added Votol ECU support |
| keycard-service | unu-keycard | Enhanced with block list support |
| modem-service | modem-service | Enhanced GPS integration via gpsd and multi-strategy recovery |
| pm-service | unu-pm | Enhanced with inhibitor management |
| settings-service | (new feature) | TOML-based persistent configuration |
| vehicle-service | unu-vehicle | Core vehicle state machine |
| update-service | unu-activation (partial) | Component-specific OTA updates |
| version-service | (new feature) | Version tracking per component |
| teal-nrf52-service | (nRF communication) | Low-level UART protocol handler |

## License

LibreScoot services are licensed under:
- CC BY-NC-SA 4.0 (most services)
- AGPL 3.0 (update-service)
- MIT (teal-nrf52-service)

See individual service repositories for specific license information.
