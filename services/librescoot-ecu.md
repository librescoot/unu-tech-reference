# librescoot-ecu (ecu-service)

## Description

The ECU service (`ecu-service`) provides a unified interface for communicating with electric scooter motor controllers (ECUs) via CAN bus. It supports both Bosch and Votol ECU types, monitoring motor speed, RPM, voltage, current, temperature, throttle state, KERS (kinetic energy recovery system) status, odometer, power metrics, and fault codes. The service publishes this data to Redis for consumption by the dashboard and other services, and manages KERS functionality based on battery temperature and vehicle state.

## Command-Line Options

```
Usage of ecu-service:
  -can_device string
        CAN device name (default "can0")
  -ecu_type string
        ECU type (bosch or votol) (default "bosch")
  -help
        Print help
  -log int
        Log level (0=NONE, 1=ERROR, 2=WARN, 3=INFO, 4=DEBUG) (default 3)
  -redis_port int
        Redis server port (default 6379)
  -redis_server string
        Redis server address (default "127.0.0.1")
  -version
        Print version info
```

## Redis Operations

### Hash: `engine-ecu`

**Fields written:**
- `motor:voltage` - Motor voltage in mV
- `motor:current` - Motor current in mA (signed, negative during regenerative braking)
- `rpm` - Motor RPM
- `speed` - Vehicle speed in km/h (calibrated)
- `raw-speed` - Raw speed before calibration
- `throttle` - Throttle state ("on", "off")
- `temperature` - ECU temperature in °C
- `odometer` - Total distance traveled in meters
- `kers` - KERS (regenerative braking) state ("on", "off")
- `power:instant-mw` - Instantaneous power in mW
- `power:consumed-mwh` - Cumulative energy consumed in mWh
- `power:recovered-mwh` - Cumulative energy recovered via regenerative braking in mWh
- `kers-reason-off` - Reason KERS is disabled ("none", "cold", "hot")

**Published channels:**
- `engine-ecu throttle` - Published when throttle state changes
- `engine-ecu kers` - Published when KERS state changes
- `engine-ecu odometer` - Published when odometer updates
- `engine-ecu kers-reason-off` - Published when KERS disable reason changes

### Pub/Sub Subscriptions

The service subscribes to the following channels to monitor system state:

- `vehicle` - Listens for vehicle state changes (e.g., "ready-to-drive")
- `battery:0` - Monitors battery 0 state and temperature
- `battery:1` - Monitors battery 1 state and temperature

### Redis Operations for Fault Management

**Set:** `engine-ecu:fault`
- Contains active fault codes (SADD when fault occurs, SREM when cleared)

**Stream:** `events:faults`
- Publishes fault events with group="engine-ecu", code (positive when set, negative when cleared), and description
- Limited to 1000 entries (MAXLEN)

**Published channel for faults:** `engine-ecu` with payload "fault"

## Hardware Interfaces

### CAN Bus

- **CAN device:** Configurable via `-can_device` option (default: `can0`)
- **Interface type:** SocketCAN
- **Connected to:** Motor controller/ECU (Bosch or Votol)

The service uses standard Linux SocketCAN to communicate with the motor controller.

### ECU Communication

The service supports two ECU types, selectable via the `-ecu_type` flag:

#### Bosch ECU

**CAN Message IDs:**
- `0x7E0` - Status1: Voltage, current, RPM, speed, throttle state
- `0x7E1` - Status2: Temperature, fault codes
- `0x7E2` - Status3: Odometer
- `0x7E3` - Status4: KERS enabled status
- `0x4E0` - Control message (sent to ECU for KERS control)
- `0x4E2` - EBS settings (sent to ECU for KERS voltage/current)

**Speed Calibration:**
- Applies calibration factor: 1.03
- Applies tolerance factor: 1.155556
- Formula: `speed = raw_speed * 1.03 * 1.155556`

**Odometer Calibration:**
- Odometer values multiplied by 1.07 and converted from 0.1km to meters

