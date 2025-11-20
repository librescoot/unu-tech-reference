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
--ltc-toggle          Enable LTC4020 toggle on float/bulk charge
```

## Redis Operations

### Hash: `ble`

**Fields written:**
- `mac-address` - Bluetooth MAC address (received from nRF52)
- `nrf-fw-version` - nRF52 firmware version string
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
- `mdb-version` - MDB firmware version string (read from this hash, forwarded to nRF52)

### Hash: `engine-ecu`

**Fields written:**
- `odometer` - Odometer/mileage value in km (received from nRF52)

### Hash: `navigation`

**Fields written:**
- `destination` - Navigation destination coordinates (from BLE event "navi:start <coords>")

**Published channel:** `navigation` (when destination field changes)

### Hash: `settings`

**Fields written:**
- `cellular.apn` - Cellular APN configuration (from BLE event "apn <value>")

**Published channel:** `settings` (when cellular.apn field changes)

### Hash: `usb`

**Fields written:**
- `mode` - USB mode ("ums" or "normal", from BLE events "usb:ums" or "usb:normal")

**Published channel:** `usb` (when mode field changes)

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

### Lists produced (LPUSH)

The service writes requests to:
- `scooter:state` - State change requests ("lock", "unlock", "lock-hibernate")
- `scooter:power` - Power requests ("hibernate", "hibernate-manual")
- `scooter:seatbox` - Seatbox commands ("open")
- `scooter:blinker` - Blinker commands ("left", "right", "both", "off")

These are triggered by BLE characteristic writes received from the nRF52 (BLE events with format "scooter:command value").

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
- **Started by:** systemd at boot
- **Restart policy:** Always (on-failure)

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
- `0x0008` - Power management (hibernation requests from nRF)
- `0x0020` - Vehicle state updates (acknowledgments)
- `0x0040` - Scooter info (mileage, firmware version from nRF)
- `0x0041` - Auxiliary battery data
- `0x0060` - CB battery detailed information (MAX1730X fuel gauge data)
- `0x0080` - Power mux status
- `0x00C0` - Data stream control acknowledgments
- `0x00E0` - Battery slot status (slot 1 and 2)
- `0xA000` - BLE firmware version
- `0xA021` - BLE reset information (reason and count)
- `0xA080` - BLE parameters (MAC address, PIN code, connection status)
- `0xAA00` - BLE command acknowledgments

**Key message types sent:**
- `0x0008` - Power management state updates
- `0x0020` - Vehicle state (locked/unlocked, seatbox, handlebar)
- `0x0040` - Scooter info (firmware version, mileage)
- `0x00C0` - Data stream enable/disable/sync
- `0x00E0` - Battery status (presence, charge, cycle count for both slots)
- `0xA000` - Request BLE firmware version
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

### Power Management

The service handles hibernation requests from the nRF52:

**Automatic hibernation:**
- nRF sends hibernation request (type=automatic)
- Service forwards: `LPUSH scooter:power hibernate`

**Manual hibernation:**
- nRF sends hibernation request (type=manual)
- If vehicle state is "parked": `LPUSH scooter:state lock-hibernate`
- Otherwise: `LPUSH scooter:power hibernate-manual`

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

When a subscribed field changes, the service:
1. Receives the field name via pub/sub
2. Reads the updated value from the Redis hash
3. Encodes and sends the update to nRF52 via USOCK

## Related Documentation

- [Bluetooth Protocol](../bluetooth/README.md)
- [nRF UART Protocol](../nrf/UART.md)
- [nRF Power Management](../nrf/power-management.md)
- [Redis Operations](../redis/README.md)
