# Bluetooth Interface Documentation

## Service Overview

The scooter exposes several Bluetooth LE services for control and monitoring. All services use the base UUID: `xxxx-6e67-5d0d-aab9-ad9126b66f91`

## Device Information

- **Device Name**: "unu Scooter"
- **Company ID**: 0xE50A
- **Advertising**: 1 second interval, 3 minute duration
- **Connection Interval**: 20-75ms
- **Security**: MITM enabled, LESC enabled, display-only pairing (6-digit PIN), bonding supported

### Control Service (9a590000)

Primary control interface for scooter functions

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a590001 | Control Input | - "scooter:state lock"<br>- "scooter:state unlock"<br>- "scooter:seatbox open"<br>- "scooter:blinker right"<br>- "scooter:blinker left"<br>- "scooter:blinker both"<br>- "scooter:blinker off" |
| 9a590002 | Power Control | - "hibernate"<br>- "wakeup"<br>- "reboot" (soft reboot via pm-service)<br>- "hard-reboot" (power-cycle all rails via nRF52) |

`hard-reboot` is only accepted during normal operation (stand-by, suspend, parked, ready-to-drive). It's rejected during active hibernation entry or if a hard reboot is already in progress.

### Status Service (9a590020)

Provides scooter state information

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a590021 | Operating State | - "stand-by"<br>- "off"<br>- "parked"<br>- "shutting-down"<br>- "ready-to-drive"<br>- "updating" |
| 9a590022 | Seatbox State | - "open"<br>- "closed"<br>- "unknown" |
| 9a590023 | Handlebar Lock | - "locked"<br>- "unlocked" |
| 9a590024 | Temperature | NTCALUG01A thermistor, tenths of °C |

### Battery Service (9a590040)

Auxiliary battery monitoring

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a590041 | AUX Voltage | 0-15000mV |
| 9a590043 | Charge Status | - "absorption-charge"<br>- "not-charging"<br>- "float-charge"<br>- "bulk-charge" |
| 9a590044 | Charge Level | 0-100% in 25% steps |

### Connectivity Battery Service (9a590060)

CBB status monitoring

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a590061 | Charge Level | 0-100% |
| 9a590063 | Remaining Capacity | Integer |
| 9a590064 | Full Capacity | Integer |
| 9a590065 | Cell Voltage | mV |
| 9a590072 | Charge Status | - "not-charging"<br>- "charging"<br>- "unknown" |

### Power State Service (9a5900a0)

System power state monitoring

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a5900a1 | Power State | - "booting"<br>- "running"<br>- "suspending"<br>- "suspending-imminent"<br>- "hibernating-imminent"<br>- "hibernating" |

(cf. [State Diagram](../states/README.md))

### Main Battery Service (9a5900e0)

Primary battery monitoring

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a5900e2 | Primary State | - "unknown"<br>- "asleep"<br>- "active"<br>- "idle" |
| 9a5900e3 | Primary Present | 0/1 |
| 9a5900e6 | Primary Cycles | Integer |
| 9a5900e9 | Primary SoC | 0-100% |
| 9a5900ee | Secondary State | - "unknown"<br>- "asleep"<br>- "active"<br>- "idle" |
| 9a5900ef | Secondary Present | 0/1 |
| 9a5900f2 | Secondary Cycles | Integer |
| 9a5900f5 | Secondary SoC | 0-100% |

### Power Mux Service (9a590100)

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a590101 | Selected Input (read) | Active battery source |

### Aux Charger Control Service (9a590120)

LTC4020 auxiliary battery charger control

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a590121 | Safe Set (write) | 0=disable, 1=enable (with safety checks) |
| 9a590122 | Force Set (write) | 0=disable, 1=enable (bypass safety checks) |
| 9a590123 | Status (read) | Current charger enabled state |

### Accelerometer Service (9a590200)

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a590201 | Wake-up Suspend (notify) | Movement detected in suspend mode |
| 9a590202 | Wake-up Hibernation (notify) | Movement detected in hibernation mode |

### Extended Commands Service (9a590400)

Unified extensible command/response channel for phone app interaction

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a590401 | Command | Write-only, up to 128 bytes. Null-terminated string command (MITM-protected) |
| 9a590402 | Response | Read+notify, up to 512 bytes. Response string from iMX (MITM-protected) |

**Supported commands:**

