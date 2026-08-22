# BLE OTA Firmware Transfer

The BLE OTA transfer lets a phone app push firmware update bundles to the scooter over Bluetooth LE — no cellular connectivity required. It is a windowed, resumable, integrity-checked transfer protocol between the phone app and bluetooth-service, tunneled transparently through the nRF52840.

Updates target one of two components per transfer:

| Component ID | Board | Install path |
|--------------|-------|--------------|
| `0x00` | MDB (main board / middle driver board) | Local update-service via `scooter:update:mdb` |
| `0x01` | DBC (dashboard computer) | Handed off to the DBC over the internal Ethernet link |

## Architecture

```
Phone app ──BLE GATT──> nRF52840 ──UART/USOCK──> bluetooth-service ──> /data/ota staging
 (unustasis)             (tunnel)                  (pkg/ota receiver)         │
                                                                              ├─ MDB: LPUSH scooter:update:mdb  → update-service (mender-update install)
                                                                              └─ DBC: HTTP PUT/scp to 192.168.7.2 → LPUSH scooter:update:dbc
```

The nRF52 holds **no OTA session state**: it forwards characteristic writes verbatim to the iMX6 as raw USOCK frames and relays status frames back as notifications (see [nRF tunnel](#nrf-tunnel)). Windowing, ACKs, resume, and verification are end-to-end between the phone and bluetooth-service.

Reference implementations (kept in sync, with shared golden test vectors):

- Scooter side: bluetooth-service `pkg/ota/` (`protocol.go`, `receiver.go`, `staging.go`, `dbc_handoff.go`)
- Phone side: unustasis `lib/domain/ota_protocol.dart`, `lib/service/ota_transfer_service.dart`
- nRF tunnel: mdb-nrf52 `src/ota_tunnel.c`

## GATT Service (9a590500)

Base UUID `xxxx-6e67-5d0d-aab9-ad9126b66f91`, like all scooter services. All three characteristics require an encrypted, MITM-protected connection (bonded with 6-digit PIN pairing).

| Characteristic | Name | Properties | Max size | Content |
|---------------|------|------------|----------|---------|
| 9a590501 | OTA_DATA | write without response | 244 B | `[offset:u32][chunk ≤ 240 B]` |
| 9a590502 | OTA_CONTROL | write (with response) | 128 B | Control messages (START, COMPLETE, ABORT, STATUS_REQ) |
| 9a590503 | OTA_STATUS | read + notify | 64 B | Status messages (ACKs, install progress, errors) |

Firmware without this service does not support BLE OTA; clients should treat its absence as "feature unavailable".

## nRF Tunnel

The tunnel bypasses the CBOR-based USOCK message convention (see [UART Protocol](../nrf/UART.md)) and uses raw frame IDs to avoid the 128-byte CBOR parameter limit and per-chunk encode/decode cost:

| Frame ID | Direction | Content |
|----------|-----------|---------|
| `0xB0` | nRF → iMX | Verbatim OTA_DATA write value |
| `0xB1` | nRF → iMX | Verbatim OTA_CONTROL write value |
| `0xB2` | iMX → nRF | Verbatim payload, notified on OTA_STATUS |

Tunnel behavior:

- **Link boost:** OTA traffic requests tighter BLE connection parameters; the boost is dropped after ~30 s without OTA writes.
- **Suspend guard:** if the iMX6 is suspended, writes are dropped and an `ERROR` with code `0x01` (suspended) is notified.
- **Overflow guard:** if the USOCK TX ring cannot hold the frame, the write is dropped and `ERROR 0x02` (overflow) is notified. This cannot happen while the phone respects the transfer window; the phone recovers via the receiver's offset-gap REWIND either way.
- Error notifications are rate-limited to one per second; messages from the nRF are at most 16 bytes.

## Wire Format

All multi-byte fields are **little-endian**.

### Phone → scooter (OTA_CONTROL, plus DATA on OTA_DATA)

| Opcode | Message | Layout |
|--------|---------|--------|
| `0x01` | START | `[0x01][version][component][chunk_size:u16][total_size:u32][sha256:32][id_len:u8][bundle_id]` |
| — | DATA (on OTA_DATA) | `[offset:u32][chunk]` |
| `0x03` | COMPLETE | `[0x03]` |
| `0x04` | ABORT | `[0x04][reason]` — `0x00` user cancel, `0x01` app error |
| `0x05` | STATUS_REQ | `[0x05]` — answered with an INSTALL_PROGRESS reflecting the current phase |

START fields:

- `version` — protocol version, must be `1`.
- `component` — `0x00` MDB, `0x01` DBC.
- `chunk_size` — bytes per DATA chunk, `1..240`. Every chunk except the last must be exactly this size (resume offsets are computed in chunk units).
- `total_size` — bundle size in bytes.
- `sha256` — SHA-256 of the complete bundle, raw 32 bytes.
- `bundle_id` — 1–64 chars, first alphanumeric, rest `[A-Za-z0-9._-]` (filename-safe; the ID is used in staging paths). See [Bundle IDs](#bundle-ids).

### Scooter → phone (OTA_STATUS notifications)

| Opcode | Message | Layout |
|--------|---------|--------|
| `0x81` | START_ACK | `[0x81][status][resume_offset:u32][window_chunks:u16][ack_every:u8][max_chunk:u16]` |
| `0x82` | ACK | `[0x82][flags][acked_offset:u32]` |
| `0x83` | COMPLETE_ACK | `[0x83][status]` |
| `0x84` | INSTALL_PROGRESS | `[0x84][phase][percent][msg_len:u8][msg]` |
| `0x85` | ABORT_ACK | `[0x85]` |
| `0x86` | ERROR | `[0x86][code][msg_len:u8][msg]` |

Clients should ignore unknown opcodes for forward compatibility. Messages are at most 60 bytes of text (fits the 64-byte characteristic).

#### START_ACK status codes

| Code | Meaning |
|------|---------|
| `0x00` | Resuming an interrupted transfer at `resume_offset` |
| `0x01` | Fresh transfer from offset 0 |
| `0x10` | Not enough free staging space |
| `0x11` | Busy (reserved — currently a new START replaces an active receive session) |
| `0x12` | Bad parameters (malformed START, unsupported version/component/chunk size) |
| `0x13` | An install is in progress; poll with STATUS_REQ until it reaches a terminal phase |

`window_chunks`, `ack_every`, and `max_chunk` announce the receiver's tuning so the constants live in one place (currently 64, 16, 240). The phone must keep at most `window_chunks` unacknowledged chunks in flight and must not exceed `max_chunk` as chunk size.

#### ACK

Cumulative: `acked_offset` is the number of bytes received in order so far. Flag `0x01` (REWIND) signals an offset gap — the phone must rewind its send position to `acked_offset` (go-back-N). REWINDs are rate-limited to one per 100 ms.

#### COMPLETE_ACK status codes

| Code | Meaning |
|------|---------|
| `0x00` | Hash verified, install queued |
| `0x01` | SHA-256 mismatch (staging discarded — retransfer needed) |
| `0x02` | Size mismatch (COMPLETE before all bytes arrived) |
| `0x03` | Queueing the install failed |

#### INSTALL_PROGRESS phases

| Phase | Meaning |
|-------|---------|
| `0x00` | Verifying (SHA-256 of the staged bundle, or update-service "preparing") |
| `0x01` | Installing (`percent` is install progress 0–100) |
| `0x02` | Pending reboot — install done; the scooter reboots itself after 3 minutes of sustained stand-by |
| `0x03` | Rebooting |
| `0x04` | Success |
| `0x05` | Failure (`msg` carries the error message) |
| `0x06` | Idle (no transfer or install active) |

Phases `0x02`, `0x04`, `0x05` are terminal. The last phase is retained after the install finishes, so a phone that reconnects later can still fetch the outcome via STATUS_REQ.

#### ERROR codes

| Code | Origin | Meaning |
|------|--------|---------|
| `0x01` | nRF | iMX6 suspended, data dropped |
| `0x02` | nRF | USOCK TX ring overflow, data dropped |
| `0x03` | bluetooth-service | Internal error (e.g. chunk overruns declared total) |
| `0x04` | bluetooth-service | Staging write failed (session aborted, staging discarded) |
| `0x05` | bluetooth-service | No staging space |
| `0x06` | bluetooth-service | No active session (e.g. COMPLETE without START) |

## Transfer Lifecycle

1. **START** — the phone sends bundle identity (component, size, SHA-256, bundle ID, chunk size).
2. **START_ACK** — the scooter answers with `resume_offset` (0 for a fresh transfer) and its window tuning. A START while another receive session is active replaces that session.
3. **DATA stream** — the phone writes `[offset][chunk]` frames (write without response), keeping at most `window_chunks` chunks unacknowledged. The scooter appends in-order chunks to the staging file and sends a cumulative ACK every `ack_every` chunks or every 250 ms, whichever comes first. Out-of-order offsets trigger a REWIND ACK.
4. **COMPLETE** — once all bytes are ACKed, the phone sends COMPLETE. The scooter fsyncs, hashes the staged file (an INSTALL_PROGRESS `verifying` is emitted first — hashing a large bundle takes time), renames `.part` to its final name, and queues the install.
5. **COMPLETE_ACK** `0x00` — the install is queued; INSTALL_PROGRESS notifications follow until a terminal phase.

Reference client timeouts (unustasis): 5 s for START_ACK and ACK movement, 30 s for COMPLETE_ACK; an ACK timeout rewinds to the last acked offset; the attempt fails after 30 rewinds. The client picks `chunk_size = min(max_chunk, ATT_MTU − 3 − 4, 240)` and requests a high connection priority for the duration of the transfer.

### Resume

Transfer state survives disconnects, app restarts, and scooter reboots:

- Each transfer stages to `<bundle>.part` plus a JSON **sidecar** recording bundle ID, component, total size, SHA-256, and chunk size.
- A START whose identity matches the sidecar resumes: `resume_offset` is the `.part` size rounded **down to a chunk boundary** (an unsynced tail may be torn after a hard reboot). The staging file is truncated to that offset.
- A START whose identity does not match discards the old partial and starts from zero.
- ABORT (user cancel) keeps the partial file and sidecar for a later resume; only identity mismatch, write failures, and hash mismatch discard staging.
- After 10 minutes without traffic, the receiver releases the session and its power inhibitor but keeps the staging for resume.
- Stale partials untouched for 7 days are cleaned up when space is needed.

## Bundle IDs

The bundle ID both identifies the transfer (resume matching) and names the staged file, so it must be the real asset basename:

- **Full images:** send the filename **stem** (no extension); the scooter appends `.mender` when staging. IDs already ending in `.mender` are used verbatim.
- **Delta bundles:** send the full filename **with** the `.delta` extension; update-service dispatches on the extension to apply the file as a delta.

update-service derives the installed version from the filename, so the name matters beyond identity. Allowed charset: first character alphanumeric, rest `[A-Za-z0-9._-]`, at most 64 bytes; anything else is rejected with START_ACK `0x12` (the ID is joined into filesystem paths, so separators and leading dots must never get through).

## Staging

Bundles stage under `/data/ota/<mdb|dbc>/` — update-service's own download directories — on the persistent data partition:

```
/data/ota/mdb/<bundle>.mender.part   in-flight transfer
/data/ota/mdb/<bundle>.json          sidecar (transfer identity)
/data/ota/mdb/<bundle>.mender        completed, queued for install
```

- The staging file is fdatasync'ed every 256 KiB so resume offsets are honest after a crash.
- A START for a fresh transfer requires the bundle size plus a 32 MiB margin free on `/data`; otherwise START_ACK `0x10` (after a stale-partial cleanup attempt).
- After a **successful MDB full-image install** the `.mender` stays in place: it becomes the base for future delta updates (update-service's retention owns it from there). Deltas, DBC bundles, and failed installs are removed from staging.

## Install

### MDB

The receiver queues `update-from-file:<path>` on the `scooter:update:mdb` Redis list. update-service runs `mender-update install` and reports into the shared `ota` hash (`status:mdb`, `install-progress:mdb`, `error-message:mdb`), which the receiver relays to the phone as INSTALL_PROGRESS notifications (paced to one per 100 ms — the SoftDevice notification queue is shallow). See [update-service](../services/librescoot-update.md).

On `pending-reboot` the transfer is finished from the receiver's perspective: update-service reboots the MDB after 3 minutes of sustained stand-by; no user action is needed beyond leaving the scooter in stand-by.

### DBC handoff

DBC bundles are received on the MDB first, then delivered to the dashboard (same pattern as ums-service's loader):

1. `LPUSH scooter:update start-dbc` — vehicle-service claims the DBC update lock: forces dashboard power on, installs a suspend-only inhibitor, arms a watchdog fed by periodic `start-dbc` heartbeats (every 5 min).
2. Wait for the DBC to become reachable at `192.168.7.2` (it may need to boot; up to 3 min).
3. Transfer the bundle: HTTP PUT to librescoot-data-server on port 8080 (request paths map under the DBC's `/data`), falling back to `scp`.
4. `LPUSH scooter:update:dbc update-from-file:/data/ota/dbc/<bundle>` — the DBC's update-service instance (connected to the MDB's Redis) installs and reports into the shared `ota` hash under `:dbc` fields; progress reaches the phone through the same relay.
5. The update lock is left held: update-service runs its own `start-dbc`/`complete-dbc` cycle around the install; releasing early would let the vehicle state machine cut DBC power mid-install.

On handoff failure the lock is released (`complete-dbc`) and the error is written to the `ota` hash so the phone receives a normal failure notification.

## Power Inhibitor

While receiving and installing, the receiver holds a `block`-type inhibitor (`id: ble-ota`) in the `power:inhibits` hash so pm-service does not suspend or hibernate mid-transfer. It is released when the session goes idle (completion, abort, 10 min transfer idle timeout) and, as a safety net, 30 minutes after an install was queued with no terminal feedback from update-service.

## Redis Status (`ota:ble`)

The receiver mirrors transfer state into the `ota:ble` hash for on-scooter observability:

| Field | Description |
|-------|-------------|
| state | `idle`, `receiving`, `installing` |
| bundle-id | Bundle ID of the active session |
| component | `mdb` or `dbc` |
| received-bytes | In-order bytes received so far |
| total-bytes | Declared bundle size |
| rate-bps | Rolling transfer rate (recomputed ~1/s) |
| updated-at | Unix timestamp of the last update |

Session fields are only present while a session is active.

## Related Documentation

- [Bluetooth Interface](README.md) — all GATT services
- [update-service](../services/librescoot-update.md) — download, delta handling, install, reboot coordination
- [bluetooth-service](../services/librescoot-bluetooth.md) — the service hosting the receiver
- [nRF UART Protocol](../nrf/UART.md) — USOCK framing
