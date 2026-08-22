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
- `status` - Service status (`idle`, `preparing`, `active`, `processing`, `awaiting-reboot`)
  - `awaiting-reboot` is set while a UMS-initiated update install runs and the service waits for the post-install reboot (see UMS exit flow). It transitions back to `idle` once the reboot is triggered, the wait fails/times out, or a new UMS session cancels the pending reboot.
- `step` - Current processing step (`settings`, `wireguard`, `radio-gaga`, `uplink-service`, `onboot`, `updates`, `maps`, or empty). The RPM and script stages run without setting `step`.
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

### Brake exit

The service subscribes to the `input-events` channel and acts on exactly one
event, `brake:left:hold` (vehicle-service emits it after a 3 s hold). Other
namespaced gestures such as `brake:right:press` and `seatbox:tap` are ignored,
so a stray input cannot interrupt a transfer.

What the hold does depends on where the service is:

- **While preparing** (`status` is `preparing`): the entry is abandoned before
  `SwitchMode` runs. The drive is already unmounted and the gadget was never
  touched, so `g_ether` stays loaded and the DBC's link survives. `usb.mode` is
  reconciled back to `normal` and `status` returns to `idle`. Librescoot 1.2 and
  later.
- **Once UMS is active**: `doSwitchToNormal` runs, which is the same path as a
  USB eject: the full exit processing below happens, including any queued update
  install and reboot. It is not a bail-out.

The cancel flag is recorded before taking the service mutex, because
`switchToUMS` holds that mutex for the whole preparing phase; setting the flag
first lets the in-flight entry observe it and abandon itself.

`scootui-qt` mirrors this on the UMS overlay, labelling the left-brake hold
`Cancel` while `status` is `preparing` and `Exit` otherwise.

## Virtual Drive

1 GB FAT32 image at `/data/usb.drive`:

```
/
├── settings.toml        # copied from /data/settings.toml if present
├── wireguard/           # WireGuard VPN configs
│   └── *.conf
├── radio-gaga/
│   └── config.yaml      # copied from /data/radio-gaga/config.yaml
├── uplink-service/
│   └── config.yaml      # copied from /data/uplink-service/config.yaml
├── onboot.sh            # copied from the on-boot script if present
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
├── log-bundles/         # pre-populated: bundles previously captured with lsc
├── diagnostics/         # pre-populated on UMS entry (read-only for user)
│   ├── mdb/
│   └── dbc/             # only if DBC was reachable at UMS entry
└── ums_log.txt          # written on exit, survives the post-processing wipe
```

## File Processing

### On UMS entry

1. Copies `/data/settings.toml` to drive root (if present)
2. Copies `/data/wireguard/*.conf` to `wireguard/`
3. Copies `/data/radio-gaga/config.yaml` to `radio-gaga/` and `/data/uplink-service/config.yaml` to `uplink-service/`
4. Copies the on-boot script to `onboot.sh`
5. Creates `system-update/`, `maps/`, `rpms/mdb/`, `rpms/dbc/`, `scripts/` and `log-bundles/` directories
6. Copies existing log bundles from `/data/log-bundles` to `log-bundles/`
7. Collects diagnostics to `diagnostics/mdb/` (journal, dmesg, system info) and `diagnostics/dbc/` if DBC is reachable. The MDB `system-info.txt` ends with a `=== modem ===` section read from the `internet` and `modem` hashes (IMEI, ICCID, IMSI, operator, access tech, signal, registration, connectivity, IP, health, SIM/PIN/APN state); fields Redis has no value for print as `-`

The config files above are round-trips: whatever comes back on exit is read
into place, and an untouched file is a no-op.

### On UMS exit (returning to normal mode)

1. **Settings** - copies `settings.toml` back to `/data/`, restarts settings-service if changed
2. **WireGuard** - syncs `*.conf` files to `/data/wireguard/`, removes local configs absent from drive, restarts settings-service if changed
3. **radio-gaga** - copies `radio-gaga/config.yaml` back to `/data/radio-gaga/`, restarts `radio-gaga.service` if changed
4. **uplink-service** - copies `uplink-service/config.yaml` back to `/data/uplink-service/`, restarts `librescoot-uplink.service` if changed
5. **onboot** - copies `onboot.sh` back into place
6. **Updates** - MDB `.mender`/`.delta` files installed locally via `scooter:update:mdb`; DBC `.mender`/`.delta` files transferred to DBC and queued via `scooter:update:dbc`
7. **Maps** - transfers `.mbtiles` to `/data/maps/map.mbtiles` on DBC; transfers Valhalla tile archives to `/data/valhalla/tiles.tar` on DBC. A `valhalla_tiles_*.tar.zst` is uploaded compressed and decompressed on the DBC, into a temp file that only replaces `tiles.tar` once the whole stream has decoded; the installed file is always the plain seekable tar, because Valhalla mmaps it as its `tile_extract`
8. **RPMs** - installs `rpms/mdb/*.rpm` locally via `rpm -Uvh --force`; transfers and installs `rpms/dbc/*.rpm` on DBC
9. **Scripts** - runs `scripts/mdb.sh` locally; transfers `scripts/dbc.sh` to DBC and runs it remotely
10. Writes `ums_log.txt` to drive root, then cleans the drive (preserving `ums_log.txt`)

Each step is independent: a failure is logged to `usb:log` and the remaining
steps still run.

**Post-update reboot:** if the exit processing queued an MDB or DBC update install, the service sets `status` to `awaiting-reboot` and a background watcher performs the install pushes, waits for completion (10 min timeout), then triggers a reboot. The reboot is gated on the vehicle state being in an allowed set (`stand-by`, `parked`, `shutting-down`); if the state is anything else, the reboot is skipped. MDB updates reboot the MDB via `scooter:power`; DBC-only updates power-cycle the dashboard via `scooter:hardware`. The watcher is cancellable: re-entering UMS cancels a pending reboot. When no update is queued, `status` goes straight back to `idle` with no reboot.

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

- [Librescoot Services](README.md)
- [Settings Service](librescoot-settings.md)
- [Update Service](librescoot-update.md)
