# librescoot-bluetooth (bluetooth-service)

## Description

The Bluetooth service provides the BLE (Bluetooth Low Energy) interface for the scooter and manages communication with the nRF52840 chip via UART. It acts as a communication bridge between the nRF52 BLE chip and Redis-based backend system, handling bidirectional translation of messages. The service exposes BLE GATT characteristics for remote control and monitoring (via nRF firmware), processes UART messages from the nRF chip, and publishes battery/vehicle state updates to Redis.

## Command-Line Options

```
--serial string        Serial device path (default "/dev/ttymxc1")
--baud int            Serial baud rate (default 115200)
--redis-addr string   Redis server address (default "localhost:6379")
--redis-pass string   Redis password (default "")
--redis-db int        Redis database number (default 0)
--log-level int       Log level (0=none, 1=error, 2=warning, 3=info, 4=debug) (default 3)
--firmware-dir string  Directory containing nRF firmware files (default "/usr/share/nrf-fw")
--auto-update          Automatically update nRF firmware on startup if newer version available (default true)
```

## Redis Operations

### Hash: `ble`

**Fields written:**
- `mac-address` - Bluetooth MAC address (received from nRF52)
- `connection-status` - BLE connection status string
- `pin-code` - Temporary pairing PIN code (when pairing is active)

**Published channel:** `ble` (when pin-code field changes)

### Hash: `cb-battery`

**Fields written:**
- `charge` - Charge level (0-100%)
- `current` - Current in μA
- `remaining-capacity` - Remaining capacity in μWh
- `full-capacity` - Full capacity in μWh
- `cell-voltage` - Cell voltage in μV
- `temperature` - Temperature in °C
- `cycle-count` - Battery cycle count
- `time-to-empty` - Time until battery is empty in seconds
- `time-to-full` - Time until battery is full in seconds
- `state-of-health` - Battery health percentage (0-100)
- `part-number` - Part identification string
- `serial-number` - Serial number
- `unique-id` - Unique identifier
- `present` - Battery presence ("true", "false")
- `charge-status` - Charging status ("not-charging", "charging")

**Published channel:** None (fields are written but not published by this service)

### Hash: `aux-battery`

**Fields written:**
- `voltage` - Voltage in mV
- `charge` - Charge level in 25% steps (0, 25, 50, 75, 100)
- `charge-status` - Charging status ("absorption-charge", "not-charging", "float-charge", "bulk-charge")
- `data-stream-enable` - Data streaming enable flag ("0", "1")

**Published channel:** None (fields are written but not published by this service)

### Hash: `power-manager`

**Fields written:**
- `nrf-reset-count` - Reset count from nRF52
- `nrf-reset-reason` - Nordic RESETREAS register value (integer)

**Published channel:** `power-manager` (when nrf-reset-reason changes)

### Hash: `power-mux`

**Fields written:**
- `selected-input` - Selected power input source ("cb", "aux")

**Published channel:** `power-mux`

### Hash: `system`

**Fields written:**
- `nrf-fw-version` - nRF52 firmware version string (received from nRF52 during initialization)

**Fields read (not written by this service):**
- `mdb-version` - MDB firmware version string (forwarded to nRF52 when it changes)

### Hash: `engine-ecu`

**Fields written:**
- `odometer` - Odometer/mileage value in meters (received from nRF52)

### Hash: `navigation`

**Fields written:**
- `latitude` - Navigation destination latitude (from extended command `nav:dest`)
- `longitude` - Navigation destination longitude (from extended command `nav:dest`)
- `destination` - Legacy combined coordinates "lat,lon" (from extended command `nav:dest` or BLE event `navi:start`)
- `address` - Destination name/address (from extended command `nav:dest lat,lon,name`)

**Fields cleared:** `nav:clear` sets all navigation fields (latitude, longitude, destination, address, timestamp) to empty strings (does not HDEL).

**Published channel:** `navigation` (when fields change)

### Hash: `settings`

**Fields written:**
- `cellular.apn` - Cellular APN (from extended command `config:apn` or legacy BLE event `apn <value>`)
- `hibernation-timer` - Hibernation timeout in seconds (from extended command `config:hibernate-timer`)
- `updates.mdb.channel` - MDB OTA update channel (from extended command `config:update-channel`)
- `updates.dbc.channel` - DBC OTA update channel (from extended command `config:update-channel`)
- `dashboard.saved-locations.<id>.latitude` - Saved location lat (from `nav:fav:add`)
- `dashboard.saved-locations.<id>.longitude` - Saved location lon (from `nav:fav:add`)
- `dashboard.saved-locations.<id>.label` - Saved location name (from `nav:fav:add`)

