# unu Scooter Pro - Technical Documentation

Reverse-engineered technical documentation of the unu Scooter Pro.

## What changed in v1.1.0

The first release containing motion-service, which takes ownership of the
BMX055 IMU from alarm-service.

- Power management gained a lot: suspend with no drive battery inserted,
  `hibernate-for`, cron-scheduled hibernation, and a last-ditch hibernate that
  fires on a low CBB or low aux voltage to avoid deep discharge
- Service mode, with a settings overlay and `lsc service-mode`
- Manual backlight control, plus slower lux smoothing to cut flicker
- Low-charge warnings for the internal batteries, and optional CBB/AUX charge
  icons in the status bar
- Hop-on can be unlocked with a keycard
- New settings: disable the horn button while the seatbox is open, and lock on
  Bluetooth disconnect. New menu entry to lock the scooter
- Battery cell and CBB temperatures on the debug screen
- Regen reworked: ecu-service publishes the applied EBS voltage and current and
  derives regen availability, and the power bar follows it

[Release notes](https://github.com/librescoot/librescoot/releases/tag/v1.1.0)

### nRF firmware

Ships nRF firmware **v2.6.0-ls**, up from v2.4.0-ls in v1.0.5.

- The radio can hold a wake timer and bring the scooter back up on its own.
  This is what makes "hibernate for" and scheduled hibernation possible: the
  rest of the system can be fully powered down and still return at a set time.
- A suspended scooter re-checks itself every few hours instead of waiting
  indefinitely for an external event.
- A hard reboot ends in stand-by rather than bringing every rail back up.

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
