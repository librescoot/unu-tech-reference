# librescoot-modem (modem-service)

## Description

The modem service manages the cellular modem (SimCom SIM7100E) for internet connectivity and GPS functionality using ModemManager over D-Bus. It monitors network registration, signal quality, access technology (2G/3G/4G), handles modem power management and recovery, manages network connectivity, and provides GPS coordinates via gpsd. The service implements intelligent health monitoring with multi-strategy recovery procedures and GPS-specific recovery mechanisms.

## Command-Line Options

```
Usage of modem-service:
  -debug
        Enable debug logging
  -gpsd-server string
        GPSD server address (default "localhost:2947")
  -interface string
        Network interface to monitor (default "wwu1i5")
  -internet-check-time duration
        Internet check interval (default 30s)
  -redis-url string
        Redis URL (default "redis://127.0.0.1:6379")
  -supl-server string
        SUPL server for A-GPS (default "supl.google.com:7276")
  -version
        Print version and exit
```

**Active polling intervals:**
- Modem health checks: Controlled by `-internet-check-time` (default: 30s)
- GPS updates: Fixed at 1 second (GPSUpdateInterval constant)

## Redis Operations

### Hash: `internet`

**Fields written:**
- `modem-health` - Modem health state ("normal", "recovering", "recovery-failed-waiting-reboot", "permanent-failure-needs-replacement")
- `modem-state` - Raw modem status ("off", "connected", "disconnected", "no-modem", "UNKNOWN")
- `status` - Derived internet connectivity status ("connected", "disconnected") - determined by a TCP:53 reachability probe against a list of public DNS resolvers
- `ip-address` - First global-unicast IPv4 address of the monitored interface (default wwu1i5), or "UNKNOWN"
- `access-tech` - Access technology from modem ("5G", "4G", "HSPA+", "HSPA", "3G", "UMTS", "EDGE", "GSM", "UNKNOWN")
- `signal-quality` - Signal strength (0-100, or 255 if unknown)
- `unu-cloud` - Cloud (uplink) connection status — written by `uplink-service`, not modem-service ("connected"/"disconnected")
- `sim-imei` - Modem IMEI identifier (identifies modem hardware, not SIM - name kept for backward compatibility)
- `sim-imsi` - SIM IMSI identifier (unique subscriber identity)
- `sim-iccid` - SIM ICCID identifier (unique SIM card identifier)

**Published channel:** `internet` (publishes field name on change)

### Hash: `modem`

**Fields written:**
- `power-state` - Modem power state ("on", "off")
- `sim-state` - SIM card state ("present", "missing", "locked", "inactive")
- `sim-lock` - SIM lock status (unlock required type or empty)
- `operator-name` - Current network operator name
- `operator-code` - Current network operator code
- `is-roaming` - Roaming status ("true", "false")
- `registration` - 3GPP registration state ("idle", "home", "searching", "denied", "roaming", "unknown")
- `registration-fail` - Registration failure reason (if any)
- `error-state` - Consolidated error state ("ok", "powered-off", "sim-missing", "sim-inactive", "sim-locked", "registration-denied", "registration-failed", "disconnected", "no-modem", "modem-disappeared")
- `connectivity` - Debounced coarse connectivity ("online", "offline", "no-sim"); online commits after 60s of agreement, offline after 3 minutes, no-sim immediately

**Published channel:** `modem` (publishes field name on change)

### Hash: `gps` (main)

**Fields written:**
- `latitude` - GPS latitude (decimal degrees, 6 decimal places)
- `longitude` - GPS longitude (decimal degrees, 6 decimal places)
- `altitude` - Altitude in meters
- `speed` - GPS speed in km/h (converted from m/s)
- `course` - GPS course/heading in degrees
- `timestamp` - GPS timestamp (RFC3339 format)
- `updated` - Last update timestamp (RFC3339 format)
- `fix` - GPS fix mode ("none", "2d", "3d")
- `ept` - Estimated time precision in seconds
- `eps` - Estimated speed error in m/s
- `snr` - Average SNR of the satellites used in the fix, in dBHz (falls back to the average over visible satellites while searching)
- `satellites-used` / `satellites-visible` - Satellite counts from gpsd SKY reports
- `mode` - GPS acquisition mode ("standalone" or "ue-based"); this release always runs standalone
- `last_ttff_seconds` / `last_ttff_mode` - Time-to-first-fix of the most recent acquisition and the mode it was acquired in
- `hdop` - Horizontal dilution of precision
- `vdop` - Vertical dilution of precision
- `pdop` - Position (3D) dilution of precision
- `eph` - Estimated horizontal position error in meters
- `active` - GPS has valid fix (boolean)
- `connected` - Connected to gpsd (boolean)
- `state` - GPS state ("off", "searching", "fix-established", "error")

