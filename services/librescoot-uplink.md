# librescoot-uplink (uplink-service)

## Purpose and ownership

uplink-service is the scooter-side client of the Librescoot uplink system. It
authenticates against the configured uplink server over WebSocket and bridges
vehicle Redis/Valkey state to the cloud in both directions: telemetry, events,
and state snapshots out; cloud commands in. The cloud-side peer is
[uplink-server](https://github.com/librescoot/uplink-server), a separate
repository that is never packaged into vehicle images.

It reads the state hashes (HGETALL) listed under
[service-interactions](../service-interactions.md#uplink-service), consumes the
`events:faults` and `ota:errors` streams, writes its own provider field
`remote-access[uplink-service]` (`connected`/`disconnected`) plus the legacy
`internet[unu-cloud]` mirror, and produces the vehicle command queues from
cloud requests. The `settings` hash is mirrored to the cloud only through a
field allowlist (`updates.*`, `pm.*`, `alarm.*`, `trip.*`, `engine-ecu.*`,
`dashboard.service-mode-active`, `scooter.developer-mode`,
`scooter.dual-battery`); credentials and saved locations stay on the vehicle.

## Build, packaging, and service

- Go with `CGO_ENABLED=0`, no CGO; builds fully static. `make deps`, `make
  build` (host), `make build-arm` (linux/arm, `GOARM=7`), `make dist`
  (stripped), `make test`, `make lint`, `make fmt`.
- The version comes from `git describe --tags --always --dirty`, injected into
  `main.version` with `-ldflags -X`; `uplink-service -version` prints it.
- Flags: `uplink-service [-config PATH] [-version]`. The default config path is
  `/data/uplink-service/uplink.yaml`.
- Yocto packaging lives in `meta-librescoot/recipes-core/uplink-service/`
  (`SRCREV = ${AUTOREV}` on `main`), which installs `/usr/bin/uplink-service`
  and the `librescoot-uplink.service` systemd unit, enabled at boot. The unit
  starts only when the config file exists
  (`ConditionPathExists=/data/uplink-service/uplink.yaml`), orders after and
  requires `redis.service`, runs with `Restart=always` (5 s), and creates
  `/data/uplink-service/` as its working directory.

## Configuration

YAML, top-level keys `uplink`, `scooter`, `telemetry`, `events`,
`notifications`, `commands`, `ntp`, `environment`, `service_name`,
`redis_url`. Start from `configs/uplink.example.yml` in the repository.
Code defaults (applied when a key is absent):

| Key | Default | Meaning |
|-----|---------|---------|
| `uplink.server_url` | — (required) | WebSocket URL of the uplink server |
| `uplink.keepalive_interval` | `5m` | Client keepalive cadence |
| `uplink.reconnect_max_delay` | `5m` | Cap for the reconnect backoff |
| `scooter.identifier` / `scooter.token` | — (required) | Server-issued credential presented in `auth` |
| `scooter.name` | empty | Optional display name |
| `environment` | `production` | `development` unlocks otherwise-restricted commands (notably `shell`) |
| `service_name` | auto-detected | systemd unit name used by the `restart` command |
| `ntp.enabled` / `ntp.server` | `true` / `pool.ntp.org` | Clock synchronisation; the clock counts as trusted only after the first successful sync — until then telemetry timestamps are monotonic-relative and reprojected afterwards |
| `telemetry.transmit_period` | `5m` | How often the offline telemetry buffer drains |
| `telemetry.event_buffer_path` | `/data/uplink-service/events.queue` | Line-oriented offline event buffer |
| `telemetry.event_max_retries` | `5` | Delivery attempts before a buffered event is discarded |
| `telemetry.buffer.max_size` | `1000` | Offline snapshots kept before subsampling |
| `telemetry.buffer.max_retries` / `retry_interval` | `5` / `1m` | Snapshot delivery retries |
| `telemetry.buffer.persist_path` | `/data/uplink-service/telemetry-buffer.json` | Survives restarts |
| `telemetry.intervals` | driving `30s`, standby `5m`, standby_no_battery `8h`, hibernate `24h` | Liveness cadence: `ready-to-drive` uses driving, `hibernating` uses hibernate, all other states use standby (main battery present) or standby_no_battery (absent) |
| `redis_url` | `localhost:6379` | Vehicle Redis/Valkey |

`commands.<name>.disabled` turns a single remote command off and
`commands.<name>.params` supplies default parameters (the shipped example
disables `redis`, the raw-debug command). The `events.movement` detector and
the `notifications` (Telegram/SMS/rules) sections are parsed and validated but
their detector and channels are not implemented yet.

## Telemetry

State is collected from the hash list in
[service-interactions](../service-interactions.md#uplink-service) and sent as:

- a **full snapshot** on every successful connection (after baseline
  initialization) and on the `get_state` command;
- **incremental changes** from hash watchers, debounced per priority —
  Immediate `1s`, Quick `5s`, Medium `60s`, Slow `15m`. `vehicle[state]`,
  lock/blinker state, `power-manager[state]`, `ota[status]`, and alarm status
  are Immediate; GPS, batteries, and `usb[mode]` are Quick; trip, navigation,
  and remote-access fields are Medium; versions, busy services, `settings`,
  and `scooter[temperature]` are Slow. Sub-threshold sensor noise is
  quantized away (e.g. battery voltages in 100 mV steps) and a few
  always-changing fields (GPS position, `internet[signal-quality]`) never
  trigger a transmission on their own.

The collector adds `meta.build-version`, `meta.environment`,
`meta.identifier`, an MDB board serial, and modem fields. Vehicle states
`hop-on` and `hop-on-learning` are reported as `stand-by` and `parked`
(the cloud protocol does not know the hop-on family). While disconnected,
changes accumulate in the persistent offline buffer and drain after
reconnect; the telemetry baseline resets on disconnect so the next connection
starts with a fresh full snapshot.

## Events

Events are sent when connected and buffered to the line-oriented event file
otherwise, with exponential retries up to `event_max_retries`. Emitted types:

`battery_critical`, `cb_battery_critical`, `power_state_change`, `nrf_reset`,
`connectivity_lost`/`connectivity_regained`, `lock_state_change`
(handlebar/seatbox), `gps_fix_lost`/`gps_fix_regained`,
`temperature_warning`, `ota_status_change`, `ota_error` (new `event=error`
entries from the `ota:errors` stream), `alarm_triggered`/`alarm_cleared`,
`alarm_state_change`, `usb_mode_change`, and `fault` (forwarded from the
`events:faults` stream with `group`, `code`, optional `description`).

Both stream consumers start at `$`: historical entries are not replayed.

## Commands

Cloud commands are allowlisted, config-gated (`commands.<name>.disabled`),
and acknowledged with a `command_response` carrying the original request ID
and a `success`/`failed` status. Redis-side mappings:

| Remote command | Vehicle-side action |
|---|---|
| `unlock`, `lock`, `lock_hibernate`, `force_lock` | `scooter:state`: `unlock`, `lock`, `lock-hibernate`, `force-lock` |
| `open_seatbox` | `scooter:seatbox`: `open` |
| `honk` | `scooter:horn`: `on`, then `off` after `duration` ms |
| `blinker_left/right/both/off` | `scooter:blinker` |
| `dashboard_on/off`, `engine_on/off`, `handlebar_lock/unlock` | `scooter:hardware` |
| `reboot`, `hibernate`, `hibernate_manual` | `scooter:power` |
| `alarm_arm/disarm/enable/disable/stop` | `scooter:alarm` |
| `trip_reset` | `scooter:trip`: JSON `counter.reset` with `source` `uplink` and a ≤60 s deadline (trip-service rejects stale deadlines) |
| `update_check` | `scooter:update:mdb`/`:dbc`: `check-now`; a both-board request collapses to the MDB when `settings[updates.mdb.orchestrate-dbc]` is on |

Additionally: `locate` and `alarm` (parameterized pulse sequences),
`navigate` (writes the `navigation` hash including multi-stop `waypoints`,
published on the `navigation` channel), `config:get/set/del/save` (the
service's own YAML), `keycards:*` (list/add/delete/master key over
`scooter:keycard`, serialized to one request in flight with results
correlated via `keycard[command-result]` and a 5 s timeout), `redis` (raw
Redis commands; disabled by the example config), `restart` (SIGTERM so
systemd respawns the unit), `get_state`, `ping`, and `shell` (development
environment only).

## Connection lifecycle

1. `auth` with `identifier`, `token`, client version, and `protocol_version`
   `0`; the server answers `auth_response`.
2. Reconnects retry after 1 s, doubling up to `reconnect_max_delay`; a
   successful connection resets the delay. Keepalives run in both directions.
3. On every connection-state change the service writes
   `remote-access[uplink-service]` synchronously and mirrors the legacy
   `internet[unu-cloud]` field; startup and shutdown write `disconnected`.
   The legacy field is diagnostic only — consumers should derive reachability
   from the `remote-access` provider fields.
4. Server messages: `auth_response`, `command`, `config_update`
   (YAML deltas for the service's own config; `restart: true` restarts the
   unit), `keepalive`. Client messages: `auth`, `state`, `change`,
   `telemetry_delta`, `telemetry_batch`, `event`, `keepalive`,
   `command_response` — all JSON with RFC3339 UTC timestamps.

See [uplink-server](https://github.com/librescoot/uplink-server) for the
cloud-side protocol and web UI, and
[service-interactions](../service-interactions.md#uplink-service) for the
queue/hash inventory.