**Published channel:** `settings` (when fields change)

### Hash: `usb`

**Fields written:**
- `mode` - USB mode ("ums" or "normal", from extended command `usb:ums`/`usb:normal` or legacy BLE events)

**Published channel:** `usb` (when mode field changes)

### Hash: `scooter` (written)

**Fields written:**
- `temperature` - External temperature in tenths of °C (from nRF vehicle state message)

**Published channel:** `scooter`

### Hash: `dashboard`

**Fields read (not written):**
- `maps-available` - Offline display maps installed (set by scootui-qt, queried via `status:maps-available`)
- `navigation-available` - Routing engine available (set by scootui-qt, queried via `status:navigation-available`)

### Hashes read (not written)

The service reads but does not write to these hashes:
- `battery:0` - Reads battery state and charge
- `battery:1` - Reads battery state and charge
- `vehicle` - Reads vehicle state for nRF synchronization
- `power-manager` - Reads power state

### Lists consumed (BRPOP)

The service consumes commands from:
- `scooter:bluetooth` - BLE management commands with indefinite blocking

**Commands recognized:**
- `advertising-start-with-whitelisting` - Start advertising with whitelist
- `advertising-restart-no-whitelisting` - Restart advertising without whitelist
- `advertising-stop` - Stop BLE advertising
- `delete-bond` - Delete current bond
- `delete-all-bonds` - Delete all bonded devices
- `remove` - Remove pairing PIN from display
- `ltc-enable` - Enable LTC4020 aux charger (safe mode)
- `ltc-disable` - Disable LTC4020 aux charger
- `ltc-force-enable` - Force-enable LTC4020 aux charger (bypasses safety check)
- `ltc-force-disable` - Force-disable LTC4020 aux charger
- `ltc-status` - Query LTC4020 charger status
- `firmware-update` - Trigger immediate nRF firmware update

### Lists produced (LPUSH)

The service writes requests to:
- `scooter:state` - State change requests ("lock", "unlock", "lock-hibernate")
- `scooter:power` - Power requests ("hibernate", "hibernate-manual", "reboot")
- `scooter:seatbox` - Seatbox commands ("open")
- `scooter:blinker` - Blinker commands ("left", "right", "both", "off")
- `scooter:keycard` - Keycard management commands ("list", "count", "add:<uid>", "remove:<uid>")
- `scooter:alarm` - Alarm commands ("enable", "disable", "arm", "disarm", "start:<seconds>", "stop")

These are triggered by BLE characteristic writes received from the nRF52 (BLE events or extended commands).

### Pub/Sub published

- `bmx:interrupt` - Accelerometer wake-up events from nRF ("wake-suspend", "wake-hibernation")

## Hardware Interfaces

### UART Interface

- **Device:** Configurable via `--serial` option (default: `/dev/ttymxc1`)
- **Baud rate:** Configurable via `--baud` option (default: 115200)
- **Protocol:** Custom "USOCK" protocol with CBOR payloads
- **Connected to:** nRF52840 BLE chip

#### USOCK Protocol Details

The USOCK protocol is a frame-based protocol for reliable serial communication:

**Frame Structure:**
- Sync Byte 1: `0xF6`
- Sync Byte 2: `0xD9`
- Frame ID: 1 byte (lower byte of message type)
- Payload Length: 2 bytes (little-endian, max 1024 bytes)
- Header CRC: 2 bytes (CRC-16/ARC over sync+frameID+length)
- Payload: Variable length CBOR-encoded data
- Payload CRC: 2 bytes (CRC-16/ARC over payload)

**CBOR Message Format:**
Messages are CBOR-encoded maps with structure:
```
{messageType: {absoluteSubtype: value}}
```

Where:
- `messageType` is a 16-bit message category (e.g., 0xA000 for BLE version)
- `absoluteSubtype` is `messageType + relativeSubtype`
- `value` can be integer, string, or array

**CRC Calculation:**
- Algorithm: CRC-16/ARC (also known as CRC-16/IBM)
- Polynomial: 0x8005
- Initial value: 0x0000
- Reflected input/output

See [nRF UART Protocol](../nrf/UART.md) for message types and protocol details.

### BLE Interface (via nRF52840)

The service does not directly manage BLE - this is handled by the nRF52840 firmware. The bluetooth-service only communicates with the nRF52 via UART to:
- Receive BLE connection events and characteristic writes
- Send state updates to be exposed via BLE characteristics
- Control advertising and bonding