**Published channel:** `gps` (publishes "timestamp" only on GPS recovery events)

### Pub/sub channel: `gps:tpv`

Full TPV snapshot (same fields as the `gps` hash, JSON object) published for every fix. Subscribe here for a continuous position stream instead of polling the hash.

### Lists consumed (BRPOP)

- `scooter:modem` - Modem power commands (pm-service pushes these before hibernation)
  - `enable` - Mark the modem as wanted; the monitor loop brings it back up
  - `disable` - Close GPS, publish the off state (`internet status=disconnected`, `internet modem-state=off`, `modem power-state=off`) and pulse the modem off via GPIO

### Hash subscriptions (field updates)

- `vehicle` -> `state` - `parked` or `ready-to-drive` re-enables the modem
- `settings` -> `modem.gps` - GPS on/off (anything other than "false" is on; default on)
- `settings` -> `modem.cell-location` - BeaconDB cell-tower fallback on/off ("true" enables; default off)

## Hardware Interfaces

### Cellular Modem

- **Model:** SimCom SIM7100E
- **Interface:** USB (managed via ModemManager)
- **Primary port:** cdc-wdm0 (QMI control interface)
- **Network interface:** Configurable via `-interface` option (default: `wwu1i5`)
- **Control:** Via the ModemManager D-Bus API, including AT commands relayed through its `Command` method
- **GPIO control:** GPIO pin 110 (LTE_POWER) for hardware reset

### Modem Power Control

The service can control modem power via GPIO pin 110 (gpiochip3 line 14, driven through the gpiocdev character-device API):
- **Start modem:** 500ms pulse (turns modem ON)
- **Restart modem:** 3500ms pulse (turns OFF), wait 12s, then 500ms pulse (turns ON)
- **USB device path:** 1-1 (for USB unbind/bind recovery)

### GPS Hardware

- **GNSS receiver:** Integrated in SimCom SIM7100E
- **Antenna power:** Configurable via AT commands (default 3050mV / 3.05V)
- **Antenna GPIO:** GPIO 41 (configured high for active antenna)
- **Interface:** gpsd via ModemManager location sources
- **SUPL server:** supl.google.com:7276 (A-GPS, applied over `AT+CGPSURL` only in UE-Based mode; UE-Based is compiled off in this release, so GPS always runs standalone)
- **Refresh rate:** 1 second
- **Accuracy threshold:** 50 meters

## Configuration

### Systemd Unit

