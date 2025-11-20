# librescoot-battery (battery-service)

## Description

The battery service monitors the two main battery slots (battery:0 and battery:1) via NFC readers. Each battery has an NFC tag that provides battery management data including state, charge level, cycle count, and fault codes. The service communicates with batteries through NFC when they are inserted and active.

## Command-Line Options

```
Usage of battery-service:
  -battery1-active
        Enable battery 1 as active in addition to battery 0 (default: inactive)
  -dangerously-ignore-seatbox
        Keep active batteries active when seatbox opens (DANGEROUS)
  -debug
        Enable debug logging for detailed NCI/DATA messages
  -device0 string
        Battery 0 NFC device (default "/dev/pn5xx_i2c0")
  -device1 string
        Battery 1 NFC device (default "/dev/pn5xx_i2c1")
  -heartbeat-timeout uint
        Heartbeat timeout for standby mode in seconds (default 40)
  -log int
        Service log level (0=NONE, 1=ERROR, 2=WARN, 3=INFO, 4=DEBUG) (default 3)
  -log0 int
        Battery 0 log level (0=NONE, 1=ERROR, 2=WARN, 3=INFO, 4=DEBUG) (default 3)
  -log1 int
        Battery 1 log level (0=NONE, 1=ERROR, 2=WARN, 3=INFO, 4=DEBUG) (default 3)
  -off-update-time uint
        Update time when disabled in seconds (30 minutes) (default 1800)
  -redis-port uint
        Redis server port (default 6379)
  -redis-server string
        Redis server address (default "127.0.0.1")
  -test-main-power
        Enable main power test mode
  -version
        Show version information
```

## Redis Operations

### Hash: `battery:0` and `battery:1`

**Fields written:**
- `state` - Battery state ("unknown", "asleep", "idle", "active")
- `present` - Battery presence ("true" or "false")
- `charge` - State of charge percentage (0-100)
- `cycle-count` - Battery cycle count
- `temperature:0` - Battery temperature sensor 0 (°C)
- `temperature:1` - Battery temperature sensor 1 (°C)
- `temperature:2` - Battery temperature sensor 2 (°C)
- `temperature:3` - Battery temperature sensor 3 (°C)
- `temperature-state` - Temperature status ("unknown", "cold", "hot", "ideal")
- `current` - Battery current (mA)
- `voltage` - Battery voltage (mV)
- `state-of-health` - Battery health percentage (0-100)
- `serial-number` - Battery serial number
- `manufacturing-date` - Manufacturing date
- `fw-version` - Firmware version

**Published channels and messages:**
- `battery:0`, `battery:1` - Battery state change notifications
  - `present` - Battery presence changed
  - `state` - Battery state changed
  - `charge` - Charge level changed
  - `temperature-state` - Temperature state changed
  - `fault` - Fault status changed

### Hash: `vehicle`

**Fields read:**
- `state` - Vehicle state (monitored to adjust battery behavior)
- `seatbox:lock` - Seatbox lock state ("closed" or "open")

**Subscribed channels:**
- `vehicle` - Vehicle state change notifications
  - `state` - Vehicle state changed
  - `seatbox:lock` - Seatbox lock state changed

### Sets: `battery:0:fault` and `battery:1:fault`

**Fault codes stored as set members:**
- Hardware faults (1-16): Temperature, voltage, current protection faults
- Software faults (32+): Communication errors, NFC reader errors

### Stream: `events:faults`

**Fault events written:**
- `group` - Source (e.g., "battery:0")
- `code` - Fault code (positive for set, negative for cleared)
- `description` - Human-readable fault description

## Hardware Interfaces

### NFC Readers

- **Device 0:** `/dev/pn5xx_i2c0` (default, configurable via `--device0`)
- **Device 1:** `/dev/pn5xx_i2c1` (default, configurable via `--device1`)
- **Chip:** PN7150 NFC controller (I2C interface)

Each battery slot has a dedicated NFC reader to communicate with the battery's NFC tag.

### Battery Communication Protocol

The service uses NFC Type 4 Tag operations to communicate with battery NFC tags:

**Read Operations:**
- `0x0300` - STATUS0: Voltage, current, firmware version, remaining/full capacity, fault code, temperatures 0-1, state of health, low SOC flag
- `0x0310` - STATUS1: Battery state (4 bytes), serial number (12 bytes)
- `0x0320` - STATUS2: Serial number continuation (4 bytes), manufacturing date (8 bytes), cycle count (2 bytes), temperatures 2-3

**Write Operations:**
- `0x0330` - COMMAND: 4-byte command code to control battery state

**Battery Commands:**
- `BMSCmdOn` (0x50505050) - Enable high-current path
- `BMSCmdOff` (0xCAFEF00D) - Disable high-current path
- `BMSCmdInsertedInScooter` (0x44414E41) - Battery inserted notification
- `BMSCmdSeatboxOpened` (0x48525259) - Seatbox opened notification
- `BMSCmdSeatboxClosed` (0x4D4B4D4B) - Seatbox closed notification
- `BMSCmdHeartbeatScooter` (0x534E4A41) - Keep-alive heartbeat

**Battery States:**
- `BMSStateUnknown` (0x00000000) - Cannot determine state
- `BMSStateAsleep` (0xA4983474) - Lowest power mode
- `BMSStateIdle` (0xB9164828) - Systems on, high-current path disabled
- `BMSStateActive` (0xC6583518) - High-current path enabled

## Configuration

### Systemd Unit

- **Unit file:** `/usr/lib/systemd/system/battery-service.service`
- **Started by:** systemd at boot
- **Restart policy:** Always

## Observable Behavior

### Startup Sequence

1. Opens NFC device interfaces for both battery slots
2. Connects to Redis
3. Initializes NFC readers (PN7150 chips)
4. Starts periodic battery polling
5. Publishes initial battery state

### Runtime Behavior

#### When Battery Inserted

1. NFC tag detected
2. Battery woken from sleep (if asleep)
3. Battery parameters read via NFC
4. State published to Redis `battery:N` hash
5. Publishes to `battery:N` channel

#### Polling Intervals

- **Active mode (non-standby):** 10 seconds between status updates
- **Active mode (standby):** 40 seconds between status updates (configurable via `--heartbeat-timeout`)
- **Inactive mode:** 30 minutes between status updates (configurable via `--off-update-time`)
- **Tag discovery (seatbox open):** 100ms polling interval for fast detection
- **Tag discovery (seatbox closed):** 2500ms polling interval for power efficiency

#### Battery States

- **unknown:** Cannot determine battery state
- **asleep:** Battery in lowest power mode
- **idle:** Battery systems on, high-current path disabled
- **active:** High-current path enabled, ready for driving/charging

State transitions are triggered by:
- Vehicle state changes (monitored via `vehicle` hash and channel)
- Seatbox lock state changes (monitored via `vehicle` hash and channel)
- Battery role (active/inactive) and enabled state
- Battery internal conditions (SOC, faults)
- NFC communication status

### Battery Control

Battery behavior is controlled by:

1. **Battery Role:**
   - `active` - Can provide power (battery 0 is always active)
   - `inactive` - Cannot provide power (battery 1 by default, use `--battery1-active` to make active)

2. **Enabled State (for active batteries):**
   - Automatically controlled based on seatbox lock state
   - When seatbox closed: battery enabled
   - When seatbox open: battery disabled (unless `--dangerously-ignore-seatbox` is set)

3. **Battery State Machine:**
   - Service sends appropriate commands (on/off) based on enabled state
   - Monitors battery compliance with commands
   - Raises `BMSFaultBMSNotFollowingCmd` if battery doesn't respond correctly

### State Machine

Each battery reader implements a hierarchical state machine:

**Top-level states:**
- `StateInit` - Waiting for initial vehicle/seatbox state from Redis
- `StateNFCReaderOff` - NFC reader deinitialized (during recovery)
- `StateNFCReaderOn` - NFC reader initialized and operational

**Discovery states (under NFCReaderOn):**
- `StateDiscoverTag` - Parent state for tag discovery
  - `StateWaitArrival` - Actively polling for tag arrival
  - `StateTagAbsent` - No tag detected, periodic checking

