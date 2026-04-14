# librescoot-scootui (scootui-qt)

> The original Flutter/Dart scootui is deprecated and replaced by this Qt/QML version.

## Description

ScootUI is the primary user interface for LibreScoot. It runs on the DBC (Dashboard Computer) and communicates with all LibreScoot services via Redis.

- **Qt 6 / QML** — UI framework
- **QMapLibre** — Vector map rendering
- **Valhalla** — Routing engine
- **hiredis** — Redis client (async pub/sub + worker thread for polling)
- **CMake** — Build system

## Features

### Real-time Telemetry Display
- Speed (raw or wheel-corrected), power output, battery levels
- Odometer, trip meter, GPS status, connectivity indicators
- System warnings and fault codes

### View Modes
- **Cluster** — Speedometer and vehicle status
- **Map** — 3D-tilted navigation with turn-by-turn directions
- **Destination** — Saved locations and destination input
- **Navigation Setup** — Route preview and confirmation
- **OTA Update** — System update progress and control

### Navigation
- Offline vector map support (MBTiles via QMapLibre)
- Online map tiles (CartoDB) as alternative
- Valhalla routing (on-device or remote)
- Speed limit indicators from vector tiles
- Auto-rotating map with heading tracking

### Other
- Alarm status display
- Hop-on / hop-off combo lock screen
- Light and dark themes with auto-switching
- Configurable blinker overlay styles
- Multi-language support

## Build

### Desktop (simulator mode)

```bash
./run-desktop.sh
```

Or manually:

```bash
cmake -B build -DDESKTOP_MODE=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j$(nproc)
SCOOTUI_REDIS_HOST=none ./build/bin/scootui
```

`SCOOTUI_REDIS_HOST=none` disables Redis and activates the built-in simulator.

### Target (cross-compile for i.MX6 armhf)

```bash
./cross-build.sh [Release|Debug]
```

Produces `deploy-armhf/` with binary, Qt plugins, and launcher. Deploy:

```bash
scp -r deploy-armhf/* target:/opt/scootui/
ssh target /opt/scootui/run-scootui.sh
```

### Make shortcuts

```bash
make build    # Configure and build
make run      # Build and run
make clean    # Remove build directory
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SCOOTUI_REDIS_HOST` | `192.168.7.1` | Redis host. `none` = simulator mode. Supports `host:port`. |
| `SCOOTUI_RESOLUTION` | `480x480` | Display resolution (`WIDTHxHEIGHT`) |
| `SCOOTUI_SETTINGS_PATH` | _(none)_ | Path to persistent settings file |

## Redis Operations

### Subscriptions (pub/sub + periodic HGETALL)

| Channel | Store | Poll interval |
|---------|-------|--------------|
| `engine-ecu` | EngineStore | 200 ms |
| `vehicle` | VehicleStore, AutoStandbyStore | 500–1000 ms |
| `buttons` | VehicleStore, ShortcutMenuStore | event-driven |
| `battery:0`, `battery:1` | BatteryStore | 30 s |
| `gps` | GpsStore | 1 s |
| `ble` | BluetoothStore | 5 s |
| `internet` | InternetStore | 5 s |
| `navigation` | NavigationStore | 5 s |
| `settings` | SettingsStore | 5 s |
| `ota` | OtaStore | 5 s |
| `usb` | UsbStore | 5 s |
| `speed-limit` | SpeedLimitStore | 5 s |
| `cb-battery` | CbBatteryStore | 30 s |
| `aux-battery` | AuxBatteryStore | 30 s |
| `dashboard` | DashboardStore | 500 ms |

Additionally polled (no subscription): `system`, `version:mdb`, `version:dbc` (30 s).

### HSET Writes

| Hash | Field | Value | When |
|------|-------|-------|------|
| `dashboard` | `ready` | `true` | Startup and every Redis reconnect |
| `dashboard` | `serial-number` | Hardware serial | Startup (if readable) |
| `dashboard` | `backlight-enabled` | `true`/`false` | On backlight control |
| `navigation` | `destination` | `lat,lon` | When destination is set |
| `settings` | `dashboard.*` | user values | On settings changes via menu |
| `usb` | `mode` | `normal`/`ums-by-dbc` | On USB mode change |

### LPUSH Commands

