# librescoot-trip (trip-service)

## Purpose and ownership

trip-service records one history entry for an unlocked ride and owns the
vehicle-wide trip counter. It uses `vehicle` state, `engine-ecu` odometer, `gps`, `profile`,
`battery:0`, `battery:1`, and the relevant `settings` fields as inputs. It
writes the `trip`, `trip:counter`, and `trip:expunge` hashes, the
`trip:completed` and `trip:command-result` channels, and the `trip:ready` lease.
It consumes the `scooter:trip` command queue.

The canonical ride lifecycle is:

```
stand-by -> unlock -> parked -> kickstand up -> ready-to-drive -> kickstand down -> parked -> lock -> stand-by
```

`parked` and `ready-to-drive` may repeat before the final lock. `hop-on` and
`hop-on-learning` are parked-equivalent pause states within that same unlocked
ride, never a ride boundary. The history row begins at the first
`ready-to-drive`, pauses duration and GPS collection in every parked-equivalent
state, resumes on each later `ready-to-drive`, and completes only at the final
lock/non-paused state. Thus one history entry spans the first Ready interval
through final lock, rather than one entry per Ready interval.

The counter is not a trip-history summary: it has its own durable state and can
be reset without changing a recorded trip. History includes GPS points and a
profile ID; the counter projection does not. The counter and history use the
same unlock-to-lock ride boundary: with the `ride` reset policy, the counter
resets at the first Ready interval of an unlock session and remains in that
session across every parked-equivalent pause until lock.

All counter distances are integer metres, durations are integer seconds,
`reset-at`, `updated-at`, and expunge timestamps are Unix seconds, and
`average-speed-kmh` is an integer km/h rounded to the nearest km/h. The ECU
odometer is also metres. The counter only includes time in `ready-to-drive`.

## Counter and reset policy

`settings[trip.counter-reset]` is a persistent enum. Its default is `ride`;
valid values are `ride`, `day`, `battery`, and `manual`. settings-service
persists the value and publishes settings changes; trip-service applies a valid
change immediately.

A counter snapshot has a durable generation. Each reset zeros distance and
duration, records its Unix time and reason, and increments the generation.
Possible reasons are `initial`, `ride`, `day`, `battery`, and `manual`.

- **`ride`** resets at the first `ready-to-drive` transition of an unlocked
  ride. `parked`, `hop-on`, and `hop-on-learning` keep that session open, so
  returning to ready-to-drive does not reset it. Locking or another
  non-paused/non-ready state closes the session; the next unlock session's
  first Ready transition starts a new one.
- **`day`** uses the local calendar date. At the start of a new session it
  resets only when the date is strictly later than the stored daily anchor.
  The first trustworthy date establishes the anchor without a reset. A clock
  before 2020, or a date moving backwards, cannot trigger a reset.
- **`battery`** resets when a present, non-empty serial number changes in a
  configured battery slot. Startup values seed the remembered identities;
  removal and reinsertion of the same pack do not reset it. Slot 1 counts only
  while dual-battery mode is enabled. Empty serials and changes in a disabled
  slot do not reset it.
- **`manual`** performs no automatic reset. A manual command is allowed only
  while the counter is idle; it returns `busy` during ready-to-drive.

Negative or backward odometer readings are ignored. The terminal odometer is
read before leaving ready-to-drive when available, so that final distance is
accounted for.

## Recovery and availability

The database is `/data/trips.db`. It is SQLite with WAL journalling, foreign
keys, a five-second busy timeout, one database connection, and incremental
vacuum enabled. Counter state is committed on input changes and checkpointed
at least every 30 seconds and during shutdown.

On restart, trip-service first reads the current odometer and vehicle state,
loads durable counter state, reconciles a nondecreasing current odometer
against the last durable one when applicable, and then synchronizes its
watchers. If Ready is observed before a valid nonnegative odometer, it defers
creating a new history row until the first valid odometer arrives; that value
becomes the trip baseline rather than an unknown zero. It deliberately discards the unavailable wall-time interval: an
active Ready interval resumes from recovery time, not from the last checkpoint.
This avoids inventing riding time after a crash or power loss.

