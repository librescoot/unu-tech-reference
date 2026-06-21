# librescoot-modem (modem-service)

## Description

The modem service manages the cellular modem (SimCom SIM7100E) for internet connectivity and GPS functionality using ModemManager (mmcli). It monitors network registration, signal quality, access technology (2G/3G/4G), handles modem power management and recovery, manages network connectivity, and provides GPS coordinates via gpsd. The service implements intelligent health monitoring with multi-strategy recovery procedures and GPS-specific recovery mechanisms.

## Command-Line Options

```
Usage of modem-service:
  -debug
        Enable debug logging
  -gpsd-server string
        GPSD server address (default "localhost:2947")
  -interface string
        Network interface to monitor (default "wwan0")
  -internet-check-time duration
        Internet check interval (default 30s)
  -redis-url string
        Redis URL (default "redis://127.0.0.1:6379")
  -supl-server string
        SUPL server for A-GPS (default "supl.google.com:7275")
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
- `connectivity` - Debounced connectivity classification folding modem-state, SIM, registration, the enable flag and health into one verdict: `connected` / `disconnected` (provisioned-but-down) / `disabled` (off by command) / `no-sim` / `denied` (registration denied/failed, e.g. deactivated SIM) / `failed` (modem broken). Consumed by the dashboard to gate the internet icon. Hysteresis: connected->disconnected 3 min, denied 60 s; disabled/no-sim/failed immediate.
- `status` - Derived internet connectivity status ("connected", "disconnected") - determined by actual ping test to 8.8.8.8
- `ip-address` - Interface IP address from wwan0/ppp0
- `access-tech` - Access technology from modem ("2G", "GSM", "3G", "UMTS", "4G", "LTE", "5G", "UNKNOWN")
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
- `registration-fail` - Registration failure reason (if any)
- `error-state` - Consolidated error state ("ok", "powered-off", "sim-missing", "sim-inactive", "sim-locked", "registration-denied", "registration-failed", "disconnected", "no-modem", "status-error")
- `pin-action` - Outcome of last SIM PIN reconcile ("unconfigured", "ok", "unlocked", "lock-enabled", "wrong-pin", "low-retries-bail", "puk-required", "error")
- `apn-action` - Outcome of last APN reconcile ("no-sim", "unconfigured", "ok", "applied", "iccid-changed-cleared", "error")

**Published channel:** `modem` (publishes field name on change)

### Hash: `gps`

**Fields written:**
- `latitude` - GPS latitude (decimal degrees, 6 decimal places)
- `longitude` - GPS longitude (decimal degrees, 6 decimal places)
- `altitude` - Altitude in meters
- `speed` - GPS speed in km/h (converted from m/s)
- `course` - GPS course/heading in degrees
- `timestamp` - GPS timestamp (RFC3339 format)
- `updated` - Last update timestamp (RFC3339 format)
- `fix` - GPS fix mode ("none", "2d", "3d")
- `snr` - GPS signal-to-noise ratio
- `hdop` - Horizontal dilution of precision
- `vdop` - Vertical dilution of precision
- `pdop` - Position (3D) dilution of precision
- `eph` - Estimated horizontal position error in meters
- `eps` - Estimated speed error in m/s
- `ept` - Estimated time error in seconds
- `satellites-used` - Satellites used in the fix
- `satellites-visible` - Satellites in view
- `active` - GPS has valid fix (boolean)
- `connected` - Connected to gpsd (boolean)
- `state` - GPS state ("off", "searching", "fix-established", "error")
- `mode` - GNSS positioning mode ("standalone", "ue-based"; assisted ue-based mode is currently disabled, so always "standalone")

**Published channel:** `gps` (publishes "timestamp" only on GPS recovery events; routine updates are silent)

### Pub/sub channel: `gps:tpv`

Full TPV snapshot (same fields as the `gps` hash, JSON object) published for every fix. Subscribe here for a continuous position stream instead of polling the hash.

### Lists consumed (BRPOP)

- `scooter:modem` - `enable`, `disable`

GPS has no commands: the GNSS positioning mode is derived automatically from connectivity state, gated by the `modem.gps` setting. The legacy `gps:enable` / `gps:disable` commands are gone.

### Hash written: `power:inhibits`

While the modem is powered, modem-service registers a `block` inhibitor in
`power:inhibits` with `who=librescoot-modem`, so pm-service does not suspend the
MDB while the modem is up. It is acquired at startup and on each re-enable, and
removed once the modem has been powered off (and on clean shutdown). When this is
the only blocker, pm-service pushes `disable` to `scooter:modem`; modem-service
drops the inhibitor after `PowerOffModem`, and the suspend proceeds.

### Settings consumed (Hash: `settings`)

Watched via the settings hash and applied on change:

- `cellular.apn` - LTE attach + data bearer APN. Empty = use SIM operator defaults.
- `cellular.username` - APN username (PAP/CHAP). Empty = none.
- `cellular.password` - APN password (PAP/CHAP). Empty = none. Never logged.
- `cellular.auth` - Auth type for the data bearer: `none` (default), `pap`, or `chap`.
- `cellular.sim-pin` - PIN for SIM unlock or lock-enable. Never logged.
- `modem.gps` - GPS enable toggle (`true`/`false`).
- `modem.cell-location` - Enable cell-tower geolocation fallback (`true`/`false`).

## Hardware Interfaces

### Cellular Modem

- **Model:** SimCom SIM7100E
- **Interface:** USB (managed via ModemManager)
- **Primary port:** cdc-wdm0 (QMI control interface)
- **Network interface:** Configurable via `-interface` option (default: `wwan0`)
- **Control:** Via ModemManager (mmcli) and AT commands
- **GPIO control:** GPIO pin 110 (LTE_POWER) for hardware reset

### Modem Power Control

The service can control modem power via GPIO pin 110:
- **Start modem:** 500ms pulse (turns modem ON)
- **Restart modem:** 3500ms pulse (turns OFF), wait 15s, then 500ms pulse (turns ON)
- **USB device path:** 1-1 (for USB unbind/bind recovery)

### GPS Hardware

- **GNSS receiver:** Integrated in SimCom SIM7100E
- **Antenna power:** Configurable via AT commands (default 3050mV / 3.05V)
- **Antenna GPIO:** GPIO 41 (configured high for active antenna)
- **Interface:** gpsd via ModemManager location sources
- **SUPL server:** supl.google.com:7275 (A-GPS for faster fixes)
- **Refresh rate:** 1 second
- **Accuracy threshold:** 50 meters

## Configuration

### Systemd Unit

- **Unit file:** `librescoot-modem.service`
- **Binary location:** `/usr/bin/modem-service`
- **Working directory:** `/etc/librescoot`
- **Started by:** systemd at boot (WantedBy: multi-user.target)
- **Restart policy:** Always, 30 second delay
- **Type:** Simple

### Network Configuration

- **Interface:** wwan0 (default) or ppp0
- **DNS:** Provided by mobile operator
- **Connectivity test:** Ping to 8.8.8.8 (Google DNS)

#### APN Reconciliation

The service reconciles `cellular.apn`, `cellular.username`, `cellular.password`, and `cellular.auth` from the `settings` hash against two backends on every monitor tick (gated to skip when the SIM is locked or missing):

1. **NetworkManager `wwan` GSM profile** &mdash; sets the data bearer APN/user/password via `nmcli connection modify`. NM brings the bearer back up via `nmcli connection down` + `up` after the change.
2. **ModemManager initial-EPS-bearer settings** &mdash; sets the LTE attach context via the `org.freedesktop.ModemManager1.Modem.Modem3gpp.SetInitialEpsBearerSettings` D-Bus method. This persists in modem NVRAM and governs the APN used during LTE attach (before any data session).

**SIM7100E quirk:** ModemManager's generic 3GPP code writes `AT+CGDCONT=0` (cid=0) for the initial EPS bearer, which simtech firmware ignores at attach time. The service additionally sends `AT+CGDCONT=1,"IP","<apn>"` and `AT+CGAUTH=1,<type>,"<user>","<pass>"` via the `Modem.Command` D-Bus method so the SIM7100E actually picks up the new APN. Both paths are taken on every apply; the AT path is the decisive one on this hardware.

**Reattach:** After a successful apply, the service sends `AT+COPS=2` followed by `AT+COPS=0` in a background goroutine, forcing the modem to deregister and re-register with the carrier. Without this, a freshly-written CGDCONT only takes effect on the next reboot &mdash; symptoms include "stuck on EDGE" when the new attach APN was needed for the LTE core to accept the connection.

**SIM swap:** The service tracks the ICCID of the SIM that was last applied to. When ModemManager reports a different ICCID, both NM and the modem are cleared to defaults (`apn-action=iccid-changed-cleared`) so the new SIM uses its operator's defaults. The user must re-set `cellular.apn` etc. for the new SIM, which re-arms reconciliation.

**AT value safety:** Settings values containing `"`, `\r`, or `\n` are rejected before being interpolated into AT commands &mdash; SIMCom AT has no escape mechanism inside string literals.