BLE services and characteristics are defined in the nRF52 firmware.

## Configuration

### Systemd Unit

- **Unit file:** `/etc/systemd/system/bluetooth-service.service` (or `/usr/lib/systemd/system/bluetooth-service.service`)
- **Type:** idle (delayed until other services have started)
- **Requires:** redis.service
- **After:** redis.service, librescoot-vehicle.service, librescoot-alarm.service
- **Started by:** systemd at boot
- **Restart policy:** Always

## Observable Behavior

### Startup Sequence

1. Parses command-line flags
2. Connects to Redis server
3. Opens UART connection to nRF52840 (USOCK protocol initialization)
4. Starts Redis command watcher goroutine (BRPOP on `scooter:bluetooth`)
5. Subscribes to Redis pub/sub channels for state updates
6. Sends nRF52 initialization sequence:
   - Disable data streaming
   - Request BLE firmware version
   - Request BLE MAC address
   - Enable data streaming
   - Sync data stream
   - Start advertising (no whitelist)
7. Sends initial state updates to nRF52:
   - Vehicle state (locked/unlocked)
   - Seatbox lock state
   - Handlebar lock state
   - Mileage (odometer)
   - Firmware version
   - Battery states (both slots: present, active, cycle count, charge)
   - Power management state
8. Enters main loop handling UART messages and Redis updates

### Runtime Behavior

- **UART message processing:** Continuous reception of USOCK frames with CBOR-encoded payloads from nRF52
- **Battery updates:** Writes CB battery and auxiliary battery data to Redis hashes
- **Vehicle state synchronization:** Monitors Redis pub/sub channels and forwards state changes to nRF52
- **BLE events:** Receives BLE characteristic writes from nRF52 as event strings and converts to Redis LPUSH commands
- **Command watching:** Blocks on `scooter:bluetooth` list waiting for BLE management commands
- **Bidirectional translation:** Redis → USOCK/CBOR for state updates; USOCK/CBOR → Redis for sensor data and events

### Message Flow

```
BLE App → nRF52840 → UART/USOCK/CBOR → bluetooth-service → Redis → other services
other services → Redis (pub/sub) → bluetooth-service → UART/USOCK/CBOR → nRF52840 → BLE App
```

**Inbound (from BLE to system):**
1. User interacts with BLE app
2. nRF52 receives BLE characteristic write
3. nRF52 sends USOCK frame with CBOR-encoded event string to bluetooth-service
4. bluetooth-service parses event and performs LPUSH to appropriate Redis list
5. Other services consume from Redis lists and perform actions

**Outbound (from system to BLE):**
1. Services update Redis hash fields
2. Redis publishes change notification on pub/sub channel
3. bluetooth-service receives pub/sub message
4. bluetooth-service reads updated value from Redis
5. bluetooth-service encodes as CBOR and sends USOCK frame to nRF52
6. nRF52 updates BLE characteristic value
7. BLE app receives notification of characteristic change

### UART Message Types Processed

The service handles various USOCK message types from the nRF52. See [nRF UART Protocol](../nrf/UART.md) for complete list.

**Key message types received:**
- `0x0000` - Generic events (BLE characteristic writes as event strings)
- `0x0020` - Vehicle state updates (acknowledgments)
- `0x0040` - Auxiliary battery data
- `0x0060` - CB battery detailed information (MAX1730X fuel gauge data)
- `0x0100` - Power mux status
- `0x0120` - LTC4020 aux charger control (bidirectional)
- `0x0200` - Accelerometer wake-up events (suspend/hibernation)
- `0x0400` - Extended commands (string commands from phone app)
- `0x0800` - Power management (hibernation requests from nRF)
- `0x00C0` - Data stream control acknowledgments
- `0x00E0` - Battery slot status (slot 1 and 2)
- `0xA000` - BLE firmware version
- `0xA020` - BLE reset information (reason and count)
- `0xA040` - Scooter info (mileage, firmware version, system time from nRF)
- `0xA080` - BLE parameters (MAC address, PIN code, connection status)
- `0xAA00` - BLE command acknowledgments

**Key message types sent:**
- `0x0020` - Vehicle state (locked/unlocked, seatbox, handlebar)
- `0x0400` - Extended response (response string to phone app, up to 512 bytes)
- `0x0800` - Power management state updates
- `0x00C0` - Data stream enable/disable/sync
- `0x00E0` - Battery status (presence, charge, cycle count for both slots)
- `0x0120` - LTC4020 aux charger control (bidirectional)
- `0xA000` - Request BLE firmware version
- `0xA040` - Scooter info (firmware version, mileage, navigation active, UMS status)
- `0xA080` - Request BLE MAC address, remove PIN
- `0xAA00` - BLE commands (advertising control, bond management)

