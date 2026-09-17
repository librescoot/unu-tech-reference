# unu Scooter Pro - Technical Documentation

Reverse-engineered technical documentation of the unu Scooter Pro.

## What changed in v1.3.1

- Timed wake from hibernation works again. pm-service keeps the nRF52 wake-timer
  acknowledgement across an inhibitor bounce and restores the modem after an
  aborted suspend, and nRF firmware v2.10.0-ls starts the wake timer when
  hibernation starts instead of leaving it disarmed.
- update-service refuses a full `.mender` for the version the board already runs
  before writing anything, and keeps the DBC's pending-reboot flag across the
  power-off, so a dashboard install is not lost when its power drops.
- bluetooth-service applies the same-version refusal to a BLE OTA bundle at START,
  answering `START_ACK 0x14` in one round trip instead of at install time.
- The USB import stage accepts `.delta` update files and drops the `rpms/` tree,
  which nothing used. A UMS-initiated MDB or DBC install now reports its reboot
  wait and result instead of ending silently.
- alarm-service suppresses the alarm for the duration of a USB mass-storage
  session, which would otherwise trip the any-motion engine when the cable is
  plugged or unplugged, and motion-service drops to its idle profile meanwhile.
- The dashboard gains a configurable speedometer scale with warn and overspeed
  thresholds, configurable road-name and speed-limit visibility, and battery
  capacity and low-SOC rows. battery-service publishes that capacity, fault code
  and low-SOC data, and `lsc` prints battery detail and UMS cycle results.
- modem-service follows SIM insertion and removal, hardens GPS source startup,
  and serializes GPS recovery with modem shutdown.
- vehicle-service publishes the saved vehicle state before hardware init, so a
  BLE client sees a state seconds earlier. uplink-service collects canonical
  board versions for telemetry.
- The MDB's PPP link to the DBC uses UART3 with SDMA.
- `lsd`, the web management interface, is deferred and not part of this release.

[Release notes](https://github.com/librescoot/librescoot/releases/tag/v1.3.1)

### nRF firmware

Ships nRF firmware **v2.10.0-ls**, up from v2.9.0-ls in v1.3.0.

- The wake timer is armed when hibernation starts, so a scheduled hibernation
  wake fires on time. This is the firmware half of the timed-wake fix above.

## System Architecture

The unu Scooter Pro uses a distributed architecture with several key systems:

### Core Electronics
- **Middle Driver Board (MDB)** - Central control system
  - Manages power distribution and system communications
  - Coordinates motor control and battery management
  - Provides cellular connectivity via SIM7100E module
  - USB gadget, connected to DBC, exposes USB Ethernet
  - Handles wakeup/sleep states

- **Dashboard Controller (DBC)**
  - Freescale i.MX6 processor
  - Manages display and user interface
  - NFC reader for keycard authentication
  - USB host, connected to MDB

- **Electronic Control Unit (ECU)**
  - BOSCH/Lingbo motor controller
    - unu 4kW: 4kW peak / 2.7kW continuous
    - unu 3kW: 3kW peak / 1.9kW continuous
  - Encrypted CAN bus communication
  - Controls motor and regenerative braking

### Power Systems
- **Main Battery System**
  - 14s7p configuration using INR22/71-7 cells
  - 50.8V nominal, 58.2V max charging voltage
  - 35Ah/1778Wh capacity
  - NFC communication for data channel
  - LED status ring

- **Auxiliary Power**
  - 12V auxiliary lead-acid battery for core systems
  - DC/DC converter for system power
  - Connectivity Box Battery (CBB, Lithium-Ion) for cellular/GPS

### Communication Interfaces
- **Bluetooth LE** - Local device connectivity
  - Service UUIDs documented in [Bluetooth Docs](bluetooth/README.md)
  - Device control and status monitoring
  - Firmware updates over BLE ([OTA transfer protocol](bluetooth/ota-transfer.md))

- **Cellular** - Remote connectivity
  - SIM7100E module on MDB
  - Remote diagnostics and updates
  - User app connectivity

- **Redis** - Internal communication
  - Runs on 192.168.7.1:6379 (MDB)
  - Inter-process communication
  - System state management
  - [Full Redis documentation](redis/README.md)

### Hardware Details

Detailed documentation available for:

- [Electronic Systems](electronic/README.md)
- [Mechanical Components](mechanical/README.md)
- [Wiring & Connectors](wiring/README.md)

## Software Services

The MDB runs several system services that coordinate vehicle operations. For detailed documentation of each service, see [Services Documentation](services/README.md).

### Librescoot Services

Librescoot provides open-source replacement firmware for unu Scooter Pro systems, including:

- **Core System Services**: alarm, battery, bluetooth, ECU, keycard, modem, power management, settings, vehicle
- **Dashboard Services**: backlight control, illumination monitoring
- **Update Services**: OTA updates, version tracking
- **Communication Services**: nRF52 UART protocol

For complete Librescoot service documentation, see [Librescoot Services](services/README.md).

## System States

The scooter operates in several power states:

- Hibernating
- Booting
- Stand-By
- Parked
- Ready
- Shutting Down

State transitions are triggered by:

- User actions (lock/unlock)
- Power management events
- System commands

[Detailed state diagrams and transitions](states/README.md)

## Command-Line Tools

### lsc - Librescoot Control CLI

`lsc` is a comprehensive command-line tool for controlling and monitoring Librescoot systems. It provides easy access to:

- Vehicle control (lock/unlock, hibernate)
- Service management (start/stop/logs)
- Battery and GPS monitoring
- Alarm system control
- Settings management
- OTA updates
- System diagnostics

See [lsc documentation](tools/lsc.md) for complete command reference.

**Quick examples:**
```bash
lsc status              # Show overall system status
lsc lock                # Lock the scooter
lsc battery             # Show battery information
lsc svc list            # List all services
lsc svc logs vehicle -f # Follow vehicle service logs
```

## Development Access

- MDB UART, Pin 1 = GND, Pin 2 = TXD, Pin 3 = RXD
- MDB access: 192.168.7.1
- DBC access: 192.168.7.2 - connect via SSH (root@192.168.7.2) from MDB
- Redis: 192.168.7.1:6379