- **Unit file:** `librescoot-modem.service`
- **Binary location:** `/usr/bin/modem-service`
- **ExecStart:** `/usr/bin/modem-service -interface wwu1i5`
- **Started by:** systemd at boot (WantedBy: multi-user.target)
- **Ordering:** `Requires=redis.service`; `After=redis.service dbus.service ModemManager.service`; `Wants=ModemManager.service`
- **Restart policy:** `Restart=always` with no `RestartSec` (systemd's 100ms default applies); `KillMode=mixed`
- **Type:** Simple

### Network Configuration

The modem typically uses:
- **APN:** Configured externally (via NetworkManager or ModemManager)
- **Interface:** wwu1i5 (the compiled-in default and what the unit passes)
- **DNS:** Provided by mobile operator
- **Connectivity test:** TCP:53 to public DNS resolvers (8.8.8.8, 1.1.1.1, 9.9.9.9, 208.67.222.222)

## Observable Behavior

### Startup Sequence

1. Parses command-line configuration
2. Connects to Redis and validates connection
3. Checks if modem is present (via interface or DBus)
4. If modem not present, attempts to enable via GPIO (up to 5 attempts with increasing wait times)
5. Verifies modem health (ModemID, primary port, power state)
6. Starts monitoring goroutine with three timers:
   - Internet check timer (default 30s)
   - GPS update timer (1s)
   - Cell-location timer (5s; only acts when `settings modem.cell-location` is enabled and there is no GPS fix)
7. Publishes initial modem and health state

### Runtime Behavior

#### Modem Health Monitoring

**Check interval:** Configurable via `-internet-check-time` (default: 30s)

**Health checks performed:**
1. Find modem ID via ModemManager DBus
2. Verify primary port is cdc-wdm0 (QMI interface)
3. Verify power state is "on"
4. If modem reports connected, run the TCP:53 connectivity probe

**Monitored parameters (via ModemManager):**
- Power state (on/off)
- SIM state (present/missing/locked/inactive)
- SIM lock status
- Network registration state (home/roaming/denied/searching)
- Signal quality (0-100 or 255 for unknown)
- Access technology (GSM, EDGE, UMTS, 3G, HSPA, HSPA+, 4G, 5G)
- Operator name and code
- Roaming status
- IMEI, IMSI, ICCID identifiers
- Interface IP address

#### Internet Connectivity Determination

The service uses a two-level status model:

1. **Raw modem status** (`modem-state` field):
   - "off" - Power state not "on"
   - "connected" - Modem reports connected state
   - "disconnected" - Modem not connected
   - "no-modem" - Modem not found
   - "UNKNOWN" - Unable to determine state

2. **Derived internet status** (`status` field):
   - "connected" - Modem connected AND the TCP:53 probe reaches at least one resolver
   - "disconnected" - Modem not connected OR every probe target is unreachable

**Connectivity test:**
- **Method:** TCP connect to port 53, tried in order against 8.8.8.8, 1.1.1.1, 9.9.9.9 and 208.67.222.222; the first success wins. The socket is pinned to the modem interface with `SO_BINDTODEVICE` so the probe cannot leak out over another route.
- **Timeout:** 2 seconds dial timeout per target
- **Trigger recovery:** If the modem reports connected but every target fails on 3 consecutive checks

This ensures the service only reports "connected" when actual internet connectivity is verified.

#### GPS State Machine

**Update interval:** 1 second (GPSUpdateInterval constant)

**GPS States:**
- `off` - GPS disabled (initial state)
- `searching` - GPS enabled, waiting for fix
- `fix-established` - Valid 2D or 3D fix obtained
- `error` - GPS configuration or connection failed

**State transitions:**
1. GPS enable: `off` → `searching` → configure GPS → connect to gpsd
2. Fix acquired: `searching` → `fix-established` (system clock set via `chronyc` on first fix)
3. Fix lost: `fix-established` → `searching`
4. Configuration failure: `searching` → `error`

**GPS Configuration Process:**

When GPS is enabled, the service performs multi-step configuration:

1. **AT Command Configuration:**
   - Stop GPS (AT+CGPS=0)
   - Disable auto-start (AT+CGPSAUTO=0)
   - Set accuracy threshold to 50m (AT+CGPSHOR=50)
   - Configure GPS antenna GPIO 41
   - Set GPS clock from system time (AT+CCLK)
   - Configure NMEA output (AT+CGPSNMEA=511)

2. **Antenna Power (Critical):**
   - Set antenna voltage to 3050mV (AT+CVAUXV=3050)
   - Enable antenna power (AT+CVAUXS=1)
   - Start GPS if not running (AT+CGPS=1,1)
   - Note: Antenna voltage can reset to 2950mV on reboot, preventing GPS

3. **ModemManager Location Sources:**
   - Disable conflicting sources (gps-nmea, gps-raw)
   - Enable 3gpp-lac-ci (cell tower location)
   - Enable gps-unmanaged (for gpsd use)
   - agps-msb is deliberately *not* enabled (the SimTech ModemManager plugin does not act on it), and the SUPL server is not set through ModemManager at all
   - Set GPS refresh rate to 1 second
   - Restart gpsd service

4. **Connect to gpsd:**
   - Subscribe to SKY reports (for DOP values: HDOP, VDOP, PDOP)
   - Subscribe to TPV reports (for position data)
   - Monitor fix mode: 0/1=none, 2=2D, 3=3D

**GPS Data Processing:**

- Location from gpsd is written to the `gps` hash and pushed on the `gps:tpv` channel
- GPS recovery notification published only when:
  - GPS regains fix after >5 minute outage AND has internet connection
  - OR first fix after service initialization

**GPS Health Monitoring:**

The service monitors GPS health separately from modem health:

1. **No data:** No TPV/SKY stanza received from the chip for 5 seconds (`gpsNoDataTimeout`), independent of fix state
2. **Fix timeout:** No fix established for 15 minutes since GPS was enabled (`gpsFixTimeout`, sized for a cold-start almanac download); disarmed once a fix lands

**GPS-Specific Recovery:**

Before escalating to modem recovery, GPS-specific recovery is attempted (up to 3 times):
1. Stop gpsd service
2. Close existing GPS connection
3. Reset GPS state tracking
4. Re-enable GPS via ModemManager
5. Reconnect to gpsd

This avoids unnecessary modem restarts for GPS-only issues.

#### Modem Health States

The service maintains a health state machine with 4 states:

1. **"normal"** - Modem operating correctly
2. **"recovering"** - Actively attempting recovery
3. **"recovery-failed-waiting-reboot"** - Max recovery attempts reached, waiting
4. **"permanent-failure-needs-replacement"** - Modem likely defective

**Recovery triggers:**
- No modem found via ModemManager
- Wrong primary port (not cdc-wdm0)
- Wrong power state (not "on")
- Internet connectivity check fails 3 times in a row (modem connected but no probe target reachable)
- Data session stalled: modem not "connected" for 15 minutes while still registered home/roaming and not blocked by a SIM/registration error
- GPS health check failures (after GPS-specific recovery fails)

#### Multi-Strategy Modem Recovery

When modem failure is detected, the service attempts recovery with 4 strategies (max 5 attempts):

**Strategy 1: Software Reset**
- Reset the modem through the ModemManager D-Bus `Reset` method
- Wait 60 seconds for recovery
- Verify modem health

**Strategy 2: USB Recovery**
- Unbind USB device (echo "1-1" > /sys/bus/usb/drivers/usb/unbind)
- Wait 2 seconds
- Bind USB device (echo "1-1" > /sys/bus/usb/drivers/usb/bind)
- Poll up to 2 seconds for re-enumeration, then wait up to 60 seconds for ModemManager to register the modem
- Verify modem health
- If the device is already off the bus (transient absence mid-reset), skip the unbind/bind and just wait up to 60 seconds for it to reappear

**Strategy 3: GPIO Hardware Reset**
- Send 3500ms GPIO pulse to turn modem OFF
- Wait 12 seconds
- Send 500ms GPIO pulse to turn modem ON
- Wait up to 60 seconds for modem to initialize
- Verify modem health
- Fallback to a D-Bus reset if the GPIO cycle fails

**Strategy 4: Extended Wait**
- Wait 30 additional seconds
- Recheck modem health

**Recovery behavior:**
- If max attempts (5) reached, wait 2 minutes and reset recovery counter (forgiving mode)
- GPS recovery counter reset on successful modem recovery
- Health state published to Redis after each recovery attempt

This multi-strategy approach handles various failure modes:
- Software hangs → D-Bus reset
- USB/driver issues → USB unbind/bind
- Firmware crashes → GPIO hardware reset
- Transient issues → Extended wait

## Log Output

The service logs to journald with systemd-aware formatting (no prefix when INVOCATION_ID is set).

**Common log patterns:**

Modem status (all fields that changed on a tick are consolidated into one line per hash, as key=value pairs):
- "internet status=connected modem-state=connected ip=... tech=4G signal=... imei=... imsi=... iccid=..."
- "modem power=on sim=present sim-lock=... operator=... mcc-mnc=... roaming=false reg=home reg-fail=... error=ok connectivity=online"

GPS events:
- "Waiting for valid GPS fix..."
- "GPS fix established"
- "gps state=... fix=... eph=...m hdop=... vdop=... pdop=... snr=...dBHz sats=n/m" (logged every 90 seconds)
- "gps ttff=...s mode=standalone snr=...dBHz sats=n/m" (on each fix acquisition)
- "GPS configuration attempt N failed: ..."
- "Successfully connected to gpsd"

Recovery events:
- "Modem failure detected: probe_failed/internet_connectivity_failed/data_session_stalled/gps_stuck_after_gps_recovery"
- "Attempting modem recovery (attempt N/5)"
- "Attempting to reset the modem via D-Bus"
- "Attempting USB recovery (unbind/bind)..."
- "Attempting modem restart (GPIO with D-Bus fallback)..."
- "Modem recovery successful via [method]"
- "GPS health check failed: gps_no_data/gps_fix_timeout"
- "Attempting GPS-specific recovery for: ..."

Startup:
- "modem-service v0.11.0-9-gbdd87c8" (version is `git describe --tags --always --dirty` at build time)
- "Modem is already present via D-Bus" or "Modem interface wwu1i5 is present, waiting for ModemManager..."
- "Starting modem service on interface wwu1i5"

Use `journalctl -u librescoot-modem` or `journalctl -u modem-service` to view logs.

## Dependencies

### Runtime Dependencies

- **SimCom SIM7100E modem** - Must be connected via USB
- **ModemManager** - For modem control, status and AT relay, over D-Bus (godbus); the `mmcli` binary is never invoked
- **gpsd** - For GPS data streaming (default: localhost:2947)
- **Redis server** - At specified URL (default: redis://127.0.0.1:6379)
- **systemctl** - For managing gpsd service during GPS recovery
- **GPIO access** - the gpiochip character device (gpiochip3 line 14 = pin 110), via go-gpiocdev; the legacy /sys/class/gpio interface is not used
- **USB sysfs** - /sys/bus/usb/drivers/usb for USB recovery (device 1-1)

### Go Dependencies

From go.mod:
- **github.com/godbus/dbus/v5** v5.2.2 - ModemManager D-Bus interface
- **github.com/librescoot/redis-ipc** v0.11.3 - Redis IPC helpers (pulls go-redis/v9 v9.18.0 indirectly)
- **github.com/stratoberry/go-gpsd** v1.3.0 - GPSD client
- **github.com/warthog618/go-gpiocdev** v0.9.1 - GPIO character-device access
- **github.com/pkg/errors** v0.9.1 - Error handling

## Related Documentation

- [Redis Operations](../redis/README.md) - Internet and GPS hash fields
- [Dashboard Redis](../dashboard/REDIS.md) - How dashboard displays connection status
- [States](../states/README.md) - How internet status affects system behavior