### BLE Event Strings Processed

Event strings received from nRF52 (message type 0x0000) are parsed and converted to Redis operations:

**Vehicle control:**
- `"scooter:state lock"` → `LPUSH scooter:state lock`
- `"scooter:state unlock"` → `LPUSH scooter:state unlock`

**Seatbox:**
- `"scooter:seatbox open"` → `LPUSH scooter:seatbox open`

**Blinker control:**
- `"scooter:blinker left"` → `LPUSH scooter:blinker left`
- `"scooter:blinker right"` → `LPUSH scooter:blinker right`
- `"scooter:blinker both"` → `LPUSH scooter:blinker both`
- `"scooter:blinker off"` → `LPUSH scooter:blinker off`

**Navigation:**
- `"navi:start <coords>"` → `HSET navigation destination <coords>` + publish

**Settings:**
- `"apn <value>"` → `HSET settings cellular.apn <value>` + publish

**USB mode:**
- `"usb:ums"` → `HSET usb mode ums` + publish
- `"usb:normal"` → `HSET usb mode normal` + publish

### Extended Commands (message type 0x0400)

Extended commands arrive as string payloads via the EXTENDED_COMMAND BLE characteristic (0x0401). The bluetooth-service routes them by prefix:

**Navigation:**
- `nav:dest lat,lon[,name]` → sets `navigation` hash fields (latitude, longitude, destination, address)
- `nav:clear` → deletes all `navigation` hash fields
- `nav:fav:add lat,lon,name` → adds to `settings:dashboard.saved-locations.<id>.*`
- `nav:fav:delete <id>` → removes saved location
- `nav:fav:navigate <id>` → sets navigation destination from saved location
- `nav:fav:list` → responds with count + one notification per saved location

**USB mode:**
- `usb:ums` → `HSET usb mode ums`
- `usb:normal` → `HSET usb mode normal`

**Keycard management:**
- `keycard:list`, `keycard:count`, `keycard:add:<uid>`, `keycard:remove:<uid>` → forwarded to `scooter:keycard` Redis list; response returned asynchronously via `keycard` hash `command-result` field

**Time:**
- `time:set <unix_timestamp>` → sets system clock via `timedatectl set-time`

**Configuration:**
- `config:apn <value>` → `HSET settings cellular.apn <value>`
- `config:hibernate-timer <seconds>` → `HSET settings hibernation-timer <value>`
- `config:update-channel <stable|testing|nightly>` → sets `settings:updates.mdb.channel` and `settings:updates.dbc.channel`
- `config:auto-standby-seconds <seconds>` → `HSET settings scooter.auto-standby-seconds <value>` (auto-lock idle timeout when parked, 0=disabled, 0-3600; last 60s shown as a cancellable countdown on the dashboard)

**Alarm:**
- `alarm:enable` → `LPUSH scooter:alarm enable`
- `alarm:disable` → `LPUSH scooter:alarm disable`
- `alarm:arm` → `LPUSH scooter:alarm arm`
- `alarm:disarm` → `LPUSH scooter:alarm disarm`
- `alarm:start` → `LPUSH scooter:alarm start` (duration default from settings)
- `alarm:start:<N>` → `LPUSH scooter:alarm start:<N>`
- `alarm:stop` → `LPUSH scooter:alarm stop`

The alarm-service processes the command and the response (`alarm:ok`) is returned via EXTENDED_RESPONSE (0x0402).

**LTC4020 aux charger control:**
- `ltc:enable` — safe-enable LTC4020 charger (rejected if unsafe)
- `ltc:disable` — disable LTC4020 charger
- `ltc:force-enable` — force-enable LTC4020 charger (bypasses safety check)
- `ltc:force-disable` — force-disable LTC4020 charger
- `ltc:status` — query charger state; responds with `ltc:status:on` or `ltc:status:off`

Response codes: `ltc:ok` (success), `ltc:error:unsafe` (rejected as unsafe), `ltc:error:invalid` (invalid state).

**Status queries (read-only):**
- `status:maps-available` → reads `dashboard:maps-available` (set by scootui-qt)
- `status:navigation-available` → reads `dashboard:navigation-available` (set by scootui-qt)

Responses are sent back via EXTENDED_RESPONSE (0x0402) as string notifications to the phone app.

### Accelerometer Wake-up Events

The service handles accelerometer wake-up messages from the nRF (message type 0x0200):