## Observable Behavior

### Startup Sequence

1. Parses command-line configuration
2. Connects to Redis and validates connection
3. Checks if modem is present (via interface or DBus)
4. If modem not present, attempts to enable via GPIO (up to 5 attempts with increasing wait times)
5. Verifies modem health (ModemID, primary port, power state)
6. Starts monitoring goroutine with two timers:
   - Internet check timer (default 30s)
   - GPS update timer (1s)
7. Publishes initial modem and health state

### Runtime Behavior

#### Modem Health Monitoring

**Check interval:** Configurable via `-internet-check-time` (default: 30s)

**Health checks performed:**
1. Find modem ID via ModemManager DBus
2. Verify primary port is cdc-wdm0 (QMI interface)
3. Verify power state is "on"
4. If modem reports connected, perform ping test to 8.8.8.8

**Monitored parameters (via ModemManager):**
- Power state (on/off)
- SIM state (present/missing/locked/inactive)
- SIM lock status
- Network registration state (home/roaming/denied/searching)
- Signal quality (0-100 or 255 for unknown)
- Access technology (2G/GSM, 3G/UMTS, 4G/LTE, 5G)
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
   - "connected" - Modem connected AND ping to 8.8.8.8 succeeds
   - "disconnected" - Modem not connected OR ping fails

