# librescoot-ecu (ecu-service)

## Description

The ECU service (`ecu-service`) provides a unified interface for communicating with electric scooter motor controllers (ECUs) via CAN bus. It monitors motor speed, RPM, voltage, current, temperature, throttle state, KERS (kinetic energy recovery system) status, odometer, power metrics, and fault codes. The service publishes this data to Redis for consumption by the dashboard and other services, and manages KERS functionality based on battery temperature and vehicle state.

## Command-Line Options

```
Usage of ecu-service:
  -can_device string
        CAN device name (default "can0")
  -gear_ratios string
        Bosch ECU gear ratios (comma-separated values 1-3, each 1-255, e.g. '100,150,200')
  -log int
        Log level (0=NONE 1=ERROR 2=WARN 3=INFO 4=DEBUG) (default 3)
  -redis_port int
        Redis server port (default 6379)
  -redis_server string
        Redis server address (default "127.0.0.1")
  -version
        Print version and exit
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
- `brake` - Brake state ("on", "off")
- `temperature` - ECU temperature in °C
- `fault:code` - Current fault code (32-bit, 0 when no fault)
- `fault:description` - Active fault description (empty string when no fault)
- `odometer` - Total distance traveled in meters
- `kers` - KERS (regenerative braking) state ("on", "off")
- `boost` - Boost mode state ("on", "off")
- `gear` - Current gear (1-3, 0 if unknown)
- `power` - Instantaneous power in mW
- `energy:consumed` - Cumulative energy consumed in mWh
- `energy:recovered` - Cumulative energy recovered via regenerative braking in mWh
- `kers-reason-off` - Reason KERS is disabled ("none", "cold", "hot")
- `kers-accepted-voltage` - EBS regen voltage cap the ECU accepted, in mV (Bosch only; 0 otherwise). The ECU echoes this after clamping the EBS Set command; it is the stored config, not a live measurement. Distinct from the commanded `engine-ecu.kers-voltage` setpoint.
- `kers-accepted-current` - EBS regen current limit the ECU accepted, in mA (Bosch only; 0 otherwise). Distinct from the commanded `engine-ecu.kers-power` setpoint.
- `regen-available` - Derived ("on"/"off"): whether regen can happen right now.
- `regen-reason` - Derived: why regen is unavailable ("none"/"cold"/"hot"/"off"/"standstill"/"full"). "standstill" means wheel RPM is below the ECU's regen engage deadband (~90 wheel RPM, ~7 km/h). "full" means the pack is at its voltage cap. Empirically derived envelope; non-Bosch controllers report gating only.
- `regen-expected` - Derived: expected regen current envelope in mA (0 on non-Bosch controllers). `motor:current` remains the real-measurement source for actual regen.
- `ecu-status` - ECU enable state ("enabled"/"disabled"), decoded from the Status4 paired enable/disable bits
- `boost-status` - Boost enable state ("enabled"/"disabled"), same Status4 signal as `boost`
- `gear-mode` - Gear-mode enable state ("enabled"/"disabled"), from Status4
- `fw-version` - ECU firmware identification word, 8 hex digits (written once the ECU has reported it)
- `warranty-date` - Unknown word from the same frame, 8 hex digits. Always zero on every controller observed so far, and the key is only written when it is non-zero, so in practice it does not appear.
- `motor:rated-power-kw` - Motor rated power in kW
- `motor:max-speed-kmh` - Motor maximum speed in km/h
- `fw:base-version` - Base software version (e.g. "4.0")
- `fw:app-version` - Application software revision
- `gear:high-current-ratio`, `gear:mid-current-ratio`, `gear:low-current-ratio` - Per-gear current scaling in percent
- `gear:high-torque-ratio`, `gear:mid-torque-ratio`, `gear:low-torque-ratio` - Per-gear torque scaling in percent
- `config:ov-threshold-mv` - ECU-reported over-voltage threshold in mV
- `config:uv-threshold-mv` - ECU-reported under-voltage threshold in mV
- `config:speed-limit-ratio` - ECU-reported speed limit in percent
- `config:wheel-circumference-cm` - ECU-reported wheel circumference in cm
- `config:max-phase-current-ma` - ECU-reported peak phase current in mA
- `config:startup-phase-current-ma` - ECU-reported startup phase current in mA

The `config:*` fields are deleted from the hash rather than written as 0 while the ECU has not reported them, so a missing field means "not reported" and not a real zero.

**Published channels:**

All notifications go out on the `engine-ecu` channel, with the name of the field
that changed as the payload:

- `throttle` - Published when throttle state changes
- `kers` - Published when KERS state changes
- `odometer` - Published when odometer updates
- `kers-reason-off` - Published when KERS disable reason changes
- `regen-available` - Published when derived regen availability or reason changes
- `fault` - Published when a fault is raised or cleared

### Hash: `settings`

**Fields read:**

- `engine-ecu.kers` - KERS enable/disable ("enabled"/"disabled"; default: enabled)
- `engine-ecu.kers-power` - KERS regenerative braking current in mA for single-battery operation (default: 10000)
- `engine-ecu.kers-power-dual` - KERS regenerative braking current in mA when both batteries are active (optional; when unset, `kers-power` is used for both cases)
- `engine-ecu.kers-voltage` - KERS target voltage in mV (Bosch only; default: 56000, valid range 42000-58000)
- `engine-ecu.boost` - Boost mode enable/disable ("true" enables, any other value disables)

Loaded on startup; updated live via `settings` pub/sub.

### Pub/Sub Subscriptions

The service subscribes to the following channels to monitor system state:

- `vehicle` - Listens for vehicle state changes (e.g., "ready-to-drive")
- `battery:0` - Monitors battery 0 state and temperature
- `battery:1` - Monitors battery 1 state and temperature
- `settings` - Listens for KERS setting changes

### Redis Operations for Fault Management

**Set:** `engine-ecu:fault`

- Contains the active fault code (SADD when a fault is raised; the key is DELeted when the fault clears)

**Stream:** `events:faults`

- Publishes fault events with group="engine-ecu"; a raised fault carries `code`, `description` and `severity`, a cleared fault carries the same `code` negated, so the two can be paired up
- Limited to 1000 entries (MAXLEN)

**Published channel for faults:** `engine-ecu` with payload "fault"

## Hardware Interfaces

### CAN Bus

- **CAN device:** Configurable via `-can_device` option (default: `can0`)
- **Interface type:** SocketCAN
- **Connected to:** Bosch motor controller/ECU

The service uses standard Linux SocketCAN to communicate with the motor controller.

### ECU Communication

The service talks to a Bosch ECU over CAN.

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

## Configuration

### Systemd Unit

- **Unit file:** `/usr/lib/systemd/system/librescoot-ecu.service`
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

1. Parse command-line options (CAN device, Redis settings, log level, gear ratios)
2. Validate the log level and the `-gear_ratios` string
3. Connect to Redis server with timeout (5s connection timeout)
4. Initialize components:
   - Battery monitor (tracks 2 battery slots)
   - IPC TX (Redis publisher)
   - Write default state to Redis (all zeros/off)
   - Start Redis health check goroutine (30s interval)
   - KERS manager (with 1.5s ready-to-drive delay timer)
   - Diagnostics manager (fault tracking)
   - Initialize CAN bus interface
   - Create the Bosch ECU instance
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
  - If no battery is active the temperature state is unknown and KERS state is not updated; when both are active the more restrictive of the two temperature states wins

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
- When the fault clears, the `engine-ecu:fault` key is deleted and the raised code is logged to the stream negated (a fault to fault transition removes the outgoing code from the set and logs its clear before the new raise)

#### Power Metrics

The service calculates and tracks power consumption and recovery:

- **Instantaneous Power:** `power = (voltage_mV * current_mA) / 1000` (in mW)
- **Energy Integration:** Power integrated over time to calculate energy in mWh
- **Consumed Energy:** Tracked when power is positive (motor driving)
- **Recovered Energy:** Tracked when power is negative (regenerative braking)
- **Maximum Delta:** 2 second maximum between updates (prevents large accumulation when ECU is off)

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

Use `journalctl -u librescoot-ecu` to view logs.

## Dependencies

- **CAN device** - Must have configured SocketCAN interface (e.g., can0)
- **ECU/Motor controller** - Must be powered and responsive on CAN bus
- **Redis server** - At specified host:port (default: 127.0.0.1:6379)
- **Battery service** - For temperature state monitoring (publishes to battery:0 and battery:1)
- **Vehicle state manager** - For ready-to-drive state (publishes to vehicle channel)

## Related Documentation

- [Redis Operations](../redis/README.md) - Engine ECU hash fields
- [Dashboard Redis](../dashboard/REDIS.md) - How dashboard displays ECU data
- [States](../states/README.md) - Vehicle states that affect motor operation