**KERS Control:**
- Sends voltage/current settings (56V, 10A) via CAN ID 0x4E2
- Sends enable/disable commands via CAN ID 0x4E0
- Supports gear mode and boost mode flags

#### Votol ECU

**CAN Message IDs:**
- `0x9026105A` - Display to controller (speed, odometer)
- `0x90261022` - Controller to display (RPM, voltage, current)
- `0x90261023` - Controller status (temperature, fault codes)

**Speed Calculation:**
- Speed calculated from RPM: `speed = rpm * 0.0783744`
- No separate speed calibration applied

**KERS Control:**
- KERS control not yet implemented for Votol (TODO in code)
- State tracking only, no active control

**Throttle State:**
- Votol ECU does not report throttle state in current implementation
- Throttle field always reports "off"

## Configuration

### Systemd Unit

- **Unit file:** `/usr/lib/systemd/system/ecu-service.service`
- **Started by:** systemd at boot
- **Restart policy:** Always

### CAN Bus Setup

The CAN interface must be configured before the service starts:
```bash
ip link set can0 type can bitrate 250000
ip link set can0 up
```

This is typically done by a systemd service or udev rule.

## Observable Behavior

### Startup Sequence

1. Parse command-line options (ECU type, CAN device, Redis settings, log level)
2. Validate ECU type (must be "bosch" or "votol")
3. Connect to Redis server with timeout (5s connection timeout)
4. Initialize components:
   - Battery monitor (tracks 2 battery slots)
   - IPC TX (Redis publisher)
   - Write default state to Redis (all zeros/off)
   - Start Redis health check goroutine (30s interval)
   - KERS manager (with 1.5s ready-to-drive delay timer)
   - Diagnostics manager (fault tracking)
   - Initialize CAN bus interface
   - Create ECU instance (Bosch or Votol based on flag)
5. Set up IPC RX subscriptions:
   - Subscribe to `vehicle` channel
   - Subscribe to `battery:0` and `battery:1` channels
   - Read initial states from Redis
6. Register CAN frame handler
7. Start CAN message publishing loop (background goroutine)
8. Begin processing CAN frames and Redis subscriptions
9. Wait for SIGINT or SIGTERM to shut down

### Runtime Behavior

#### CAN Message Processing

- Continuously receives CAN frames from ECU
- Parses relevant CAN IDs for motor data
- Updates Redis hash on value changes
- Publishes to `engine-ecu` channel on updates

#### Speed Monitoring

- Speed reported in km/h
- Typical range: 0-45 km/h
- High update frequency (multiple times per second)
- Dashboard polls `engine-ecu:speed` when vehicle is ready-to-drive

#### KERS (Regenerative Braking)

The service manages KERS based on battery temperature and vehicle state:

- **KERS Enable Conditions:**
  - Active battery temperature is "ideal"
  - Vehicle is in "ready-to-drive" state
  - 1.5 second delay after vehicle becomes ready-to-drive
  - Vehicle is stopped (speed = 0)

- **KERS Disable Reasons (`kers-reason-off` values):**
  - `"none"` - KERS is enabled or should be enabled
  - `"cold"` - Active battery temperature is too cold
  - `"hot"` - Active battery temperature is too hot

- **Battery Temperature Monitoring:**
  - Monitors both battery slots (battery:0 and battery:1)
  - Uses temperature state of whichever battery is marked "active"
  - If no battery is active or both are active, KERS state is not updated

- **State Machine:**
  - Subscribes to `vehicle` channel for state changes
  - Subscribes to `battery:0` and `battery:1` for temperature updates
  - Updates KERS state only when vehicle is stopped
  - Applies 1.5s delay when transitioning to ready-to-drive state

#### Odometer

- Total distance in meters
- Monotonically increasing
- Persisted by ECU (survives power cycles)

#### Fault Detection

The service monitors ECU fault codes and manages them through Redis. Faults are specific to each ECU type:

**Common Faults (Both ECU Types):**
- Battery over-voltage / under-voltage
- Motor stalled
- Hall sensor abnormal
- Throttle abnormal
- Power-on self-check error
- Over-temperature
- Internal 15V abnormal

**Bosch-Specific Faults:**
- Motor short-circuit
- Motor open-circuit
- MOSFET check error
- Motor temperature protection
- Throttle active at power-up

**Votol-Specific Fault Mapping:**
- Fault codes are bit-mapped (0x01, 0x02, 0x04, etc.)
- Subset of common faults supported

**Fault Handling:**
- Active faults added to `engine-ecu:fault` set
- Fault events published to `events:faults` stream
- Notification published to `engine-ecu` channel with "fault" payload
- When fault clears, code is removed from set and negative code logged to stream

#### Power Metrics

The service calculates and tracks power consumption and recovery:

- **Instantaneous Power:** `power = (voltage_mV * current_mA) / 1000` (in mW)
- **Energy Integration:** Power integrated over time to calculate energy in mWh
- **Consumed Energy:** Tracked when power is positive (motor driving)
- **Recovered Energy:** Tracked when power is negative (regenerative braking)
- **Maximum Delta:** 5 second maximum between updates (prevents large accumulation when ECU is off)

## Log Output

The service logs to journald (or stdout when not running under systemd). Common log patterns:

- **Startup:**
  - Selected ECU type (Bosch or Votol)
  - Redis connection status
  - Component initialization (Battery, IPC TX/RX, KERS, Diagnostics, ECU)
  - Default Redis state written

- **Runtime:**
  - Vehicle state changes (ready-to-drive, etc.)
  - Battery state updates (active, temperature-state)
  - KERS state changes and reason updates
  - Fault code set/cleared events
  - CAN health check status
  - Redis connection issues

- **Detailed Logging (at INFO/DEBUG levels):**
  - Battery subscription messages
  - Vehicle subscription messages
  - KERS update decisions
  - Power metrics calculations

Use `journalctl -u ecu-service` to view logs.

## Dependencies

- **CAN device** - Must have configured SocketCAN interface (e.g., can0)
- **ECU/Motor controller** - Must be powered and responsive on CAN bus (Bosch or Votol)
- **Redis server** - At specified host:port (default: 127.0.0.1:6379)
- **Battery service** - For temperature state monitoring (publishes to battery:0 and battery:1)
- **Vehicle state manager** - For ready-to-drive state (publishes to vehicle channel)

## ECU Type Comparison

### Bosch vs Votol

| Feature | Bosch ECU | Votol ECU |
|---------|-----------|-----------|
| **CAN IDs** | Standard (0x7E0-0x7E3) | Extended (0x90261xxx) |
| **Speed Source** | Direct from ECU | Calculated from RPM |
| **Speed Calibration** | Yes (1.03 × 1.155556) | RPM-based (× 0.0783744) |
| **Throttle Reporting** | Yes (via Status1) | No (always "off") |
| **KERS Control** | Full (voltage, current, enable) | Not implemented (state only) |
| **Odometer** | Via Status3 (calibrated ×1.07) | Via Display message |
| **Fault Codes** | 32-bit code | 8-bit bitmask |
| **Voltage Scaling** | 10mV per bit | 100mV per bit |
| **Current Scaling** | 10mA per bit | 100mA per bit |
| **Endianness** | Big-endian | Little-endian |

### When to Use Each ECU Type

- Use `-ecu_type bosch` for:
  - Bosch motor controllers (common in Unu scooters)
  - When KERS control via CAN is required
  - When throttle state monitoring is needed

- Use `-ecu_type votol` for:
  - Votol motor controllers
  - When only monitoring is needed (no KERS control)
  - Systems where RPM-based speed calculation is preferred

## Related Documentation

- [Redis Operations](../redis/README.md) - Engine ECU hash fields
- [Dashboard Redis](../dashboard/REDIS.md) - How dashboard displays ECU data
- [States](../states/README.md) - Vehicle states that affect motor operation
