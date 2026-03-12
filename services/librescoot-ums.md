# librescoot-ums (ums-service)

## Description

Manages USB gadget mode switching on the MDB between network (`g_ether`) and USB Mass Storage (`g_mass_storage`) modes. In UMS mode, exposes a 1 GB FAT32 virtual drive at `/data/usb.drive` to the host PC. On switching back to normal mode, processes files placed on the drive: syncs settings and WireGuard configs, installs Mender updates, and transfers maps to the DBC.

## Command-Line Options

```
REDIS_ADDR=localhost:6379    Redis server address (environment variable)
```

## Redis Operations

### Hash: `usb`

**Fields read/written:**
- `mode` - Current USB mode (`normal`, `ums`, `ums-by-dbc`)

**Fields written:**
- `status` - Service status (`idle`, `preparing`, `active`, `processing`)

**Subscribed channel:** `usb`
- `mode` - Triggers mode switch when published

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

## Virtual Drive

1 GB FAT32 image at `/data/usb.drive`:

```
/
├── settings.toml        # copied from /data/settings.toml if present
├── wireguard/           # WireGuard VPN configs
│   └── *.conf
├── system-update/       # place .mender update files here
│   ├── librescoot-mdb-*.mender
│   └── librescoot-dbc-*.mender
└── maps/                # place map files here
    ├── *.mbtiles
    └── *tiles.tar or valhalla_tiles_*.tar
```

## File Processing

### On UMS entry

1. Copies `/data/settings.toml` to drive root (if present)
2. Copies `/data/wireguard/*.conf` to `wireguard/`
3. Creates `system-update/` and `maps/` directories

### On UMS exit (returning to normal mode)

1. **Settings** — copies `settings.toml` back to `/data/`, restarts settings-service
2. **WireGuard** — syncs `*.conf` files to `/data/wireguard/`, removes local configs absent from drive, restarts settings-service if changed
3. **Updates** — MDB `.mender` files installed locally and marked for reboot; DBC `.mender` files transferred to DBC and installed remotely
4. **Maps** — transfers `.mbtiles` or Valhalla tile archives to DBC at `/data/maps/map.mbtiles`
5. Cleans the drive
6. Reboots if an update was installed

## Hardware

- **Network mode:** `g_ether` kernel module
- **UMS mode:** `g_mass_storage` kernel module
- Requires root for `modprobe` operations
- DBC file transfers: SSH/SCP to `192.168.7.2` via HTTP server at `192.168.7.1:31337`

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