- **Suspend wake-up (0x0201):** Published to Redis `bmx:interrupt` as `"wake-suspend"`. The nRF sends this immediately when movement is detected during iMX suspend.
- **Hibernation wake-up (0x0202):** Published to Redis `bmx:interrupt` as `"wake-hibernation"`. The nRF sends this after the VERSION handshake on the next boot, if the wake-up from hibernation was caused by accelerometer movement.

The alarm-service subscribes to `bmx:interrupt` to trigger alarm escalation.

### Power Management

The service handles hibernation requests from the nRF52:

**Automatic hibernation:**
- nRF sends hibernation request (type=automatic)
- Service forwards: `LPUSH scooter:power hibernate`

**Manual hibernation:**
- nRF sends hibernation request (type=manual)
- If vehicle state is "parked": `LPUSH scooter:state lock-hibernate`
- Otherwise: `LPUSH scooter:power hibernate-manual`

**Soft reboot:**
- nRF receives "reboot" from the BLE power control characteristic
- Service forwards: `LPUSH scooter:power reboot`
- pm-service triggers a Linux-only reboot (same path as post-OTA reboots)

**Hard reboot:**
- nRF receives "hard-reboot" from the BLE power control characteristic
- nRF notifies iMX that a power cycle is imminent, then controls the power rails directly
- iMX reboots automatically when power is restored

When power-manager enters hibernation state, the service:
1. Disables data streaming to nRF52
2. Sends hibernation level request (L1 or L2)
3. Sends power management state update to nRF52

## Log Output

The service logs to journald. Common log patterns include:
- UART frame parsing errors
- CBOR decoding errors
- Redis connection status
- BLE command processing

Use `journalctl -u bluetooth-service` to view logs.

## Dependencies

- **nRF52840 firmware** - Must be running compatible firmware with USOCK/CBOR protocol support
- **Redis server** - Must be accessible at configured address (default: localhost:6379)
- **UART device** - nRF52840 must be accessible via serial device (default: /dev/ttymxc1)
- **Go runtime** - Compiled as static binary, no runtime dependencies

## CB Battery Monitoring

The service receives detailed battery information from the nRF52 (which reads from MAX1730X fuel gauge) and processes alerts and faults:

### CB Battery Alert Conditions (Status Register)

Written to `cb-battery:alert` hash field `alert`:
- Minimum Current Alert Threshold Exceeded
- Maximum Current Alert Threshold Exceeded
- Minimum Voltage Alert Threshold Exceeded
- Maximum Voltage Alert Threshold Exceeded
- Minimum Temperature Alert Threshold Exceeded
- Maximum Temperature Alert Threshold Exceeded
- Minimum SOC Alert Threshold Exceeded
- Maximum SOC Alert Threshold Exceeded

### CB Battery Fault Conditions

Written to `cb-battery:fault` hash field `fault`:

**From Protection Status Register:**
- Discharging fault (ODCP, UVP, TOOHOTD, DIEHOT)
- Charging fault (TOOCOLDC, OVP, OCCP, QOVFLW, TOOHOTC, FULL, DIEHOT)

**From Battery Status Register:**
- ChargeFET Failure-Short Detected
- DischargeFET Failure-Short Detected
- FET Failure open

Alerts and faults are cleared automatically when the condition is resolved (all relevant bits clear).

## Redis Pub/Sub Subscriptions

The service subscribes to these Redis channels to monitor for state changes:

- `vehicle` - Monitors for vehicle state, seatbox lock, and handlebar lock changes
- `battery:0` - Monitors for battery slot 1 state, presence, charge, and cycle count changes
- `battery:1` - Monitors for battery slot 2 state, presence, charge, and cycle count changes
- `power-manager` - Monitors for power management state changes
- `engine-ecu` - Monitors for odometer/mileage changes
- `system` - Monitors for MDB firmware version changes
- `ble` - Monitors for pin-code removal notifications
- `navigation` - Monitors for destination changes → sends navigation active status (0/1) to nRF
- `usb` - Monitors for USB mode changes → sends UMS status (0/1) to nRF
- `keycard` - Monitors for `command-result` field → relays response to phone via extended response

When a subscribed field changes, the service:
1. Receives the field name via pub/sub
2. Reads the updated value from the Redis hash
3. Encodes and sends the update to nRF52 via USOCK

## Related Documentation

- [Bluetooth Protocol](../bluetooth/README.md)
- [nRF UART Protocol](../nrf/UART.md)
- [nRF Power Management](../nrf/power-management.md)
- [Redis Operations](../redis/README.md)
