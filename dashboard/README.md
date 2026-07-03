# Dashboard Interface Documentation

## Overview

The Dashboard Controller (DBC) provides the primary user interface for the scooter, displaying critical information such as speed, battery status, and navigation. It runs a Qt/QML-based UI application that communicates with other system components via Redis.

## Implementation

The dashboard UI is implemented as a Qt/QML application (unu-dashboard-ui) that:
- Runs on the DBC (Dashboard Controller)
- Connects to Redis at 192.168.7.1:6379 in production (defaults to 127.0.0.1:6379, configurable via command-line options)
- Subscribes to Redis pub/sub channels for real-time updates
- Monitors vehicle state, battery status, engine ECU, GPS, and internet connectivity
- Renders the user interface on the integrated display
- Reads hardware serial number from `/sys/fsl_otp/HW_OCOTP_CFG0` and `/sys/fsl_otp/HW_OCOTP_CFG1`
- Reads OS version from `/etc/os-release` and sets `system dbc-version` to VERSION_ID+BUILD_ID
- Sets `dashboard ready true` only after successfully reading serial number
- Stores hardware serial number in `dashboard serial-number` Redis key

## Display Modes

The dashboard operates in three primary modes, controlled via the `dashboard mode` Redis key:

| Mode | Description | Activation |
|------|-------------|------------|
| speedometer | Default mode showing speed and status | Default at startup |
| navigation | Map view with route guidance | Activated when navigation starts |
| debug | Development diagnostics | Activated by `LPUSH scooter:dashboard-mode debug` |

**Note:** The navigation-related functionality is not normally accessible and will not be triggered during normal use, but there is vestigial code from an abandoned implementation by unu. Information about navigation functionality is derived from the remaining code in the binary as well as an implementation demo video uploaded by unu's development partner.

**Note:** Debug mode is partially broken, the following documentation is based on binary analysis, but only the FPS / animation metrics have been triggered.

## Debug Mode

The debug mode provides a development and diagnostic interface that is not intended for regular users. It displays:

- System logs and diagnostic messages
- Redis key values in real-time
- Service status information
- Performance metrics (like FPS)
- System version information

### Activating Debug Mode

Debug mode can be activated by:
1. Push to the command list: `LPUSH scooter:dashboard-mode debug`
2. The dashboard uses BLPOP to read from this list and switches to debug view
3. The dashboard then writes the mode to `dashboard:mode` as confirmation

### Debug Data Structure

The debug data is stored in a Redis sorted set:
```
ZRANGE dashboard:debug 0 -1 WITHSCORES
```

The values are other Redis keys to be displayed on the screen, e.g.

```
ZADD dashboard:debug 0 "aux-battery charge-status"
```

would show the charge-status of the 12V AUX battery on the screen.
The scores indicate the priority. As many values as possible are fit on the screen, based on their score.

## UI Components

### Central Content

The central display area adapts based on the current mode:

| Mode | Content | Features |
|------|---------|----------|
| speedometer | Speedometer dial | Speed, energy recuperation indicators |
| navigation | Map view | Route visualization, turn instructions |
| debug | Debug information | System diagnostics, logs |

### Speedometer Display

The speedometer shows:
- Current speed (km/h or mph based on user settings)
- Energy recuperation status during braking
- Throttle status indicators
- Battery charge levels

Speed display can adapt to the user's preferred unit system (metric/imperial), but only metric is used in shipped scooters.

### Navigation View

The navigation interface includes:
- Interactive map with route visualization
- Turn-by-turn instruction banners
- Distance to destination
- Estimated arrival information

The view adapts based on vehicle state:
- Parked: Route overview mode
- Driving: Tracking mode with upcoming instructions
- Rerouting: Rerouting status display

### Status Bar

The top status bar has three zones in a single row: a battery display on the left, a clock centered, and status indicators on the right. Total distance/odometer is not part of the top bar; it lives in the bottom bar alongside the speedometer.

Both side widgets measure their own width at every "degrade level" (see below) and a coordinator in the top bar hands each side the most detailed level that still fits next to the clock. When the clock is hidden (`showClock` setting is `never`), the two sides share the whole row width instead of a fixed half each.

#### Left Zone: Battery Display

