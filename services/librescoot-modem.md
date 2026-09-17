# librescoot-modem (modem-service)

## Description

The modem service manages the cellular modem (SimCom SIM7100E) for internet connectivity and GPS functionality using ModemManager (mmcli). It monitors network registration, signal quality, access technology (2G/3G/4G), handles modem power management and recovery, manages network connectivity, and provides GPS coordinates via gpsd. The service implements intelligent health monitoring with multi-strategy recovery procedures and GPS-specific recovery mechanisms. It also sends and receives SMS: outbound messages via the `scooter:sms` queue, inbound messages published to the `sms` hash.

## Command-Line Options

```
Usage of modem-service:
  -connectivity-targets string
        Comma-separated host:port fallback targets for the connectivity probe
        (default "8.8.8.8:53,1.1.1.1:53,9.9.9.9:53,208.67.222.222:53")
  -data-usage-file string
        Where to persist cellular byte totals; empty keeps them in memory only
        (default "/data/internet-usage.json")
  -debug
        Enable debug logging
  -gpsd-server string
        GPSD server address (default "localhost:2947")
  -interface string
        Network interface to monitor (default "wwan0")
  -internet-check-max-interval duration
        Upper bound for connectivity probe backoff (default 5m0s)
  -internet-check-time duration
        Internet check interval (default 30s)
  -redis-url string
        Redis URL (default "redis://127.0.0.1:6379")
  -sms-keepalive
        Keep the CS (SGs) registration alive for SMS delivery via periodic self-calls
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
- `connectivity` - Debounced connectivity classification folding modem-state, SIM, registration, the enable flag and health into one verdict: `connected` / `disconnected` (provisioned-but-down) / `disabled` (off by command) / `no-sim` / `denied` (registration denied/failed, e.g. deactivated SIM) / `failed` (modem broken). Consumed by the dashboard to gate the internet icon. Hysteresis: -> connected 60 s, connected -> disconnected 3 min, -> denied 60 s; disabled/no-sim/failed and any other -> disconnected immediate.
- `status` - Derived internet connectivity status ("connected", "disconnected") - set from the layer-8 reachability probe (DNS query to the network-assigned resolvers, then TCP dial of the `-connectivity-targets` fallbacks)
- `ip-address` - Interface IP address from wwan0/ppp0
- `access-tech` - Access technology from modem ("5G", "4G", "HSPA+", "HSPA", "3G", "UMTS", "EDGE", "GSM", "UNKNOWN")
- `signal-quality` - Signal strength (0-100, or 255 if unknown)
- `unu-cloud` - Cloud (uplink) connection status — written by `uplink-service`, not modem-service ("connected"/"disconnected")
- `sim-imei` - Modem IMEI identifier (identifies modem hardware, not SIM - name kept for backward compatibility)
- `sim-imsi` - SIM IMSI identifier (unique subscriber identity)
- `sim-iccid` - SIM ICCID identifier (unique SIM card identifier)
- `reachability` - Probe verdict: `ok` / `unreachable` (nothing answered but the local stack is healthy, which is the correct steady state on a restricted APN) / `no-path` (local stack broken)
- `link-layer` - Local stack assessment: `ok`, or the failed layer plus an optional reason

**Published channel:** `internet` (publishes field name on change)

### Hash: `internet-usage`

Cellular byte totals, taken from the ModemManager bearer's own counters.

**Fields written:**

- `rx-bytes` - Bytes received over the cellular bearer since `since`
- `tx-bytes` - Bytes transmitted over the cellular bearer since `since`
- `rx-bytes-roaming` - The part of `rx-bytes` that moved while registered as roaming
- `tx-bytes-roaming` - The part of `tx-bytes` that moved while registered as roaming
- `since` - RFC 3339 timestamp of when counting started
- `updated` - RFC 3339 timestamp of the last write

**Published channel:** none. The hash is written silently because the totals move
on every poll while data is flowing; consumers poll it.

The totals are monotonic. ModemManager's own counters are not: they belong to a
bearer object, and it hands out a fresh one on every modem reset. modem-service
reads MM's across-reconnect figures (`total-rx-bytes`/`total-tx-bytes`, MM 1.20+,
falling back to the per-connection-attempt `rx-bytes`/`tx-bytes`) and folds each
reading into a running total, treating a new bearer or a counter going backwards
as a restart. Period boundaries are not modelled on the vehicle: difference the
totals to get usage over a window.

The roaming fields are a subset, not a separate pot - roaming traffic is counted
in both, so home traffic is `rx-bytes - rx-bytes-roaming`.

Persisted to `/data/internet-usage.json` (see `-data-usage-file`) when
the modem is disabled ahead of a suspend/hibernate/poweroff and on service
shutdown, with a 6 hour backstop for a unit that stays up without a power
transition. Writing on every poll would spend eMMC write cycles on a counter that
is device-reported and not billing-grade, so a hard power cut can lose up to that
much counted traffic. A `since` that has moved forward means the stored file was
lost and the baseline restarted.

### Hash: `modem`

**Fields written:**

- `power-state` - Modem power state ("on", "off")
- `sim-state` - SIM card state ("present", "missing", "locked", "inactive")
- `sim-lock` - SIM lock status (unlock required type or empty)
- `registration` - Network registration state ("home", "roaming", "searching", "denied", "idle", "unknown")
- `operator-name` - Current network operator name
- `operator-code` - Current network operator code
- `is-roaming` - Roaming status ("true", "false")
- `registration-fail` - Registration failure reason (if any)
- `error-state` - Consolidated error state ("ok", "powered-off", "sim-missing", "sim-inactive", "sim-locked", "registration-denied", "registration-failed", "disconnected", "no-modem", "modem-disappeared")
- `pin-action` - Outcome of last SIM PIN reconcile ("unconfigured", "ok", "unlocked", "lock-enabled", "wrong-pin", "low-retries-bail", "puk-required", "error")
- `apn-action` - Outcome of last APN reconcile ("no-sim", "unconfigured", "ok", "applied", "iccid-changed-cleared", "error")

**Published channel:** `modem` (publishes field name on change)

### SMS: hash `sms`, streams `sms:received` / `sms:sent`

**`sms` hash (latest-value convenience state):**

- `state` - Send state of the last outbound message ("idle", "sending", "error"); published as a `state` notification on the `sms` channel
- `last-sent-to` - Recipient number of the last successfully sent SMS
- `last-sent-at` - RFC 3339 timestamp the last send completed
- `last-received-from` - Sender number of the last inbound SMS
- `last-received-text` - Body of the last inbound SMS
- `last-received-at` - RFC 3339 timestamp the last inbound SMS arrived
- `unread-count` - Inbound messages received since service start

The `last-received-*` fields refresh silently; per-message notifications go to
the dedicated channels below.

**Streams (capped at 100 entries, one dedicated pub/sub channel each):**

- `sms:received` - one entry per inbound message: `from`, `text`, `timestamp`.
  The `sms:received` channel carries each entry as JSON including its stream
  `id`.
- `sms:sent` - one entry per terminal send outcome: `request-id` (caller's
  `id` token from `scooter:sms`, empty if none), `to`, `text`, `outcome`
  (`sent`/`error`), `error`, `timestamp`. The `sms:sent` channel carries each
  entry as JSON including its stream `id`.

An inbound message is deleted from modem storage only after its XADD
succeeded, so modem storage buffers messages across Redis outages and the
periodic drain retries delivery. Messages that arrived while the service was
offline are drained on startup. Redis is not persistent on librescoot: the
streams are a live window, empty after reboot.

With `-sms-keepalive` enabled, the service keeps the CS (SGs) registration
alive by briefly calling its own number after ~13 minutes without CS activity,
working around operators that implicitly detach idle CS registrations (which
silently stops inbound SMS). Off by default: the self-call is only free as
long as the SIM's mailbox does not pick up busy calls, and it needs a SIM with
a stored MSISDN.

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
- `scooter:sms` - outbound SMS requests as JSON: `{"id":"optional-token","to":"+49...","text":"..."}` (the only queue with a JSON payload)

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
- **Restart modem:** 3500ms pulse (turns OFF), wait 12s, then 500ms pulse (turns ON)
- **USB device path:** 1-1 (for USB unbind/bind recovery)

### GPS Hardware

- **GNSS receiver:** Integrated in SimCom SIM7100E
- **Antenna power:** Configurable via AT commands (default 3050mV / 3.05V)
- **Antenna GPIO:** GPIO 41 (configured high for active antenna)
- **Interface:** gpsd via ModemManager location sources
- **SUPL server:** supl.google.com:7276 (plain-TCP SUPL port; 7275 is TLS-only and unused)
- **Refresh rate:** 1 second
- **Accuracy threshold:** 50 meters

## Configuration

### Systemd Unit

- **Unit file:** `librescoot-modem.service`
- **Binary location:** `/usr/bin/modem-service`
- **Started by:** systemd at boot (WantedBy: multi-user.target)
- **Restart policy:** `Restart=always`, no `RestartSec` set (systemd's default applies)
- **Type:** Simple

### Network Configuration

- **Interface:** wwan0 (default) or ppp0
- **DNS:** Provided by mobile operator
- **Connectivity test:** DNS query to the network-assigned resolvers, falling back to a TCP dial of the `-connectivity-targets` list. No ICMP is used.

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
6. Starts monitoring goroutine with three timers:
   - Internet check timer (`-internet-check-time`, default 30s)
   - GPS update timer (`GPSUpdateInterval`, 1s)
   - Cell-location timer (`CellLocationUpdateInterval`, 5s; drives the cell-tower geolocation fallback when `modem.cell-location` is on and there is no GPS fix)
7. Publishes initial modem and health state

### Runtime Behavior

#### Modem Health Monitoring

**Check interval:** Configurable via `-internet-check-time` (default: 30s)

**Health checks performed:**

1. Find modem ID via ModemManager DBus
2. Verify primary port is cdc-wdm0 (QMI interface)
3. Verify power state is "on"
4. If the local link assessment is healthy, run the reachability probe (DNS/TCP over the modem interface)

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
   - "connected" - the reachability probe got an answer
   - "disconnected" - no target answered, or the local link assessment was unhealthy so the probe was skipped

**Connectivity test:**

- **Method:** DNS A query for `connectivity-probe.invalid` against each network-assigned resolver, then a TCP dial of each `-connectivity-targets` entry (default `8.8.8.8:53,1.1.1.1:53,9.9.9.9:53,208.67.222.222:53`), all bound to the modem interface with SO_BINDTODEVICE. Any DNS response counts, whatever the rcode.
- **Timeout:** 2 seconds per DNS query and per dial
- **Interval:** backs off exponentially while the local stack is healthy, up to `-internet-check-max-interval` (default 5m); any change in the local link assessment forces an immediate re-probe
- **Trigger recovery:** never. A failed probe sets `status=disconnected` and `reachability=unreachable`, but only the local `link.Assess` verdict can trigger a modem remedy.

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
   - Set GPS refresh rate to 1 second
   - Restart gpsd service

4. **Connect to gpsd:**
   - Subscribe to SKY reports (for DOP values: HDOP, VDOP, PDOP)
   - Subscribe to TPV reports (for position data)
   - Monitor fix mode: 0/1=none, 2=2D, 3=3D

**GPS Data Processing:**

- gpsd TPV reports are stored verbatim; `CurrentLoc()` returns the latest one
- The same values are written to the `gps` hash and published as JSON on `gps:tpv`; there is no filtering or smoothing stage
- GPS recovery notification (a `timestamp` publish on the `gps` channel) is published only when there is an internet connection AND either it is the first fix after service init, or GPS regained a fix after a >5 minute outage

**GPS Health Monitoring:**

The service monitors GPS health separately from modem health:

1. **No data:** No GPS stanza (TPV or SKY) received for 5 seconds (`gpsNoDataTimeout`), independent of fix state
2. **Fix timeout:** No fix established for 15 minutes since GPS was enabled (`gpsFixTimeout`), sized for a cold start without SUPL; disarmed once a fix is established

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
- GPS health check failures (after GPS-specific recovery fails)

#### Multi-Strategy Modem Recovery

When modem failure is detected, the service attempts recovery with 4 strategies (max 5 attempts):

**Strategy 1: Software Reset**

- Reset the modem via the ModemManager D-Bus `Reset` method
- Wait 60 seconds for recovery
- Verify modem health

**Strategy 2: USB Recovery**

- Unbind USB device (echo "1-1" > /sys/bus/usb/drivers/usb/unbind)
- Wait 2 seconds (`UnbindWaitMS`)
- Bind USB device (echo "1-1" > /sys/bus/usb/drivers/usb/bind)
- Poll up to 2 seconds (`BindWaitMS`) for /sys/bus/usb/devices/1-1 to re-enumerate
- Wait up to 60 seconds (`health.RecoveryWaitTime`) for ModemManager to expose the modem again
- Verify modem health

**Strategy 3: GPIO Hardware Reset**

- Send 3500ms GPIO pulse to turn modem OFF
- Wait 12 seconds (`ModemOffWaitMS`)
- Send 500ms GPIO pulse to turn modem ON
- Wait up to 60 seconds (`health.RecoveryWaitTime`) for ModemManager to expose the modem again
- Verify modem health
- Fall back to the D-Bus Reset method if the GPIO cycle fails

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

The service logs to journald with systemd-aware formatting (no prefix or timestamps when `JOURNAL_STREAM` is set; otherwise a `modem-service: ` prefix plus timestamps).

**Common log patterns:**

Modem status (only the fields that changed, batched into at most two space-joined `key=value` lines per tick; several keys are abbreviated):

- "internet status=connected modem-state=connected ip=10.0.0.2 tech=4G signal=62 connectivity=connected" (also `imei=`, `imsi=`, `iccid=`)
- "modem power=on sim=present reg=home error=ok" (also `sim-lock=`, `pin-action=`, `apn-action=`, `operator=`, `mcc-mnc=`, `roaming=`, `reg-fail=`)

GPS events:

- "Waiting for valid GPS fix..."
- "GPS fix established"
- "gps state=fix-established fix=3d eph=4.2m hdop=0.8 vdop=1.2 pdop=1.4 snr=38.0dBHz sats=9/14" (GPS diagnostics, logged every 90 seconds; the eph/DOP fields are dropped while still searching)
- "GPS configuration attempt N failed: ..."
- "Successfully connected to gpsd"

Recovery events:

- "Modem failure detected: probe_failed/link_layer_failure/sgs_refresh/gps_stuck_after_gps_recovery: ..."
- "Attempting modem recovery (attempt N/5)"
- "Attempting to reset the modem via D-Bus"
- "Attempting USB recovery (unbind/bind)..."
- "Attempting modem restart (GPIO with D-Bus fallback)..."
- "Modem recovery successful via [method]"
- "GPS health check failed: gps_no_data: no GPS stanzas received for ..."
- "GPS health check failed: gps_fix_timeout: no GPS fix established for ..."
- "Attempting GPS-specific recovery for: ..."

Startup:

- "modem-service v0.13.0" (the version string is injected at build time from `git describe --tags`)
- "Modem interface wwan0 is already present"
- "Starting modem service on interface wwan0"

Use `journalctl -u librescoot-modem` or `journalctl -u modem-service` to view logs.

## Dependencies

### Runtime Dependencies

- **SimCom SIM7100E modem** - Must be connected via USB
- **ModemManager** - For modem control and status (via D-Bus, not the `mmcli` binary)
- **gpsd** - For GPS data streaming (default: localhost:2947)
- **Redis server** - At specified URL (default: redis://127.0.0.1:6379)
- **systemctl** - For managing gpsd service during GPS recovery
- **GPIO character device** - /dev/gpiochip3 line 14 (GPIO4.14, pin 110) for hardware modem power control
- **USB sysfs** - /sys/bus/usb/drivers/usb for USB recovery (device 1-1)

### Go Dependencies

From go.mod:

- **github.com/godbus/dbus/v5** v5.2.2 - D-Bus client (ModemManager, NetworkManager)
- **github.com/librescoot/redis-ipc** v0.14.0 - Redis IPC wrapper (pulls github.com/redis/go-redis/v9 v9.18.0 indirectly)
- **github.com/pkg/errors** v0.9.1 - Error handling
- **github.com/stratoberry/go-gpsd** v1.3.0 - GPSD client
- **github.com/warthog618/go-gpiocdev** v0.9.1 - GPIO character-device access for modem power control

## Related Documentation

- [Redis Operations](../redis/README.md) - Internet and GPS hash fields
- [Dashboard Redis](../dashboard/REDIS.md) - How dashboard displays connection status
- [States](../states/README.md) - How internet status affects system behavior