**Connectivity test:**
- **Method:** ping -c 1 -W 1 8.8.8.8
- **Timeout:** 2 seconds (context timeout)
- **Trigger recovery:** If modem reports connected but ping fails

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
   - Set GPS clock from system time
   - Enable XTRA assisted GPS (AT+CGPSXE=1)
   - Configure NMEA output (AT+CGPSNMEA=511)

2. **Antenna Power (Critical):**
   - Set antenna voltage to 3050mV (AT+CVAUXV=3050)
   - Enable antenna power (AT+CVAUXS=1)
   - Start GPS if not running (AT+CGPS=1,1)
   - Note: Antenna voltage can reset to 2950mV on reboot, preventing GPS

3. **ModemManager Location Sources:**
   - Disable conflicting sources (gps-nmea, gps-raw)
   - Set SUPL server to supl.google.com:7275
   - Enable 3gpp-lac-ci (cell tower location)
   - Enable agps-msb (A-GPS)
   - Enable gps-unmanaged (for gpsd use)
   - Set GPS refresh rate to 1 second
   - Restart gpsd service

4. **Connect to gpsd:**
   - Subscribe to SKY reports (for DOP values: HDOP, VDOP, PDOP)
   - Subscribe to TPV reports (for position data)
   - Monitor fix mode: 0/1=none, 2=2D, 3=3D

**GPS Data Processing:**

- Raw location from gpsd is stored in `LastRawReportedLocation`
- Kalman filter is applied to produce filtered location in `CurrentLoc`
- Both raw and filtered data published to separate Redis hashes
- Main `gps` hash contains either raw or filtered based on `modem:gps:filter` setting
- GPS recovery notification published only when:
  - GPS regains fix after >5 minute outage AND has internet connection
  - OR first fix after service initialization

**GPS Health Monitoring:**

The service monitors GPS health separately from modem health:

1. **Data staleness:** No GPS data for 30 seconds
2. **Timestamp stuck:** GPS timestamp unchanged for 180 seconds
3. **Fix timeout:** No fix established for 300 seconds since GPS enabled

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
- Internet connectivity check fails (modem connected but ping fails)
- GPS health check failures (after GPS-specific recovery fails)