| Element | Shown when | Notes |
|---------|-----------|-------|
| Battery 0 icon + value | Always | Value is charge (%) or estimated range (km), depending on the `batteryDisplayMode` setting (`percentage` / `range`); the `icon` mode hides the value text entirely and leaves just the icon |
| Battery 1 icon + value | A second pack is present (dual-battery scooters) | Same value formatting as battery 0 |
| CBB (Connectivity Battery Box) level glyph | `showCbBattery` setting is `always`, or `warning` (default) and the CBB charge is below 50% | Icon-only glyph, bucketed to 0/25/50/75/100%; suppressed while a CB warning/stranded icon is showing in its place |
| AUX (12V) level glyph | `showAuxBattery` setting is `always`, or `warning` (default) and AUX voltage is below 11700 mV | Icon-only glyph, bucketed to 0/25/50/75/100% (from the AUX SoC quantization); suppressed while an AUX warning/stranded icon is showing in its place |
| Seatbox-open icon | Seatbox lock is open | |
| CB-not-present icon | No CBB detected | Blank battery glyph with a slashed overlay |
| CB warning icon | CBB charge < 50%, not charging, main pack present/active, seatbox closed (3s debounce); or CBB reports low charge while no main pack is inserted ("stranded") | Blank battery glyph with an error overlay |
| AUX warning icon | AUX voltage < 11495 mV (or < 11000 mV critical), main pack present, seatbox closed (3s debounce); or AUX voltage < 11700 mV while no main pack is inserted ("stranded") | Blank battery glyph with an error overlay |

Detail sheds in this order as space runs out: drop range decimals, drop battery 1's value text, collapse the AUX level glyph into the overflow chip, collapse the CBB level glyph into the overflow chip, drop battery 0's value text. Warning/error icons (seatbox, CB-not-present, CB/AUX warning, stranded) never degrade.

#### Right Zone: Status Indicators

The row lays out right-to-left, so the internet/modem icon sits at the outer right edge of the bar, with cloud, bluetooth, GPS, OTA status, and temperature progressing leftward toward the clock.

| Element | Shown when | Notes |
|---------|-----------|-------|
| Internet/modem icon | `showInternet` setting is `always`, or `active-or-error` (default) with the modem connected or in an error state, or `error` with an error state only | Off/disconnected glyphs, or 0-4 signal bars when connected (`signalQuality / 20`, capped at 4); small access-tech label (2G/3G/H/H+/4G/5G/1x/G) overlaid when connected |
| Cloud icon | A cloud client (radio-gaga / uplink-service) has published `unu-cloud`, and `showCloud` setting allows it (`active-or-error` by default) | Connected/disconnected glyph; independent of the internet/modem icon, not a diagonal-line overlay on it |
| Bluetooth icon | `showBluetooth` setting allows it (`active-or-error` by default) | Connected/disconnected glyph |
| GPS icon | `showGps` setting allows it (`error` only by default) | Off / searching (pulsing center dot) / fix-established / error glyphs |
| OTA status | An OTA update is active and the vehicle is Ready-to-Drive or Parked | Icon reflects downloading/preparing/installing/waiting-for-reboot/error; percentage digits shown next to it while downloading, preparing, or installing |
| Temperature | `showTemperature` setting is `always`, or `warning` (default) while ambient temperature is in the frost band (< 5 degC) | Rounded ambient temperature with a degree sign; a snowflake+"!" glyph is prepended while in the frost band |

Detail sheds in this order as space runs out: drop OTA progress digits, collapse bluetooth into the overflow chip, collapse cloud into the overflow chip, collapse GPS into the overflow chip, collapse temperature into the overflow chip. Any icon shown specifically because of an error state (or, for temperature, the frost warning) never degrades.

#### Overflow Chip

Icons collapsed by degradation are replaced by a single "..."+N chip (N = number of hidden icons) at the point in the row where they used to sit. It is display-only; full status detail is available elsewhere (e.g. the parked detail view).

#### Reduced-Power (Turtle) Indicator

The turtle / reduced-power icon is not part of the top status bar. It is one of the telltales in the floating bottom-left telltale panel, alongside engine-warning, hazard-lights, and parking-brake telltales, shown when a present and active battery pack is at or below 20% charge.

#### Internet Status Redis Keys

The connection status is determined by these Redis keys:

```
HGET internet status       # "connected" or "disconnected"
HGET internet unu-cloud    # "connected" or "disconnected"
HGET internet signal-quality  # 0-100 signal strength percentage
HGET internet access-tech  # Network type (LTE, UMTS, etc.)
```

### Notification System

The dashboard displays various notifications for:
- Battery status (low charge warnings, charging status)
- System warnings (faults, errors)
- Navigation events
- Vehicle state changes

## Redis Interface

### Dashboard Service Keys

```
HGETALL dashboard
```

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| ready | "true"/"false" | Dashboard initialization status | "true" |
| mode | string | Current display mode | "speedometer" |
| serial-number | string | Dashboard serial number | "379999993" |

### Navigation View States

