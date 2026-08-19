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

Both boards run the same unit name, `librescoot-update.service`. There is no
`-mdb` or `-dbc` suffix on the installed unit; the component comes from the
arguments, and each board's image ships its own version of the file:

| Board | ExecStart |
|-------|-----------|
| MDB | `/usr/bin/update-service --component=mdb --boot-update` |
| DBC | `/usr/bin/update-service --component=dbc --redis-addr=192.168.7.1:6379 --boot-update` |

The DBC points at the MDB's datastore, since there is only one and it lives on the
MDB. `systemctl status librescoot-update` is the same command on either board.

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
| `error:{component}` | Error type when status is `error` | See [Error types](#error-types) |
| `error-message:{component}` | Human-readable error details | String or empty |
| `download-abort-reason:{component}` | Why a download was abandoned for being too slow | `stalled`, `budget-exceeded`, or empty |
| `download-skip-checks:{component}` | Update checks still to be skipped before another download is attempted | Integer, or empty when no backoff applies |
| `heartbeat:{component}` | Unix seconds, refreshed while an update operation is running | Integer or empty |

Two fields on the same hash are **not** namespaced, and describe the vehicle rather
than one board:

| Field | Description | Values |
|-------|-------------|--------|
| `status` | Flat update status, stock convention | `downloading-updates`, `installing-updates`, `installation-complete-waiting-reboot`, or empty |
| `update-type` | Whether the flat status blocks use of the vehicle | `blocking`, or empty |

**Published channel:** `ota`
- All field updates are published atomically on state transitions

#### Flat status

`status` and `update-type` mirror the per-component state into the non-namespaced
convention used by stock, for consumers that do not know about `status:mdb` and
`status:dbc`. They carry no information the namespaced fields lack; anything written
against Librescoot should read those instead.

The mapping from a component's status:

| Component status | `status` | `update-type` |
|---|---|---|
| `downloading` | `downloading-updates` | `blocking` |
| `preparing`, `installing` | `installing-updates` | `blocking` |
| `pending-reboot` | `installation-complete-waiting-reboot` | `blocking` |
| `idle`, `error`, absent, unrecognised | empty | empty |

Both components feed the same pair, and when they disagree **the least advanced one
wins**. If the MDB is still downloading while the DBC is staged and waiting for its
power cycle, the pair reads `downloading-updates`. The pair only clears once neither
board is busy, so a consumer asking "is this scooter mid-update" never sees it clear
while one board is still pulling bytes.

The MDB's update-service is the sole writer. It watches `status:mdb` and `status:dbc`
and recomputes on either change, including once at startup, so a service restart in
the middle of an update cannot leave a stale `blocking` behind. The DBC never writes
these fields; a second writer would race the first on the same two keys.

An `error` on either component maps to the empty pair, not to a distinct flat value.
A consumer that needs to distinguish a failed update from no update has to read
`error:{component}`.

#### Error types

Values `error:{component}` takes, with `error-message:{component}` carrying the detail.

| Value | Meaning |
|-------|---------|
| `download-failed` | The artifact could not be fetched |
| `checksum-mismatch` | A downloaded or staged file did not match its expected checksum |
| `file-not-found` | A path given to `update-from-file:` does not exist |
| `invalid-file` | A path given to `update-from-file:` is neither a `.mender` nor a `.delta` |
| `image-too-large` | The artifact's rootfs payload is larger than the rootfs slot it would be written to. Checked before installation starts, so nothing is written |
| `install-failed` | `mender-update install` failed |
| `no-base-image` | A delta arrived with no local `.mender` for the running version to apply it against |
| `delta-rejected` | A delta does not apply to the installed version (wrong channel, or not newer) |
| `delta-apply-failed` | Applying a locally delivered delta failed |
| `delta-failed` | A delta update failed and a full update is being started instead. Transient: cleared to `idle` after two seconds, then the full update proceeds |
| `reboot-failed` | The update installed but the reboot could not be triggered |

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
component backed off spends one and updates the field. Counting checks rather than
storing a deadline keeps the ladder working on a scooter whose clock is wrong, which
a battery-less RTC or a boot before the modem attaches can easily produce.

The escalation is stored as a rung, not as a fixed count, and the count is recomputed
from the current `check-interval` every time a skip is served. Changing the interval
therefore rescales an outstanding backoff instead of stranding it: 48 skips recorded
while testing at `30m` do not become twelve days when the interval returns to `6h`.

Each component serves its own ladder on its own checks. Note the DBC only checks when
it is powered, so its checks are events rather than a cadence, and several short rides
in a day can spend a backoff that was sized for one.

#### Heartbeat

`heartbeat:{component}` is refreshed every 30 seconds for the whole duration of an
update operation, including the quiet stretches: the delta path waits minutes between
download attempts with `status` still `downloading` and writes nothing else, and the
connect-retry loop can go similarly quiet.

The interval is a stable contract, not an implementation detail, so a consumer may
treat a heartbeat that has stopped advancing as evidence the reporter is gone rather
than merely quiet.

Two cautions for anyone building on that.

`pending-reboot` is not a quiet operation, it is a finished one. A DBC install ends
there and the heartbeat stops, legitimately, until the next power cycle applies the
update. Only `downloading`, `preparing` and `installing` are states where a stopped
heartbeat means something is wrong. A staleness test that says "non-terminal" without
naming those three will flag every successfully updated DBC.

An absent heartbeat is not a stale one. Images before this field existed never write
it, so a consumer must require that a heartbeat has been observed for the current
operation before applying any age test, or it will condemn healthy devices running
older firmware.

vehicle-service does **not** apply an age test. It runs an inactivity timer reset by
any `ota` field ending in `:dbc`, `download-bytes:dbc` included, and uses the heartbeat
only as a one-way capability flag: once it has seen one, it shortens that timer from
15 minutes to 3. The on-vehicle threshold is therefore 3 minutes of total field
silence, not 90 seconds of heartbeat age.

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
  - `preview-channel:<channel>` — report what a switch to `<channel>` would fetch, without changing anything
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

# Price a channel switch before committing to it
redis-cli LPUSH scooter:update:mdb preview-channel:stable
redis-cli LPUSH scooter:update:dbc preview-channel:stable
redis-cli HMGET ota preview-status:mdb preview-version:mdb preview-size:mdb
```

## Channel Previews

`preview-channel:<channel>` answers "what would switching to this channel fetch" before
anything is committed to. It reads the release index for `<channel>`, resolves the
latest release carrying a `.mender` for this component's `variant_id`, and publishes the
tag and artifact size to the `ota` hash. It sets no configuration, starts no download,
and never writes the update status fields, so it is safe to issue mid-update.

| Field | Meaning |
|-------|---------|
| `preview-channel:{component}` | The channel asked about, echoed so a reader can spot a stale answer |
| `preview-status:{component}` | `checking`, `ready`, `unavailable`, or `error` |
| `preview-version:{component}` | Release tag, on `ready` |
| `preview-size:{component}` | Bytes of the full `.mender` artifact, on `ready` |

`unavailable` means the channel carries nothing for this board's variant, which is a
real answer rather than a failure to retry. `error` covers an invalid channel and a
release index that could not be reached: a preview is bounded at 20 seconds end to end
rather than running the full retry ladder a background check uses, because a rider is
waiting on it. All four fields are cleared at service start.

The size reported is always the full artifact. A channel switch has no delta base to
patch against, so `checkForUpdates` forces `full` whenever the installed version's
channel differs from the configured one, whatever `updates.{component}.method` says.

Each component answers only for itself. The dashboard's
Settings > System > Updates > Switch Release Channel entry asks both and sums the two sizes
before prompting the rider to confirm.

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