| Command | Description | Response |
|---------|-------------|----------|
| `nav:dest lat,lon[,name]` | Set navigation destination | `nav:ok` |
| `nav:clear` | Clear navigation destination | `nav:ok` |
| `nav:fav:add lat,lon,name` | Save a location | `nav:fav:added:<id>` |
| `nav:fav:delete <id>` | Delete saved location | `nav:ok` |
| `nav:fav:navigate <id>` | Navigate to saved location | `nav:ok` |
| `nav:fav:list` | List saved locations | `nav:fav:count:<n>` then `nav:fav:<id>:lat,lon,name` per entry |
| `usb:ums` | Enter USB Mass Storage mode | `usb:ok` |
| `usb:normal` | Exit USB Mass Storage mode | `usb:ok` |
| `keycard:list` | List keycards | Response via keycard-service |
| `keycard:count` | Count keycards | Response via keycard-service |
| `keycard:add:<uid>` | Add keycard | Response via keycard-service |
| `keycard:remove:<uid>` | Remove keycard | Response via keycard-service |
| `time:set <unix_timestamp>` | Set system clock | `time:ok` |
| `config:apn <value>` | Set cellular APN | `config:ok` |
| `config:hibernate-timer <seconds>` | Set hibernation timeout | `config:ok` |
| `config:update-channel <channel>` | Set OTA update channel (stable/testing/nightly) | `config:ok` |
| `config:auto-standby-seconds <seconds>` | Set auto-lock idle timeout when parked (0=disabled, 0-3600) | `config:ok` |
| `alarm:enable` | Enable alarm system | `alarm:ok` |
| `alarm:disable` | Disable alarm system | `alarm:ok` |
| `alarm:arm` | Arm alarm (runtime, bypasses enabled setting) | `alarm:ok` |
| `alarm:disarm` | Disarm alarm | `alarm:ok` |
| `alarm:start` / `alarm:start:<N>` | Trigger alarm (optional duration in seconds) | `alarm:ok` |
| `alarm:stop` | Stop active alarm | `alarm:ok` |
| `status:maps-available` | Query if offline maps are installed | `status:maps-available:true` or `false` |
| `status:navigation-available` | Query if routing engine is available | `status:navigation-available:true` or `false` |
| `cap:list` | Enumerate supported capability categories | `cap:count:<n>` then `cap:<name>` per category |
| `cap:<category>` | List commands for a category | `cap:<category>:count:<n>` then `cap:<category>:<command>` per command |

Error responses follow the pattern `<prefix>:error:<details>`.

### Scooter Info Service (9a59a040)

System-level telemetry and configuration

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a59a041 | iMX Software Version | Version string (read-only) |
| 9a59a042 | Mileage/Odometer | Integer, km (read-only) |
| 9a59a043 | System Time | Unix timestamp string (write-only) |
| 9a59a044 | Navigation Active | 0 = no destination, 1 = destination set (read+notify) |
| 9a59a045 | UMS Status | 0 = normal, 1 = USB Mass Storage mode (read+notify) |

### System Info Service (9a59a000)

| Characteristic | Description | Values |
|---------------|-------------|---------|
| 9a59a001 | nRF Version | Version string (e.g. "v2.2.1-ls") |
| 9a59a021 | Reset Reason | Nordic RESETREAS register value (see below) |
| 9a59a022 | Reset Count | Integer |

#### RESETREAS (Reset Reason Register)

Reset reason register. Cumulative unless cleared. Fields are cleared by writing '1'. If no reset sources are flagged, indicates reset from on-chip reset generator (power-on-reset or brownout reset).

| Field   | Bit(s) | Access | Description | Value | Meaning |
|---------|---------|--------|-------------|--------|---------|
| RESETPIN | 0 | RW | Reset from pin-reset detected | 0<br>1 | Not detected<br>Detected |
| DOG | 1 | RW | Reset from watchdog detected | 0<br>1 | Not detected<br>Detected |
| SREQ | 2 | RW | Reset from soft reset detected | 0<br>1 | Not detected<br>Detected |
| LOCKUP | 3 | RW | Reset from CPU lock-up detected | 0<br>1 | Not detected<br>Detected |
| OFF | 16 | RW | Reset due to wake up from System OFF mode (DETECT signal from GPIO) | 0<br>1 | Not detected<br>Detected |
| LPCOMP | 17 | RW | Reset due to wake up from System OFF mode (ANADETECT signal from LPCOMP) | 0<br>1 | Not detected<br>Detected |
| DIF | 18 | RW | Reset due to wake up from System OFF mode (debug interface mode entry) | 0<br>1 | Not detected<br>Detected |
| NFC | 19 | RW | Reset due to wake up from System OFF mode (NFC field detect) | 0<br>1 | Not detected<br>Detected |
| VBUS | 20 | RW | Reset due to wake up from System OFF mode (VBUS rising into valid range) | 0<br>1 | Not detected<br>Detected |

Register layout has:
- Low bits (0-3): Basic reset sources
- High bits (16-20): System OFF wake-up sources
