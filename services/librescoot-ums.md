# librescoot-ums (ums-service)

## Description

Manages USB gadget mode switching on the MDB between network (`g_ether`) and USB Mass Storage (`g_mass_storage`) modes. In UMS mode, exposes a 1 GB FAT32 virtual drive at `/data/usb.drive` to the host PC. On switching back to normal mode, processes files placed on the drive: syncs settings and WireGuard configs, installs Mender updates and RPMs, runs scripts, and transfers maps to the DBC.

## Command-Line Options

```
REDIS_ADDR=localhost:6379    Redis server address (environment variable)
REDIS_PASSWORD=              Redis password (environment variable)
UMS_MAP_TIMEOUT=10m          Per-file timeout for map transfers (environment variable)
UMS_RPM_TIMEOUT=5m           Per-file timeout for RPM transfers (environment variable)
UMS_SCRIPT_TIMEOUT=2m        Per-file timeout for script transfers (environment variable)
UMS_MENDER_TIMEOUT=15m       Per-file timeout for Mender update transfers (environment variable)
```

## Redis Operations

### Hash: `usb`

**Fields read/written:**
- `mode` - Current USB mode (`normal`, `ums`, `ums-by-dbc`)

**Fields written:**
- `status` - Service status (`idle`, `preparing`, `active`, `processing`)
- `step` - Current processing step (`settings`, `wireguard`, `updates`, `maps`, or empty)
- `progress` - Upload progress percentage (0–100) during file transfers
- `detail` - Human-readable transfer sub-step (e.g. `map.mbtiles (120/380 MB)`)

**Subscribed channel:** `usb`
- `mode` - Triggers mode switch when published

### List: `usb:log`

Processing events are pushed here in real-time during UMS exit processing. Capped at 100 entries. Also written to `ums_log.txt` on the drive at the end of processing.

### LED feedback

Uses blinker channels 3, 4, 6, 7 via `scooter:led:fade` to indicate UMS state:

| State | LEDs |
|-------|------|
| UMS active (host connected) | All 4 blinker channels on |
| `ums-by-dbc`: first disconnect, waiting for PC | Front blinkers (3, 4) only |
| Normal / off | All 4 off |

## USB Modes

```bash
# Switch to USB Mass Storage mode
redis-cli HSET usb mode ums
redis-cli PUBLISH usb mode

# UMS mode with DBC-specific double-disconnect behavior
redis-cli HSET usb mode ums-by-dbc
redis-cli PUBLISH usb mode

# Return to normal (g_ether) mode
redis-cli HSET usb mode normal
redis-cli PUBLISH usb mode
```

**Mode behavior:**
- **ums** — returns to normal after first USB disconnect
- **ums-by-dbc** — stays in UMS after first disconnect, switches to normal after second disconnect (for DBC updates, which may disconnect and reconnect mid-process)
- **normal** — standard g_ether USB network mode

Holding the left brake while in UMS mode also triggers an immediate return to normal mode (via the `input-events` Redis channel).

## Virtual Drive

1 GB FAT32 image at `/data/usb.drive`:

```
/
├── settings.toml        # copied from /data/settings.toml if present
├── wireguard/           # WireGuard VPN configs
│   └── *.conf
├── system-update/       # place .mender or .delta update files here
│   ├── librescoot-mdb-*.mender
│   └── librescoot-dbc-*.mender
├── maps/                # place map files here
│   ├── *.mbtiles
│   └── *tiles.tar or valhalla_tiles_*.tar
├── rpms/
│   ├── mdb/             # RPMs to install on MDB
│   └── dbc/             # RPMs to transfer and install on DBC
├── scripts/
│   ├── mdb.sh           # shell script to run on MDB
│   └── dbc.sh           # shell script to transfer and run on DBC
└── diagnostics/         # pre-populated on UMS entry (read-only for user)
    ├── mdb/
    └── dbc/             # only if DBC was reachable at UMS entry
```

## File Processing

### On UMS entry

1. Copies `/data/settings.toml` to drive root (if present)
2. Copies `/data/wireguard/*.conf` to `wireguard/`
3. Creates `system-update/`, `maps/`, `rpms/mdb/`, `rpms/dbc/`, and `scripts/` directories
4. Collects diagnostics to `diagnostics/mdb/` (journal, dmesg, system info) and `diagnostics/dbc/` if DBC is reachable

### On UMS exit (returning to normal mode)

1. **Settings** — copies `settings.toml` back to `/data/`, restarts settings-service if changed
2. **WireGuard** — syncs `*.conf` files to `/data/wireguard/`, removes local configs absent from drive, restarts settings-service if changed
3. **Updates** — MDB `.mender`/`.delta` files installed locally via `scooter:update:mdb`; DBC `.mender`/`.delta` files transferred to DBC and queued via `scooter:update:dbc`
4. **Maps** — transfers `.mbtiles` to `/data/maps/map.mbtiles` on DBC; transfers Valhalla tile archives to `/data/valhalla/tiles.tar` on DBC
5. **RPMs** — installs `rpms/mdb/*.rpm` locally via `rpm -Uvh --force`; transfers and installs `rpms/dbc/*.rpm` on DBC
6. **Scripts** — runs `scripts/mdb.sh` locally; transfers `scripts/dbc.sh` to DBC and runs it remotely
7. Writes `ums_log.txt` to drive root, then cleans the drive (preserving `ums_log.txt`)

## Hardware

- **Network mode:** `g_ether` kernel module
- **UMS mode:** `g_mass_storage` kernel module
- Requires root for `modprobe`/`rmmod` operations
- DBC file transfers: HTTP PUT to port 8080 on `192.168.7.2` (primary); SCP fallback. MDB serves staging files over HTTP at `192.168.7.1:31337`.

## File Locations

| Path | Purpose |
|------|---------|
| `/data/usb.drive` | Virtual USB drive image |
| `/data/settings.toml` | Device settings |
| `/data/wireguard/` | WireGuard VPN configs |
| `/data/ota/` | OTA update staging |
| `/data/dbc/` | DBC file staging |

## Building

```bash
make build        # ARM7
make build-amd64  # AMD64
```

## Related Documentation

- [LibreScoot Services](librescoot-services.md)
- [Settings Service](librescoot-settings.md)
- [Update Service](librescoot-update.md)
