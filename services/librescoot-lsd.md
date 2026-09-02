# librescoot-lsd (lsd)

## Description

The Librescoot Daemon is a web management interface for the scooter. It runs on the MDB, is built from the [lsc repository](https://github.com/librescoot/lsc) (`cmd/lsd`) and installed by the lsc package, and serves an embedded single-page UI plus a small HTTP API over the same Redis interfaces the vehicle services already expose. It adds no Redis contracts of its own.

Pages: dashboard with live vehicle, battery, connectivity, board and fault state and the vehicle commands; a schema-driven settings editor; navigation destination and saved locations; keycard management; a file browser for `/data`; cloud connectivity (Sunshine bootstrap, radio-gaga and uplink-service configs); updates (per-board status, channel, local `.mender` and `.delta` install); Librescoot systemd units; log bundles, journal viewer, map and modem details.

## Command-Line Options

```
  -addr string          HTTP listen address (default "192.168.7.1:8090")
  -redis-addr string    Redis server address (default "localhost:6379")
  -data string          Data directory exposed in the file browser and used for
                        keycard, OTA and log-bundle paths (default "/data")
  -token string         Require this bearer token on every request (default: no auth)
  -sunshine-url string  Sunshine instance for the Cloud page (default "https://sunshine.rescoot.org")
  -version              Print version and exit
```

## Systemd Unit

`librescoot-lsd.service`, MDB only, enabled by default. `After=valkey.service librescoot-netconfig.service`, `Requires=valkey.service`. The binary is `/usr/bin/lsd`.

The default address is the MDB's usb0 address, so reachability follows the usb0 link: the daemon is available while the dashboard is powered or the usb0 gate is held open (`system[usb0-gate]`, `scooter.usb0-policy`). While the address cannot be bound (usb0 down, UMS mode) the daemon retries every five seconds instead of exiting.

## Redis Operations

### Hashes read

`vehicle`, `engine-ecu`, `battery:0`, `battery:1`, `aux-battery`, `cb-battery`, `power-manager`, `power-mux`, `system`, `scooter`, `gps`, `internet`, `modem`, `alarm`, `dashboard`, `keycard`, `navigation`, `ota`, `maps`, `settings`, `version:mdb`, `version:dbc`; the key `settings:schema`; the sets `vehicle:fault`, `engine-ecu:fault`, `battery:0:fault`, `battery:1:fault`; the stream `events:faults`.

### Subscribed channels

The same names as the hashes above plus `keycard:events`. Each notification is turned into one Server-Sent Event carrying the field's new value (or the fault set, or the keycard event), which is how the UI stays live without polling.

### Hashes written

- `settings` - setting writes (`HSET`, or `HDEL` to restore a default), followed by `PUBLISH settings <key>`; saved locations under `dashboard.saved-locations.<id>.*` with `PUBLISH settings dashboard.saved-locations.<id>`
- `navigation` - `latitude`, `longitude`, `address`, `timestamp`, `destination` (all emptied on clear), one `PUBLISH navigation <field>` each, `destination` last

### Lists pushed

| List | Payloads |
|------|----------|
| `scooter:state` | `lock`, `unlock` |
| `scooter:seatbox` | `open` |
| `scooter:horn` | `on`, `off` (a "honk" is `on` followed by `off` after 400 ms) |
| `scooter:blinker` | `off`, `left`, `right`, `both` |
| `scooter:alarm` | `arm`, `disarm`, `stop`, `start:5` |
| `scooter:power` | `run`, `hibernate`, `hibernate-manual`, `hibernate-for:<seconds>`, `hibernate-cancel`, `reboot` |
| `settings:overlay` | `apply:service`, `clear:service` |
| `scooter:keycard` | `add:<uid>`, `remove:<uid>`, `set-master:<uid>`, `learn:start`, `learn:stop`, `learn:master:start`, `learn:master:stop`, `reset`; the daemon waits for `keycard[command-result]` |
| `scooter:update:<board>` | `check-now`, `preview-channel:<channel>`, `update-from-file:<path>#sha256=<hex>` |
| `scooter:hardware` | `dashboard:on`, before copying a DBC update file to the dashboard |

## HTTP API

All routes accept the optional bearer token as `Authorization: Bearer` or `?token=`. State-changing requests carrying a foreign `Origin` or `Sec-Fetch-Site` are rejected.

| Request | Behaviour |
|---|---|
| `GET /` | Embedded UI |
| `GET /api/info` | Version, data directory, Sunshine URL, whether a token is required |
| `GET /api/status` | Snapshot: the hashes above plus the fault sets |
| `GET /api/stream` | Server-Sent Events: a `status` snapshot, then `{h, f, v}` field patches, `{h, f: "fault", set}` fault sets, and `keycard:events` payloads |
| `GET /api/faults`, `GET /api/events` | Fault sets; recent `events:faults` entries |
| `GET /api/settings`, `GET /api/settings/schema`, `PUT /api/settings/set` | Values, schema, validated batch write `{values: {key: value}}` |
| `POST /api/control` | `{action}` from the fixed table above |
| `GET/POST /api/navigation`, `PUT/DELETE /api/navigation/locations` | Destination and saved locations |
| `GET /api/keycards`, `POST /api/keycards/command` | UID lists and `scooter:keycard` commands with their result |
| `GET/PUT/DELETE /api/files`, `POST /api/files/mkdir`, `GET /files/<path>` | File browser under `-data`; folders download as tar |
| `GET /api/cloud`, `POST /api/cloud/bootstrap`, `POST /api/cloud/config` | Identity and service state; Sunshine bootstrap with a bootstrap token; install a pasted config |
| `GET /api/updates`, `PUT /api/updates/upload`, `POST /api/updates/action` | OTA state; stage a `.mender` or `.delta` under `/data/ota/<board>`; check, preview, channel switch, install, delete |
| `GET /api/services`, `POST /api/services/action` | Known units; start, stop, restart, enable, disable |
| `GET/POST /api/system/logs`, `GET /api/system/journal` | Log bundles via `lsc logs`; journal tail per unit or dmesg |

### DBC updates

The DBC's update-service runs on the DBC with its own `/data`. A file uploaded for the DBC is staged on the MDB under `/data/ota/dbc`; on install the daemon powers the dashboard on if needed, copies the file to the DBC's `/data/ota/dbc` through the DBC's data-server on `192.168.7.2:8080`, and queues `update-from-file` with the file's SHA-256 on `scooter:update:dbc`.

## Security

The daemon runs as root and has full control over the scooter. It is meant for the usb0 management network only: bind it there (the default), firewall the port, and set `-token` when the network is shared. There is no TLS.
