# librescoot-events (event-service)

## Description

event-service turns existing Redis traffic into a normalised event bus and
runs user-defined rules against it. It has two halves:

- An **adapter** that watches a fixed set of hashes and channels other
  services already write to, and derives `topic`/`from`/`to` events from the
  transitions it sees there (vehicle state, seatbox, kickstand, handlebar
  lock, blinkers, battery presence and charge, alarm status, power state,
  OTA status, keycard auth, motion detection, incoming SMS, dashboard
  readiness, and button gestures). It writes nothing to those hashes and
  derives no state of its own; it only observes and republishes.
- A **rules engine** that lets a user attach one or more actions, run in
  sequence, to any event topic, entirely from TOML files, with no service of
  their own to write or deploy.

With no rules loaded, there is no additional `ev:*` subscription. The adapter,
worker pool, scheduler and periodic statistics publisher still run.

## Version

Packaged for MDB nightly builds ahead of Librescoot 1.4.0; not included in
1.3.1 stable. Source: [event-service](https://github.com/librescoot/event-service).
The image's build revision determines the installed version.

## Command-Line Options

```
--redis <addr>               Datastore address (default: localhost:6379)
--log-level <level>          debug, info, warn, error (default: info)
--rules-dir <path>           Directory of rule TOML files (default: /data/extensions)
--workers <n>                Action worker count (default: 2)
--queue <n>                  Action queue depth (default: 256)
--replay-window <duration>   How far past due a recorded step may be and still
                              run at start (default: 5m). Zero or less replays
                              only steps still in the future.
--stats-interval <duration>  How often the extensions hash counters are
                              refreshed (default: 10s). A non-positive value
                              logs a warning and falls back to the default.
```

`--log-level` is parsed and printed at startup but does not currently gate
anything: every log line, including the ones prefixed `debug:`, is written
regardless of the flag's value.

A missing `--rules-dir` is not an error; it is the normal state of a scooter
with no extensions installed.

## Redis Operations

### Stream: `events`

Every event the adapter derives is appended here. Rules do not publish new
events; they only act on the ones already on the bus. The stream is trimmed
approximately to 2000 entries (`MAXLEN ~`). Each entry has two fields:
`topic` (the topic string) and `e` (the JSON event envelope).

```bash
redis-cli xrevrange events + - COUNT 10
```

### Pub/Sub: `ev:<topic>`

Every event on the stream is also published on a channel named `ev:` plus
its topic, so a consumer can subscribe to exactly the topics it needs instead
of tailing the whole stream.

```bash
redis-cli psubscribe 'ev:*'
redis-cli psubscribe 'ev:alarm.*'
```

event-service itself subscribes only to the `ev:` patterns at least one
loaded, enabled rule's `on` or `cancel-on` actually names. Rules are read
once, at startup, and the subscription set is computed from them there and
then; there is no reload and no signal that rereads them, so a change under
`--rules-dir` takes effect at the next service restart. With zero rules
loaded there is no rule subscription at all. Rules do not read the stream to
catch up: triggers missed during downtime or a disconnected subscription are
not replayed. Durable pending-step recovery is separate.

### Hash: `extensions`

Rule-engine counters, refreshed at `--stats-interval`. An asynchronous initial
publication writes all fields individually, so early reads can see missing or
partial data. After that, only changed fields are written; failed writes are
retried on a later tick. These are polled hashes, with no change publication.
Counters reset on service restart.

| Field | Meaning |
|---|---|
| `rules` | how many rules compiled and are currently live |
| `dispatched` | actions handed to a worker since start |
| `dropped` | actions the worker pool refused because its queue was full or it was shutting down; the operator's lever is `--workers` / `--queue` |
| `refused` | triggers a `queue`-concurrency rule turned away because that rule's own backlog (capped at 8) was already full; the lever is that rule's own sequence, not the worker pool |
| `failed` | actions that ran and returned an error |
| `pending` | timers armed right now: steps waiting out an `after`, gaps between `repeat` passes, and `debounce` quiet windows. Observability only; a fire leaves the count the moment it is claimed, so `0` does not mean nothing is in flight |
| `runs-active` | sequence runs part-way through their steps, including ones parked on a timer. A trigger sitting in a `queue` backlog has not started and is not counted here |
| `version` | build version; constant for the life of the process |

`dropped` and `refused` are two different failure modes and are kept as
separate fields on purpose: one is the shared worker pool running out of
room, the other is one rule's own backlog filling up, and they point at
different fixes.

### Hash: `extensions:pending`

One field per waiting durable step, keyed by an internal run id, JSON-encoded.
There is no sweep and no expiry: a record is written when a durable step is
scheduled and retained through worker queuing until the action starts, or
removed when its pending tail is cancelled. This is service-restart recovery
in Valkey, not an on-disk store or a vehicle-reboot guarantee.
See [Durability](#durability) below for what ends up in it and when it is
dropped instead of replayed.

## Event Envelope

```json
{
  "id": "1712345678901-0",
  "ts": 1712345678901,
  "topic": "battery.charge.changed",
  "src": "adapter",
  "from": "52",
  "to": "51",
  "data": {"slot": 0}
}
```

The stream entry ID is assigned by the datastore on append. The channel JSON
contains that ID, so adapter events received by rules also populate `LS_ID`.
The stream's `e` JSON was encoded before ID assignment; use the outer stream
entry ID when reading it. `from`/`to` are top-level fields because "changed
from X to Y" is the shape most rules match on. `src` is `adapter` for everything event-service derives itself.

## Adapter Topics and Sources

All derived events have `src = "adapter"`. The adapter watches the hashes
below and three raw channels: `input-events`, `motion:interrupt`, and
`sms:received`. Startup seeding emits no events; repeated hash values are
suppressed. Most hash transitions require a non-empty previous value.
Raw channel events have no `from`/`to` transition.

| Redis source | Derived topics | Condition / extra `data` |
|---|---|---|
| `vehicle[state]` | `vehicle.state.changed` | Every observed transition with a known previous state |
| `vehicle[state]` | `vehicle.unlocked`, `vehicle.locked` | `stand-by` → `parked`; any transition to `stand-by`, respectively |
| `vehicle[state]` | `ride.started`, `ride.ended` | Entering / leaving `ready-to-drive` |
| `vehicle[state]` | `vehicle.hibernating` | Entering the `waiting-hibernation*` family from outside it |
| `vehicle[seatbox:lock]` | `vehicle.seatbox.opened`, `vehicle.seatbox.closed` | `open` / any other value |
| `vehicle[kickstand]` | `vehicle.kickstand.up`, `vehicle.kickstand.down` | `up` / any other value |
| `vehicle[handlebar:lock-sensor]` | `vehicle.handlebar.locked`, `vehicle.handlebar.unlocked` | `locked` / any other value |
| `vehicle[blinker:switch]` | `vehicle.blinker.changed` | Switch value changed |
| `battery:0`, `battery:1` (`present`, `state`, `charge`) | `battery.inserted`, `battery.removed`, `battery.state.changed`, `battery.charge.changed` | Presence `true` / any other value; numeric `data.slot` is 0 or 1; new charge must parse as an integer |
| `aux-battery[charge]`, `cb-battery[charge]` | `aux.charge.changed`, `cbb.charge.changed` | New charge must parse as an integer; no slot |
| `alarm[status]` | `alarm.status.changed`, `alarm.armed`, `alarm.disarmed`, `alarm.triggered` | Complete change plus named event for `armed`, `disarmed`/`disabled`, or a `-triggered` suffix; triggered `data.level` is 1, 2, or 0 for an unrecognised level |
| `power-manager[state]` | `power.state.changed` | State transition |
| `power-manager[wakeup-source]` | `power.wake` | Changed source also in `data.source` |
| `internet[connectivity]` | `net.connectivity.changed` | Connectivity transition |
| `ota[status:<component>]` | `ota.status.changed` | `data.component` is the field suffix |
| `keycard[authentication]` | `keycard.auth.passed`, `keycard.auth.failed` | New value `passed` / `failed`; optional `data.uid`, `data.type` read live from the hash |
| `dashboard[ready]` | `dashboard.ready` | New value `true` |
| `input-events` | `button.<source>.<gesture>` | Source colons become dots, e.g. `brake:left:hold` → `button.brake.left.hold` |
| `motion:interrupt` | `motion.detected` | Original payload string in `data.raw` |
| `sms:received` | `sms.received` | Original payload string in `data.raw`, not flattened SMS fields |

Accepted gestures are `press`, `release`, `tap`, `long-tap`, `hold`, and
`double-tap`. The adapter does not subscribe to raw `buttons`, `motion:sensors`,
`motion:heading`, or `gps:tpv`. No ECU-fault, GPS-fix, settings-change,
system-boot/shutdown, or named OTA-available/installed events are derived by
these adapters. A single state transition can emit several named topics.

Hash notifications carry field names, not a snapshot of each value. Rapid
producer updates can overwrite an intermediate value before the adapter reads
it, so this bus is not an authoritative record of every vehicle transition.

## Rules

TOML files under `--rules-dir`, one or more `[[rule]]` blocks per file,
loaded and compiled at startup. A file that fails to parse, or that contains
a key nothing recognises, is rejected file by file: the rest still load,
because losing every rule over one typo in one file is worse than running a
subset.

```toml
[[rule]]
name        = "hazards-on-alarm"
on          = ["alarm.triggered"]
concurrency = "restart"
cancel-on   = ["alarm.disarmed"]

  [[rule.step]]
  do   = "redis"
  list = "scooter:blinker"
  push = "both"

  [[rule.step]]
  after = "30s"
  do    = "redis"
  list  = "scooter:blinker"
  push  = "off"
```

On the alarm, the first step requests hazards on and the delayed step requests
off. `alarm.disarmed` cancels the pending tail, including that off step; it
does not undo the earlier on command. To request off on disarm, add a separate
rule:

```toml
[[rule]]
name = "hazards-off-on-disarm"
on = ["alarm.disarmed"]

  [[rule.step]]
  do = "redis"
  list = "scooter:blinker"
  push = "off"
```

This is not an ordering guarantee across rules or against other command
producers. Already accepted jobs are not interrupted and can overlap this
rule's off action; cancellation alone cannot guarantee that hazards stop.

`on` matches a topic exactly, with `*` for everything or `prefix.*` for
anything starting with `prefix.`. Mid-pattern globs are not supported: a
pattern matches literally or not at all, so a typo in a topic name fires
nothing rather than something unintended. `when`, at rule level or step
level, is an `expr` expression compiled once at load, evaluated against
`topic`, `src`, `from`, `to`, `data`, and `state("hash", "field")` for the
last value event-service's own shadow store observed for a hash field the
event itself does not carry. Watched hashes are seeded by `StartWithSync()`
using `HGETALL` at startup without emitting transitions. Later hash
notifications update the store; writes without notifications can leave it
stale. Missing or unwatched fields return `""`, indistinguishable from an
empty value. `state()` does not read Valkey live.

A rule with no `when` fires on every event `on` matches; a step with no `when`
always runs once reached. A false step condition ends the run, not just that
step. It is checked before submission, which may precede execution in a busy
worker pool.

### Step sequences

A rule can carry several `[[rule.step]]` blocks. They run strictly in order:
a step is submitted only once the one before it finished, and a step that
fails ends the run, with the remaining steps not run. A sequence is a recipe,
so carrying on past a failed step would act on a state that step never
established.

A step may carry `after`, a non-negative duration that delays it relative to
the previous step finishing (or the run starting for the first step).
An omitted or zero `after` is submitted without a timer delay when reached.
A step waiting out `after` holds no worker thread; it sits on a scheduler
timer, so a rule can say "and thirty seconds later, turn it off" without
occupying a worker for the wait.

### Durability

A step with a positive `after` is `durable` by default. The waiting step is
written to `extensions:pending` when scheduled and removed when its action
starts or its pending tail is cancelled. Recovery covers an event-service
restart while Valkey retains the hash; it does not guarantee survival across
a datastore restart or vehicle reboot. The image's Valkey configuration
disables RDB and AOF disk persistence.

At startup, overdue records are submitted and future timers rearmed before
the rule subscription opens. This does not wait for replayed actions to
complete. A rule with `repeat` resumes on the pass it was on.

This is not exactly-once execution. A record-write failure is logged, but the
step still runs without restart recovery. A failed record deletion can cause
another execution on restart; a crash after deletion but before successful
action completion can lose the action. There is no guarantee that a sequence
finishes or restores a safe vehicle state.

A record is dropped instead of replayed, with a log line saying why, if its
rule is no longer loaded, if that rule no longer has a step at the recorded
index, if the step at that index was reconfigured while the service was
down, if it is more than `--replay-window` (default 5 minutes) past due, or
if it is dated further ahead than the step's own `after` could ever put it,
which is what a clock that ran backwards over the restart leaves behind.
Editing rule files while the service is down is expected: a record
identifies its step by what that step was configured to do, not just its
position, so reordering or rewriting steps drops the stale record instead of
firing whatever now sits at the same index. A replay window of zero or less
replays only what is still in the future, so a scooter that was off for a
week does not come back up acting on what it was doing when it went down.

Records go through the rule's `concurrency` policy the same way a live
trigger does, so a rule that ends up with two records resumes one run rather
than two. A step that comes due while the action pool has no room for it
keeps its record for a later startup, subject to the replay checks above.
The same holds for a queued step abandoned without starting when the service
stops; there is no automatic retry during the current run.

Write `durable = false` on a delayed step to opt out. Specifying `durable`
without a positive `after` (including `after = "0s"`) is a load error.
Nothing is recorded for a gap between completed `repeat` passes or for a
trigger sitting in a `queue` backlog; these are lost on restart.

### Concurrency and cancellation

`concurrency` decides what a fresh trigger does to a run of the same rule
that has not finished:

- `restart` (default): drop the pending tail of the live run and start over.
- `drop`: ignore the trigger while a run is live; the rule fires normally
  again once that run ends.
- `queue`: hold the trigger and run the sequence again once the live run has
  finished, so runs go back to back rather than side by side. The backlog is
  capped at 8 per rule; anything past that is refused, counted in `refused`,
  and logged.

`cancel-on` takes topics in the same form as `on`. A matching event drops
every live run of that rule: pending timers are cancelled, the queued
backlog is thrown away, and no further step is submitted. It is applied
before matching, so one event can cancel one rule and fire another in the
same pass.

A step already handed to the worker pool when the cancel arrives is **not**
interrupted, whether a worker is already running it or it is still waiting
its turn in the pool's queue. A `redis` push or `exec` command already
accepted is not cancelled by this event (it can still fail or be stopped by
service shutdown). Cancellation prevents submission of its remaining tail.

### Repeat

`repeat = { count = 3, every = "700ms" }` at rule level runs the whole step
sequence again once it finishes, `count` times total, waiting `every`
between one pass ending and the next starting. With no `repeat` key, or
`count = 1`, a rule runs a single pass. `every` only has to be set, and only
has to be positive, once `count` is greater than 1. The gap between passes is
not durable, only a step's own `after` is: a restart during the gap simply
ends the run on the pass it had reached.

### Cooldown and debounce

`cooldown` (a duration) is a leading-edge suppressor: the first event of a
burst fires the rule immediately, and any further match within the window is
ignored outright.

`debounce` (a duration) is a trailing edge: nothing fires while matching
events keep arriving, each one restarting the window, and once the window
elapses without another match the rule fires exactly once, carrying the most
recent event seen rather than the one that opened the window.

They compose rather than conflict. With both set, `cooldown` is checked
against the debounced dispatch itself, not against each event that only
restarted the quiet window, so a burst that never goes quiet long enough to
satisfy `debounce` never reaches `cooldown` at all.

### Naming and load errors

A rule's `name` must be unique across every file in the directory: it is the
handle a rule's runs, concurrency policy and `cancel-on` list are grouped
under, so two rules sharing one name would fight over all three. The second
definition of a name fails to load with an error naming both files; the
rest of both files still load. A disabled rule (`enabled = false`) claims no
name, and neither does a rule that fails to compile, so an old copy kept
around under `enabled = false` while a variant is tried, or a fix landing
under the name a broken rule already failed to claim, both work as expected.

`can`, `lua` and `http` step kinds are not supported yet; a rule naming one
fails to load. An unrecognised `concurrency` value is rejected the same way,
naming the rule, the file, and the three accepted values.

## Actions

- `redis`: `LPUSH` a fixed value (`push`) onto a list (`list`), creating it
  if absent.
  One datastore round trip, no process spawned; the default choice for
  anything that stays on the vehicle.
- `exec`: run the executable name or path in `command` with a `timeout`
  (default `10s`). It is not a shell command line: arguments, pipelines and
  redirection require an executable wrapper script. The event is on
  stdin as JSON, plus environment variables `LS_TOPIC`, `LS_SRC`, `LS_FROM`,
  `LS_TO`, `LS_ID`, and one `LS_DATA_<KEY>` per scalar `data` field, so a
  short shell script needs no JSON parser. The command runs in its own
  process group; the hard timeout kills the whole group, not just the
  direct child.
- `can`, `lua`, `http`: unsupported; a rule using one fails to load.

## Safety

There is no allowlist, no rate limit, and no interlock on what a rule can
do. A `redis` step can push onto `scooter:state`, `scooter:horn`,
`scooter:blinker`, `scooter:seatbox`, or any other command queue, exactly as
freely as vehicle-service's own legitimate callers can. Two rules can watch
each other's output topics and cycle a command back and forth indefinitely,
including through the steering lock; nothing here detects or breaks that
loop. The extension subsystem is a power-user feature by design, and it is
deliberately not event-service's job to second-guess what a rule tells the
vehicle to do.

Durability extends the same stance across a service restart. A step with a
positive `after` can resume on the next start if its record survives, so a rule
nobody retriggered this session, left waiting from before the restart, can
still push to a command queue once the service is back up, with nothing in
between that the rider watching the vehicle now would connect to it. That is
intentional: durability exists so a sequence that already told the vehicle
to do half of something finishes the other half, and there is no separate
check asking whether it still should. Do not write an `after` step onto a
command queue that should not fire from something that happened before the
current rider ever saw the vehicle.

## Installation

**Unit file:** `librescoot-events.service`

```ini
[Unit]
Description=Librescoot Event Service
After=valkey.service
Wants=valkey.service
RequiresMountsFor=/data

[Service]
Type=simple
ExecStart=/usr/bin/event-service \
    --redis=localhost:6379 \
    --log-level=info
Restart=always
RestartSec=5
User=root

Nice=5
CPUWeight=20
MemoryMax=48M
TasksMax=64

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

The resource limits and priorities (`Nice`, `CPUWeight`, `MemoryMax`,
`TasksMax`) reduce contention; they are not isolation or a guarantee against
starving other services. In this unit, `exec` runs as root with the service's
privileges. Treat rule files and scripts as trusted administrative code;
these settings do not prevent unsafe commands or Redis flooding.
`--rules-dir` is not passed, so `/data/extensions` applies. The mount dependency
ensures `/data` is available before startup.

## Dependencies

- **Redis (valkey)** - for the event stream, the `ev:*` channels, the
  `extensions` and `extensions:pending` hashes, and reading the hashes the
  adapter watches.
- **Whatever command list a rule's `redis` step targets** - the
  rules engine does not own those queues; it pushes onto them the same way
  any other client would.

## Related Documentation

- [Redis Operations](../redis/README.md) - datastore conventions this
  service follows
- [Librescoot Services](README.md) - service overview