An unfinished history row is handled from the recovered vehicle state. A row
paused in `parked`, `hop-on`, or `hop-on-learning` remains open and paused; a
row recovered in `ready-to-drive` resumes as a new observed Ready interval;
and a row recovered in any other state (including `stand-by`) is abandoned.
The recovered row still belongs to the same unlock-to-lock ride when it remains
open. GPS collection remains paused until a later Ready interval.

`trip:ready` is a liveness lease, not a permanent feature flag. While startup
has completed, its string value is `"1"` with a 90-second TTL; trip-service
refreshes it every 30 seconds and deletes it on orderly shutdown. Its absence
means a caller must treat the current counter interface as unavailable or
stale.

## Redis contract

### `trip:counter` hash

trip-service writes a complete synchronous snapshot. `api-version` must be
`"1"`; a reader that does not understand that version must not interpret the
other fields.

| Field | Type and unit | Values / meaning |
|---|---|---|
| `api-version` | string | `"1"` |
| `distance-m` | integer metres | Counter distance |
| `duration-s` | integer seconds | Durable and currently projected ready-to-drive time |
| `average-speed-kmh` | integer km/h | Counter distance divided by counter duration, rounded; `0` if duration is zero |
| `reset-policy` | enum | `ride`, `day`, `battery`, or `manual` |
| `reset-at` | Unix seconds | Time of the most recent reset or initial state |
| `reset-reason` | enum | `initial`, `ride`, `day`, `battery`, or `manual` |
| `generation` | nonnegative integer | Increments on every reset |
| `status` | enum | `idle` or `recording` (`recording` means ready-to-drive) |
| `updated-at` | Unix seconds | Last durable state update |

### Reset queue and result channel

Producers send compact JSON to the `scooter:trip` Redis list:

```json
{"id":"client-request-id","op":"counter.reset","source":"client-name","expires-at":1700000015000}
```

`id` is required for an accepted reset and is the idempotency key; `source` is
carried by the request but does not alter reset semantics. `expires-at` is a
required Unix-millisecond deadline. It must be in the future and no more than
60 seconds ahead when trip-service receives the command. An already-expired
queued attempt is discarded without executing or publishing a stale correlated
result; a missing or excessively long-lived deadline returns `timeout`. A
deliberate retry may reuse the same ID with a fresh short deadline. The service accepts
only `op: "counter.reset"`. Each non-expired request publishes one correlated
JSON result on `trip:command-result`:

```json
{"id":"client-request-id","op":"counter.reset","status":"ok","error":""}
```

`status` is `ok` or `error`. Errors are `invalid` for malformed or unsupported
requests, `busy` for a reset while recording, `timeout` for an invalid command
deadline, and `internal` when a reset could not be committed. Error text is bounded to 256 bytes. The reset state and its
idempotency record commit in one SQLite transaction. Repeating an ID returns
its recorded outcome; records are retained for 30 days, subject to a 10,000
record safety cap.

For a successful manual reset, trip-service commits the zeroed state before it
publishes the result. It synchronously publishes the new `trip:counter`
snapshot before the success result, so a consumer subscribed before enqueueing
can read the generation associated with that acknowledgement.

## Trip-history retention

`settings[trip.expunge]` is one atomic persistent setting for history
retention; its default is `age:365d`. Its complete transport-safe grammar is:

```text
never
age:<duration>
count:<canonical-nonnegative-signed-int64-decimal>
size:<canonical-nonnegative-signed-int64-decimal>
```

`<duration>` is either a sequence of ASCII Go-style components
`<canonical-integer>[.<digits>]<unit>`, using only `ns`, `us`, `ms`, `s`, `m`,
or `h`, or one canonical integer-day token `Nd`. A parsed component duration
must be 1 through 9223372036854775807 nanoseconds. Integer days are `1d`
through `106751d`; `d` cannot be mixed with any other component. A canonical
nonnegative signed-int64 decimal is `0` or an ASCII decimal integer without a
leading zero, in the inclusive range 0 through 9223372036854775807.

The parser rejects Unicode micro signs (`µ` and `μ`), whitespace, signs,
leading zeroes, zero or sub-nanosecond ages, overflow, malformed or mixed day
units, and trailing junk. The boundary corpus is:

- Valid: `never`, `age:1ns`, `age:1us`, `age:1.5ms`, `age:1h30m`, `age:1d`,
  `age:106751d`, `count:0`, `count:9223372036854775807`, `size:0`, and
  `size:9223372036854775807`.
- Invalid: `age:0`, `age:0ns`, `age:0.5ns`, `age:.5us`, `age:1.s`,
  `age:1µs`, `age:1μs`, `age:106752d`, `age:2562047h47m16.854775808s`, `count:01`, `count:+1`,
  `count:9223372036854775808`, `size:-1`, `size:9223372036854775808`, and
  any value containing whitespace (for example ` age:1s`, `age:1s `,
  `age:1 s`, `count:1\t`, or `size:\n1`).

Production validation is fail-safe. settings-service validates `trip.expunge`
on TOML hydration and live Redis updates. An invalid persisted value is repaired
to the last persisted valid policy, or `never` when none exists, and the repair
is written back once; it refuses to persist an invalid value. Independently, if
trip-service cannot read the setting at startup or receives a malformed stored
value, it fails closed to `never` and reports an expunge error. Only an absent
setting selects the `age:365d` default. A later invalid live update leaves the
last valid in-service policy selected and reports an error.

Expunge runs at startup, after a completed or abandoned trip, and on the
30-second periodic tick. It runs only while no trip is recording. An active
ride is never pruned; a scheduled pass reports `deferred` and waits for an idle
pass. Failures also defer rather than interrupt recording.

Only `completed` and `abandoned` trips are eligible. Deletion is oldest first,
in batches of at most 100, and foreign-key cascade deletes their GPS points.
`age` requires a trustworthy wall clock (Unix time no earlier than 2020);
otherwise it defers without deleting history. `count` keeps the newest N
eligible trips.

For `size`, the measured limit is SQLite page storage plus the WAL. Before it
deletes any history, each pass attempts bounded pre-reclamation: a truncating
WAL checkpoint followed by at most 100 incremental-vacuum pages. It then
removes at most 100 eligible oldest rows and repeats that bounded reclamation.
Consequently one pass need not reach the requested size (there may be no
eligible rows, active rows are protected, SQLite may retain free pages, or the
checkpoint may be busy); later idle passes retry. A legacy database without
incremental auto-vacuum is not size-pruned until its one-time migration sets
incremental mode and runs `VACUUM`. That migration is started only while idle
and is cancelable when Ready begins, without holding ride startup; cancellation
or failure defers the pass and a later idle pass retries it. It never deletes an
active trip, counter state, or reset-command idempotency records.

### `trip:expunge` hash

| Field | Type | Meaning |
|---|---|---|
| `api-version` | string | `"1"` |
| `policy` | enum | `never`, `age`, `count`, or `size` |
| `value` | string | Policy operand (`365d`, duration, count, or bytes); empty for `never` |
| `status` | enum | `idle`, `running`, `deferred`, or `error` |
| `last-run` | Unix seconds | Most recent successful pass |
| `last-error` | string | Most recent policy or run error, bounded to 256 bytes |
| `deleted-trips` | integer | Trips deleted by the latest pass |
| `db-bytes` | integer bytes | Latest SQLite main database storage measurement |
| `wal-bytes` | integer bytes | Latest WAL file storage measurement |
| `updated-at` | Unix seconds | Publication time |

Retention deletes local completed/abandoned history and their saved points; it
is not a counter reset and does not erase data outside this database. Conversely,
resetting the counter never deletes trip-history rows or GPS points.

## Privacy and access limits

The counter and Bluetooth trip response intentionally contain no GPS trace,
trip-history record, or profile ID. `trip:counter` is a vehicle-wide display
counter, not an access-controlled per-rider record. Redis access is trusted
local infrastructure, and anyone with that access can read its hashes or send
its queue commands.

The Bluetooth extended-command characteristics require an encrypted,
MITM-protected bonded connection. There is no per-phone authorization layer:
any bonded phone that can use extended commands can read the counter, request a
manual reset, and use writable generic settings, including the counter policy
and retention setting. BLE does not provide trip-history or GPS-trace queries.
