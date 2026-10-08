# BLE File Transfer

The file service transfers named artifacts between a BLE client and
bluetooth-service. It is separate from [firmware OTA](ota-transfer.md): file
uploads do not install firmware or activate maps.

Clients require both `files=1` in `cap:ext` and the GATT characteristics below.
Firmware without the file service is unsupported; the existing OTA service is
not a substitute. Log archives contain sensitive diagnostics.

Public reference implementations:

- [bluetooth-service](https://github.com/librescoot/bluetooth-service),
  `pkg/filetransfer/`.
- [mobile-app](https://github.com/librescoot/mobile-app),
  `packages/scooter_core/lib/src/file_transfer_protocol.dart` and
  `packages/scooter_flutter/lib/file_transfer_client.dart`.

## Transport

UUIDs use base `9a59xxxx-6e67-5d0d-aab9-ad9126b66f91`; service ID is `0600`.
The connection requires encryption with authenticated pairing.

| Characteristic | Properties | Maximum value | USOCK frame |
| --- | --- | --- | --- |
| `0601` data | Write without response, notify | 244 bytes | `0xB3`, both directions |
| `0602` control | Write with response | 128 bytes | `0xB4`, client to service |
| `0603` status | Read, notify | 128 bytes | `0xB5`, service to client |

Subscribe to data and status notifications before sending requests. All integers
are unsigned little-endian. A request starts with
`[operation:u8][version:u8][request:u32][budget:u16]`. Version is `1`; request
IDs are nonzero. Budget is the client's notification/data payload limit,
`20..244` bytes, bounded by ATT MTU minus three.

Names are 1–64 ASCII bytes: initial alphanumeric, subsequent characters
alphanumeric, `.`, `_` or `-`. Paths and hidden staging names are invalid.

## Named stores

| ID | Name | Policy |
| --- | --- | --- |
| `0` | logs | Read-only `.tar.gz` archives in `/data/log-bundles` |
| `1` | inbox | Verified, non-overwriting uploads in `/data/ble-files/inbox` |

`lsc logs` publishes an archive only after closing, syncing and atomically
renaming its staging file. The catalog excludes hidden staging files and
non-regular files; it contains at most 2048 entries, newest first. Files are
limited to 4 GiB. Upload admission reserves a 32 MiB free-space margin.

## Control requests

Layouts below follow the common request header. `name` means
`[store:u8][length:u8][ASCII name]`.

| Operation | Value | Body |
| --- | --- | --- |
| LIST | `1` | `[store:u8][index:u32]` |
| STAT | `2` | `name` |
| PUT | `3` | `name[chunk:u16][size:u64][SHA-256:32]` |
| GET | `4` | `name[chunk:u16][resume offset:u64][SHA-256:32]` |
| COMPLETE | `5` | `[session:u32]` |
| CANCEL | `6` | `[session:u32]` |
| ACK | `7` | `[session:u32][offset:u64][rewind:u8]` |
| STATUS | `8` | `[session:u32]` |

LIST index zero creates a catalog snapshot. Continue using the returned index,
same request ID and store. Snapshots expire after one minute.

STAT returns size and SHA-256. GET supplies that hash to reject changed files.
Chunk size is at most `budget - 12`. Sessions use the START request ID for
subsequent control messages. CANCEL with session zero also cancels a matching
request before START completes, including hashing.

## Responses

Status notifications contain fragments:
`[request:u32][sequence:u32][offset:u16][total:u16][body fragment]`.
Each response body is at most 256 bytes. Assemble only contiguous fragments
with matching request and sequence; never combine different responses.

| Kind | Value | Complete body |
| --- | --- | --- |
| LIST | `0x81` | `[kind][0][next:u32][size:u64][mtime:u64][name length:u8][name]` |
| LIST end | `0x81` | `[kind][1]` |
| STAT | `0x82` | `[kind][0][size:u64][SHA-256:32]` |
| START | `0x83` | `[kind][0][session:u32][offset:u64][size:u64][chunk:u16][window:u16][SHA-256:32]` |
| ACK | `0x84` | `[kind][session:u32][offset:u64][rewind:u8]` |
| COMPLETE | `0x85` | `[kind][0]` |
| CANCEL | `0x86` | `[kind][0]` |
| ERROR | `0x87` | `[kind][code:u8]` |

`mtime` is Unix time in seconds. Error codes are invalid request `1`, not found
`2`, busy `3`, denied `4`, insufficient space `5`, changed identity `6`,
integrity failure `7`, I/O failure `8`, and invalid session `9`.

## Data, resume and completion

Data values are `[session:u32][offset:u64][bytes]`. Send no more than the
negotiated window of unacknowledged chunks; the service advertises eight.
Offsets are cumulative. A gap requires rewinding to the receiver's acknowledged
offset. All chunks except the final chunk have the negotiated size.

PUT resumes a matching name/size/hash staging identity at a chunk-aligned offset.
COMPLETE requires every byte received and verifies SHA-256 before publication.
Publication never overwrites an existing artifact. Lost successful completion
responses can be replayed for one minute.

GET resumes at the supplied chunk-aligned offset. The client acknowledges only
bytes safely written to its private partial file. After verifying the complete
hash, it sends COMPLETE and publishes its local archive. Corrupted downloads
must not become shareable files.

Cancellation and disconnect keep resumable partials but release active sessions.
Active file operations hold the `ble-files` block inhibitor in `power:inhibits`.
Completion, cancellation and BLE disconnect release it. File transfers and
firmware OTA transfers are mutually exclusive; OTA START reports busy while a
file transfer is active, and file admission reports busy while OTA is active.