The navigation view has several states that adapt based on vehicle status:

| View Mode | Activation | Features |
|-----------|------------|----------|
| Idle | Default when parked | Standard map view |
| Driving | When ready-to-drive without navigation | Driver-focused view (current position and surroundings) |
| Tracking | When navigating while driving | Turn instructions, route highlighting |
| RouteOverview | When parked with active route | Full route display |
| Rerouting | When recalculating route | Rerouting status |

### Theme Adaptation

The dashboard automatically switches between:
- Dark theme (Speedometer mode)
- Light theme (Navigation mode)

Theme transitions include animation timing for smooth visual changes.

## Behavior Patterns

### Startup Sequence

1. Dashboard application starts (unu-dashboard-ui)
2. Connects to Redis (192.168.7.1:6379 in production, defaults to 127.0.0.1:6379, configurable via `-b` and `-p` options)
3. Subscribes to all service Redis pub/sub channels
4. Reads OS version from `/etc/os-release` and sets `system dbc-version` to VERSION_ID+BUILD_ID
5. Reads hardware serial number from `/sys/fsl_otp/HW_OCOTP_CFG0` and `/sys/fsl_otp/HW_OCOTP_CFG1`
6. Sets `dashboard serial-number` to combined serial number value
7. Sets `dashboard ready true` (only if serial number read succeeds, otherwise logs warning)
8. Defaults to Speedometer mode
9. Starts periodic polling timer for non-published properties

### Mode Switching Logic

Mode switching occurs when:
- Navigation is started/stopped (via `LPUSH scooter:navigation start/stop`)
- Debug mode is explicitly enabled/disabled (via `LPUSH scooter:dashboard-mode debug`)
- Dashboard reads mode commands from Redis lists using BLPOP with infinite timeout

### Navigation Behavior

The navigation system responds to several states:
- Navigation triggered by `LPUSH scooter:navigation start` (using the Mapbox API - doesn't work anymore)
- Navigation stopped by `LPUSH scooter:navigation stop`
- Automatic rerouting when deviating from route (doesn't seem work)
- Trip summary displayed upon arrival (assumed from decompilation, could not trigger)

## Notification Types

The dashboard displays various notification types:

| Notification Category | Examples | Behavior |
|-----------------------|----------|----------|
| Battery Status | Low charge warnings, charging status | Timed or persistent based on condition |
| System Warnings | Faults, errors, system status | Persistent until condition resolves |
| Navigation Events | Turn instructions, arrival notices | Context-sensitive, tied to navigation state |
| Vehicle State | Kickstand, handlebar lock, seat status | Condition-based, auto-dismissing |

## Command-Line Options

The dashboard UI application accepts these command-line options that affect externally observable behavior:

| Option | Description |
|--------|-------------|
| `-b <bindaddress>` | Redis server bind address (default: 127.0.0.1) |
| `-p <redisport>` | Redis server port (default: 6379) |
| `--showFps` | Show FPS counter in top bar |
| `--show-internet-details` | Show connection type and signal strength in top bar |
| `--debug-gps` | Show GPS coordinates on screen |
| `--screenshot <delay>` | Take screenshot after startup delay in seconds |
| `--disable-poweroff` | Disable system poweroff during shutdown |

## System Integration

### Files Read
- `/sys/fsl_otp/HW_OCOTP_CFG0` - Hardware serial number (first part, hex format)
- `/sys/fsl_otp/HW_OCOTP_CFG1` - Hardware serial number (second part, hex format)
- `/etc/os-release` - OS version (VERSION_ID and BUILD_ID fields)

### System Commands
- `poweroff` - Executed during shutdown sequence (can be disabled with `--disable-poweroff`)

### Log Output Examples
- `"Could not read serial number. NOT setting dashboard:ready = true"` - Serial number read failure
- `"Could not load translations for any of the languages requested: [list]"` - Translation loading failure
- `"Power off is disabled."` - Poweroff disabled via command-line flag
- `"Could not power off the system!"` - Poweroff command failed
- `"Could not set up keep-alive socket, Redis connection handling might not work properly"` - Socket setup issue

## Redis Dependencies

The dashboard UI depends on these Redis services:

| Service | Key Pattern | Used For |
|---------|-------------|----------|
| vehicle | vehicle:* | Vehicle state, brake status |
| engine-ecu | engine-ecu:* | Speed, throttle, KERS status |
| battery | battery:{0,1}:* | Battery charge, status |
| navigation | navigation:* | Navigation status |
| gps | gps:* | Position data for map |
| internet | internet:* | Connection status |
| system | system:* | Firmware versions |
| dashboard | dashboard:* | Dashboard state and mode |