#### Multi-Strategy Modem Recovery

When modem failure is detected, the service attempts recovery with 4 strategies (max 5 attempts):

**Strategy 1: Software Reset**
- Use mmcli to reset modem (mmcli -m X --reset)
- Wait 60 seconds for recovery
- Verify modem health

**Strategy 2: USB Recovery**
- Unbind USB device (echo "1-1" > /sys/bus/usb/drivers/usb/unbind)
- Wait 30 seconds
- Bind USB device (echo "1-1" > /sys/bus/usb/drivers/usb/bind)
- Wait 30 seconds for ModemManager to detect
- Verify modem health

**Strategy 3: GPIO Hardware Reset**
- Send 3500ms GPIO pulse to turn modem OFF
- Wait 15 seconds
- Send 500ms GPIO pulse to turn modem ON
- Wait 60 seconds for modem to initialize
- Verify modem health
- Fallback to mmcli reset if GPIO fails

**Strategy 4: Extended Wait**
- Wait 30 additional seconds
- Recheck modem health

**Recovery behavior:**
- If max attempts (5) reached, wait 2 minutes and reset recovery counter (forgiving mode)
- GPS recovery counter reset on successful modem recovery
- Health state published to Redis after each recovery attempt

This multi-strategy approach handles various failure modes:
- Software hangs → mmcli reset
- USB/driver issues → USB unbind/bind
- Firmware crashes → GPIO hardware reset
- Transient issues → Extended wait

## Log Output

The service logs to journald with systemd-aware formatting (no prefix when INVOCATION_ID is set).

**Common log patterns:**

Modem status:
- "internet status: connected/disconnected"
- "internet modem-state: off/connected/disconnected/no-modem"
- "internet signal-quality: N"
- "internet access-tech: LTE/UMTS/etc"
- "modem power-state: on/off"
- "modem sim-state: present/missing/locked/inactive"
- "modem error-state: ok/powered-off/sim-missing/etc"

GPS events:
- "Waiting for valid GPS fix..."
- "GPS fix established"
- "gps quality: X.XX" (logged every 90 seconds)
- "GPS configuration attempt N failed: ..."
- "Successfully connected to gpsd"

Recovery events:
- "Modem failure detected: wrong_primary_port/wrong_power_state/etc"
- "Attempting modem recovery (attempt N/5)"
- "Attempting to reset the modem via mmcli"
- "Attempting USB recovery (unbind/bind)..."
- "Attempting modem restart (GPIO with mmcli fallback)..."
- "Modem recovery successful via [method]"
- "GPS health check failed: gps_data_stale/gps_timestamp_stuck/etc"
- "Attempting GPS-specific recovery for: ..."

Startup:
- "modem-service v0.2.0"
- "Modem interface wwan0 is already present"
- "Starting modem service on interface wwan0"

Use `journalctl -u librescoot-modem` or `journalctl -u modem-service` to view logs.

## Dependencies

### Runtime Dependencies

- **SimCom SIM7100E modem** - Must be connected via USB
- **ModemManager** - For modem control and status (mmcli command)
- **gpsd** - For GPS data streaming (default: localhost:2947)
- **Redis server** - At specified URL (default: redis://127.0.0.1:6379)
- **systemctl** - For managing gpsd service during GPS recovery
- **GPIO access** - /sys/class/gpio for hardware modem control (pin 110)
- **USB sysfs** - /sys/bus/usb/drivers/usb for USB recovery (device 1-1)

### Go Dependencies

From go.mod:
- **github.com/redis/go-redis/v9** v9.7.0 - Redis client
- **github.com/rescoot/go-mmcli** v0.5.0 - ModemManager interface
- **github.com/stratoberry/go-gpsd** v1.3.0 - GPSD client
- **gonum.org/v1/gonum** v0.15.0 - Kalman filter for GPS
- **github.com/pkg/errors** v0.9.1 - Error handling

## Related Documentation

- [Redis Operations](../redis/README.md) - Internet and GPS hash fields
- [Dashboard Redis](../dashboard/REDIS.md) - How dashboard displays connection status
- [States](../states/README.md) - How internet status affects system behavior