**Tag present states (under NFCReaderOn):**
- `StateTagPresent` - Parent state when battery inserted
  - `StateCheckPresence` - Verifying battery responds to commands
  - `StateWaitLastCmd` - Waiting for minimum time between commands (400ms)
  - Seatbox open path:
    - `StateSendOff` - Sending OFF command
    - `StateSendOpened` - Sending SEATBOX_OPENED command
    - `StateSendInsertedOpen` - Sending INSERTED_IN_SCOOTER command
  - Seatbox closed path (heartbeat):
    - `StateHeartbeat` - Setting up heartbeat timer
    - `StateHeartbeatActions` - Performing heartbeat sequence
    - `StateSendClosed` - Sending SEATBOX_CLOSED command
    - `StateSendOnOff` - Sending ON or OFF command based on enabled state
    - `StateCondStateOK` - Checking if battery state matches expected
    - `StateWaitUpdate` - Waiting for next heartbeat interval
    - `StateSendInsertedClosed` - Sending INSERTED_IN_SCOOTER for recovery

**State machine features:**
- Event-driven transitions (tag events, timeouts, vehicle state changes)
- Hierarchical states with parent-child relationships
- Automatic recovery from communication failures
- Suspend inhibitor management during critical operations
- Discovery polling rate adapts to seatbox state

### Error Recovery

The service implements multiple recovery mechanisms:

1. **NFC Read Verification:**
   - Double-read all battery data
   - Compare reads to detect corruption
   - Retry up to 4 times on mismatch

2. **Arbiter Busy Recovery:**
   - Detect NFC arbiter busy condition
   - Call SelectTag(0) to reset arbiter
   - Retry operation

3. **Communication Failure Recovery:**
   - Track consecutive communication failures
   - After failures, transition to `StateNFCReaderOff`
   - Deinitialize NFC reader
   - Wait 2 seconds
   - Full reinitialization with power cycle
   - Resume normal operation

4. **Zero Data Recovery:**
   - Detect when battery returns all-zero data
   - Increment recovery counter
   - Retry up to 10 times with heartbeat
   - After threshold, enter passive discovery (long polling intervals)

5. **Heartbeat Timeout Recovery:**
   - Monitor battery state compliance
   - If state incorrect after timeout, force tag rediscovery
   - Prevents endless stuck states

6. **Cold Boot Recovery:**
   - Detect PN7150 cold boot semantic errors (status 0x06)
   - Automatically reinitialize reader
   - Resume discovery

### Fault Detection and Reporting

The service monitors for battery faults using a debounced fault management system:

**Hardware Faults (from BMS):**
1. `ChgTempOverHighProt` - High temperature during charging
2. `ChgTempOverLowProt` - Low temperature during charging
3. `DsgTempOverHighProt` - High temperature during discharge
4. `DsgTempOverLowProt` - Low temperature during discharge
5. `SignalWireBrokeProt` - Signal wire disconnected
6. `SecondLvlOverTemp` - Critical temperature level
7. `PackVoltHighProt` - Battery pack overvoltage
8. `MosTempOverHighProt` - Power transistor overheating
9. `CellVoltHighProt` - Cell overvoltage
10. `PackVoltLowProt` - Battery pack undervoltage
11. `CellVoltLowProt` - Cell undervoltage
12. `CrgOverCurrentProt` - Charging overcurrent
13. `DsgOverCurrentProt` - Discharge overcurrent
14. `ShortCircuitProt` - Short circuit detected

**Software Faults (detected by service):**
- `BMSNotFollowingCmd` (32) - Battery not responding to commands (5s set debounce, 10s reset debounce)
- `BMSZeroData` (33) - Battery data unavailable (critical, immediate)
- `BMSCommsError` (34) - Battery communication failed (critical, 5s set debounce, 10s reset debounce)
- `NFCReaderError` (35) - NFC reader malfunction (critical, 30s set debounce)

**Fault Reporting:**
- Faults stored in Redis sets: `battery:N:fault`
- Fault events logged to Redis stream: `events:faults`
- Fault changes published to `battery:N` channel with message "fault"
- Critical faults cause battery to report as not present

## Log Output

The service logs to journald with leveled logging:

**Log Levels:**
- 0 = NONE - No logs
- 1 = ERROR - Only error messages
- 2 = WARN - Warning messages and errors
- 3 = INFO - Informational messages (default)
- 4 = DEBUG - Detailed debug messages

