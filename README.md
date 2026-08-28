# unu Scooter Pro - Technical Documentation

Reverse-engineered technical documentation of the unu Scooter Pro.

## What changed in v1.3.0

- A phone can clear its own Bluetooth bond over the `ble:forget` extended
  command, so an app's "forget this scooter" clears both halves instead of only
  the phone's. The dashboard gains Settings > System > Clear Paired Phones,
  offered while parked, and `lsc` gains `bluetooth status`, `bluetooth forget`
  and `bluetooth forget-all`. See
  [Clearing paired phones](services/librescoot-bluetooth.md#clearing-paired-phones).
- ecu-service is a Bosch-only rewrite. It derives and publishes regenerative
  braking availability and the applied regen envelope, re-sends the gear ratios
  after every ECU power cycle, stops transmitting while the controller is
  unpowered, and raises fault E20 when a powered controller goes quiet after
  having reported a non-zero speed. The at-rest case is logged rather than
  dashed onto the cluster.
- OTA downloads get a per-component budget and a retry ladder. An attempt that
  falls below the throughput floor, or runs past the wall clock cap, is
  abandoned and retried later instead of holding the system awake, and a
  liveness heartbeat lets vehicle-service cut power to a wedged DBC install.
  Deltas are rejected if the base image they were built against is not the one
  installed.
- A map download can defer DBC power off for up to three minutes, so a large
  tileset is no longer cut off every session.
- USB map sticks accept zstd-compressed Valhalla tile archives, free space on
  the DBC is checked before a tile archive is uploaded, and the virtual drive
  is labelled `LIBRESCOOT`.
- The alarm gates triggers per source and gains handlebar and button inputs.
  The handlebar-position input has to stay off-place for a second before it
  counts; both handlebar inputs stay muted for 90 s after arming, and the alarm
  records what set it off.
- modem-service publishes cumulative cellular byte totals to the
  `internet-usage` hash, with the roaming share broken out.
- Service mode gains a way out from the debug screen: a 3 s hold on the left
  brake clears the overlay. Applying and clearing it from the dashboard menu
  already worked in v1.2.1; what changed is that the menu no longer opens on
  the debug screen, which is where service mode parks the dashboard. See
  [Service mode](services/librescoot-settings.md#service-mode-overlay-service).

[Release notes](https://github.com/librescoot/librescoot/releases/tag/v1.3.0)

### nRF firmware

Ships nRF firmware **v2.9.0-ls**, up from v2.7.2-ls in v1.2.1.

- A hard reboot no longer wipes the stored bonds.
- The single-bond delete does something. Earlier firmware accepted the command
  and dropped it, so bluetooth-service gates the BLE path on it: below
  v2.8.0-ls, `ble:forget` is refused with `ble:error:unsupported` and the `cap`
  probe stops listing `forget`, rather than telling a phone its bond is gone
  when it is not. `lsc bluetooth forget` carries no such gate. It pushes
  `delete-bond` onto `scooter:bluetooth`, which the service forwards to the
  nRF unconditionally, so on older firmware it reports success and clears
  nothing.
- Whitelist slots go to the peers that connected most recently rather than to
  the first ones created, so an extra pairing no longer pushes a phone in daily
  use out of the states that advertise whitelist-only.
- Clearing bonds no longer resets the chip.
- One pairing dialog per connect instead of two: the nRF no longer raises a
  security request on every connect. Pairing is still Secure Connections
  passkey entry, and the command and response characteristics still require an
  authenticated link.
- Notifications the radio cannot queue are retried rather than dropped, so a
  central that subscribes once no longer sits on a stale value.
- Power management state is published as it changes rather than on the next one
  second sample.

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