| List | Commands | Written by |
|------|----------|-----------|
| `scooter:blinker` | `left`, `right`, `both`, `off` | Blinker/hazard controls |
| `scooter:hop-on` | `engage`, `engage-silent`, `release` | HopOnStore |

### HDEL

- `navigation destination`, `latitude`, `longitude`, `address`, `timestamp` — on destination clear

### LRANGE

- `usb:log` (indices 0–19) — UMS transfer log, polled while `usb status` is `processing`

## Settings

Settings are stored in the `settings` Redis hash. Managed by settings-service.

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `dashboard.show-raw-speed` | `true`/`false` | `false` | Raw ECU speed vs wheel-corrected |
| `dashboard.show-gps` | `always`/`active-or-error`/`error`/`never` | `error` | GPS icon visibility |
| `dashboard.show-bluetooth` | `always`/`active-or-error`/`error`/`never` | `active-or-error` | Bluetooth icon |
| `dashboard.show-cloud` | `always`/`active-or-error`/`error`/`never` | `error` | Cloud connection icon |
| `dashboard.show-internet` | `always`/`active-or-error`/`error`/`never` | `always` | Cellular icon |
| `dashboard.show-clock` | `true`/`false` | `true` | Clock visibility |
| `dashboard.theme` | `light`/`dark`/`auto` | `auto` | UI theme |
| `dashboard.blinker-style` | `icon`/`overlay` | `icon` | Blinker indicator style |
| `dashboard.language` | `en`, `de`, … | `en` | UI language |
| `dashboard.battery-display-mode` | `percentage`/`range` | `percentage` | Battery display |
| `dashboard.power-display-mode` | `kw`/`amps` | `kw` | Power unit |
| `dashboard.mode` | `speedometer`/`navigation` | `speedometer` | Default screen |
| `dashboard.map.type` | `online`/`offline` | `offline` | Map source |
| `dashboard.map.render-mode` | `vector`/`raster` | `raster` | Offline map rendering |
| `dashboard.map.traffic-overlay` | `true`/`false` | `false` | Traffic overlay (online only) |
| `dashboard.valhalla-url` | URL | `http://127.0.0.1:8002/` | Valhalla routing endpoint |
| `dashboard.maps.check-for-updates` | `true`/`false` | `true` | Auto-check for map updates |
| `dashboard.maps.auto-download` | `true`/`false` | `false` | Auto-download map updates |
| `dashboard.hop-on-combo` | pipe-delimited tokens | _(empty)_ | Custom hop-on unlock combo |

## Hardware Interfaces

### Serial Number

Primary: `/sys/devices/soc0/serial_number`

Fallback (OTP fuses): `/sys/fsl_otp/HW_OCOTP_CFG0` + `HW_OCOTP_CFG1`

### Boot Animation

On Linux startup:
1. Fades in framebuffer overlay: `imx-overlay-alpha fade 0 255 1000` (skipped on kernel 6.6 imx-drm)
2. Stops boot animation: `systemctl stop boot-animation.service`

### Shutdown

On SIGTERM or `vehicle state` → `shutting-down`: `ShutdownStore::forceBlackout()` blacks out the display.

## Map Tiles

Offline tiles expected at `/data/maps/map.mbtiles` on the DBC. The app watches `/data/maps/` via inotify and reloads map services when the file appears or changes.

## Project Structure

```
src/
  core/           App initialization, environment config
  models/         Data models and enums
  repositories/   Redis (hiredis-based) and in-memory MDB implementations
  stores/         QML-exposed state stores
  services/       System services (navigation, settings, map, input, ...)
  routing/        Valhalla client and route models
  simulator/      Simulator service (desktop mode only)
  l10n/           Translations
qml/
  screens/        Main UI screens
  widgets/        Reusable UI components
  overlays/       Modal overlays (menu, toast, ...)
  simulator/      Simulator panel (desktop mode only)
  theme/          Theme definitions
```

## Dependencies

- Redis server
- Qt 6.4+ (Quick, Qml, Svg, Network, Sql, Concurrent)
- QMapLibre (required on target; optional in desktop mode)
- hiredis
- Valhalla routing engine

## Related Documentation

- [dashboard/README.md](../dashboard/README.md) — Complete dashboard documentation
- [dashboard/REDIS.md](../dashboard/REDIS.md) — Redis operations reference
- [Redis Operations](../redis/README.md) — Dashboard hash fields
- [States](../states/README.md) — Vehicle state display
