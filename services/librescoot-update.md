# librescoot-update (update-service)

## Description

Manages over-the-air (OTA) updates for MDB and DBC components. Runs as two separate instances (one per component), each checking a release index for available updates, downloading them via Mender, and orchestrating installation with safe reboot scheduling. Uses a power inhibitor client to prevent updates during critical vehicle operations.

## Command-Line Options

```
  --component string         Component to update: mdb or dbc (required)
  --redis-addr string        Redis server address (default: localhost:6379)
  --channel string           Update channel: stable, testing, nightly (default: nightly; auto-detected from installed version)
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
| `librescoot-update-mdb.service` | MDB |
| `librescoot-update-dbc.service` | DBC |

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
| `error:{component}` | Error type when status is `error` | `invalid-release-tag`, `download-failed`, `install-failed`, `reboot-failed` |
| `error-message:{component}` | Human-readable error details | String or empty |
| `download-abort-reason:{component}` | Why a download was abandoned for being too slow | `stalled`, `budget-exceeded`, or empty |
| `download-skip-checks:{component}` | Update checks still to be skipped before another download is attempted | Integer, or empty when no backoff applies |
| `heartbeat:{component}` | Unix seconds, refreshed while an update operation is running | Integer or empty |

**Published channel:** `ota`
- All field updates are published atomically on state transitions

#### Abandoned downloads

A download that is too slow is abandoned rather than left to run indefinitely. Each
attempt is bounded by a wall-clock cap and a rolling throughput floor (see the
`settings` fields below). When either bound is hit, the component returns to `idle`,
not `error`: the attempt was abandoned rather than failed, the partial file is kept,
and the next attempt resumes it.

`download-abort-reason` and `download-skip-checks` record what happened.
`download-bytes` and `download-total` are deliberately preserved across an abort so
the partial's progress stays visible. Both abort fields are cleared when a fresh
attempt starts, and they survive a service restart, because they mirror on-disk state
rather than describing the running process.

Consequently a scooter in a bad coverage area reads as `idle` with a non-empty
`download-abort-reason`, not as a fault. Consumers that only watch `status` will see
nothing wrong, which is intended.

The backoff is counted in update checks, not in elapsed time, and
`download-skip-checks` is the number still to be served. Each check that finds the
component backed off spends one and decrements the field. Counting checks rather than
storing a deadline keeps the ladder working on a scooter whose clock is wrong, which
a battery-less RTC or a boot before the modem attaches can easily produce, and it
costs nothing in expressiveness: retries only ever happen when a check runs, so a
deadline shorter than the check interval was never observable anyway.

For the DBC the count is spent by the MDB, not by the DBC itself. The MDB powers the
dashboard specifically in order to let it check, so a count only the DBC could
decrement would leave it backed off permanently. The MDB decrements as it declines to
power the dashboard, which means its own check cadence drives the countdown.

#### Heartbeat

`heartbeat:{component}` is refreshed every 30 seconds for the whole duration of an
update operation, including the quiet stretches: the delta path waits minutes between
download attempts with `status` still `downloading` and writes nothing else, and the
connect-retry loop can go similarly quiet.

The interval is a stable contract, not an implementation detail. A heartbeat older
than 90 seconds (three intervals) while `status:{component}` is non-terminal means the
reporter is gone rather than merely quiet, and the state may be treated as abandoned.
vehicle-service uses exactly this to decide how long a DBC update may hold dashboard
power.

### Hash: `settings` (read/written)

**Fields read:**
- `updates.{component}.channel` — update channel (`stable`, `testing`, `nightly`)
- `updates.{component}.check-interval` — check interval (e.g. `6h`, `30m`)
- `updates.{component}.releases-url` — release index base URL
- `updates.{component}.dry-run` — dry-run mode (`true`/`false`)
- `updates.{component}.download-max-duration` - wall-clock cap on a single download attempt (default `60m`, `0` disables)
- `updates.{component}.download-stall-window` - rolling window the download throughput floor is measured over (default `2m`, `0` disables)
- `updates.{component}.download-stall-min-bytes` - bytes that must arrive within each stall window (default `65536`)
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
  - `update-from-file:/path/to/file.mender#sha256=<hex>` - with checksum
  - `update-from-url:https://...` — install from URL
  - `update-from-url:https://...#sha256=<hex>` - with checksum
  - the legacy checksum form `:sha256:<hex>` is still accepted; `#sha256=` is preferred (keeps the source a valid URL)

Lifecycle commands (`start`, `complete`, `start-dbc`, `complete-dbc`) are **published** to the shared `scooter:update` list, which vehicle-service consumes to drive its `updating` state. update-service does not listen there itself.

### Lists published (LPUSH)

- `scooter:power` → `reboot` — triggers system reboot after MDB update installs
- `scooter:governor` → `ondemand` — requested at download start (full and delta paths) so pm-service switches the CPU out of powersave

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
# Force immediate check (per component)
redis-cli LPUSH scooter:update:mdb check-now
redis-cli LPUSH scooter:update:dbc check-now

# Install from local file
redis-cli LPUSH scooter:update:dbc "update-from-file:/data/ota/librescoot-dbc-nightly-20251212T024719.mender"

# Install from URL
redis-cli LPUSH scooter:update:mdb "update-from-url:https://example.com/update.mender#sha256=abc123..."
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
make dist          # ARM dist binary → update-service-arm-dist
make host          # Host binary for development
make install       # Install to /usr/bin/update-service
make tidy fmt test # Lint and test
```

## Related Documentation

- [Librescoot Services](README.md)
- [Power Management](librescoot-pm.md) — inhibitor integration
- [UMS Service](librescoot-ums.md) — USB-based update delivery