**Configuration:**
- `--log` - Service-wide log level (default: 3)
- `--log0` - Battery 0 reader log level (defaults to `--log`)
- `--log1` - Battery 1 reader log level (defaults to `--log`)
- `--debug` - Enable detailed NCI/DATA messages from NFC HAL

**Common log messages:**
- NFC communication errors and recovery
- Battery state transitions
- Fault activation and clearing
- Tag arrival/departure events
- State machine transitions (debug level)
- NCI protocol messages (debug mode only)

**Viewing logs:**
```bash
journalctl -u battery-service -f           # Follow logs
journalctl -u battery-service --since today # Today's logs
```

## Dependencies

- **Go runtime** - CGO_ENABLED=0 for static binary compilation
- **PN7150 NFC readers** - Must be accessible via I2C at `/dev/pn5xx_i2c0` and `/dev/pn5xx_i2c1`
- **Redis server** - Must be running at specified host:port (default: 127.0.0.1:6379)
- **Battery NFC tags** - Batteries must have functional NFC Type 4 tags
- **systemd** - For suspend inhibitor functionality during NFC transactions
- **Linux kernel** - I2C support and device nodes

**Go Dependencies:**
- `github.com/redis/go-redis/v9` - Redis client
- `golang.org/x/sys` - System calls for I2C and systemd integration

## LibreScoot Implementation

The LibreScoot **battery-service** is a complete Go reimplementation with architectural improvements:

### Key Features

- **Per-battery log levels:** Separate `--log0` and `--log1` flags for independent log control
- **Service-wide log level:** Global `--log` flag with per-battery override capability
- **Build-time information:** Git revision and build time embedded in binary (`--version`)
- **Enhanced NFC error handling:** Robust recovery from I2C errors and NFC reader failures
- **Temperature state management:** Four-state temperature monitoring (unknown/cold/hot/ideal)
- **Debounced fault management:** Prevents fault flapping with configurable debounce times
- **Suspend inhibitor integration:** Blocks system suspend during critical NFC transactions
- **Dual battery support:** Independent control of two battery slots with configurable roles
- **Seatbox safety:** Automatic battery disable when seatbox opens (unless overridden)

### Architecture Improvements

- **Goroutine-based concurrency:** Each battery reader runs in its own goroutine with independent state machine
- **Event-driven design:** Tag arrival/departure events, vehicle state changes, seatbox updates processed asynchronously
- **Clean NFC HAL:** Hardware abstraction layer for PN7150 with error classification (transient vs. fatal)
- **Read verification:** Double-read verification for critical data to prevent corruption
- **Arbiter busy handling:** Automatic retry with tag reselection on NFC arbiter conflicts
- **Heartbeat monitoring:** Configurable heartbeat timeouts with automatic recovery
- **State machine recovery:** Automatic NFC reader reinitialization on communication failures
- **Redis transactions:** Atomic updates to battery hashes with pipelined operations

### Building

```bash
# Build for ARM target (ARMv7)
make build                  # Output: bin/battery-service

# Build for AMD64 (development/testing)
make build-amd64           # Output: bin/battery-service-amd64

# Build for current platform
make build-native

# Development build (with debug symbols)
make dev-build

# Clean build artifacts
make clean
```

**Build system:**
- Static linking (`-extldflags '-static'`)
- Version information embedded via linker flags
- Cross-compilation support for ARM and AMD64
- Minimal dependencies (CGO_ENABLED=0)

### Compatibility

LibreScoot battery-service maintains full Redis compatibility with original firmware:

**Compatible interfaces:**
- Same hash fields in `battery:0` and `battery:1`
- Same channel publication patterns
- Same fault reporting mechanisms
- Same vehicle state monitoring

**Behavioral improvements:**
- More robust error recovery
- Better fault classification
- Enhanced logging
- Configurable timeouts

**Not a drop-in replacement for:**
- Command-line options changed (original used different flag names)
- No `battery:N:power` list consumption (control is internal based on vehicle/seatbox state)

## Related Documentation

- [Electronic Components](../electronic/README.md) - PN7150 NFC reader details
- [Redis Operations](../redis/README.md) - Battery hash fields
- [States](../states/README.md) - Battery state definitions
- [LibreScoot Services](librescoot-services.md) - Battery service details
