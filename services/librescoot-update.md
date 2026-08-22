# librescoot-update (update-service)

## Description

Manages over-the-air (OTA) updates for MDB and DBC components. Runs as two separate instances (one per component), each checking a release index for available updates, downloading them via Mender, and orchestrating installation with safe reboot scheduling. Uses a power inhibitor client the other way round: while downloading, preparing or installing it registers a delay inhibit in `power:inhibits` so pm-service does not suspend or hibernate mid-update.

## Command-Line Options

```
  --component string         Component to update: mdb or dbc (required)
  --redis-addr string        Redis server address (default: localhost:6379)
  --channel string           Update channel: stable, testing, nightly (no default; inferred from the installed version, then from Redis settings. The service exits if no valid channel can be determined)
  --releases-url string      Release index base URL (default: https://downloads.librescoot.org/releases)
  --check-interval duration  Interval between update checks; 0 to disable (default: 6h)
  --download-dir string      OTA file download directory (default: /data/ota/{component})
  --dry-run                  Log reboot actions instead of executing them
  --boot-update              Enable boot partition updates
  --boot-mount string        Boot partition mount point (default: /uboot)
  --boot-device string       U-Boot device path (auto-detected if empty)
  --boot-dtb string          DTB filename (default: librescoot-{component}.dtb)
  --boot-uboot-seek int64    512-byte blocks to seek before writing U-Boot (default: 2)
```

CLI flags override Redis settings. `--component` and `--redis-addr` are CLI-only.

## Systemd Units

| Unit | Component |
|------|-----------|
| `librescoot-update.service` (MDB image) | MDB |
| `librescoot-update.service` (DBC image) | DBC |

The repo carries two unit files, `librescoot-update-mdb.service` and
`librescoot-update-dbc.service`, but the Yocto recipe installs the one matching
`MACHINE` as `librescoot-update.service`. Each board therefore runs a single
instance under that one unit name.

Binary: `/usr/bin/update-service`

## Redis Operations

### Hash: `ota` (written)

All fields are namespaced by component (`mdb` or `dbc`):

| Field | Description | Values |
|-------|-------------|--------|
| `status:{component}` | Current update status | `idle`, `downloading`, `preparing`, `installing`, `pending-reboot`, `error` |
| `update-version:{component}` | Target version being installed | e.g. `20251009t162327` |
| `update-method:{component}` | Update method in use | `full`, `delta` |
| `download-progress:{component}` | Download progress (0–100) | Integer or empty |
| `download-bytes:{component}` | Bytes downloaded | Integer or empty |
| `download-total:{component}` | Total download size in bytes | Integer or empty |
| `install-progress:{component}` | Install/delta application progress (0–100) | Integer or empty |
| `error:{component}` | Error type when status is `error` | `download-failed`, `install-failed`, `delta-failed`, `reboot-failed`, `file-not-found`, `invalid-file` |
| `error-message:{component}` | Human-readable error details | String or empty |

**Published channel:** `ota`

- All field updates are published atomically on state transitions

### Hash: `settings` (read/written)

**Fields read:**

- `updates.{component}.channel` — update channel (`stable`, `testing`, `nightly`)
- `updates.{component}.check-interval` — check interval (e.g. `6h`, `30m`)
- `updates.{component}.releases-url` — release index base URL
- `updates.{component}.dry-run` — dry-run mode (`true`/`false`)
- `updates.{component}.method` — update method (`full` or `delta`)
- `updates.mdb.orchestrate-dbc` — MDB-only: whether MDB orchestrates DBC updates

**Fields written:**

- `updates.{component}.last-check-time` — RFC3339 timestamp of last update check

**Subscribed channel:** `settings`

- All `updates.{component}.*` field changes are applied at runtime

### Hash: `version:{component}` (read)

- `version_id` — installed version string (used to detect channel and for delta base)
- `variant_id` — hardware variant identifier

### Lists consumed (BRPOP)

- `scooter:update:{component}` — component-specific commands:
  - `check-now` — trigger immediate update check
  - `update-from-file:/path/to/file.mender` — install from local file
  - `update-from-file:/path/to/file.mender:sha256:<hex>` — with checksum
  - `update-from-url:https://...` — install from URL
  - `update-from-url:https://...:sha256:<hex>` — with checksum

### Lists published (LPUSH)

- `scooter:power` → `reboot` — triggers system reboot after MDB update installs
- `scooter:update` - lifecycle commands written for vehicle-service to consume.
  update-service never reads this list.
  - `start-dbc` - signal DBC update is starting
  - `complete-dbc` - signal DBC update completed

### Hash: `power:inhibits` (written via inhibitor client)

Written during download/install to prevent suspend/hibernate. See [pm-service docs](librescoot-pm.md) for inhibitor details.

## Configuration via Redis

```bash
# Change update channel
redis-cli HSET settings updates.mdb.channel stable
redis-cli PUBLISH settings updates.mdb.channel

# Change check interval
redis-cli HSET settings updates.dbc.check-interval 12h
redis-cli PUBLISH settings updates.dbc.check-interval

# Switch to delta updates
redis-cli HSET settings updates.mdb.method delta
redis-cli PUBLISH settings updates.mdb.method

# Enable dry-run
redis-cli HSET settings updates.dbc.dry-run true
redis-cli PUBLISH settings updates.dbc.dry-run
```

## Commands

```bash
# Force immediate check (per component; there is no shared check-now list)
redis-cli LPUSH scooter:update:mdb check-now
redis-cli LPUSH scooter:update:dbc check-now

# Install from local file
redis-cli LPUSH scooter:update:dbc "update-from-file:/data/ota/librescoot-dbc-nightly-20251212T024719.mender"

# Install from URL
redis-cli LPUSH scooter:update:mdb "update-from-url:https://example.com/update.mender:sha256:abc123..."
```

## Update Method

- **full** — downloads and installs a complete Mender artifact
- **delta** — downloads a delta patch relative to the current version, applies it with xdelta; falls back to full if no base file exists

Configured via `updates.{component}.method` in Redis settings. Default is `delta`.

## Reboot Behavior

- **MDB**: waits until vehicle is in stand-by state for 3 minutes, then triggers reboot via `scooter:power`
- **DBC**: sets status to `pending-reboot`; reboot applied on next natural power-on (no active trigger)
- With `--dry-run`: logs reboot intent only

## File Locations

| Path | Purpose |
|------|---------|
| `/data/ota/mdb/` | MDB OTA download staging |
| `/data/ota/dbc/` | DBC OTA download staging |
| `/uboot` | Boot partition mount point (if `--boot-update`) |

## Building

```bash
make build         # ARM binary → bin/update-service (make dist is an alias for build)
make build-host    # Host binary for development
make fmt test lint # Format, test, lint
make deps          # go mod download && go mod tidy
```

## Related Documentation

- [LibreScoot Services](README.md)
- [Power Management](librescoot-pm.md) — inhibitor integration
- [UMS Service](librescoot-ums.md) — USB-based update delivery
